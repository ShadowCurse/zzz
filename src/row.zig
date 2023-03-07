const std = @import("std");
const Allocator = std.mem.Allocator;
const String = std.ArrayList(u8);

const ctype = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    // @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("ctype.h");
    @cInclude("string.h");
});

const Syntax = @import("syntax.zig");
const Key = @import("key.zig");

const EditorSyntax = Syntax.EditorSyntax;

fn isSeparator(c: u8) bool {
    return c == 0 or ctype.isspace(c) != 0 or ctype.strchr(",.()+-/*=~%[];", c) != 0;
}

/// This structure represents a single line of the file we are editing.
pub const EditorRow = struct {
    /// Index in the file
    file_index: usize,
    /// Row raw content
    chars: String,
    /// Syntax highlight for each character in render
    highlight: String,
    /// Row content "rendered" for screen (with TABs)
    render: String,
    syntax: ?*const EditorSyntax,
    allocator: Allocator,

    const Self = @This();

    pub fn new(str: []u8, file_index: usize, syntax: ?*const EditorSyntax, allocator: Allocator) !Self {
        var self = Self{
            .file_index = file_index,
            .chars = String.fromOwnedSlice(allocator, str),
            .highlight = String.init(allocator),
            .render = String.init(allocator),
            .syntax = syntax,
            .allocator = allocator,
        };
        try self.updateRender();
        return self;
    }

    // Free self's heap allocated stuff.
    pub fn deinit(self: *Self) void {
        self.chars.deinit();
        self.highlight.deinit();
        self.render.deinit();
    }

    // Return true if the specified row last char is part of a multi line comment
    // that starts at this self or at one before, and does not end at the end
    // of the self but spawns to the next self.
    pub fn hasOpenComment(self: *Self) bool {
        if (self.render.items.len != 0 and self.highlight.items[self.render.items.len - 1] == Syntax.HL_MLCOMMENT and
            (self.render.items.len < 2 or (self.render.items[self.render.items.len - 2] != '*' or
            self.render.items[self.render.items.len - 1] != '/'))) return true;
        return false;
    }

    // Insert a character at the specified position in a row, moving the remaining
    // chars on the right if needed.
    pub fn insertChar(self: *Self, at: usize, c: u8) !void {
        if (self.chars.items.len < at) {
            // Pad the string with spaces if the insert location is outside the
            // current length by more than a single character.
            const padding = at - self.chars.items.len;
            try self.chars.appendNTimes(' ', padding);
            try self.chars.append(c);
        } else {
            try self.chars.insert(at, c);
        }
        try self.updateRender();
    }

    // Delete the character at offset 'at' from the specified self.
    pub fn deleteChar(self: *Self, at: usize) !void {
        if (self.chars.items.len <= at) return;
        _ = self.chars.orderedRemove(at);
        try self.updateRender();
    }

    // Append the string 's' at the end of a self
    pub fn appendSlice(self: *Self, str: []u8) !void {
        try self.chars.appendSlice(str);
        try self.updateRender();
    }

    pub fn resize(self: *Self, size: usize) !void {
        try self.chars.resize(size);
        try self.updateRender();
    }

    pub fn renderToString(self: *Self, coloff: u64, screencols: u64, string: *String) !void {
        var remaining_line_width = self.render.items.len - coloff;
        var current_color: i32 = -1;
        if (remaining_line_width > 0) {
            if (remaining_line_width > screencols) {
                remaining_line_width = screencols;
            }
            var render_chars = self.render.items[coloff..];
            var highlight = self.highlight.items[coloff..];
            for (0..remaining_line_width) |j| {
                switch (highlight[j]) {
                    Syntax.HL_NORMAL => {
                        if (current_color != -1) {
                            try string.appendSlice("\x1b[39m");
                            current_color = -1;
                        }
                        try string.appendNTimes(render_chars[j], 1);
                    },
                    Syntax.HL_NONPRINT => {
                        var symbol: u8 = undefined;
                        try string.appendSlice("\x1b[7m");
                        if (render_chars[j] <= 26) {
                            symbol = '@' + render_chars[j];
                        } else {
                            symbol = '?';
                        }
                        try string.appendNTimes(symbol, 1);
                        try string.appendSlice("\x1b[0m");
                    },
                    else => {
                        const color = Syntax.syntaxToColor(highlight[j]);
                        if (color != current_color) {
                            var buf: [16]u8 = undefined;
                            _ = try std.fmt.bufPrint(&buf, "\x1b[{d}m", .{color});
                            current_color = color;
                            try string.appendSlice(&buf);
                        }
                        try string.appendSlice(render_chars[j .. j + 1]);
                    },
                }
            }
        }
        try string.appendSlice("\x1b[39m");
        try string.appendSlice("\x1b[0K");
        try string.appendSlice("\r\n");
    }

    // Set every byte of self.hl (that corresponds to every character in the line)
    // to the right syntax highlight type (HL_* defines).
    pub fn updateSyntax(self: *Self) !void {
        // reset all syntax to normal
        try self.highlight.resize(self.render.items.len);
        std.mem.set(u8, self.highlight.items, Syntax.HL_NORMAL);

        if (self.syntax == null) {
            return;
        }

        const syntax = self.syntax.?;
        const keywords = syntax.keywords;
        const scs = syntax.singleline_comment_start;
        // const mcs = syntax.multiline_comment_start;
        // const mce = syntax.multiline_comment_end;

        // Point to the first non-space char.
        var i: usize = 0;
        while (i < self.render.items.len and ctype.isspace(self.render.items[i]) != 0) : (i += 1) {}

        // Tell the parser if 'i' points to start of word.
        var word_start = true;
        var in_string: ?u8 = null;

        // If the previous line has an open comment, this line starts
        // with an open comment state.

        while (i < self.render.items.len) {
            // Handle // comments.
            if (word_start and i + 2 <= self.render.items.len and std.mem.eql(u8, self.render.items[i .. i + 2], scs)) {
                // From here to end is a comment
                std.mem.set(u8, self.highlight.items[i..self.highlight.items.len], Syntax.HL_COMMENT);
                return;
            }

            // Handle multi line comments.
            // if (in_comment) {
            //     self.highlight.items[i] = Syntax.HL_MLCOMMENT;
            //     if (&self.render.items[i .. i + 2] == &mce) {
            //         self.highlight.items[i + 1] = Syntax.HL_MLCOMMENT;
            //         in_comment = false;
            //         word_start = true;
            //         i += 2;
            //         continue;
            //     } else {
            //         word_start = false;
            //         i += 1;
            //         continue;
            //     }
            // } else if (&self.render.items[i .. i + 2] == &mcs) {
            //     self.highlight.items[i] = Syntax.HL_MLCOMMENT;
            //     self.highlight.items[i + 1] = Syntax.HL_MLCOMMENT;
            //     in_comment = true;
            //     word_start = false;
            //     i += 2;
            //     continue;
            // }

            // Handle "" and ''
            if (in_string != null) {
                self.highlight.items[i] = Syntax.HL_STRING;
                if (self.render.items[i] == '\\') {
                    self.highlight.items[i + 1] = Syntax.HL_STRING;
                    word_start = false;
                    i += 2;
                } else {
                    // if current char is end of string (" or ')
                    if (self.render.items[i] == in_string.?) {
                        in_string = null;
                    }
                    i += 1;
                }
            } else if (self.render.items[i] == '\"' or self.render.items[i] == '\'') {
                in_string = self.render.items[i];
                self.highlight.items[i] = Syntax.HL_STRING;
                word_start = false;
                i += 1;
            } else if (ctype.isprint(self.render.items[i]) == 0) {
                self.highlight.items[i] = Syntax.HL_NONPRINT;
                word_start = false;
                i += 1;
            } else if ((ctype.isdigit(self.render.items[i]) != 0 and (word_start or self.highlight.items[i - 1] == Syntax.HL_NUMBER)) or
                (self.render.items[i] == '.' and 0 < i and self.highlight.items[i - 1] == Syntax.HL_NUMBER))
            {
                self.highlight.items[i] = Syntax.HL_NUMBER;
                word_start = false;
                i += 1;
            } else if (word_start) {
                var found_keyword: ?[]const u8 = null;
                for (keywords) |keyword| {
                    if (keyword.len <= self.render.items.len - i and std.mem.eql(u8, self.render.items[i .. i + keyword.len], keyword) and isSeparator(self.render.items[i + keyword.len])) {
                        found_keyword = keyword;
                        break;
                    }
                }
                if (found_keyword) |keyword| {
                    std.mem.set(u8, self.highlight.items[i .. i + keyword.len], Syntax.HL_KEYWORD1);
                    i += keyword.len;
                } else {
                    i += 1;
                }
                word_start = false;
            } else {
                word_start = isSeparator(self.render.items[i]);
                i += 1;
            }
        }
        return;
    }

    // Update the rendered version and the syntax highlight of a self.
    pub fn updateRender(self: *Self) !void {
        // Create a version of the self we can directly print on the screen,
        // respecting tabs, substituting non printable characters with '?'.
        var tabs: u32 = 0;
        for (self.chars.items) |c| {
            if (c == @enumToInt(Key.Key.TAB))
                tabs += 1;
        }

        const tab_size = 4;

        var size = self.chars.items.len + tabs * tab_size;
        try self.render.resize(size);

        var idx: u32 = 0;
        for (self.chars.items) |c| {
            if (c == @enumToInt(Key.Key.TAB)) {
                std.mem.set(u8, self.render.items[idx .. idx + tab_size], ' ');
                idx += tab_size;
            } else {
                self.render.items[idx] = c;
                idx += 1;
            }
        }

        // Update the syntax highlighting attributes of the self.
        try self.updateSyntax();
    }
};
