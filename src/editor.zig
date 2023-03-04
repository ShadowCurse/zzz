const std = @import("std");
const Allocator = std.mem.Allocator;
const String = std.ArrayList(u8);
const Rows = std.ArrayList(EditorRow);

const Row = @import("row.zig");
const Key = @import("key.zig");
const Syntax = @import("syntax.zig");

const EditorRow = Row.EditorRow;
const EditorSyntax = Syntax.EditorSyntax;
const HLDB = Syntax.HLDB;

/// Cursor x position in characters
cx: u32,
/// Cursor y position in characters
cy: u32,
/// Offset of row displayed
rowoff: u32,
// Offset of column displayed
coloff: u32,
/// Number dkjfbnk;djfof rows that we can show
screenrows: u32,
/// Number of cols that we can show
screencols: u32,
/// Terminal raw mode
rawmode: bool,
/// Rows
rows: Rows,
/// File modified but not saved
dirty: bool,
/// Currently open filename
filename: ?[]u8,
statusmsg: [80]u8,
statusmsg_time: u64,
/// Current syntax highlight
syntax: ?*const EditorSyntax,
allocator: Allocator,

const Self = @This();

pub fn new(allocator: Allocator) !Self {
    return Self{
        .cx = 0,
        .cy = 0,
        .rowoff = 0,
        .coloff = 0,
        .screenrows = 0,
        .screencols = 0,
        .rawmode = false,
        .rows = try Rows.initCapacity(allocator, 0),
        .dirty = false,
        .filename = null,
        .statusmsg = undefined,
        .statusmsg_time = 0,
        .syntax = null,
        .allocator = allocator,
    };
}

pub fn updateSize(self: *Self, rows: u32, cols: u32) void {
    self.screenrows = rows;
    self.screencols = cols;
}

// Select the syntax highlight scheme depending on the filename,
// setting it in the global self E.syntax.
pub fn selectSyntaxHighlight(self: *Self, filename: []u8) void {
    for (HLDB) |s| {
        for (s.extensions) |ext| {
            if (std.mem.endsWith(u8, filename, ext))
                self.syntax = &s;
            return;
        }
    }
}

// Insert the specified char at the current prompt position.
fn insertChar(self: *Self, c: u8) void {
    var filerow = self.rowoff + self.cy;
    var filecol = self.coloff + self.cx;
    // If the row where the cursor is currently located does not exist in our
    // logical representaion of the file, add enough empty rows as needed.
    while (self.rows.items.len <= filerow) {
        self.insertRow(self.rows.items.len, "");
    }
    const row = &self.rows.items[filerow];
    row.insertChar(filecol, c);
    // fix cursor
    if (self.cx == self.screencols - 1) {
        self.coloff += 1;
    } else {
        self.cx += 1;
    }
    self.dirty = true;
}

// Delete the char at the current prompt position.
fn delChar(self: *Self) void {
    var filerow = self.rowoff + self.cy;
    var filecol = self.coloff + self.cx;

    if (filerow >= self.rows.items.len or (filecol == 0 and filerow == 0)) {
        return;
    }

    const row = &self.rows.items[filerow];

    if (filecol == 0) {
        // Handle the case of column 0, we need to move the current line
        // on the right of the previous one.
        self.rows.items[filerow - 1].appendSlice(row.chars.items);
        const delited_row = self.rows.orderedRemove(filerow);
        delited_row.deinit();

        if (self.cy == 0) {
            self.rowoff -= 1;
        } else {
            self.cy -= 1;
        }
        self.cx = filecol;
        if (self.cx >= self.screencols) {
            var shift = (self.screencols - self.cx) + 1;
            self.cx -= shift;
            self.coloff += shift;
        }
    } else {
        row.deleteChar(filecol - 1);
        if (self.cx == 0 & &self.coloff) {
            self.coloff -= 1;
        } else {
            self.cx -= 1;
        }
    }
    self.dirty = true;
}

