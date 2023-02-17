const std = @import("std");
const File = std.fs.File;

pub const Key = enum(u32) {
    KEY_NULL = 0, // NULL
    CTRL_C = 3, // Ctrl-c
    CTRL_D = 4, // Ctrl-d
    CTRL_F = 6, // Ctrl-f
    CTRL_H = 8, // Ctrl-h
    TAB = 9, // Tab
    CTRL_L = 12, // Ctrl+l
    ENTER = 13, // Enter
    CTRL_Q = 17, // Ctrl-q
    CTRL_S = 19, // Ctrl-s
    CTRL_U = 21, // Ctrl-u
    ESC = 27, // Escape
    BACKSPACE = 127, // Backspace
    // The following are just soft codes, not really reported by the terminal directly.
    ARROW_LEFT = 1000,
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    DEL_KEY,
    HOME_KEY,
    END_KEY,
    PAGE_UP,
    PAGE_DOWN,
    _
};

// Read a key from the terminal put in raw mode, trying to handle escape sequences.
pub fn readKey(in: File) anyerror!Key {
    var c: [1]u8 = undefined;
    var nread = try in.read(&c);
    while (nread == 0) : (nread = try in.read(&c)) {}

    var key = @intToEnum(Key, c[0]);
    if (key == .ESC) {
        // escape sequence
        var seq: [3]u8 = undefined;
        // If this is just an ESC, we'll timeout here.
        nread = try in.read(seq[0..1]);
        if (nread == 0) {
            return .ESC;
        }
        nread = try in.read(seq[1..2]);
        if (nread == 0) {
            return .ESC;
        }
        // ESC [ sequences.
        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                // Extended escape, read additional byte.
                nread = try in.read(seq[2..3]);
                if (nread == 0) {
                    return .ESC;
                }
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '3' => return .DEL_KEY,
                        '5' => return .PAGE_UP,
                        '6' => return .PAGE_DOWN,
                        else => {
                            std.log.err("read strange sequence: {s}", .{seq});
                            std.process.exit(1);
                        },
                    }
                }
            } else {
                switch (seq[1]) {
                    'A' => return .ARROW_UP,
                    'B' => return .ARROW_DOWN,
                    'C' => return .ARROW_RIGHT,
                    'D' => return .ARROW_LEFT,
                    'H' => return .HOME_KEY,
                    'F' => return .END_KEY,
                    else => {
                        std.log.err("read strange sequence: {s}", .{seq});
                        std.process.exit(1);
                    },
                }
            }
        }
        // ESC O sequences.
        else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return .HOME_KEY,
                'F' => return .END_KEY,
                else => std.process.exit(1),
            }
        }
    }
    return key;
}
