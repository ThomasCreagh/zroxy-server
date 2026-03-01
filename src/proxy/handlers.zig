const std = @import("std");
const Worker = @import("worker.zig").Worker;
const Connection = @import("connection.zig").Connection;
const http = @import("../http.zig");

const posix = std.posix;
const log = std.log;

pub fn onClientRead(self: *Worker, conn: *Connection, bytes: i32) !void {
    if (bytes == 0) {
        conn.closing = true;
        try self.closeConnection(conn);
        return;
    }

    conn.client_buf_len = @intCast(bytes);
    conn.client_buf_sent = 0;

    try conn.request.parse(conn.client_buf[0..conn.client_buf_len]);

    const host = conn.request.host orelse return error.NoHostHeader;
    const port = conn.request.port;

    if (conn.request.method == .CONNECT) {
        log.info("CONNECT {s}:{d}", .{ host, port });

        const fd = try self.upstream.createSocket();
        const flag: c_int = 1;
        try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&flag));
        conn.upstream_fd = fd;

        conn.upstream_addr = try self.upstream.resolveHost(host, port);
        conn.state = .connecting_upstream;
        conn.is_tunnel = true;
        try self.queueConnect(conn);
        return;
    }

    log.info("{s} {s}:{d}{s}", .{ @tagName(conn.request.method), host, port, conn.request.path });

    const upstream = try self.getUpstreamFromPool();
    conn.upstream_fd = upstream.fd;

    if (upstream.is_new) {
        conn.upstream_addr = try self.upstream.resolveHost(host, port);
        conn.state = .connecting_upstream;
        try self.queueConnect(conn);
    } else {
        conn.state = .forwarding_to_upstream;
        try self.queueWriteToUpstream(conn);
    }
}

pub fn onUpstreamConnected(self: *Worker, conn: *Connection, result: i32) !void {
    // Accept 0 or -EISCONN as success.
    if (result != 0 and result != -106) {
        if (conn.is_tunnel) {
            _ = posix.write(conn.client_fd, "HTTP/1.1 502 Bad Gateway\r\n\r\n") catch {};
        }
        conn.closing = true;
        return self.closeConnection(conn);
    }

    if (conn.is_tunnel) {
        _ = try posix.write(conn.client_fd, "HTTP/1.1 200 Connection Established\r\n\r\n");

        conn.state = .tunneling;
        try self.queueTunnelReadClient(conn);
        try self.queueTunnelReadUpstream(conn);
        return;
    }

    conn.state = .forwarding_to_upstream;
    try self.queueWriteToUpstream(conn);
}

pub fn onTunnelClientRead(self: *Worker, conn: *Connection, bytes: i32) !void {
    if (bytes <= 0) {
        try self.closeConnection(conn);
        return;
    }
    conn.tun_c2u_len = @intCast(bytes);
    try self.queueTunnelWriteUpstream(conn);
}

pub fn onTunnelUpstreamWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
    if (bytes <= 0) {
        try self.closeConnection(conn);
        return;
    }
    conn.tun_c2u_len = 0;
    try self.queueTunnelReadClient(conn);
}

pub fn onTunnelUpstreamRead(self: *Worker, conn: *Connection, bytes: i32) !void {
    if (bytes <= 0) {
        try self.closeConnection(conn);
        return;
    }
    conn.tun_u2c_len = @intCast(bytes);
    try self.queueTunnelWriteClient(conn);
}

pub fn onTunnelClientWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
    if (bytes <= 0) {
        try self.closeConnection(conn);
        return;
    }
    conn.tun_u2c_len = 0;
    try self.queueTunnelReadUpstream(conn);
}

pub fn onUpstreamWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
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

pub fn onUpstreamRead(self: *Worker, conn: *Connection, bytes: i32) !void {
    if (bytes == 0) {
        if (conn.upstream_fd) |fd| {
            posix.close(fd);
            conn.upstream_fd = null;
        }

        if (conn.upstream_buf_len > 0) {
            conn.state = .forwarding_to_client;
            try self.queueWriteToClient(conn);
        } else {
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
        try conn.response.parse(data);

        if (!conn.response.headers_complete) {
            try self.queueReadFromUpstream(conn);
            return;
        }

        conn.using_splice = blk: {
            if (conn.response.is_chunked) break :blk false;
            if (conn.response.content_length == null) break :blk false;
            break :blk true;
        };
    }

    if (conn.upstream_buf_sent < conn.response.headers_end_pos) {
        conn.upstream_buf_sent = 0;
        conn.state = .forwarding_to_client;
        try self.queueWriteToClient(conn);
        return;
    }

    if (conn.using_splice) {
        conn.state = .splicing_to_client;
        try self.queueSpliceToClient(conn);
    } else {
        conn.upstream_buf_sent = 0;
        conn.state = .forwarding_to_client;
        try self.queueWriteToClient(conn);
    }
}

pub fn onClientWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
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

pub fn onSpliceCompleted(self: *Worker, conn: *Connection, bytes: i32) !void {
    if (bytes == 0) {
        conn.using_splice = false;
        conn.state = .reading_upstream_response;
        try self.queueReadFromUpstream(conn);
        return;
    }

    conn.body_bytes_spliced += @intCast(bytes);
    const body_total = conn.response.content_length.?;

    if (conn.body_bytes_spliced >= body_total) {
        if (conn.upstream_fd) |fd| {
            self.returnUpstreamToPool(fd);
            conn.upstream_fd = null;
        }
        conn.state = .reading_client_request;
        conn.request = .{};
        conn.response = .{};
        conn.client_buf_len = 0;
        conn.upstream_buf_len = 0;
        conn.body_bytes_spliced = 0;
        try self.queueReadFromClient(conn);
    } else {
        try self.queueSpliceToClient(conn);
    }
}
