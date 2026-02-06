const std = @import("std");
const net = std.net;

pub fn main() !void {
    const address = try net.Address.parseIp("127.0.0.1", 8080);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.debug.print("Fast backend listening on 8080\n", .{});

    const response =
        \\HTTP/1.1 200 OK
        \\Content-Length: 13
        \\Connection: keep-alive
        \\
        \\Hello, World!
    ;

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleClient, .{ conn, response });
        thread.detach();
    }
}

fn handleClient(conn: net.Server.Connection, response: []const u8) void {
    defer conn.stream.close();

    var buf: [4096]u8 = undefined;

    while (true) {
        const n = conn.stream.read(&buf) catch return;
        if (n == 0) return;

        _ = conn.stream.writeAll(response) catch return;
    }
}
