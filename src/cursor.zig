const std = @import("std");
const File = std.fs.File;

const Key = @import("key.zig");

pub const HIDE_CURSOR = "\x1b[?25l";
pub const SHOW_CURSOR = "\x1b[?25h";
pub const MOVE_CURSOR_TO_0_0 = "\x1b[H";
pub const GET_CURSOR_POS = "\x1b[6n";

pub const SET_DEFAULT_COLOR = "\x1b[0m";
// Swap foreground and background colors
pub const INVERT_COLORS = "\x1b[7m";
pub const SET_DEFAULT_FOREGROUND = "\x1b[39m";

pub const ERASE_LINE_AFTER = "\x1b[0K";

const Position = struct { row: u32, col: u32 };

const Error = error{
    CursorPositon,
};

// Use the ESC [6n escape sequence to query the horizontal cursor position and return it.
// On error -1 is returned, on success the position of the cursor is stored at *rows and *cols and 0 is returned.
pub fn getCursorPosition(in: File, out: File) anyerror!Position {
    // Report cursor location
    _ = try out.write(GET_CURSOR_POS);

    // Read the response: ESC [ {rows} ; {cols} R
    var i: usize = 0;
    var buff: [32]u8 = undefined;
    while (i < buff.len - 1) : (i += 1) {
        _ = try in.read(buff[i .. i + 1]);
        if (buff[i] == 'R') {
            break;
        }
    }
    buff[i] = 0;

    // Parse it.
    if (buff[0] != @enumToInt(Key.Key.ESC) or buff[1] != '[') {
        return Error.CursorPositon;
    }

    var iter = std.mem.split(u8, buff[2..(i - 1)], ";");
    var rows_str = iter.next().?;
    var cols_str = iter.next().?;
    var rows = try std.fmt.parseInt(u32, rows_str, 10);
    var cols = try std.fmt.parseInt(u32, cols_str, 10);

    return Position{
        .row = rows,
        .col = cols,
    };
}
