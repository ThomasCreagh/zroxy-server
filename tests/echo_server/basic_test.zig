const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.debug.print("Connecting...\n", .{});
    const stream = try net.tcpConnectToHost(gpa.allocator(), "127.0.0.1", 8081);
    defer stream.close();

    std.debug.print("Writing...\n", .{});
    _ = try stream.write("Hello");

    std.debug.print("Reading...\n", .{});
    var buf: [1024]u8 = undefined;
    const n = try stream.read(&buf);

    std.debug.print("Got: {s}\n", .{buf[0..n]});
}
