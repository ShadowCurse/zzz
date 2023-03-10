const std = @import("std");
const File = std.fs.File;
const Termios = std.os.termios;

const Editor = @import("editor.zig");
const Key = @import("key.zig");
const Row = @import("row.zig");
const Cursor = @import("cursor.zig");

// Raw mode: 1960 magic
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

fn disableRawMode(orig_termios: Termios, stdin: File) anyerror!void {
    std.log.info("disableRawMode", .{});
    try std.os.tcsetattr(stdin.handle, std.os.linux.TCSA.FLUSH, orig_termios);
}

const Size = struct { height: u32, width: u32 };
// Try to get the number of columns in the current terminal. If the ioctl()
// call fails the function will try to query the terminal itself.
// Returns 0 on success, -1 on error.
fn getWindowSize(in: File, out: File) anyerror!Size {
    // struct winsize ws;
    var ws: std.os.linux.winsize = undefined;

    const TIOCGWINSZ: u32 = 0x5413;
    if (std.os.linux.ioctl(1, TIOCGWINSZ, @ptrToInt(&ws)) == -1 or ws.ws_col == 0) {
        // Get the initial position so we can restore it later.
        var orig_pos = try Cursor.getCursorPosition(in, out);
        // Go to right/bottom margin and get position.
        _ = try out.write("\x1b[999C\x1b[999B");
        // Get new position
        var pos = try Cursor.getCursorPosition(in, out);

        // Restore position.
        var seq: [32]u8 = undefined;
        var fixed_allo = std.heap.FixedBufferAllocator.init(&seq);
        const alloc = fixed_allo.allocator();
        _ = try std.fmt.allocPrint(alloc, "\x1b[{d};%{d}H", .{ orig_pos.row, orig_pos.col });
        _ = try out.write(&seq);

        return .{
            .height = pos.row,
            .width = pos.col,
          };
    } else {
        return .{
            .height = ws.ws_row,
            .width = ws.ws_col,
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

    var editor = try Editor.new(allocator);
    defer editor.deinit();

    const window_size = try getWindowSize(std.io.getStdIn(), std.io.getStdOut());
    editor.updateSize(window_size.height, window_size.width);

    // TODO
    // signal(SIGWINCH, handleSigWinCh);

    editor.selectSyntaxHighlight(args[1]);
    try editor.openFile(args[1]);

    const orig_termios = try enableRawMode(std.io.getStdIn());

    var exit: bool = false;
    while (!exit) {
        try editor.refreshScreen(std.io.getStdOut());
        var key = try Key.readKey(std.io.getStdIn());
        exit = try editor.processKeypress(key);
    }
    try disableRawMode(orig_termios, std.io.getStdIn());
}
