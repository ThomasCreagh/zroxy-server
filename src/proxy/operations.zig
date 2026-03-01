const std = @import("std");
const Worker = @import("worker.zig").Worker;
const Connection = @import("connection.zig").Connection;
const TunnelOp = @import("connection.zig").TunnelOp;

const linux = std.os.linux;

pub fn queueConnect(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    linux.io_uring_sqe.prep_connect(
        sqe,
        conn.upstream_fd.?,
        @ptrCast(&conn.upstream_addr),
        @sizeOf(@TypeOf(conn.upstream_addr)),
    );
    sqe.user_data = conn.user_data;
    conn.pending_ops += 1;
}

pub fn queueMultishotAccept(worker: *Worker) !void {
    const sqe = try worker.ring.get_sqe();
    linux.io_uring_sqe.prep_multishot_accept(sqe, worker.listen_fd, null, null, 0);
    sqe.user_data = 0;
}

pub fn queueReadFromClient(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    linux.io_uring_sqe.prep_recv(sqe, conn.client_fd, conn.client_buf[0..], 0);
    sqe.user_data = conn.user_data;
    conn.pending_ops += 1;
}

pub fn queueWriteToUpstream(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    const data = conn.client_buf[conn.client_buf_sent..conn.client_buf_len];
    linux.io_uring_sqe.prep_send(sqe, conn.upstream_fd.?, data, linux.MSG.NOSIGNAL);
    sqe.user_data = conn.user_data;
    conn.pending_ops += 1;
}

pub fn queueReadFromUpstream(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    const offset = conn.upstream_buf_len;
    linux.io_uring_sqe.prep_recv(sqe, conn.upstream_fd.?, conn.upstream_buf[offset..], 0);
    sqe.user_data = conn.user_data;
    conn.pending_ops += 1;
}

pub fn queueWriteToClient(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    const data = conn.upstream_buf[conn.upstream_buf_sent..conn.upstream_buf_len];
    linux.io_uring_sqe.prep_send(sqe, conn.client_fd, data, linux.MSG.NOSIGNAL);
    sqe.user_data = conn.user_data;
    conn.pending_ops += 1;
}

pub fn queueSpliceToClient(worker: *Worker, conn: *Connection) !void {
    const body_total = conn.response.content_length.?;
    const body_remaining = body_total - conn.body_bytes_spliced;

    if (body_remaining == 0) {
        if (conn.upstream_fd) |fd| {
            worker.returnUpstreamToPool(fd);
            conn.upstream_fd = null;
        }
        conn.state = .reading_client_request;
        conn.response = .{};
        conn.request = .{};
        conn.client_buf_len = 0;
        conn.upstream_buf_len = 0;
        try queueReadFromClient(worker, conn);
        return;
    }

    const sqe = try worker.ring.get_sqe();
    linux.io_uring_sqe.prep_splice(
        sqe,
        conn.upstream_fd.?,
        @as(u64, @bitCast(@as(i64, -1))),
        conn.client_fd,
        @as(u64, @bitCast(@as(i64, -1))),
        @min(body_remaining, 65537),
    );
    sqe.user_data = conn.user_data;
    conn.pending_ops += 1;
}

pub fn queueTunnelReadClient(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    linux.io_uring_sqe.prep_recv(sqe, conn.client_fd, conn.tun_c2u_buf[0..], 0);
    sqe.user_data = Connection.encodeUserData(conn, .read_client);
    conn.pending_ops += 1;
}

pub fn queueTunnelWriteUpstream(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    const data = conn.tun_c2u_buf[0..conn.tun_c2u_len];
    linux.io_uring_sqe.prep_send(sqe, conn.upstream_fd.?, data, linux.MSG.NOSIGNAL);
    sqe.user_data = Connection.encodeUserData(conn, .write_upstream);
    conn.pending_ops += 1;
}

pub fn queueTunnelReadUpstream(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    linux.io_uring_sqe.prep_recv(sqe, conn.upstream_fd.?, conn.tun_u2c_buf[0..], 0);
    sqe.user_data = Connection.encodeUserData(conn, .read_upstream);
    conn.pending_ops += 1;
}

pub fn queueTunnelWriteClient(worker: *Worker, conn: *Connection) !void {
    const sqe = try worker.ring.get_sqe();
    const data = conn.tun_u2c_buf[0..conn.tun_u2c_len];
    linux.io_uring_sqe.prep_send(sqe, conn.client_fd, data, linux.MSG.NOSIGNAL);
    sqe.user_data = Connection.encodeUserData(conn, .write_client);
    conn.pending_ops += 1;
}
