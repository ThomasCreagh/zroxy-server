const std = @import("std");
const Worker = @import("worker.zig").Worker;
const posix = std.posix;
const linux = std.os.linux;

const BACKLOG = 4096;

pub const Server = struct {
    workers: []Worker,
    threads: []std.Thread,
    allocator: std.mem.Allocator,
    listening_sockets: []posix.socket_t,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, port: u16, num_workers: usize) !Server {
        const workers = try allocator.alloc(Worker, num_workers);
        const threads = try allocator.alloc(std.Thread, num_workers);
        const listening_sockets = try allocator.alloc(posix.socket_t, num_workers);

        for (listening_sockets, 0..) |*socket, i| {
            socket.* = try createListenSocket(port);
            std.log.info("Created listen socket {} on port {}\n", .{ i, port });
        }

        for (workers, 0..) |*worker, i| {
            worker.* = try Worker.init(allocator, listening_sockets[i], i);
        }

        return .{
            .workers = workers,
            .threads = threads,
            .allocator = allocator,
            .listening_sockets = listening_sockets,
            .port = port,
        };
    }

    pub fn run(self: *Server) !void {
        for (self.workers, 0..) |*worker, i| {
            self.threads[i] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        }

        for (self.threads) |thread| {
            thread.join();
        }
    }

    pub fn deinit(self: *Server) void {
        for (self.listening_sockets) |socket| {
            posix.close(socket);
        }
        for (self.workers) |*worker| {
            worker.deinit();
        }
        self.allocator.free(self.listening_sockets);
        self.allocator.free(self.workers);
        self.allocator.free(self.threads);
    }
};

fn createListenSocket(port: u16) !posix.socket_t {
    const socket = try posix.socket(
        posix.AF.INET, // ipv4
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(socket);

    var server_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
        .zero = .{0} ** 8,
    };

    const reuseport: c_int = 1; // allows reuse of port
    try posix.setsockopt(
        socket,
        posix.SOL.SOCKET,
        posix.SO.REUSEPORT,
        std.mem.asBytes(&reuseport),
    );

    const reuseaddr: c_int = 1; // allows reuse address
    try posix.setsockopt(
        socket,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        std.mem.asBytes(&reuseaddr),
    );

    try posix.bind(
        socket,
        @ptrCast(&server_addr),
        @sizeOf(@TypeOf(server_addr)),
    );

    try posix.listen(
        socket,
        BACKLOG, // que up to "backlog" pending connections
    );

    return socket;
}
