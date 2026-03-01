const std = @import("std");
const operations = @import("operations.zig");
const handlers = @import("handlers.zig");
const cache_mod = @import("caching.zig");
const http = @import("../http.zig");
const Connection = @import("connection.zig").Connection;
const TunnelOp = @import("connection.zig").TunnelOp;
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
        try operations.queueMultishotAccept(self);

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
        const user_data = cqe.user_data;
        const result = cqe.res;

        // Multishot accept — user_data == 0, no Connection pointer.
        if (user_data == 0) {
            if (result >= 0) {
                try self.addConnection(result);
            } else {
                log.warn("Multishot accept ended: {}, re-queuing", .{result});
                try operations.queueMultishotAccept(self);
            }
            return;
        }

        const decoded = Connection.decodeUserData(user_data);
        const conn = decoded.ptr;
        const op = decoded.op;

        if (conn.pending_ops > 0) conn.pending_ops -= 1;

        if (conn.closing) {
            if (conn.pending_ops == 0) {
                try self.freeConnection(conn);
            }
            return;
        }

        if (conn.state == .tunneling) {
            if (result < 0) {
                conn.closing = true;
                if (conn.pending_ops == 0) try self.freeConnection(conn);
                return;
            }
            try self.tunnelStateMachine(conn, op, result);
            return;
        }

        if (result < 0) {
            conn.closing = true;
            if (conn.pending_ops == 0) try self.freeConnection(conn);
            return;
        }
        try self.stateMachine(conn, result);
    }

    fn stateMachine(self: *Worker, conn: *Connection, result: i32) !void {
        switch (conn.state) {
            .reading_client_request => handlers.onClientRead(self, conn, result) catch |err| {
                log.err("onClientRead: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .connecting_upstream => handlers.onUpstreamConnected(self, conn, result) catch |err| {
                log.err("onUpstreamConnected: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .forwarding_to_upstream => handlers.onUpstreamWritten(self, conn, result) catch |err| {
                log.err("onUpstreamWritten: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .reading_upstream_response => handlers.onUpstreamRead(self, conn, result) catch |err| {
                log.err("onUpstreamRead: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .forwarding_to_client => handlers.onClientWritten(self, conn, result) catch |err| {
                log.err("onClientWritten: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .splicing_to_client => handlers.onSpliceCompleted(self, conn, result) catch |err| {
                log.err("onSpliceCompleted: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .tunneling => unreachable,
        }
    }

    fn tunnelStateMachine(self: *Worker, conn: *Connection, op: TunnelOp, result: i32) !void {
        switch (op) {
            .read_client => handlers.onTunnelClientRead(self, conn, result) catch |err| {
                log.err("onTunnelClientRead: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .write_upstream => handlers.onTunnelUpstreamWritten(self, conn, result) catch |err| {
                log.err("onTunnelUpstreamWritten: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .read_upstream => handlers.onTunnelUpstreamRead(self, conn, result) catch |err| {
                log.err("onTunnelUpstreamRead: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .write_client => handlers.onTunnelClientWritten(self, conn, result) catch |err| {
                log.err("onTunnelClientWritten: {}", .{err});
                conn.closing = true;
                if (conn.pending_ops == 0) self.freeConnection(conn) catch {};
            },
            .none => {},
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
        try operations.queueReadFromClient(self, conn);
    }

    pub fn closeConnection(self: *Worker, conn: *Connection) !void {
        conn.closing = true;
        posix.close(conn.client_fd);
        if (conn.upstream_fd) |fd| {
            posix.close(fd);
            conn.upstream_fd = null;
        }
        if (conn.pending_ops == 0) {
            try self.freeConnection(conn);
        }
    }

    pub fn freeConnection(self: *Worker, conn: *Connection) !void {
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
};

fn pinToCpu(cpu_id: usize) !void {
    var set: linux.cpu_set_t = undefined;
    @memset(&set, 0);
    const idx = cpu_id / @bitSizeOf(usize);
    const bit = cpu_id % @bitSizeOf(usize);
    set[idx] |= @as(usize, 1) << @intCast(bit);
    try linux.sched_setaffinity(0, @ptrCast(&set));
}
