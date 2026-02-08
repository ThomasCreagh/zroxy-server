const std = @import("std");
const Worker = @import("worker.zig").Worker;
const Connection = @import("connection.zig").Connection;

const linux = std.os.linux;

pub fn queueConnect(self: *Worker, conn: *Connection) !void {
    const sqe = try self.ring.get_sqe();
    linux.io_uring_sqe.prep_connect(
        sqe,
        conn.upstream_fd.?,
        @ptrCast(&conn.upstream_addr),
        @sizeOf(@TypeOf(conn.upstream_addr)),
    );
    sqe.user_data = conn.user_data;
}

pub fn queueMultishotAccept(self: *Worker) !void {
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

pub fn queueReadFromClient(self: *Worker, conn: *Connection) !void {
    const sqe = try self.ring.get_sqe();
    linux.io_uring_sqe.prep_recv(sqe, conn.client_fd, conn.client_buf[0..], 0);
    sqe.user_data = conn.user_data;
}

pub fn queueWriteToUpstream(self: *Worker, conn: *Connection) !void {
    const sqe = try self.ring.get_sqe();
    const data = conn.client_buf[conn.client_buf_sent..conn.client_buf_len];
    linux.io_uring_sqe.prep_send(sqe, conn.upstream_fd.?, data, linux.MSG.NOSIGNAL);
    sqe.user_data = conn.user_data;
}

pub fn queueReadFromUpstream(self: *Worker, conn: *Connection) !void {
    const sqe = try self.ring.get_sqe();
    const offset = conn.upstream_buf_len;
    linux.io_uring_sqe.prep_recv(sqe, conn.upstream_fd.?, conn.upstream_buf[offset..], 0);
    sqe.user_data = conn.user_data;
}

pub fn queueWriteToClient(self: *Worker, conn: *Connection) !void {
    const sqe = try self.ring.get_sqe();
    const data = conn.upstream_buf[conn.upstream_buf_sent..conn.upstream_buf_len];
    linux.io_uring_sqe.prep_send(sqe, conn.client_fd, data, linux.MSG.NOSIGNAL);
    sqe.user_data = conn.user_data;
}

pub fn queueSpliceToClient(self: *Worker, conn: *Connection) !void {
    const body_total = conn.response.content_length.?;
    const body_remaining = body_total - conn.body_bytes_spliced;

    if (body_remaining == 0) {
        if (conn.upstream_fd) |fd| {
            self.returnUpstreamToPool(fd);
            conn.upstream_fd = null;
        }
        conn.state = .reading_client_request;
        conn.response = .{};
        conn.request = .{};
        conn.client_buf_len = 0;
        conn.upstream_buf_len = 0;
        try self.queueReadFromClient(conn);
        return;
    }

    const sqe = try self.ring.get_sqe();

    linux.io_uring_sqe.prep_splice(
        sqe,
        conn.upstream_fd.?,
        @as(u64, @bitCast(@as(i64, -1))),
        conn.client_fd,
        @as(u64, @bitCast(@as(i64, -1))),
        @min(body_remaining, 65537),
    );
    sqe.user_data = conn.user_data;
}
