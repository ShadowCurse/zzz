const std = @import("std");
const File = std.fs.File;
const Termios = std.os.termios;

const ctype = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    // @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("ctype.h");
    @cInclude("string.h");
});

const Editor = @import("editor.zig");
const Key = @import("key.zig");
// usingnamespace @import("key.zig");
const Row = @import("row.zig");

const Position = struct { row: u32, col: u32 };

const Error = error{
    CursorPositon,
};

// Raw mode: 1960 magic shit.
fn enableRawMode(stdin: File) anyerror!Termios {
    std.log.info("enableRawMode", .{});

    if (!stdin.isTty()) {
        std.log.err("passed fd is not a tty", .{});
        std.os.exit(1);
    }

    var orig_termios = try std.os.tcgetattr(stdin.handle);

    // modify the original mode
    var raw = orig_termios;
    // input modes: no break, no CR to NL, no parity check, no strip char, no start/stop output control.
    raw.iflag &= ~(std.os.linux.BRKINT | std.os.linux.ICRNL | std.os.linux.INPCK | std.os.linux.ISTRIP | std.os.linux.IXON);
    // output modes - disable post processing
    raw.oflag &= ~(std.os.linux.OPOST);
    // control modes - set 8 bit chars
    raw.cflag |= (std.os.linux.CS8);
    // local modes - choing off, canonical off, no extended functions, no signal chars (^Z,^C)
    raw.lflag &= ~(std.os.linux.ECHO | std.os.linux.ICANON | std.os.linux.IEXTEN | std.os.linux.ISIG);
    // control chars - set return condition: min number of bytes and timer.
    raw.cc[5] = 0; //std.os.VMIN] = 0; // Return each byte, or zero for timeout.
    raw.cc[7] = 1; //std.os.VTIME] = 1; // 100 ms timeout (unit is tens of second).

    // put terminal in raw mode after flushing
    try std.os.tcsetattr(stdin.handle, std.os.linux.TCSA.FLUSH, raw);

    return orig_termios;
}

fn disableRawMode(orig_termios: *Termios, stdin: File) anyerror!void {
    std.log.info("disableRawMode", .{});
    try std.os.tcsetattr(stdin.handle, std.os.linux.TCSA.FLUSH, orig_termios.*);
}
// Use the ESC [6n escape sequence to query the horizontal cursor position and return it.
// On error -1 is returned, on success the position of the cursor is stored at *rows and *cols and 0 is returned.
fn getCursorPosition(in: File, out: File) anyerror!Position {
    // Report cursor location
    _ = try out.write("\x1b[6n");

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

// Try to get the number of columns in the current terminal. If the ioctl()
// call fails the function will try to query the terminal itself.
// Returns 0 on success, -1 on error.
fn getWindowSize(in: File, out: File) anyerror!Position {
    // struct winsize ws;
    var ws: std.os.linux.winsize = undefined;

    const TIOCGWINSZ: u32 = 0x5413;
    if (std.os.linux.ioctl(1, TIOCGWINSZ, @ptrToInt(&ws)) == -1 or ws.ws_col == 0) {
        // Get the initial position so we can restore it later.
        var orig_pos = try getCursorPosition(in, out);
        // Go to right/bottom margin and get position.
        _ = try out.write("\x1b[999C\x1b[999B");
        // Get new position
        var pos = try getCursorPosition(in, out);
        // Restore position.

        var seq: [32]u8 = undefined;
        var fixed_allo = std.heap.FixedBufferAllocator.init(&seq);
        const alloc = fixed_allo.allocator();

        _ = try std.fmt.allocPrint(alloc, "\x1b[{d};%{d}H", .{ orig_pos.row, orig_pos.col });
        _ = try out.write(&seq);

        return pos;
    } else {
        return Position{
            .row = ws.ws_row,
            .col = ws.ws_col,
        };
    }
}

// Turn the editor rows into a single heap-allocated string.
// Returns the pointer to the heap-allocated string and populate the
// integer pointed by 'buflen' with the size of the string, escluding
// the final nulterm.
// fn editorRowsToString(buflen: *u32) *u8 {
//     // char *buf = NULL, *p;
//     // int totlen = 0;
//     // int j;
//
//     // Compute count of bytes
//     for (j = 0; j < E.numrows; j+=1)
//         totlen += E.row[j].size+1; // +1 is for "\n" at end of every row
//     *buflen = totlen;
//     totlen+=1; // Also make space for nulterm
//
//     p = buf = malloc(totlen);
//     for (j = 0; j < E.numrows; j+=1) {
//         memcpy(p,E.row[j].chars,E.row[j].size);
//         p += E.row[j].size;
//         *p = '\n';
//         p+=1;
//     }
//     *p = '\0';
//     return buf;
// }

// Set an editor status message for the second line of the status, at the
// end of the screen.
// fn editorSetStatusMessage(const char *fmt, ...) void {
//     va_list ap;
//     va_start(ap,fmt);
//     vsnprintf(state.statusmsg,sizeof(state.statusmsg),fmt,ap);
//     va_end(ap);
//     state.statusmsg_time = time(NULL);
// }

// fn handleSigWinCh() void {
//     updateWindowSize();
//     if (state.cy > state.screenrows) state.cy = state.screenrows - 1;
//     if (state.cx > state.screencols) state.cx = state.screencols - 1;
//     editorRefreshScreen();
// }

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.log.info("Usage: zzz <filename>", .{});
        std.process.exit(1);
    }

    // var a = "abc";
    // var b = "abc";
    // const message = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    // const message2 = [_]u8{ 'h', 'e', 'l', 'l', 'o' };

    // var c = a[0..a.len] == b[0..b.len];
    // var c = a == b;
    // var c = message == message2;
    // std.log.info("Equal: {}", .{c});

    var row = try Row.EditorRow.init(null, allocator);
    defer row.deinit();

    var c = row.hasOpenComment();
    std.log.info("C: {}", .{c});

    var editor = Editor.new();

    // TODO
    editor.updateSize(1, 1);

    // TODO
    // signal(SIGWINCH, handleSigWinCh);

    // state.selectSyntaxHighlight(args[1]);
    // state.editorOpen(argv[1]);

    var orig_termios = try enableRawMode(std.io.getStdIn());

    var key = try Key.readKey(std.io.getStdIn());
    std.log.info("Read: {}", .{key});

    var pos = try getCursorPosition(std.io.getStdIn(), std.io.getStdOut());
    std.log.info("Cursor pos: {}", .{pos});

    var size = try getWindowSize(std.io.getStdIn(), std.io.getStdOut());
    std.log.info("Window size: {}", .{size});

    try disableRawMode(&orig_termios, std.io.getStdIn());

    // editorSetStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find");
    // while (1) {
    //     editorRefreshScreen();
    //     editorProcessKeypress(STDIN_FILENO);
    // }
}
