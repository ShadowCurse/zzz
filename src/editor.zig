const std = @import("std");
const Allocator = std.mem.Allocator;
const String = std.ArrayList(u8);
const Rows = std.ArrayList(Row);

const Row = @import("row.zig");
const Key = @import("key.zig");
const Syntax = @import("syntax.zig");
const Cursor = @import("cursor.zig");

/// Cursor x position in characters
cx: u64,
/// Cursor y position in characters
cy: u64,
/// Offset of row displayed
row_offset: u64,
// Offset of column displayed
column_offset: u64,
/// Number dkjfbnk;djfof rows that we can show
screen_height: u64,
/// Number of cols that we can show
screen_width: u64,
/// Rows
rows: Rows,
/// File modified but not saved
dirty: bool,
/// Currently open filename
filename: ?[]u8,
/// Current syntax highlight
syntax: ?*const Syntax,
allocator: Allocator,

const Self = @This();

pub fn new(allocator: Allocator) !Self {
    return Self{
        .cx = 0,
        .cy = 0,
        .row_offset = 0,
        .column_offset = 0,
        .screen_height = 0,
        .screen_width = 0,
        .rows = try Rows.initCapacity(allocator, 0),
        .dirty = false,
        .filename = null,
        .syntax = null,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    for (self.rows.items) |*r| {
        r.*.deinit();
    }
    self.rows.deinit();
}

pub fn updateSize(self: *Self, height: u64, width: u64) void {
    self.screen_height = height;
    self.screen_width = width;
}

// Select the syntax highlight scheme depending on the filename,
// setting it in the global self E.syntax.
pub fn selectSyntaxHighlight(self: *Self, filename: []u8) void {
    for (&Syntax.SYNTAX_ARRAY) |*s| {
        for (s.extensions) |ext| {
            if (std.mem.endsWith(u8, filename, ext)) {
                self.syntax = s;
            }
            return;
        }
    }
}

// Insert the specified char at the current prompt position.
fn insertChar(self: *Self, c: u8) !void {
    const filerow = self.row_offset + self.cy;
    const filecol = self.column_offset + self.cx;
    // If the row where the cursor is currently located does not exist in our
    // logical representaion of the file, add enough empty rows as needed.
    while (self.rows.items.len <= filerow) {
        try self.insertRow(self.rows.items.len, "");
    }
    const row = &self.rows.items[filerow];
    try row.insertChar(filecol, c);
    // fix cursor
    if (self.cx == self.screen_width - 1) {
        self.column_offset += 1;
    } else {
        self.cx += 1;
    }
    self.dirty = true;
}

// Delete the char at the current prompt position.
fn delChar(self: *Self) !void {
    const filerow = self.row_offset + self.cy;
    const filecol = self.column_offset + self.cx;

    if (filerow >= self.rows.items.len or (filecol == 0 and filerow == 0)) {
        return;
    }

    const row = &self.rows.items[filerow];

    if (filecol == 0) {
        // Handle the case of column 0, we need to move the current line
        // on the right of the previous one.
        try self.rows.items[filerow - 1].appendSlice(row.chars.items);
        var delited_row = self.rows.orderedRemove(filerow);
        delited_row.deinit();

        if (self.cy == 0) {
            self.row_offset -= 1;
        } else {
            self.cy -= 1;
        }
        self.cx = filecol;
        if (self.cx >= self.screen_width) {
            const shift = (self.screen_width - self.cx) + 1;
            self.cx -= shift;
            self.column_offset += shift;
        }
    } else {
        try row.deleteChar(filecol - 1);
        if (self.cx == 0 and self.column_offset != 0) {
            self.column_offset -= 1;
        } else {
            self.cx -= 1;
        }
    }
    self.dirty = true;
}

/// Inserting a newline is slightly complex as we have to handle inserting a
/// newline in the middle of a line, splitting the line as needed.
fn insertNewline(self: *Self) !void {
    const filerow = self.row_offset + self.cy;
    var filecol = self.column_offset + self.cx;

    if (filerow >= self.rows.items.len) {
        if (filerow == self.rows.items.len) {
            try self.insertRow(filerow, "");
        }
    } else {
        var row = &self.rows.items[filerow];
        // If the cursor is over the current line size, we want to conceptually
        // think it's just over the last character.
        if (filecol >= @as(u64, row.chars.items.len)) {
            filecol = @as(u64, row.chars.items.len);
        }
        if (filecol == 0) {
            try self.insertRow(filerow, "");
        } else {
            // We are in the middle of a line. Split it between two rows.
            try self.insertRow(filerow + 1, row.chars.items[filecol..]);
            try self.rows.items[filerow].resize(filecol);
        }
    }
    // fix cursor position
    if (self.cy == self.screen_height - 1) {
        self.row_offset += 1;
    } else {
        self.cy += 1;
    }
    self.cx = 0;
    self.column_offset = 0;
}

/// Insert a row at the specified position, shifting the other rows on the bottom
/// if required.
fn insertRow(self: *Self, at: usize, str: []u8) !void {
    if (at > self.rows.items.len)
        return;

    const new_row = try Row.new(str, at, self.syntax, self.allocator);
    try self.rows.insert(at, new_row);

    for (self.rows.items[at + 1 ..]) |*r| {
        r.*.file_index += 1;
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

    try screen_buffer.appendSlice(Cursor.HIDE_CURSOR);
    try screen_buffer.appendSlice(Cursor.MOVE_CURSOR_TO_0_0);

    // subtract 2 because we have 1 status line and 1 empty line after that
    for (0..self.screen_height - 2) |y| {
        const filerow = self.row_offset + y;
        if (filerow >= self.rows.items.len) {
            // Clear row and print ~ and go to the next line
            try screen_buffer.appendSlice("~" ++ Cursor.ERASE_LINE_AFTER ++ "\r\n");
            continue;
        }

        const row = &self.rows.items[filerow];
        try row.renderToString(self.column_offset, self.screen_width, &screen_buffer);
        try screen_buffer.appendSlice(Cursor.ERASE_LINE_AFTER ++ "\r\n");
    }

    // Clear from cursor to the end of the line
    try screen_buffer.appendSlice(Cursor.ERASE_LINE_AFTER);
    // Invert color
    try screen_buffer.appendSlice(Cursor.INVERT_COLORS);
    {
        const msg = try std.fmt.allocPrint(self.allocator, "rows: {d}, x: {d} y: {d}, cf: {d}, rf: {d}\n", .{ self.rows.items.len, self.cx, self.cy, self.column_offset, self.row_offset });
        defer self.allocator.free(msg);

        try screen_buffer.appendSlice(msg);
    }

    // Reset colors and add new line
    try screen_buffer.appendSlice(Cursor.SET_DEFAULT_COLOR);

    var seq: [16]u8 = undefined;
    var fixed_allo = std.heap.FixedBufferAllocator.init(&seq);
    const alloc = fixed_allo.allocator();
    // Put cursor at self.cy self.cx
    // In terminal position is 1 based so add 1 because in the editor
    // position is 0 baesd
    const buf = try std.fmt.allocPrint(alloc, "\x1b[{d};{d}H", .{ self.cy + 1, self.cx + 1 });
    try screen_buffer.appendSlice(buf);

    // Show cursor
    try screen_buffer.appendSlice(Cursor.SHOW_CURSOR);
    _ = try stdio.write(screen_buffer.items);
}

// Handle cursor position change because arrow keys were pressed.
fn moveCursor(self: *Self, key: Key.Key) void {
    var file_row = self.row_offset + self.cy;
    var file_col = self.column_offset + self.cx;

    switch (key) {
        .ARROW_LEFT => {
            // if cursor at most left position
            if (self.cx == 0) {
                // if there is horizontal offset
                if (self.column_offset != 0) {
                    self.column_offset -= 1;
                } else {
                    // if there is a row above we set cursor to the ends
                    // of that row
                    if (file_row > 0) {
                        self.cy -= 1;
                        self.cx = self.rows.items[file_row - 1].chars.items.len;
                        // if previous row is too long update the column_offset
                        if (self.cx > self.screen_width - 1) {
                            self.column_offset = self.cx - self.screen_width + 1;
                            self.cx = self.screen_width - 1;
                        }
                    }
                }
            } else {
                self.cx -= 1;
            }
        },
        .ARROW_RIGHT => {
            if (file_row < self.rows.items.len) {
                const current_row = &self.rows.items[file_row];

                // if there cursor is not at the end of the row
                if (file_col < current_row.chars.items.len) {
                    if (self.cx == self.screen_width - 1) {
                        self.column_offset += 1;
                    } else {
                        self.cx += 1;
                    }
                } else if (file_col == current_row.chars.items.len) {
                    self.cx = 0;
                    self.column_offset = 0;
                    if (self.cy == self.screen_height - 1) {
                        self.row_offset += 1;
                    } else {
                        self.cy += 1;
                    }
                }
            }
        },
        .ARROW_UP => {
            if (self.cy == 0) {
                if (self.row_offset != 0) {
                    self.row_offset -= 1;
                }
            } else {
                self.cy -= 1;
            }
        },
        .ARROW_DOWN => {
            if (file_row < self.rows.items.len) {
                if (self.cy == self.screen_height - 1) {
                    self.row_offset += 1;
                } else {
                    self.cy += 1;
                }
            }
        },
        else => {
            unreachable;
        },
    }
    // Fix cx if the current line has not enough chars.
    file_row = self.row_offset + self.cy;
    file_col = self.column_offset + self.cx;

    if (file_row < self.rows.items.len) {
        const current_row = self.rows.items[file_row];
        if (current_row.chars.items.len < file_col) {
            self.cx -= file_col - current_row.chars.items.len;
            if (self.cx < 0) {
                self.column_offset += self.cx;
                self.cx = 0;
            }
        }
    }
}

// Process events arriving from the standard input, which is, the user
// is typing stuff on the terminal.
pub fn processKeypress(self: *Self, key: Key.Key) !bool {
    switch (key) {
        .ESC,
        .CTRL_D,
        .CTRL_F,
        .CTRL_H,
        .TAB,
        .CTRL_L,
        .CTRL_Q,
        .CTRL_U,
        .HOME_KEY,
        .END_KEY,
        .PAGE_UP,
        .PAGE_DOWN,
        => {},
        .CTRL_C => {
            return true;
        },
        .ENTER => {
            try self.insertNewline();
        },
        .CTRL_S => {
            try self.save();
        },
        .BACKSPACE,
        .DEL_KEY,
        => {
            try self.delChar();
        },
        .ARROW_UP, .ARROW_DOWN, .ARROW_LEFT, .ARROW_RIGHT => {
            self.moveCursor(key);
        },
        .Key => {
            try self.insertChar(key.Key);
        },
    }

    return false;
}

// Load the specified program in the editor memory
pub fn openFile(self: *Self, filename: []u8) !void {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var index: usize = 0;
    while (in_stream.readUntilDelimiterAlloc(self.allocator, '\n', 1024)) |line| : (index += 1) {
        const row = try Row.new(line, index, self.syntax, self.allocator);
        try self.rows.append(row);
    } else |e| {
        if (e != error.EndOfStream) {
            return e;
        }
    }
    self.filename = filename;
}

// Save the current file on disk. Return 0 on success, 1 on error.
fn save(self: *Self) !void {
    var size: usize = 0;
    for (self.rows.items) |row| {
        size += row.chars.items.len + 1;
    }

    var buffer = try String.initCapacity(self.allocator, size);
    defer buffer.deinit();

    for (self.rows.items) |row| {
        try buffer.appendSlice(row.chars.items);
        try buffer.appendNTimes('\n', 1);
    }

    var file = try std.fs.cwd().openFile(self.filename.?, .{ .mode = .write_only });
    defer file.close();

    try file.writeAll(buffer.items);
}
