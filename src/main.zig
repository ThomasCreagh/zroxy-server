const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    std.debug.print("server started...\n", .{});

    const server_socket = try get_server_socket(8083, 10);
    defer posix.close(server_socket);

    while (true) {
        const client_socket = get_client_socket(server_socket) catch continue;
        defer posix.close(client_socket);

        echo(client_socket);
    }
}

fn get_server_socket(port: u16, backlog: u31) !posix.socket_t {
    const server_socket = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM,
        posix.IPPROTO.TCP,
    );

    var server_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
        .zero = .{0} ** 8,
    };

    try posix.bind(
        server_socket,
        @ptrCast(&server_addr),
        @sizeOf(@TypeOf(server_addr)),
    );

    try posix.listen(
        server_socket,
        backlog, // que up to "backlog" pending connections
    );

    return server_socket;
}

fn get_client_socket(server_socket: posix.socket_t) posix.AcceptError!posix.socket_t {
    var client_addr: posix.sockaddr.in = undefined;

    var client_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));

    const client_socket = try posix.accept(
        server_socket,
        @ptrCast(&client_addr),
        &client_len,
        0, // no flags
    );
    return client_socket;
}

fn echo(client_socket: posix.socket_t) void {
    var buf: [4096]u8 = undefined;

    while (true) {
        const bytes_read = posix.read(client_socket, &buf) catch |err| {
            std.debug.print("read failed. got and error: {}\n", .{err});
            continue;
        };

        if (bytes_read == 0) break;

        _ = posix.write(client_socket, buf[0..bytes_read]) catch |err| {
            std.debug.print("write failed. got and error: {}\n", .{err});
            continue;
        };
    }
}
