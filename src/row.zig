const std = @import("std");
const Allocator = std.mem.Allocator;
const String = std.ArrayListUnmanaged(u8);

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

// This structure represents a single line of the file we are editing.
pub const EditorRow = struct {
    idx: u32, // row index in the file, zero-based.
    chars: []u8, // row raw content.
    highlight: []u8, // syntax highlight type for each character in render
    render: []u8, // row content "rendered" for screen (for TABs).
    // hl_oc: bool, // row had open comment at end in last syntax highlight check.
    syntax: ?*EditorSyntax,
    allocator: Allocator,

    const Self = @This();

    pub fn init(syntax: ?*EditorSyntax, allocator: Allocator) !Self {
        var chars = try allocator.alloc(u8, 0);
        var highlight = try allocator.alloc(u8, 0);
        var render = try allocator.alloc(u8, 0);
        var self = Self{
            .idx = 0,
            .chars = chars,
            .highlight = highlight,
            .render = render,
            // .hl_oc = false,
            .syntax = syntax,
            .allocator = allocator,
        };
        try self.updateRender();
        return self;
    }

    // Free self's heap allocated stuff.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.chars);
        self.allocator.free(self.highlight);
        self.allocator.free(self.render);
    }

    // Return true if the specified row last char is part of a multi line comment
    // that starts at this self or at one before, and does not end at the end
    // of the self but spawns to the next self.
    pub fn hasOpenComment(self: *Self) bool {
        if (self.render.len != 0 and self.highlight[self.render.len - 1] == Syntax.HL_MLCOMMENT and
            (self.render.len < 2 or (self.render[self.render.len - 2] != '*' or
            self.render[self.render.len - 1] != '/'))) return true;
        return false;
    }

    // Insert a character at the specified position in a self, moving the remaining
    // chars on the right if needed.
    pub fn insertChar(self: *Self, at: u32, c: u8) void {
        if (self.size < at) {
            // Pad the string with spaces if the insert location is outside the
            // current length by more than a single character.
            var padding = at - self.chars.len;
            // In the next line +1 means: new char.
            self.chars = self.allocator.realloc(self.chars, self.chars.len + padding + 1);
            std.mem.set(self.chars[self.chars.len .. self.chars.len + padding], ' ');
            // TODO
            // self.chars[self.chars.len + padlen + 1] = 0;
            // self.size += padlen + 1;
        } else {
            // If we are in the middle of the string just make space for 1 new
            // char plus the (already existing) null term.
            self.chars = self.allocator.realloc(self.chars, self.chars.len + 1);
            std.mem.copy(self.chars[at + 1 .. self.chars.len], self.chars[at .. self.chars.len - 1]);
        }
        self.chars[at] = c;
        self.updateRender();
    }

    // Delete the character at offset 'at' from the specified self.
    pub fn deleteChar(self: *Self, at: u32) void {
        if (self.size <= at) return;
        std.mem.copy(self.chars[at .. self.chars.len - 1], self.chars[at + 1 .. self.chars.len]);
        self.updateRender();
    }

    // Append the string 's' at the end of a self
    pub fn appendString(self: *Self, s: *String) void {
        self.chars = self.allocator.realloc(self.chars, self.chars.len + s.items.len);
        std.mem.copy(self.chars[self.chars.len - s.items.len .. self.chars.len], s.items);
        self.updateRender();
    }

    // Set every byte of self.hl (that corresponds to every character in the line)
    // to the right syntax highlight type (HL_* defines).
    pub fn updateSyntax(self: *Self, inside_comment: bool) !bool {
        // TODO why can't we modify input parameter
        var in_comment = inside_comment;

        self.highlight = try self.allocator.realloc(self.highlight, self.render.len);
        std.mem.set(u8, self.highlight, Syntax.HL_NORMAL);

        if (self.syntax == null) {
            return false;
        }
        const syntax = self.syntax.?;
        const keywords = syntax.keywords;
        const scs = &syntax.singleline_comment_start;
        const mcs = &syntax.multiline_comment_start;
        const mce = &syntax.multiline_comment_end;

        // Point to the first non-space char.
        var i: usize = 0;
        while (ctype.isspace(self.render[i]) == 0) : (i += 1) {}

        var word_start = true; // Tell the parser if 'i' points to start of word.
        var in_string: ?*u8 = null; // Are we inside "" or '' ?

        // If the previous line has an open comment, this line starts
        // with an open comment state.

        outer: while (i < self.render.len) {
            // Handle // comments.
            if (word_start and &self.render[i .. i + 2] == scs) {
                // From here to end is a comment
                std.mem.set(u8, self.highlight[i..self.highlight.len], Syntax.HL_COMMENT);
                return false;
            }

            // Handle multi line comments.
            if (in_comment) {
                self.highlight[i] = Syntax.HL_MLCOMMENT;
                if (&self.render[i .. i + 2] == mce) {
                    self.highlight[i + 1] = Syntax.HL_MLCOMMENT;
                    in_comment = false;
                    word_start = true;
                    i += 2;
                    continue;
                } else {
                    word_start = false;
                    i += 1;
                    continue;
                }
            } else if (&self.render[i .. i + 2] == mcs) {
                self.highlight[i] = Syntax.HL_MLCOMMENT;
                self.highlight[i + 1] = Syntax.HL_MLCOMMENT;
                in_comment = true;
                word_start = false;
                i += 2;
                continue;
            }

            // Handle "" and ''
            if (in_string != null) {
                self.highlight[i] = Syntax.HL_STRING;
                if (self.render[i] == '\\') {
                    self.highlight[i + 1] = Syntax.HL_STRING;
                    word_start = false;
                    i += 2;
                    continue;
                }
                // if current char is end of string (" or ')
                if (self.render[i] == in_string.?.*) {
                    in_string = null;
                }
                i += 1;
                continue;
            } else {
                if (self.render[i] == '"' or self.render[i] == '\'') {
                    in_string = &self.render[i];
                    self.highlight[i] = Syntax.HL_STRING;
                    word_start = false;
                    i += 1;
                    continue;
                }
            }

            // Handle non printable chars.
            if (ctype.isprint(self.render[i]) == 0) {
                self.highlight[i] = Syntax.HL_NONPRINT;
                word_start = false;
                i += 1;
                continue;
            }

            // Handle numbers
            if ((ctype.isdigit(self.render[i]) != 0 and (word_start or self.highlight[i - 1] == Syntax.HL_NUMBER)) or
                (self.render[i] == '.' and 0 < i and self.highlight[i - 1] == Syntax.HL_NUMBER))
            {
                self.highlight[i] = Syntax.HL_NUMBER;
                word_start = false;
                i += 1;
                continue;
            }

            // Handle keywords and lib calls
            if (word_start) {
                // var j2: usize = 0;
                for (keywords) |_, j| {
                    // j2 = j;
                    var klen = keywords[j].len;
                    var kw2 = keywords[j][klen - 1] == '|';
                    if (kw2) klen -= 1;

                    // if there is a keyword and there is separator after it
                    if (&self.render[i .. i + klen] == &keywords[j] and isSeparator(self.render[i + klen])) {
                        var kw: u8 = Syntax.HL_KEYWORD1;
                        if (!kw2) {
                            kw = Syntax.HL_KEYWORD2;
                        }
                        // Keyword
                        std.mem.set(u8, self.highlight[i .. i + klen], kw);
                        i += klen;
                        word_start = false;
                        continue :outer;
                    }
                }
            }

            // Not special chars
            word_start = isSeparator(self.render[i]);
            i += 1;
        }

        // Propagate syntax change to the next self if the open comment
        // state changed. This may recursively affect all the following selfs
        // in the file.
        var oc = self.hasOpenComment();
        return oc;
    }

    // Update the rendered version and the syntax highlight of a self.
    pub fn updateRender(self: *Self) !void {
        // Create a version of the self we can directly print on the screen,
        // respecting tabs, substituting non printable characters with '?'.
        var tabs: u32 = 0;
        for (self.chars) |c| {
            if (c == @enumToInt(Key.Key.TAB))
                tabs += 1;
        }

        const tab_size = 8;

        self.allocator.free(self.render);
        var allocsize = self.chars.len + tabs * 8; // + nonprint * 9 + 1;
        self.render = try self.allocator.alloc(u8, allocsize);

        var idx: u32 = 0;
        for (self.chars) |c| {
            if (c == @enumToInt(Key.Key.TAB)) {
                std.mem.set(u8, self.render[idx .. idx + tab_size], ' ');
                idx += tab_size;
            } else {
                self.render[idx] = c;
                idx += 1;
            }
        }

        // Update the syntax highlighting attributes of the self.
        // TODO use return value
        _ = try self.updateSyntax(false);
    }
};
