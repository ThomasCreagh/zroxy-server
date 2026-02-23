const std = @import("std");
const operations = @import("operations.zig");
const handlers = @import("handlers.zig");
const cache_mod = @import("caching.zig");
const http = @import("../http.zig");
const Connection = @import("connection.zig").Connection;
const UpstreamManager = @import("upstream.zig").UpstreamManager;

const posix = std.posix;
const linux = std.os.linux;
const log = std.log;

pub const Worker = struct {
    ring: linux.IoUring,
    connections: std.AutoHashMap(u64, *Connection),
    allocator: std.mem.Allocator,
    listen_fd: posix.socket_t,
    worker_id: usize,
    upstream: UpstreamManager,
    upstream_pool: std.ArrayList(posix.socket_t),
    cache: cache_mod.Cache,

    const MAX_POOL_SIZE = 50;
    const RING_SIZE = 8192;
    const MAX_ACCEPTS_PER_BATCH = 256;
    const CQE_BUF_SIZE = 128;
    pub fn init(allocator: std.mem.Allocator, listen_fd: posix.socket_t, worker_id: usize) !Worker {
        return .{
            .ring = try linux.IoUring.init(RING_SIZE, 0),
            .connections = std.AutoHashMap(u64, *Connection).init(allocator),
            .allocator = allocator,
            .listen_fd = listen_fd,
            .worker_id = worker_id,
            .upstream = UpstreamManager.init(allocator),
            .upstream_pool = try std.ArrayList(posix.socket_t).initCapacity(allocator, MAX_POOL_SIZE),
            .cache = try cache_mod.Cache.init(allocator, 100 * 1024 * 1024),
        };
    }

    pub fn run(self: *Worker) !void {
        try pinToCpu(self.worker_id);

        try self.queueMultishotAccept();

        var cqe_buf: [CQE_BUF_SIZE]linux.io_uring_cqe = undefined;

        while (true) {
            _ = try self.ring.submit_and_wait(1);
            const cqe_count = try self.ring.copy_cqes(&cqe_buf, 0);

            for (cqe_buf[0..cqe_count]) |cqe| {
                self.handleCompletion(cqe) catch |err| {
                    log.err("Handler error: {}", .{err});
                };
            }
        }
    }

    fn handleCompletion(self: *Worker, cqe: linux.io_uring_cqe) !void {
        //log.debug("handleCompletion", .{});
        const user_data = cqe.user_data;
        const result = cqe.res;

        if (user_data == 0) {
            if (result >= 0) {
                try self.addConnection(result);
            } else {
                log.warn("Multishot accept ended: {}, re-queuing", .{result});
                try self.queueMultishotAccept();
            }
            return;
        }

        const conn: *Connection = @ptrFromInt(user_data);
        if (conn.closing) return;

        if (result < 0) {
            conn.closing = true;
            try self.closeConnection(conn);
            return;
        }

        switch (conn.state) {
            .reading_client_request => {
                self.onClientRead(conn, result) catch |err| {
                    log.err("  onClientRead error: {}\n", .{err});
                    conn.closing = true;
                    self.closeConnection(conn) catch {};
                    return;
                };
            },
            .connecting_upstream => {
                self.onUpstreamConnected(conn, result) catch |err| {
                    log.err("  onUpstreamConnected error: {}\n", .{err});
                    conn.closing = true;
                    self.closeConnection(conn) catch {};
                    return;
                };
            },
            .forwarding_to_upstream => {
                self.onUpstreamWritten(conn, result) catch |err| {
                    log.err("  onUpstreamWritten error: {}\n", .{err});
                    conn.closing = true;
                    self.closeConnection(conn) catch {};
                    return;
                };
            },
            .reading_upstream_response => {
                self.onUpstreamRead(conn, result) catch |err| {
                    log.err("  onUpstreamRead error: {}\n", .{err});
                    conn.closing = true;
                    self.closeConnection(conn) catch {};
                    return;
                };
            },
            .forwarding_to_client => {
                self.onClientWritten(conn, result) catch |err| {
                    log.err("  onClientWritten error: {}\n", .{err});
                    conn.closing = true;
                    self.closeConnection(conn) catch {};
                    return;
                };
            },
            .splicing_to_client => {
                self.onSpliceCompleted(conn, result) catch |err| {
                    log.err("  onSpliceCompleted error: {}\n", .{err});
                    conn.closing = true;
                    self.closeConnection(conn) catch {};
                    return;
                };
            },
        }
    }

    pub fn getUpstreamFromPool(self: *Worker) !struct { fd: posix.socket_t, is_new: bool } {
        if (self.upstream_pool.pop()) |fd| {
            return .{ .fd = fd, .is_new = false };
        }
        const fd = try self.upstream.createSocket();
        const flag: c_int = 1;
        try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&flag));
        return .{ .fd = fd, .is_new = true };
    }

    pub fn returnUpstreamToPool(self: *Worker, fd: posix.socket_t) void {
        if (self.upstream_pool.items.len < MAX_POOL_SIZE) {
            self.upstream_pool.append(self.allocator, fd) catch {
                posix.close(fd);
            };
        } else {
            posix.close(fd);
        }
    }

    pub fn addConnection(self: *Worker, fd: i32) !void {
        const conn = try self.allocator.create(Connection);
        conn.* = Connection.init(fd, @intFromPtr(conn));
        try self.connections.put(@intFromPtr(conn), conn);
        try self.queueReadFromClient(conn);
    }

    pub fn closeConnection(self: *Worker, conn: *Connection) !void {
        posix.close(conn.client_fd);
        if (conn.upstream_fd) |fd| posix.close(fd);

        if (self.connections.fetchRemove(@intFromPtr(conn))) |_| {
            self.allocator.destroy(conn);
        }
    }

    pub fn deinit(self: *Worker) void {
        var it = self.connections.valueIterator();
        while (it.next()) |conn| {
            posix.close(conn.*.client_fd);
            if (conn.*.upstream_fd) |fd| posix.close(fd);
            self.allocator.destroy(conn.*);
        }
        self.connections.deinit();
        self.ring.deinit();
        self.cache.deinit();
    }

    // handelers
    pub inline fn onClientRead(self: *Worker, conn: *Connection, bytes: i32) !void {
        return handlers.onClientRead(self, conn, bytes);
    }

    pub inline fn onUpstreamConnected(self: *Worker, conn: *Connection, bytes: i32) !void {
        return handlers.onUpstreamConnected(self, conn, bytes);
    }

    pub inline fn onUpstreamWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
        return handlers.onUpstreamWritten(self, conn, bytes);
    }

    pub inline fn onUpstreamRead(self: *Worker, conn: *Connection, bytes: i32) !void {
        return handlers.onUpstreamRead(self, conn, bytes);
    }

    pub inline fn onClientWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
        return handlers.onClientWritten(self, conn, bytes);
    }

    pub inline fn onSpliceCompleted(self: *Worker, conn: *Connection, bytes: i32) !void {
        return handlers.onSpliceCompleted(self, conn, bytes);
    }

    // operations
    pub inline fn queueConnect(self: *Worker, conn: *Connection) !void {
        return operations.queueConnect(self, conn);
    }

    pub inline fn queueReadFromClient(self: *Worker, conn: *Connection) !void {
        return operations.queueReadFromClient(self, conn);
    }

    pub inline fn queueMultishotAccept(self: *Worker) !void {
        return operations.queueMultishotAccept(self);
    }

    pub inline fn queueWriteToUpstream(self: *Worker, conn: *Connection) !void {
        return operations.queueWriteToUpstream(self, conn);
    }

    pub inline fn queueReadFromUpstream(self: *Worker, conn: *Connection) !void {
        return operations.queueReadFromUpstream(self, conn);
    }

    pub inline fn queueWriteToClient(self: *Worker, conn: *Connection) !void {
        return operations.queueWriteToClient(self, conn);
    }

    pub inline fn queueSpliceToClient(self: *Worker, conn: *Connection) !void {
        return operations.queueSpliceToClient(self, conn);
    }
};

fn pinToCpu(cpu_id: usize) !void {
    var set: linux.cpu_set_t = undefined;
    @memset(&set, 0);

    const idx = cpu_id / @bitSizeOf(usize);
    const bit = cpu_id % @bitSizeOf(usize);
    set[idx] |= @as(usize, 1) << @intCast(bit);

    try linux.sched_setaffinity(0, @ptrCast(&set));
}