/// Inserting a newline is slightly complex as we have to handle inserting a
/// newline in the middle of a line, splitting the line as needed.
fn insertNewline(self: *Self) void {
    const filerow = self.rowoff + self.cy;
    const filecol = self.coloff + self.cx;

    if (filerow >= self.rows.items.len) {
        if (filerow == self.rows.items.len) {
            try self.insertRow(filerow, "");
        }
    } else {
        var row = &self.rows.items[filerow];
        // If the cursor is over the current line size, we want to conceptually
        // think it's just over the last character.
        if (filecol >= row.chars.len) filecol = row.size;
        if (filecol == 0) {
            try self.insertRow(filerow, "");
        } else {
            // We are in the middle of a line. Split it between two rows.
            try self.insertRow(filerow + 1, row.chars[filecol..]);
            self.rows.items[filerow].resize(filecol);
        }
    }
    // fix cursor position
    if (self.cy == self.screenrows - 1) {
        self.rowoff += 1;
    } else {
        self.cy += 1;
    }
    self.cx = 0;
    self.coloff = 0;
}

/// Insert a row at the specified position, shifting the other rows on the bottom
/// if required.
fn insertRow(self: *Self, at: usize, str: []u8) !void {
    if (at > self.rows.items.len)
        return;

    const new_row = try EditorRow.new(str, at, self.syntax, self.allocator);
    try self.rows.insert(at, new_row);

    for (self.rows.items[at + 1 ..]) |r| {
        r.file_index += 1;
    }

    self.dirty = true;
}

// Remove the row at the specified position, shifting the remainign on the
// top.
fn delRow(self: *Self, at: i32) void {
    if (at >= self.rows.len)
        return;

    const row = self.rows.orderedRemove(at);
    row.deinit();

    for (self.rows.items[at..]) |r| {
        r.file_index -= 1;
    }

    self.dirty = true;
}

// This function writes the whole screen using VT100 escape characters
// starting from the logical self of the editor in the global self 'E'.
pub fn refreshScreen(self: *Self, stdio: std.fs.File) anyerror!void {
    var screen_buffer = try String.initCapacity(self.allocator, 0);
    defer screen_buffer.deinit();

    try screen_buffer.appendSlice("\x1b[?25l"); // Hide cursor
    try screen_buffer.appendSlice("\x1b[H"); // Go home
    for (0..self.rows.items.len) |y| {
        const filerow = self.rowoff + y;
        if (filerow >= self.rows.items.len) {
            try screen_buffer.appendSlice("~\x1b[0K\r\n");
            continue;
        }

        const row = &self.rows.items[filerow];
        var remaining_line_width = row.render.items.len - self.coloff;
        var current_color: i32 = -1;
        if (remaining_line_width > 0) {
            if (remaining_line_width > self.screencols) {
                remaining_line_width = self.screencols;
            }
            var chars = row.render.items[self.coloff..];
            var highlight = row.highlight.items[self.coloff..];
            for (0..remaining_line_width) |j| {
                if (highlight[j] == Syntax.HL_NONPRINT) {
                    var symbol: u8 = undefined;
                    try screen_buffer.appendSlice("\x1b[7m");
                    if (chars[j] <= 26) {
                        symbol = '@' + chars[j];
                    } else {
                        symbol = '?';
                    }
                    try screen_buffer.appendNTimes(symbol, 1);
                    try screen_buffer.appendSlice("\x1b[0m");
                } else if (highlight[j] == Syntax.HL_NORMAL) {
                    if (current_color != -1) {
                        try screen_buffer.appendSlice("\x1b[39m");
                        current_color = -1;
                    }
                    try screen_buffer.appendNTimes(chars[j], 1);
                } else {
                    const color = Syntax.syntaxToColor(highlight[j]);
                    if (color != current_color) {
                        var buf: [16]u8 = undefined;
                        _ = try std.fmt.bufPrint(&buf, "\x1b[{d}m", .{color});
                        current_color = color;
                        try screen_buffer.appendSlice(&buf);
                    }
                    try screen_buffer.appendSlice(chars[j .. j + 1]);
                }
            }
        }
        try screen_buffer.appendSlice("\x1b[39m");
        try screen_buffer.appendSlice("\x1b[0K");
        try screen_buffer.appendSlice("\r\n");
    }

    // Create a two rows status. First row:
    try screen_buffer.appendSlice("\x1b[0K");
    try screen_buffer.appendSlice("\x1b[7m");
    // var status: [80]u8 = undefined;
    // var rstatus: [80]u8 = undefined;
    // var len = snprintf(status, sizeof(status), "%.20s - %d lines %s", self.filename, self.numrows); //, self.dirty ? "(modified)" : "");
    // var rlen = snprintf(rstatus, sizeof(rstatus), "%d/%d", self.rowoff + self.cy + 1, self.numrows);
    // if (len > self.screencols) len = self.screencols;
    // screen_buffer.appendSlice(status);
    // while (len < self.screencols) {
    //     if (self.screencols - len == rlen) {
    //         screen_buffer.appendSlice(rstatus);
    //         break;
    //     } else {
    //         screen_buffer.appendSlice(" ");
    //         len += 1;
    //     }
    // }
    try screen_buffer.appendSlice("\x1b[0m\r\n");

    // Second row depends on self.statusmsg and the status message update time.
    try screen_buffer.appendSlice("\x1b[0K");
    // var msglen = strlen(self.statusmsg);
    // if (msglen & &time(NULL) - self.statusmsg_time < 5)
    //     screen_buffer.appendSlice(self.statusmsg); //, msglen <= self.screencols ? msglen : self.screencols);

    // Put cursor at its current position. Note that the horizontal position
    // at which the cursor is displayed may be different compared to 'self.cx'
    // because of TABs
    // var j = 0;
    // var cx = 1;
    // var filerow = self.rowoff + self.cy;
    // var row = if (filerow >= self.numrows) {
    //     null;
    // } else {
    //     &self.row[filerow];
    // };
    // if (row) {
    //     j = self.coloff;
    //     while (j < (self.cx + self.coloff)) : (j += 1) {
    //         if (j < row.size and row.chars[j] == Key.TAB) cx += 7 - ((cx) % 8);
    //         cx += 1;
    //     }
    // }
    // snprintf(buf, sizeof(buf), "\x1b[%d;%dH", self.cy + 1, cx);
    // screen_buffer.appendSlice(buf);
    try screen_buffer.appendSlice("\x1b[?25h"); // Show cursor.
    _ = try stdio.write(screen_buffer.items);
}

