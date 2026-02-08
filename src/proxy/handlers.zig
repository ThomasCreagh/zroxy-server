const std = @import("std");
const Worker = @import("worker.zig").Worker;
const Connection = @import("connection.zig").Connection;

const posix = std.posix;

pub fn onClientRead(self: *Worker, conn: *Connection, bytes: i32) !void {
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

pub fn onUpstreamConnected(self: *Worker, conn: *Connection, result: i32) !void {
    //log.debug("onUpstreamConnected", .{});

    // accept 0 or -EISCONN as success
    if (result != 0 and result != -106) {
        conn.closing = true;
        return self.closeConnection(conn);
    }

    conn.state = .forwarding_to_upstream;
    try self.queueWriteToUpstream(conn);
}

pub fn onUpstreamWritten(self: *Worker, conn: *Connection, bytes: i32) !void {
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

pub fn onUpstreamRead(self: *Worker, conn: *Connection, bytes: i32) !void {
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

        conn.using_splice = blk: {
            if (conn.response.is_chunked) break :blk false;
            if (conn.response.content_length == null) break :blk false;
            // TODO: Dont splice if caching.
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
