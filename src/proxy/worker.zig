const std = @import("std");
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
            .upstream = UpstreamManager.init("127.0.0.1", 8080),
        };
    }

    pub fn run(self: *Worker) !void {
        try pinToCpu(self.worker_id);

        try self.queueAccepts(MAX_ACCEPTS_PER_BATCH);

        var cqe_buf: [CQE_BUF_SIZE]linux.io_uring_cqe = undefined;

        while (true) {
            _ = try self.ring.submit_and_wait(1);

            const cqe_count = try self.ring.copy_cqes(cqe_buf[0..], 0);
            for (cqe_buf[0..cqe_count]) |cqe| {
                self.handleCompletion(cqe) catch |err| {
                    std.debug.print("Error handling completion: {}\n", .{err});
                };
            }
        }
    }

    fn handleCompletion(self: *Worker, cqe: linux.io_uring_cqe) !void {
        const user_data = cqe.user_data;
        const result = cqe.res;

        if (user_data == 0) {
            if (result >= 0) {
                try self.addConnection(result);
            }
            try self.queueAccepts(1);
            return;
        }

        const conn: *Connection = @ptrFromInt(user_data);
        if (conn.closing) return;

        if (result < 0) {
            conn.closing = true;
            return self.closeConnection(conn);
        }

        switch (conn.state) {
            .reading_client_request => try self.onClientRead(conn, result),
            .connecting_upstream => try self.onUpstreamConnected(conn, result),
            .forwarding_to_upstream => try self.onUpstreamWritten(conn, result),
            .reading_upstream_response => try self.onUpstreamRead(conn, result),
            .forwarding_to_client => try self.onClientWritten(conn, result),
        }
    }

    fn onClientRead(self: *Worker, conn: *Connection, bytes: i32) !void {
        if (bytes == 0) {
            conn.closing = true;
            return self.closeConnection(conn);
        }

        conn.client_data_len = @intCast(bytes);
        conn.client_data_sent = 0;

        try http.parseHost(conn);

        const upstream_fd = try self.upstream.createSocket();
        conn.upstream_fd = upstream_fd;
        conn.upstream_addr = self.upstream.getAddress();
        conn.state = .connecting_upstream;

        try self.queueConnect(conn);
    }

    fn onUpstreamConnected(self: *Worker, conn: *Connection, result: i32) !void {
        // accept 0 or -EISCONN as success
        if (result != 0 and result != -106) {
            conn.closing = true;
            return self.closeConnection(conn);
        }

        conn.state = .forwarding_to_upstream;
        try self.queueWriteToUpstream(conn);
    }

    fn onUpstreamWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
        conn.client_data_sent += @intCast(bytes);

        if (conn.client_data_sent >= conn.client_data_len) {
            // start reading response
            conn.state = .reading_upstream_response;
            conn.upstream_data_len = 0;
            conn.upstream_data_sent = 0;
            try self.queueReadFromUpstream(conn);
        } else {
            // continue writing
            try self.queueWriteToUpstream(conn);
        }
    }

    fn onUpstreamRead(self: *Worker, conn: *Connection, bytes: i32) !void {
        if (bytes == 0) {
            // upstream closed, close upstream but keep client alive
            if (conn.upstream_fd) |fd| {
                posix.close(fd);
                conn.upstream_fd = null;
            }

            if (conn.upstream_data_len > 0) {
                // send remaining data
                conn.state = .forwarding_to_client;
                try self.queueWriteToClient(conn);
            } else {
                // ready for next request
                conn.state = .reading_client_request;
                try self.queueReadFromClient(conn);
            }
            return;
        }

        conn.upstream_data_len = @intCast(bytes);
        conn.upstream_data_sent = 0;
        conn.state = .forwarding_to_client;
        try self.queueWriteToClient(conn);
    }

    fn onClientWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
        conn.upstream_data_sent += @intCast(bytes);

        if (conn.upstream_data_sent >= conn.upstream_data_len) {
            // response sent
            if (conn.upstream_fd) |_| {
                // keep-alive: read more from upstream
                conn.state = .reading_upstream_response;
                try self.queueReadFromUpstream(conn);
            } else {
                // upstream closed, wait for next client request
                conn.state = .reading_client_request;
                try self.queueReadFromClient(conn);
            }
        } else {
            // continue writing
            try self.queueWriteToClient(conn);
        }
    }

    // queue operations
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

    fn queueAccepts(self: *Worker, count: usize) !void {
        for (0..count) |_| {
            const sqe = try self.ring.get_sqe();
            linux.io_uring_sqe.prep_accept(
                sqe,
                self.listen_fd,
                null,
                null,
                posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            );
            sqe.user_data = 0;
        }
    }

    fn queueReadFromClient(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        linux.io_uring_sqe.prep_recv(sqe, conn.client_fd, conn.client_buf[0..], 0);
        sqe.user_data = conn.user_data;
    }

    fn queueWriteToUpstream(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        const data = conn.client_buf[conn.client_data_sent..conn.client_data_len];
        linux.io_uring_sqe.prep_send(sqe, conn.upstream_fd.?, data, linux.MSG.NOSIGNAL);
        sqe.user_data = conn.user_data;
    }

    fn queueReadFromUpstream(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        linux.io_uring_sqe.prep_recv(sqe, conn.upstream_fd.?, conn.upstream_buf[0..], 0);
        sqe.user_data = conn.user_data;
    }

    fn queueWriteToClient(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        const data = conn.upstream_buf[conn.upstream_data_sent..conn.upstream_data_len];
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
    const CPU_SETSIZE = 1024;
    const cpu_set_t = [CPU_SETSIZE / @bitSizeOf(usize)]usize;

    var set: cpu_set_t = undefined;
    @memset(&set, 0);

    const idx = cpu_id / @bitSizeOf(usize);
    const bit = cpu_id % @bitSizeOf(usize);
    set[idx] |= @as(usize, 1) << @intCast(bit);

    try linux.sched_setaffinity(0, @ptrCast(&set));
}

