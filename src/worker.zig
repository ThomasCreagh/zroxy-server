const std = @import("std");
const Connection = @import("connection.zig").Connection;
const posix = std.posix;
const linux = std.os.linux;

pub const Worker = struct {
    ring: linux.IoUring,
    connections: std.AutoHashMap(u64, *Connection),
    allocator: std.mem.Allocator,
    listen_fd: posix.socket_t,
    worker_id: usize,

    const RING_SIZE = 4096; // * 8;
    const MAX_ACCEPTS_PER_BATCH = 128;
    const CQE_BUF_SIZE = 64;

    pub fn init(allocator: std.mem.Allocator, listen_fd: posix.socket_t, worker_id: usize) !Worker {
        const ring = try linux.IoUring.init(RING_SIZE, 0);

        return .{
            .ring = ring,
            .connections = std.AutoHashMap(u64, *Connection).init(allocator),
            .allocator = allocator,
            .listen_fd = listen_fd,
            .worker_id = worker_id,
        };
    }

    pub fn run(self: *Worker) !void {
        try pinToCpu(self.worker_id);
        //std.debug.print("Worker {} pinned to CPU {}\n", .{ self.worker_id, self.worker_id });

        try self.queueAccepts(MAX_ACCEPTS_PER_BATCH);

        var stats_timer: usize = 0;
        var cqe_buf: [CQE_BUF_SIZE]linux.io_uring_cqe = undefined;

        while (true) {
            _ = try self.ring.submit_and_wait(1);

            const cqe_count = try self.ring.copy_cqes(cqe_buf[0..], 0);
            for (cqe_buf[0..cqe_count]) |cqe| {
                try self.handleCompletion(cqe);
            }

            stats_timer += cqe_count;
            if (stats_timer > 10_000) {
                stats_timer = 0;
                std.debug.print("Worker {}: {} active connections\n", .{
                    self.worker_id,
                    self.connections.count(),
                });
            }
        }
    }

    fn handleCompletion(self: *Worker, cqe: linux.io_uring_cqe) !void {
        const user_data = cqe.user_data;
        const result = cqe.res;

        if (user_data == 0) {
            if (result >= 0) {
                const client_fd: i32 = result;
                try self.addConnection(client_fd);
            }
            try self.queueAccepts(1);
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
                if (result == 0) {
                    conn.closing = true;
                    try self.closeConnection(conn);
                    return;
                }

                conn.client_data_len = @intCast(result);
                conn.client_data_sent = 0;

                conn.parseHost() catch {
                    std.debug.print("Failed to parse Host header\n", .{});
                    conn.closing = true;
                    try self.closeConnection(conn);
                    return;
                };

                if (conn.upstream_fd == null) {
                    const upstream_fd = try self.connectUpstream();
                    conn.upstream_fd = upstream_fd;
                    conn.state = .connecting_upstream;
                    try self.queueConnect(conn);
                } else {
                    conn.state = .forwarding_to_upstream;
                    try self.queueWriteToUpstream(conn);
                }
            },
            .connecting_upstream => {
                if (result < 0) {
                    std.debug.print("Failed to connect to upstream: {}\n", .{result});
                    conn.closing = true;
                    try self.closeConnection(conn);
                    return;
                }

                conn.state = .forwarding_to_upstream;
                try self.queueWriteToUpstream(conn);
            },
            .forwarding_to_upstream => {
                conn.client_data_sent += @intCast(result);

                if (conn.client_data_sent >= conn.client_data_len) {
                    conn.state = .reading_upstream_response;
                    conn.upstream_data_len = 0;
                    conn.upstream_data_sent = 0;
                    try self.queueReadFromUpstream(conn);
                } else {
                    try self.queueWriteToUpstream(conn);
                }
            },
            .reading_upstream_response => {
                if (result == 0) {
                    if (conn.upstream_fd) |fd| {
                        posix.close(fd);
                        conn.upstream_fd = null;
                    }

                    if (conn.upstream_data_len > 0) {
                        conn.state = .forwarding_to_client;
                        try self.queueWriteToClient(conn);
                    } else {
                        conn.state = .reading_client_request;
                        try self.queueReadFromClient(conn);
                    }
                    return;
                }

                conn.upstream_data_len = @intCast(result);
                conn.upstream_data_sent = 0;

                conn.state = .forwarding_to_client;
                try self.queueWriteToClient(conn);
            },
            .forwarding_to_client => {
                conn.upstream_data_sent += @intCast(result);

                if (conn.upstream_data_sent >= conn.upstream_data_len) {
                    if (conn.upstream_fd == null) {
                        conn.state = .reading_client_request;
                        try self.queueReadFromClient(conn);
                    } else {
                        conn.state = .reading_upstream_response;
                        try self.queueReadFromUpstream(conn);
                    }
                } else {
                    try self.queueWriteToClient(conn);
                }
            },
        }
    }

    fn addConnection(self: *Worker, fd: i32) !void {
        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);

        conn.* = Connection.init(fd, @intFromPtr(conn));

        try self.connections.put(@intFromPtr(conn), conn);

        try self.queueReadFromClient(conn); // queue init
    }

    fn connectUpstream(self: *Worker) !posix.socket_t {
        _ = self;
        return try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
    }
    fn queueConnect(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();

        conn.upstream_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, 8080),
            .addr = std.mem.nativeToBig(u32, 0x7F000001),
            .zero = [_]u8{0} ** 8,
        };

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

        linux.io_uring_sqe.prep_recv(
            sqe,
            conn.client_fd,
            conn.client_buf[0..],
            0,
        );

        sqe.user_data = conn.user_data;
    }

    fn queueWriteToUpstream(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();

        const to_write = conn.client_buf[conn.client_data_sent..conn.client_data_len];

        linux.io_uring_sqe.prep_send(
            sqe,
            conn.upstream_fd.?,
            to_write,
            linux.MSG.NOSIGNAL,
        );

        sqe.user_data = conn.user_data;
    }

    fn queueReadFromUpstream(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();

        linux.io_uring_sqe.prep_recv(
            sqe,
            conn.upstream_fd.?,
            conn.upstream_buf[0..],
            0,
        );

        sqe.user_data = conn.user_data;
    }

    fn queueWriteToClient(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();

        const to_write = conn.upstream_buf[conn.upstream_data_sent..conn.upstream_data_len];

        linux.io_uring_sqe.prep_send(
            sqe,
            conn.client_fd,
            to_write,
            linux.MSG.NOSIGNAL,
        );

        sqe.user_data = conn.user_data;
    }

    fn closeConnection(self: *Worker, conn: *Connection) !void {
        posix.close(conn.client_fd);
        if (conn.upstream_fd) |fd| {
            posix.close(fd);
            conn.upstream_fd = null;
        }

        if (self.connections.fetchRemove(@intFromPtr(conn))) |_| {
            self.allocator.destroy(conn);
        }
    }

    pub fn deinit(self: *Worker) void {
        var it = self.connections.valueIterator();
        while (it.next()) |conn| {
            posix.close(conn.*.client_fd);
            if (conn.*.upstream_fd) |fd| {
                posix.close(fd);
            }
            self.allocator.destroy(conn.*);
        }
        self.connections.deinit();
        self.ring.deinit();
    }
};

fn CPU_ZERO(set: *linux.cpu_set_t) void {
    @memset(set, 0);
}

fn CPU_SET(cpu: usize, set: *linux.cpu_set_t) void {
    const idx = cpu / @bitSizeOf(usize);
    const bit = cpu % @bitSizeOf(usize);
    set[idx] |= @as(usize, 1) << @intCast(bit);
}

fn pinToCpu(cpu_id: usize) !void {
    var set: linux.cpu_set_t = undefined;
    CPU_ZERO(&set);
    CPU_SET(cpu_id, &set);

    try linux.sched_setaffinity(
        0,
        @ptrCast(&set),
    );
}
