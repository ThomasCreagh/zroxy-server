const std = @import("std");
const posix = std.posix;
const tui = @import("tui.zig");
const Server = @import("proxy/server.zig").Server;

const PORT = 8081;
const WORKERS = 6;

var g_tui: tui.Tui = .{};

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = "[" ++ @tagName(level) ++ "] ";
    g_tui.appendLog(prefix ++ fmt, args);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    try g_tui.init();

    var server = try Server.init(allocator, PORT, WORKERS);
    defer server.deinit();

    const server_thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    defer server_thread.join();

    try g_tui.runInputLoop();
}
