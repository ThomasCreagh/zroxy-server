const std = @import("std");
const log = std.log;
const Connection = @import("connection.zig").Connection;
const UpstreamManager = @import("upstream.zig").UpstreamManager;
const http = @import("../http.zig");
const posix = std.posix;
const linux = std.os.linux;

pub const Worker = struct {
    ring: linux.IoUring,
    connections: std.AutoHashMap(u64, *Connection),
    allocator: std.mem.Allocator,
    listen_fd: posix.socket_t,
    worker_id: usize,
    upstream: UpstreamManager,
    upstream_pool: std.ArrayList(posix.socket_t),

    const MAX_POOL_SIZE = 50;
    const RING_SIZE = 8192;
    const MAX_ACCEPTS_PER_BATCH = 256;
    const CQE_BUF_SIZE = 128;
    pub fn init(allocator: std.mem.Allocator, listen_fd: posix.socket_t, worker_id: usize) !Worker {
        var worker = Worker{
            .ring = try linux.IoUring.init(RING_SIZE, 0),
            .connections = std.AutoHashMap(u64, *Connection).init(allocator),
            .allocator = allocator,
            .listen_fd = listen_fd,
            .worker_id = worker_id,
            .upstream = UpstreamManager.init("127.0.0.1", 8080),
            .upstream_pool = try std.ArrayList(posix.socket_t).initCapacity(allocator, MAX_POOL_SIZE),
        };

        const prewarm_count = 20;
        for (0..prewarm_count) |_| {
            const fd = worker.upstream.createSocket() catch |err| {
                log.warn("Failed to create prewarm socket: {}", .{err});
                break;
            };

            const flag: c_int = 1;
            posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&flag)) catch {
                posix.close(fd);
                continue;
            };

            const addr = worker.upstream.getAddress();
            posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch |err| {
                log.warn("Failed to prewarm connection: {}", .{err});
                posix.close(fd);
                break;
            };

            worker.upstream_pool.append(allocator, fd) catch {
                posix.close(fd);
                break;
            };
        }

        log.info("Worker {} initialized with {} pre-warmed connections", .{ worker_id, worker.upstream_pool.items.len });

        return worker;
    }

    pub fn run(self: *Worker) !void {
        try pinToCpu(self.worker_id);

        // Queue ONE multishot accept instead of 256 regular accepts
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
        }
    }

    fn onClientRead(self: *Worker, conn: *Connection, bytes: i32) !void {
        if (bytes == 0) {
            conn.closing = true;
            try self.closeConnection(conn);
            return;
        }

        conn.client_buf_len = @intCast(bytes);
        conn.client_buf_sent = 0;

        try conn.request.parse(conn.client_buf[0..conn.client_buf_len]);

        const upstream = try self.getUpstreamFromPool();
        conn.upstream_fd = upstream.fd;

        if (upstream.is_new) {
            conn.upstream_addr = self.upstream.getAddress();
            conn.state = .connecting_upstream;
            try self.queueConnect(conn);
        } else {
            // Already connected, skip to forwarding
            conn.state = .forwarding_to_upstream;
            try self.queueWriteToUpstream(conn);
        }
    }

    fn onUpstreamConnected(self: *Worker, conn: *Connection, result: i32) !void {
        //log.debug("onUpstreamConnected", .{});

        // accept 0 or -EISCONN as success
        if (result != 0 and result != -106) {
            conn.closing = true;
            return self.closeConnection(conn);
        }

        conn.state = .forwarding_to_upstream;
        try self.queueWriteToUpstream(conn);
    }

    fn onUpstreamWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
        //log.debug("onUpstreamWritten", .{});
        conn.client_buf_sent += @intCast(bytes);

        if (conn.client_buf_sent >= conn.client_buf_len) {
            conn.state = .reading_upstream_response;
            conn.upstream_buf_len = 0;
            conn.upstream_buf_sent = 0;
            try self.queueReadFromUpstream(conn);
        } else {
            try self.queueWriteToUpstream(conn);
        }
    }

    fn onUpstreamRead(self: *Worker, conn: *Connection, bytes: i32) !void {
        //log.debug("onUpstreamRead", .{});
        if (bytes == 0) {
            // EOF from upstream
            if (conn.upstream_fd) |fd| {
                //log.debug("onUpstreamRead: close fd", .{});
                posix.close(fd);
                conn.upstream_fd = null;
            }

            if (conn.upstream_buf_len > 0) {
                //log.debug("onUpstreamRead: write to client", .{});
                conn.state = .forwarding_to_client;
                try self.queueWriteToClient(conn);
            } else {
                //log.debug("onUpstreamRead: read next client request", .{});
                conn.state = .reading_client_request;
                conn.request = .{};
                conn.response = .{};
                try self.queueReadFromClient(conn);
            }
            return;
        }

        conn.upstream_buf_len += @intCast(bytes);
        conn.response.bytes_received += @intCast(bytes);

        if (!conn.response.headers_complete) {
            const data = conn.upstream_buf[0..conn.upstream_buf_len];

            //log.debug("onUpstreamRead: parse headers", .{});
            try conn.response.parse(data);

            if (!conn.response.headers_complete) {
                //log.debug("onUpstreamRead: headers not complete", .{});
                try self.queueReadFromUpstream(conn);
                return;
            }
        }

        conn.upstream_buf_sent = 0;
        conn.state = .forwarding_to_client;
        try self.queueWriteToClient(conn);
    }

    fn onClientWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
        conn.upstream_buf_sent += @intCast(bytes);

        if (conn.upstream_buf_sent >= conn.upstream_buf_len) {
            const response_complete = blk: {
                if (conn.response.is_chunked) {
                    break :blk false;
                } else if (conn.response.content_length) |expected| {
                    const body_received = conn.response.bytes_received - conn.response.headers_end_pos;
                    break :blk body_received >= expected;
                } else {
                    break :blk false;
                }
            };

            if (response_complete) {
                if (conn.upstream_fd) |fd| {
                    self.returnUpstreamToPool(fd);
                    conn.upstream_fd = null;
                }

                conn.state = .reading_client_request;
                conn.request = .{};
                conn.response = .{};
                conn.client_buf_len = 0;
                conn.upstream_buf_len = 0;
                try self.queueReadFromClient(conn);
            } else {
                conn.state = .reading_upstream_response;
                conn.upstream_buf_len = 0;
                try self.queueReadFromUpstream(conn);
            }
        } else {
            try self.queueWriteToClient(conn);
        }
    }
    fn getUpstreamFromPool(self: *Worker) !struct { fd: posix.socket_t, is_new: bool } {
        if (self.upstream_pool.pop()) |fd| {
            return .{ .fd = fd, .is_new = false };
        }
        const fd = try self.upstream.createSocket();
        const flag: c_int = 1;
        try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&flag));
        return .{ .fd = fd, .is_new = true };
    }

    fn returnUpstreamToPool(self: *Worker, fd: posix.socket_t) void {
        if (self.upstream_pool.items.len < MAX_POOL_SIZE) {
            self.upstream_pool.append(self.allocator, fd) catch {
                posix.close(fd);
            };
        } else {
            posix.close(fd);
        }
    }

    fn addConnection(self: *Worker, fd: i32) !void {
        const conn = try self.allocator.create(Connection);
        conn.* = Connection.init(fd, @intFromPtr(conn));
        try self.connections.put(@intFromPtr(conn), conn);
        try self.queueReadFromClient(conn);
    }

    fn queueConnect(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        linux.io_uring_sqe.prep_connect(
            sqe,
            conn.upstream_fd.?,
            @ptrCast(&conn.upstream_addr),
            @sizeOf(@TypeOf(conn.upstream_addr)),
        );
        sqe.user_data = conn.user_data;
    }

    fn queueMultishotAccept(self: *Worker) !void {
        const sqe = try self.ring.get_sqe();
        linux.io_uring_sqe.prep_multishot_accept(
            sqe,
            self.listen_fd,
            null,
            null,
            0,
        );
        sqe.user_data = 0;
    }

    fn queueReadFromClient(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        linux.io_uring_sqe.prep_recv(sqe, conn.client_fd, conn.client_buf[0..], 0);
        sqe.user_data = conn.user_data;
    }

    fn queueWriteToUpstream(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        const data = conn.client_buf[conn.client_buf_sent..conn.client_buf_len];
        linux.io_uring_sqe.prep_send(sqe, conn.upstream_fd.?, data, linux.MSG.NOSIGNAL);
        sqe.user_data = conn.user_data;
    }

    fn queueReadFromUpstream(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        const offset = conn.upstream_buf_len;
        linux.io_uring_sqe.prep_recv(sqe, conn.upstream_fd.?, conn.upstream_buf[offset..], 0);
        sqe.user_data = conn.user_data;
    }

    fn queueWriteToClient(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        const data = conn.upstream_buf[conn.upstream_buf_sent..conn.upstream_buf_len];
        linux.io_uring_sqe.prep_send(sqe, conn.client_fd, data, linux.MSG.NOSIGNAL);
        sqe.user_data = conn.user_data;
    }

    fn closeConnection(self: *Worker, conn: *Connection) !void {
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
