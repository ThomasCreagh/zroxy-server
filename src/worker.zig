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
    next_user_data: u64,

    const RING_SIZE = 4096;
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
            .next_user_data = 1,
        };
    }

    pub fn run(self: *Worker) !void {
        try pinToCpu(self.worker_id);
        std.debug.print("Worker {} pinned to CPU {}\n", .{ self.worker_id, self.worker_id });

        try self.queueAccepts(MAX_ACCEPTS_PER_BATCH);

        var stats_timer: usize = 0;
        var cqe_buf: [CQE_BUF_SIZE]linux.io_uring_cqe = undefined;

        while (true) {
            _ = try self.ring.submit_and_wait(1);

            const cqe_count = try self.ring.copy_cqes(cqe_buf[0..], 0); // returns io completions, waiting if neccassery
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
            .reading => {
                if (result == 0) { // eof
                    conn.closing = true;
                    try self.closeConnection(conn);
                } else {
                    conn.bytes_to_write = @intCast(result);
                    try self.queueWrite(conn);
                }
            },
            .writing => {
                conn.bytes_written += @intCast(result);
                if (conn.bytes_written >= conn.bytes_to_write) {
                    conn.bytes_written = 0;
                    conn.bytes_to_write = 0;
                    try self.queueRead(conn);
                } else {
                    try self.queueWrite(conn); // partial write, continue writing
                }
            },
        }
    }

    fn addConnection(self: *Worker, fd: i32) !void {
        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);

        //const user_data = self.next_user_data;
        //self.next_user_data += 1;

        conn.* = Connection.init(fd, @intFromPtr(conn));

        try self.connections.put(@intFromPtr(conn), conn);

        try self.queueRead(conn); // queue init
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

    fn queueRead(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        conn.state = .reading;

        linux.io_uring_sqe.prep_recv(
            sqe,
            conn.fd,
            conn.buf[0..],
            0,
        );

        sqe.user_data = conn.user_data;
    }

    fn queueWrite(self: *Worker, conn: *Connection) !void {
        const sqe = try self.ring.get_sqe();
        conn.state = .writing;

        const to_write = conn.buf[conn.bytes_written..conn.bytes_to_write];

        linux.io_uring_sqe.prep_send(
            sqe,
            conn.fd,
            to_write,
            linux.MSG.NOSIGNAL,
        );

        sqe.user_data = conn.user_data;
    }

    fn closeConnection(self: *Worker, conn: *Connection) !void {
        // @intFromPtr(conn)
        if (self.connections.fetchRemove(@intFromPtr(conn))) |_| {
            //const conn = kv.value;
            posix.close(conn.fd);
            self.allocator.destroy(conn);
        }
    }

    pub fn deinit(self: *Worker) void {
        var it = self.connections.valueIterator();
        while (it.next()) |conn| {
            posix.close(conn.*.fd);
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

    //if (rc != 0) return error.CpuAffinityFailed;
}
