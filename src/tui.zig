const std = @import("std");
const Server = @import("proxy/server.zig").Server;
const posix = std.posix;

const MENU_WIDTH = 34;
const DIVIDER_COL = MENU_WIDTH + 1;

var g_original_termios: posix.termios = undefined;

pub const Tui = struct {
    server: *Server = undefined,
    mutex: std.Thread.Mutex = .{},
    log_row: u16 = 3,
    term_rows: u16 = 24,
    term_cols: u16 = 80,

    pub fn init(self: *Tui) !void {
        try self.getTermSize();
        try self.drawChrome();
    }

    fn getTermSize(self: *Tui) !void {
        var ws: posix.winsize = undefined;
        _ = std.os.linux.ioctl(posix.STDOUT_FILENO, 0x5413, @intFromPtr(&ws));
        self.term_rows = ws.row;
        self.term_cols = ws.col;
    }

    fn drawChrome(self: *Tui) !void {
        var buf: [4096]u8 = undefined;
        var stdout_impl = std.fs.File.stdout().writer(&buf);
        const w = &stdout_impl.interface;

        try w.writeAll("\x1b[2J");
        try w.writeAll("\x1b[1;1H\x1b[7m zroxy-server commands \x1b[0m");
        try w.writeAll("\x1b[1;36H\x1b[7m logs \x1b[0m");
        var row: u16 = 1;
        while (row <= self.term_rows) : (row += 1) {
            try w.print("\x1b[{d};{d}H|", .{ row, DIVIDER_COL });
        }
        try w.writeAll("\x1b[3;1H  block <url>");
        try w.writeAll("\x1b[4;1H  unblock <url>");
        try w.writeAll("\x1b[5;1H  quit");
        try w.print("\x1b[{d};1H Enter command: ", .{self.term_rows});
        try w.flush();
    }

    pub fn appendLog(self: *Tui, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var buf: [512]u8 = undefined;
        var stdout_impl = std.fs.File.stdout().writer(&buf);
        const w = &stdout_impl.interface;

        if (self.log_row >= self.term_rows) {
            self.log_row = 3;
            var row: u16 = 3;
            while (row < self.term_rows) : (row += 1) {
                w.print("\x1b[{d};{d}H\x1b[K", .{ row, DIVIDER_COL + 2 }) catch return;
            }
        }

        w.print("\x1b[s\x1b[{d};{d}H", .{ self.log_row, DIVIDER_COL + 2 }) catch return;
        w.print(fmt, args) catch return;
        w.writeAll("\x1b[u") catch return;
        w.flush() catch return;

        self.log_row += 1;
    }

    pub fn runInputLoop(self: *Tui) !void {
        const stdin = std.fs.File.stdin();

        const original_termios = try posix.tcgetattr(stdin.handle);
        g_original_termios = original_termios;
        var raw = original_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        try posix.tcsetattr(stdin.handle, .FLUSH, raw);

        defer {
            posix.tcsetattr(stdin.handle, .FLUSH, g_original_termios) catch {};
            var buf: [64]u8 = undefined;
            var stdout_impl = std.fs.File.stdout().writer(&buf);
            const w = &stdout_impl.interface;
            w.writeAll("\x1b[?25h\x1b[2J\x1b[H") catch {};
            w.flush() catch {};
        }

        // handle ctrl+c via sigaction so we can restore terminal first
        const handler = struct {
            fn handle(_: c_int) callconv(.c) void {
                // restore terminal
                var buf: [64]u8 = undefined;
                var stdout_impl = std.fs.File.stdout().writer(&buf);
                const w = &stdout_impl.interface;
                posix.tcsetattr(std.fs.File.stdin().handle, .FLUSH, g_original_termios) catch {};
                w.writeAll("\x1b[?25h\x1b[2J\x1b[H") catch {};
                w.flush() catch {};
                posix.exit(0);
            }
        };
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = handler.handle },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &sa, null);

        var cmd_buf: [256]u8 = undefined;
        var cmd_len: usize = 0;

        while (true) {
            var byte: [1]u8 = undefined;
            _ = try stdin.read(&byte);

            switch (byte[0]) {
                '\r', '\n' => {
                    const cmd = std.mem.trim(u8, cmd_buf[0..cmd_len], " ");
                    self.handleCommand(cmd);
                    cmd_len = 0;

                    self.mutex.lock();
                    defer self.mutex.unlock();
                    var buf: [64]u8 = undefined;
                    var stdout_impl = std.fs.File.stdout().writer(&buf);
                    const w = &stdout_impl.interface;
                    try w.print("\x1b[{d};1H\x1b[2K Enter command: ", .{self.term_rows});
                    try w.flush();
                },
                127, 8 => {
                    if (cmd_len > 0) {
                        cmd_len -= 1;
                        self.mutex.lock();
                        defer self.mutex.unlock();
                        var buf: [16]u8 = undefined;
                        var stdout_impl = std.fs.File.stdout().writer(&buf);
                        const w = &stdout_impl.interface;
                        try w.writeAll("\x1b[D \x1b[D");
                        try w.flush();
                    }
                },
                3 => return, // ctrl+c
                else => {
                    if (cmd_len < cmd_buf.len - 1 and byte[0] >= 32) {
                        cmd_buf[cmd_len] = byte[0];
                        cmd_len += 1;
                        self.mutex.lock();
                        defer self.mutex.unlock();
                        var buf: [8]u8 = undefined;
                        var stdout_impl = std.fs.File.stdout().writer(&buf);
                        const w = &stdout_impl.interface;
                        try w.writeByte(byte[0]);
                        try w.flush();
                    }
                },
            }
        }
    }

    fn handleCommand(self: *Tui, cmd: []const u8) void {
        if (std.mem.startsWith(u8, cmd, "block ")) {
            const host = cmd[6..];
            self.server.blockHost(host) catch |err| {
                self.appendLog("block failed: {}", .{err});
                return;
            };
            self.appendLog("blocked: {s}", .{host});
        } else if (std.mem.startsWith(u8, cmd, "unblock ")) {
            const host = cmd[8..];
            self.server.unblockHost(host) catch |err| {
                self.appendLog("unblock failed: {}", .{err});
                return;
            };
            self.appendLog("unblocked: {s}", .{host});
        } else if (std.mem.startsWith(u8, cmd, "quit")) {
            self.appendLog("quitting...", .{});
            posix.raise(posix.SIG.INT) catch {};
        } else if (cmd.len > 0) {
            self.appendLog("unknown command: {s}", .{cmd});
        }
    }
};
