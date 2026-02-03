const std = @import("std");
const posix = std.posix;

const loop = @import("event/loop.zig");

pub fn main() !void {
    std.debug.print("server started...\n", .{});

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    const server_socket = try set_up_server_socket(8081, 10);
    defer posix.close(server_socket);

    try loop.init(server_socket, allocator);

    //    while (true) {
    //        const client_socket = get_client_socket(server_socket) catch continue;

    //        _ = try std.Thread.spawn(.{}, echo, .{client_socket});
    //    }
}

// (posix.BindError || posix.ListenError)
fn set_up_server_socket(port: u16, backlog: u31) !posix.socket_t {
    const server_socket = try get_server_socket();
    try listen_and_bind(server_socket, port, backlog);

    return server_socket;
}

fn listen_and_bind(socket: posix.socket_t, port: u16, backlog: u31) (posix.SetSockOptError || posix.BindError || posix.ListenError)!void {
    var server_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
        .zero = .{0} ** 8,
    };

    try posix.setsockopt(
        socket,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    try posix.bind(
        socket,
        @ptrCast(&server_addr),
        @sizeOf(@TypeOf(server_addr)),
    );

    try posix.listen(
        socket,
        backlog, // que up to "backlog" pending connections
    );
}

fn get_server_socket() posix.SocketError!posix.socket_t {
    const flags = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;

    const server_socket = try posix.socket(
        posix.AF.INET,
        flags,
        posix.IPPROTO.TCP,
    );

    return server_socket;
}

// fn get_client_socket(server_socket: posix.socket_t) posix.AcceptError!posix.socket_t {
//     var client_addr: posix.sockaddr.in = undefined;
//
//     var client_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));
//
//     const client_socket = try posix.accept(
//         server_socket,
//         @ptrCast(&client_addr),
//         &client_len,
//         0, // no flags same as INADDR_ANY
//     );
//     return client_socket;
// }
