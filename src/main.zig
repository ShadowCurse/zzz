const std = @import("std");
const File = std.fs.File;
const Termios = std.os.termios;

const Editor = @import("editor.zig");
const Key = @import("key.zig");
const Row = @import("row.zig");
const Cursor = @import("cursor.zig");

// Raw mode: 1960 magic
fn enableRawMode(stdin: File) anyerror!Termios {
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
    // Return each byte, or zero for timeout.
    raw.cc[5] = 0;
    // 100 ms timeout (unit is tens of second).
    raw.cc[7] = 1;

    // put terminal in raw mode after flushing
    try std.os.tcsetattr(stdin.handle, std.os.linux.TCSA.FLUSH, raw);

    return orig_termios;
}

fn disableRawMode(orig_termios: Termios, stdin: File) anyerror!void {
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

fn handle_SIGWINCH(_: c_int) callconv(.C) void {
    const std_in = std.io.getStdIn();
    const std_out = std.io.getStdOut();

    const window_size = getWindowSize(std_in, std_out) catch {
        return;
    };
    global_editor.update_size(window_size);
}

const GlobalState = struct {
    out: File,
    editor: *Editor,

    const Self = @This();

    fn update_size(self: *Self, size: Size) void {
        self.editor.updateSize(size.height, size.width);
        self.editor.refreshScreen(self.out) catch {
            return;
        };
    }
};
var global_editor: GlobalState = undefined;

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

    const std_in = std.io.getStdIn();
    const std_out = std.io.getStdOut();

    global_editor.editor = &editor;
    global_editor.out = std_out;

    const window_size = try getWindowSize(std_in, std_out);
    editor.updateSize(window_size.height, window_size.width);

    const action = std.os.linux.Sigaction{
        .handler = .{ .handler = handle_SIGWINCH },
        .mask = std.os.linux.empty_sigset,
        .flags = 0,
        .restorer = null,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.WINCH, &action, null);

    editor.selectSyntaxHighlight(args[1]);
    try editor.openFile(args[1]);

    const orig_termios = try enableRawMode(std_in);

    var exit: bool = false;
    while (!exit) {
        try editor.refreshScreen(std_out);
        var key = try Key.readKey(std_in);
        exit = try editor.processKeypress(key);
    }
    try disableRawMode(orig_termios, std_in);
}