// fn find(self: *Self, fd: std.os.fd_t) void {
//     var query: [KILO_QUERY_LEN + 1]u8; // = {0};
//     var qlen = 0;
//     var last_match = -1; // Last line where a match was found. -1 for none.
//     var find_next = 0; // if 1 search next, if -1 search prev.
//     var saved_hl_line = -1; // No saved HL
//     var saved_hl = null;
//
//     // #define FIND_RESTORE_HL do { \
//     //     if (saved_hl) { \
//     //         memcpy(E.row[saved_hl_line].hl,saved_hl, E.row[saved_hl_line].rsize); \
//     //         free(saved_hl); \
//     //         saved_hl = NULL; \
//     //     } \
//     // } while (0)
//
//     // Save the cursor position in order to restore it later.
//     var saved_cx = self.cx;
//     var saved_cy = self.cy;
//     var saved_coloff = self.coloff;
//     var saved_rowoff = self.rowoff;
//
//     while (1) {
//         // editorSetStatusMessage(
//         //     "Search: %s (Use ESC/Arrows/Enter)", query);
//         // editorRefreshScreen();
//         self.refreshScreen();
//
//         var c = readKey(fd);
//         if (c == DEL_KEY or c == CTRL_H or c == BACKSPACE) {
//             if (qlen != 0) {
//                 qlen -= 1;
//                 query[qlen] = '\0';
//             }
//             last_match = -1;
//         } else if (c == ESC or c == ENTER) {
//             if (c == ESC) {
//                 self.cx = saved_cx;
//                 self.cy = saved_cy;
//                 self.coloff = saved_coloff;
//                 self.rowoff = saved_rowoff;
//             }
//             FIND_RESTORE_HL;
//             editorSetStatusMessage("");
//             return;
//         } else if (c == ARROW_RIGHT or c == ARROW_DOWN) {
//             find_next = 1;
//         } else if (c == ARROW_LEFT or c == ARROW_UP) {
//             find_next = -1;
//         } else if (isprint(c)) {
//             if (qlen < KILO_QUERY_LEN) {
//                 query[qlen] = c;
//                 qlen += 1;
//                 query[qlen] = '\0';
//                 last_match = -1;
//             }
//         }
//
//         // Search occurrence.
//         if (last_match == -1) find_next = 1;
//         if (find_next) {
//             var match = NULL;
//             var match_offset = 0;
//             var i = 0;
//             var current = last_match;
//
//             while (i < self.numrows) : (i += 1) {
//                 current += find_next;
//                 if (current == -1) {
//                     current = self.numrows - 1;
//                 } else if (current == self.numrows) current = 0;
//                 match = strstr(self.row[current].render, query);
//                 if (match) {
//                     match_offset = match - self.row[current].render;
//                     break;
//                 }
//             }
//             find_next = 0;
//
//             // Highlight
//             // FIND_RESTORE_HL;
//             if (saved_hl) {
//                 memcpy(E.row[saved_hl_line].hl, saved_hl, E.row[saved_hl_line].rsize);
//                 free(saved_hl);
//                 saved_hl = NULL;
//             }
//
//             if (match) {
//                 erow * row = &E.row[current];
//                 last_match = current;
//                 if (row.hl) {
//                     saved_hl_line = current;
//                     saved_hl = malloc(row.rsize);
//                     memcpy(saved_hl, row.hl, row.rsize);
//                     memset(row.hl + match_offset, HL_MATCH, qlen);
//                 }
//                 self.cy = 0;
//                 self.cx = match_offset;
//                 self.rowoff = current;
//                 self.coloff = 0;
//                 // Scroll horizontally as needed.
//                 if (self.cx > self.screencols) {
//                     var diff = self.cx - self.screencols;
//                     self.cx -= diff;
//                     self.coloff += diff;
//                 }
//             }
//         }
//     }
// }

