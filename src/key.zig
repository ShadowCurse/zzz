const std = @import("std");
const File = std.fs.File;

pub const KeyEnum = enum {
    CTRL_C,
    CTRL_D,
    CTRL_F,
    CTRL_H,
    TAB,
    CTRL_L,
    ENTER,
    CTRL_Q,
    CTRL_S,
    CTRL_U,
    ESC,
    BACKSPACE,
    ARROW_LEFT,
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    DEL_KEY,
    HOME_KEY,
    END_KEY,
    PAGE_UP,
    PAGE_DOWN,
    Key,
};

pub const Key = union(KeyEnum) {
    CTRL_C: void,
    CTRL_D: void,
    CTRL_F: void,
    CTRL_H: void,
    TAB: void,
    CTRL_L: void,
    ENTER: void,
    CTRL_Q: void,
    CTRL_S: void,
    CTRL_U: void,
    ESC: void,
    BACKSPACE: void,
    ARROW_LEFT: void,
    ARROW_RIGHT: void,
    ARROW_UP: void,
    ARROW_DOWN: void,
    DEL_KEY: void,
    HOME_KEY: void,
    END_KEY: void,
    PAGE_UP: void,
    PAGE_DOWN: void,
    Key: u8,
};

const KeyCodes = enum(u32) {
    CTRL_C = @bitCast([_]u8{ 3, 170, 170, 170 }), // Ctrl-c
    CTRL_D = @bitCast([_]u8{ 4, 170, 170, 170 }), // Ctrl-d
    CTRL_F = @bitCast([_]u8{ 6, 170, 170, 170 }), // Ctrl-f
    CTRL_H = @bitCast([_]u8{ 8, 170, 170, 170 }), // Ctrl-h
    TAB = @bitCast([_]u8{ 9, 170, 170, 170 }), // Tab
    CTRL_L = @bitCast([_]u8{ 12, 170, 170, 170 }), // Ctrl+l
    ENTER = @bitCast([_]u8{ 13, 170, 170, 170 }), // Enter
    CTRL_Q = @bitCast([_]u8{ 17, 170, 170, 170 }), // Ctrl-q
    CTRL_S = @bitCast([_]u8{ 19, 170, 170, 170 }), // Ctrl-s
    CTRL_U = @bitCast([_]u8{ 21, 170, 170, 170 }), // Ctrl-u
    ESC = @bitCast([_]u8{ 27, 170, 170, 170 }), // Escape
    BACKSPACE = @bitCast([_]u8{ 127, 170, 170, 170 }), // Backspace

    ARROW_LEFT = @bitCast([_]u8{ 27, 91, 68, 170 }),
    ARROW_RIGHT = @bitCast([_]u8{ 27, 91, 67, 170 }),
    ARROW_UP = @bitCast([_]u8{ 27, 91, 65, 170 }),
    ARROW_DOWN = @bitCast([_]u8{ 27, 91, 66, 170 }),
    DEL_KEY = @bitCast([_]u8{ 27, 91, 51, 126 }),
    PAGE_UP = @bitCast([_]u8{ 27, 91, 53, 126 }),
    PAGE_DOWN = @bitCast([_]u8{ 27, 91, 54, 126 }),
    _,
};

// Read a key from the terminal put in raw mode, trying to handle escape sequences.
pub fn readKey(in: File) anyerror!Key {
    var code: [4]u8 = undefined;
    var nread = try in.read(&code);
    while (nread == 0) : (nread = try in.read(&code)) {}
    const key_code: u32 = @bitCast(code);
    return switch (@as(KeyCodes, @enumFromInt(key_code))) {
        .CTRL_C => Key.CTRL_C,
        .CTRL_D => Key.CTRL_D,
        .CTRL_F => Key.CTRL_F,
        .CTRL_H => Key.CTRL_H,
        .TAB => Key.TAB,
        .CTRL_L => Key.CTRL_L,
        .ENTER => Key.ENTER,
        .CTRL_Q => Key.CTRL_Q,
        .CTRL_S => Key.CTRL_S,
        .CTRL_U => Key.CTRL_U,
        .ESC => Key.ESC,
        .BACKSPACE => Key.BACKSPACE,
        .ARROW_LEFT => Key.ARROW_LEFT,
        .ARROW_RIGHT => Key.ARROW_RIGHT,
        .ARROW_UP => Key.ARROW_UP,
        .ARROW_DOWN => Key.ARROW_DOWN,
        .DEL_KEY => Key.DEL_KEY,
        .PAGE_UP => Key.PAGE_UP,
        .PAGE_DOWN => Key.PAGE_DOWN,
        _ => Key{ .Key = (code[0]) },
    };
}
