const std = @import("std");
const posix = std.posix;
const Server = @import("proxy/server.zig").Server;

const PORT = 8081;
const RING_PER_WORKER = 4096;
const WORKERS = 6;

pub const std_options: std.Options = .{
    .log_level = .info,
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