// Handle cursor position change because arrow keys were pressed.
fn moveCursor(self: *Self, key: Key.Key) void {
    var cursor_row = self.rowoff + self.cy;
    var cursor_col = self.coloff + self.cx;
    var rowlen = 0;
    var current_row = if (cursor_row >= self.rows.len) {
        null;
    } else {
        &self.row[cursor_row];
    };

    switch (key) {
        .ARROW_LEFT => {
            // if cursor at most left position
            if (self.cx == 0) {
                // if there is horizontal offset
                if (self.coloff != 0) {
                    self.coloff -= 1;
                } else {
                    // if there is a row above we set cursor to the ends
                    // of that row
                    if (cursor_row > 0) {
                        self.cy -= 1;
                        self.cx = self.rows[cursor_row - 1].chars.len;
                        // if previous row is too long update the coloff
                        if (self.cx > self.screencols - 1) {
                            self.coloff = self.cx - self.screencols + 1;
                            self.cx = self.screencols - 1;
                        }
                    }
                }
            } else {
                self.cx -= 1;
            }
        },
        .ARROW_RIGHT => {
            // if there cursor is not at the end of the row
            if (current_row and cursor_col < current_row.chars.len) {
                if (self.cx == self.screencols - 1) {
                    self.coloff += 1;
                } else {
                    self.cx += 1;
                }
            } else if (current_row and cursor_col == current_row.chars.len) {
                self.cx = 0;
                self.coloff = 0;
                if (self.cy == self.screenrows - 1) {
                    self.rowoff += 1;
                } else {
                    self.cy += 1;
                }
            }
        },
        .ARROW_UP => {
            if (self.cy == 0) {
                if (self.rowoff) self.rowoff -= 1;
            } else {
                self.cy -= 1;
            }
        },
        .ARROW_DOWN => {
            if (cursor_row < self.numrows) {
                if (self.cy == self.screenrows - 1) {
                    self.rowoff += 1;
                } else {
                    self.cy += 1;
                }
            }
        },
    }
    // Fix cx if the current line has not enough chars.
    cursor_row = self.rowoff + self.cy;
    cursor_col = self.coloff + self.cx;
    current_row = if (cursor_row >= self.numrows) {
        null;
    } else {
        &self.row[cursor_row];
    };
    if (cursor_col > current_row.chars.len) {
        self.cx -= cursor_col - rowlen;
        if (self.cx < 0) {
            self.coloff += self.cx;
            self.cx = 0;
        }
    }
}

