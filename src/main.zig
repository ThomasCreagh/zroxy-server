const std = @import("std");
const posix = std.posix;
const Server = @import("proxy/server.zig").Server;

const PORT = 8081;
const RING_PER_WORKER = 4096;
const WORKERS = 6;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    var buf: [256]u8 = undefined;
    var stdout_impl = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_impl.interface;

    try stdout.print("server started on port {}...\n", .{PORT});
    try stdout.flush();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    var server = try Server.init(allocator, PORT, WORKERS);
    defer server.deinit();

    try stdout.print("Server listening on port {}\n", .{PORT});
    try stdout.print("Workers: {}\n", .{server.workers.len});
    try stdout.flush();

    try server.run();
}
