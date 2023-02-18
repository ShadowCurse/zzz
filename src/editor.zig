const std = @import("std");
const Allocator = std.mem.Allocator;
const String = std.ArrayListUnmanaged(u8);

const Row = @import("row");
const Syntax = @import("syntax");

const EditorRow = Row.EditorRow;
const EditorSyntax = Syntax.EditorSyntax;
const HLDB = Syntax.HLDB;

const Editor = struct {
    cx: u32, // Cursor x position in characters
    cy: u32, // Cursor y position in characters
    rowoff: u32, // Offset of row displayed.
    coloff: u32, // Offset of column displayed.
    screenrows: u32, // Number of rows that we can show
    screencols: u32, // Number of cols that we can show
    rawmode: bool, // Is terminal raw mode enabled?
    rows: ?[]EditorRow, // Rows
    dirty: bool, // File modified but not saved.
    filename: ?[]u8, // Currently open filename
    statusmsg: [80]u8,
    statusmsg_time: u64,
    syntax: ?EditorSyntax, // Current syntax highlight, or NULL.
    allocator: Allocator,

    const Self = @This();

    pub fn new(allocator: Allocator) Self {
        return Self{
            .cx = 0,
            .cy = 0,
            .rowoff = 0,
            .coloff = 0,
            .screenrows = 0,
            .screencols = 0,
            .rawmode = false,
            .rows = null,
            .dirty = false,
            .filename = null,
            .statusmsg = undefined,
            .statusmsg_time = 0,
            .syntax = null,
            .allocator = allocator,
        };
    }

    fn updateSize(self: *Self, rows: u32, cols: u32) void {
        self.screenrows = rows;
        self.screencols = cols;
    }

    // Select the syntax highlight scheme depending on the filename,
    // setting it in the global self E.syntax.
    fn selectSyntaxHighlight(self: *Self, filename: []u8) void {
        for (HLDB) |s| {
            for (s.filename) |extention| {
                if (std.mem.endsWith(u8, filename, extention))
                    self.syntax = s;
                return;
            }
        }
    }

    // Insert the specified char at the current prompt position.
    fn insertChar(self: *Self, c: u8) void {
        var filerow = self.rowoff + self.cy;
        var filecol = self.coloff + self.cx;
        var row = null;
        if (filerow >= self.numrows) {
            row = null;
        } else {
            row = &self.row[filerow];
        }

        // If the row where the cursor is currently located does not exist in our
        // logical representaion of the file, add enough empty rows as needed.
        if (!row) {
            while (self.rows.len <= filerow)
                self.insertRow(self.numrows, "");
        }
        row = &self.row[filerow];
        row.insertChar(filecol, c);
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
        var row = null;
        if (filerow >= self.numrows) {
            row = null;
        } else {
            row = &self.row[filerow];
        }

        if (!row or (filecol == 0 and filerow == 0)) return;
        if (filecol == 0) {
            // Handle the case of column 0, we need to move the current line
            // on the right of the previous one.
            filecol = self.rows[filerow - 1].size;
            self.row[filerow - 1].appendString(row.chars, row.size);
            self.delRow(filerow);
            row = null;
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
            row.delChar(filecol - 1);
            if (self.cx == 0 & &self.coloff) {
                self.coloff -= 1;
            } else {
                self.cx -= 1;
            }
        }
        if (row) row.editorUpdateRow();
        self.dirty = true;
    }

    // Inserting a newline is slightly complex as we have to handle inserting a
    // newline in the middle of a line, splitting the line as needed.
    fn insertNewline(self: *Self) void {
        var filerow = self.rowoff + self.cy;
        var filecol = self.coloff + self.cx;
        var row = null;
        if (filerow >= self.numrows) {
            row = null;
        } else {
            row = &self.row[filerow];
        }

        if (!row) {
            if (filerow == self.numrows) {
                self.insertRow(filerow, "", 0);
                if (self.cy == self.screenrows - 1) {
                    self.rowoff += 1;
                } else {
                    self.cy += 1;
                }
                self.cx = 0;
                self.coloff = 0;
            }
            return;
        }
        // If the cursor is over the current line size, we want to conceptually
        // think it's just over the last character.
        if (filecol >= row.size) filecol = row.size;
        if (filecol == 0) {
            self.insertRow(filerow, "", 0);
        } else {
            // We are in the middle of a line. Split it between two rows.
            self.insertRow(filerow + 1, row.chars + filecol, row.size - filecol);
            row = &self.row[filerow];
            // row.chars[filecol] = '\0';
            row.size = filecol;
            row.updateRow();
        }
        if (self.cy == self.screenrows - 1) {
            self.rowoff += 1;
        } else {
            self.cy += 1;
        }
        self.cx = 0;
        self.coloff = 0;
    }

    // Insert a row at the specified position, shifting the other rows on the bottom
    // if required.
    fn insertRow(self: *Self, at: i32, s: []u8) void {
        if (at > self.rows.len)
            return;
        self.rows = self.allocator.realloc(self.rows, self.numrows + 1);
        if (at != self.rows.len) {
            std.mem.copy(u8, self.rows[at + 1 ..], self.rows[at..]);
            for (self.rows[at + 1 ..]) |row| {
                row.idx += 1;
            }
        }
        self.rows[at].init(s, self.allocator);

        // self.rows[at].size = len;
        // self.rows[at].chars = allocator.alloc(u8, len + 1);
        // std.mem.copy(u8, self.rows[at].chars[0 .. len + 1], s[0 .. len + 1]);
        // self.rows[at].hl = null;
        // self.rows[at].hl_oc = false;
        // self.rows[at].render = null;
        // self.rows[at].rsize = 0;
        // self.rows[at].idx = at;
        self.rows[at].uptade();
        self.dirty = true;
    }

    // Remove the row at the specified position, shifting the remainign on the
    // top.
    fn delRow(self: *Self, at: i32) void {
        if (at >= self.rows.len) return;
        var row = &self.rows[at];
        row.deinit();
        std.mem.copy(self.rows[at .. self.rows.len - at - 1], self.rows[at + 1 .. self.rows.len - at - 1]);
        for (self.rows[at..]) |r| {
            r.idx += 1;
        }
        self.dirty = true;
    }

    // This function writes the whole screen using VT100 escape characters
    // starting from the logical self of the editor in the global self 'E'.
    fn refreshScreen(self: *Self, stdio: std.fs.File) anyerror!void {
        var screen_buffer = String.initCapacity(self.allocator, 0);
        defer screen_buffer.deinit(self.allocator);

        screen_buffer.appendSlice("\x1b[?25l"); // Hide cursor
        screen_buffer.appendSlice("\x1b[H"); // Go home
        for (self.rows) |_, y| {
            var filerow = self.rowoff + y;
            if (filerow >= self.rows.len) {
                screen_buffer.appendSlice("~\x1b[0K\r\n");
                continue;
            }

            var row = &self.rows[filerow];
            var len = row.render.len - self.coloff;
            var current_color = -1;
            if (len > 0) {
                if (len > self.screencols) len = self.screencols;
                var chars = row.render[self.coloff..];
                var highlight = row.highlight[self.coloff..];
                var j: u32 = 0;
                while (j < len) : (j += 1) {
                    if (highlight[j] == Syntax.HL_NONPRINT) {
                        var symbol: u8 = undefined;
                        screen_buffer.appendSlice("\x1b[7m");
                        if (chars[j] <= 26) {
                            symbol = '@' + chars[j];
                        } else {
                            symbol = '?';
                        }
                        screen_buffer.appendSlice(&symbol);
                        screen_buffer.appendSlice("\x1b[0m");
                    } else if (highlight[j] == Syntax.HL_NORMAL) {
                        if (current_color != -1) {
                            screen_buffer.appendSlice("\x1b[39m");
                            current_color = -1;
                        }
                        screen_buffer.appendSlice(chars[j]);
                    } else {
                        var color = Syntax.syntaxToColor(highlight[j]);
                        if (color != current_color) {
                            var buf: [16]u8 = undefined;
                            var fixed_allo = std.heap.FixedBufferAllocator.init(&buf);
                            const alloc = fixed_allo.allocator();
                            _ = try std.fmt.allocPrint(alloc, "\x1b[{d}m", .{color});
                            current_color = color;
                            screen_buffer.appendSlice(buf);
                        }
                        screen_buffer.appendSlice(chars[j .. j + 1]);
                    }
                }
            }
            screen_buffer.appendSlice("\x1b[39m");
            screen_buffer.appendSlice("\x1b[0K");
            screen_buffer.appendSlice("\r\n");
        }

        // Create a two rows status. First row:
        screen_buffer.appendSlice("\x1b[0K");
        screen_buffer.appendSlice("\x1b[7m");
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
        screen_buffer.appendSlice("\x1b[0m\r\n");

        // Second row depends on self.statusmsg and the status message update time.
        screen_buffer.appendSlice("\x1b[0K", 4);
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
        screen_buffer.appendSlice("\x1b[?25h"); // Show cursor.
        try stdio.write(screen_buffer);
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
    fn moveCursor(self: *Self, key: KEY_ACTION) void {
        var filerow = self.rowoff + self.cy;
        var filecol = self.coloff + self.cx;
        var rowlen;
        var row = if (filerow >= self.numrows) {
            null;
        } else {
            &self.row[filerow];
        };

        switch (key) {
            .ARROW_LEFT => {
                if (self.cx == 0) {
                    if (self.coloff) {
                        self.coloff -= 1;
                    } else {
                        if (filerow > 0) {
                            self.cy -= 1;
                            self.cx = self.row[filerow - 1].size;
                            if (self.cx > self.screencols - 1) {
                                self.coloff = self.cx - self.screencols + 1;
                                self.cx = self.screencols - 1;
                            }
                        }
                    }
                } else {
                    self.cx -= 1;
                }
                break;
            },
            .ARROW_RIGHT => {
                if (row and filecol < row.size) {
                    if (self.cx == self.screencols - 1) {
                        self.coloff += 1;
                    } else {
                        self.cx += 1;
                    }
                } else if (row & &filecol == row.size) {
                    self.cx = 0;
                    self.coloff = 0;
                    if (self.cy == self.screenrows - 1) {
                        self.rowoff += 1;
                    } else {
                        self.cy += 1;
                    }
                }
                break;
            },
            .ARROW_UP => {
                if (self.cy == 0) {
                    if (self.rowoff) self.rowoff -= 1;
                } else {
                    self.cy -= 1;
                }
                break;
            },
            .ARROW_DOWN => {
                if (filerow < self.numrows) {
                    if (self.cy == self.screenrows - 1) {
                        self.rowoff += 1;
                    } else {
                        self.cy += 1;
                    }
                }
                break;
            },
        }
        // Fix cx if the current line has not enough chars.
        filerow = self.rowoff + self.cy;
        filecol = self.coloff + self.cx;
        row = if (filerow >= self.numrows) {
            null;
        } else {
            &self.row[filerow];
        };
        rowlen = if (row) {
            row.size;
        } else {
            0;
        };
        if (filecol > rowlen) {
            self.cx -= filecol - rowlen;
            if (self.cx < 0) {
                self.coloff += self.cx;
                self.cx = 0;
            }
        }
    }

    // Process events arriving from the standard input, which is, the user
    // is typing stuff on the terminal.
    // #define KILO_QUIT_TIMES 3
    fn processKeypress(self: *Self, key: Key) void {
        // When the file is modified, requires Ctrl-q to be pressed N times
        // before actually quitting.
        // static int quit_times = KILO_QUIT_TIMES;
        const quit_times: u32 = 3;

        switch (key) {
            .ENTER => { // Enter
                self.insertNewline();
                break;
            },
            .CTRL_C => { // Ctrl-c
                // We ignore ctrl-c, it can't be so simple to lose the changes
                // to the edited file.
                break;
            },
            .CTRL_Q => { // Ctrl-q
                // Quit if the file was already saved.
                if (self.dirty & &quit_times) {
                    // editorSetStatusMessage("WARNING!!! File has unsaved changes. "
                    //     "Press Ctrl-Q %d more times to quit.", quit_times);
                    quit_times -= 1;
                    return;
                }
                exit(0);
                break;
            },
            .CTRL_S => { // Ctrl-s
                self.save();
                break;
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
                break;
            },
            .PAGE_UP, .PAGE_DOWN => {
                if (c == PAGE_UP and self.cy != 0) {
                    self.cy = 0;
                } else if (c == PAGE_DOWN and self.cy != self.screenrows - 1)
                    self.cy = self.screenrows - 1;

                var times = self.screenrows;
                while (times != 0) : (times -= 1) {
                    if (c == PAGE_UP) {
                        self.moveCursor(ARROW_UP);
                    } else {
                        self.moveCursor(ARROW_DOWN);
                    }
                }

                break;
            },
            .ARROW_UP, .ARROW_DOWN, .ARROW_LEFT, .ARROW_RIGHT => {
                self.moveCursor(c);
                break;
            },
            .CTRL_L => { // ctrl+l, clear screen
                // Just refresht the line as side effect.
                break;
            },
            .ESC => {
                // Nothing to do for ESC in this mode.
                break;
            },
            else => {
                self.insertChar(c);
                break;
            },
        }

        // quit_times = KILO_QUIT_TIMES; // Reset it to the original value.
    }

    // Load the specified program in the editor memory and returns 0 on success
    // or 1 on error.
    fn editorOpen(self: *Self, filename: []u8) void {
        // FILE *fp;
        //
        // E.dirty = 0;
        // free(E.filename);
        // size_t fnlen = strlen(filename)+1;
        // E.filename = malloc(fnlen);
        // memcpy(E.filename,filename,fnlen);
        //
        // fp = fopen(filename,"r");
        // if (!fp) {
        //     if (errno != ENOENT) {
        //         perror("Opening file");
        //         exit(1);
        //     }
        //     return 1;
        // }
        //
        // char *line = NULL;
        // size_t linecap = 0;
        // ssize_t linelen;
        // while((linelen = getline(&line,&linecap,fp)) != -1) {
        //     if (linelen && (line[linelen-1] == '\n' || line[linelen-1] == '\r'))
        //         line[-=1linelen] = '\0';
        //     editorInsertRow(E.numrows,line,linelen);
        // }
        // free(line);
        // fclose(fp);
        // E.dirty = 0;
        // return 0;
    }

    // Save the current file on disk. Return 0 on success, 1 on error.
    fn save(self: *Self) void {
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
};