// Process events arriving from the standard input, which is, the user
// is typing stuff on the terminal.
// #define KILO_QUIT_TIMES 3
pub fn processKeypress(self: *Self, key: Key.Key) void {
    // When the file is modified, requires Ctrl-q to be pressed N times
    // before actually quitting.
    // static int quit_times = KILO_QUIT_TIMES;
    // const quit_times: u32 = 3;

    switch (key) {
        .ENTER => { // Enter
            self.insertNewline();
        },
        .CTRL_C => { // Ctrl-c
            // We ignore ctrl-c, it can't be so simple to lose the changes
            // to the edited file.
        },
        .CTRL_Q => { // Ctrl-q
            // Quit if the file was already saved.
            // if (self.dirty & &quit_times) {
            //     // editorSetStatusMessage("WARNING!!! File has unsaved changes. "
            //     //     "Press Ctrl-Q %d more times to quit.", quit_times);
            //     quit_times -= 1;
            //     return;
            // }
            // exit(0);
            // break;
        },
        .CTRL_S => { // Ctrl-s
            self.save();
        },
        // .CTRL_F => {
        // editorFind(fd);
        // break;
        // },
        .BACKSPACE, // Backspace
        .CTRL_H, // Ctrl-h
        .DEL_KEY,
        => {
            self.delChar();
        },
        // .PAGE_UP, .PAGE_DOWN => {
        //     if (c == PAGE_UP and self.cy != 0) {
        //         self.cy = 0;
        //     } else if (c == PAGE_DOWN and self.cy != self.screenrows - 1)
        //         self.cy = self.screenrows - 1;
        //
        //     var times = self.screenrows;
        //     while (times != 0) : (times -= 1) {
        //         if (c == PAGE_UP) {
        //             self.moveCursor(ARROW_UP);
        //         } else {
        //             self.moveCursor(ARROW_DOWN);
        //         }
        //     }
        //
        //     break;
        // },
        .ARROW_UP, .ARROW_DOWN, .ARROW_LEFT, .ARROW_RIGHT => {
            self.moveCursor(key);
        },
        .CTRL_L => { // ctrl+l, clear screen
            // Just refresht the line as side effect.
            // break;
        },
        .ESC => {
            // Nothing to do for ESC in this mode.
            // break;
        },
        else => {
            self.insertChar(@enumToInt(key));
        },
    }

    // quit_times = KILO_QUIT_TIMES; // Reset it to the original value.
}

// Load the specified program in the editor memory and returns 0 on success
// or 1 on error.
pub fn editorOpen(self: *Self, filename: []u8) !void {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var index: usize = 0;
    while (in_stream.readUntilDelimiterAlloc(self.allocator, '\n', 1024)) |line| : (index += 1) {
        const row = try EditorRow.new(line, index, self.syntax, self.allocator);
        try self.rows.append(row);
    } else |e| {
        return e;
    }
}

// Save the current file on disk. Return 0 on success, 1 on error.
fn save(_: *Self) void {
    // int len;
    // char *buf = editorRowsToString(&len);
    // int fd = open(E.filename,O_RDWR|O_CREAT,0644);
    // if (fd == -1) goto writeerr;
    //
    // // Use truncate + a single write(2) call in order to make saving
    // // a bit safer, under the limits of what we can do in a small editor.
    // if (ftruncate(fd,len) == -1) goto writeerr;
    // if (write(fd,buf,len) != len) goto writeerr;
    //
    // close(fd);
    // free(buf);
    // E.dirty = 0;
    // editorSetStatusMessage("%d bytes written on disk", len);

    // writeerr:
    //     free(buf);
    //     if (fd != -1) close(fd);
    //     editorSetStatusMessage("Can't save! I/O error: %s",strerror(errno));
    //     return 1;
}
