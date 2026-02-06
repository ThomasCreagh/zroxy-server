const std = @import("std");
const Connection = @import("proxy/connection.zig").Connection;

const ParseError = error{
    NoHostHeader,
    BadContentLength,
    BadTransferEncoding,
    BadConnectionValue,
};

pub const Status = std.http.Status;

pub const ConnectionState = enum {
    keep_alive,
    close,
    upgrade,
};

pub const TransferEncoding = enum {
    chunked,
    none,
};

pub fn parse(conn: *Connection) !void {
    _ = conn;
}

// parse Status codes
pub fn futureParseResponse(conn: *Connection) !void {
    const request = conn.client_buf[0..conn.client_data_len];

    var req_sep = std.mem.tokenizeSequence(u8, request, "\r\n\r\n");

    const head = req_sep.next().?;

    const maybe_body = req_sep.next();
    var body: []const u8 = undefined;
    var no_body = true;

    if (maybe_body) |raw_body| {
        body = raw_body;
        no_body = false;
    }
    var lines = std.mem.tokenizeAny(u8, head, "\r\n");

    try parseStatus(lines.next().?, conn);
    try parseHeader(lines, conn);

    if (conn.upstream_host == null) {
        return ParseError.NoHostHeader;
    }

    // try parseBody(body, conn);
}

fn parseStatus(line: []const u8, conn: *Connection) !void {
    var status_it = std.mem.tokenizeAny(u8, line, " \t");
    _ = status_it.next().?; // skip HTTP version

    const status_code = try std.fmt.parseInt(u16, status_it.next().?, 10);
    conn.status = @enumFromInt(status_code);
}

fn parseBody(body: []const u8, conn: *Connection) !void {
    _ = body;
    _ = conn;
}

fn parseHeader(it: std.mem.TokenIterator(u8), conn: *Connection) !void {
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "host:")) {
            try parseHost(
                std.mem.trim(u8, line[5..], "\t "),
                conn,
            );
        } else if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            try parseContentLength(
                std.mem.trim(u8, line[15..], "\t "),
                conn,
            );
        } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
            try parseTransferEncoding(
                std.mem.trim(u8, line[18..], "\t "),
                conn,
            );
        } else if (std.ascii.startsWithIgnoreCase(line, "connection:")) {
            try parseConnection(
                std.mem.trim(u8, line[11..], "\t "),
                conn,
            );
        }
    }
}

fn parseHost(value: []const u8, conn: *Connection) !void {
    if (std.mem.indexOf(u8, value, ":")) |colon_pos| {
        conn.upstream_host = value[0..colon_pos];
        conn.upstream_port = std.fmt.parseInt(u8, value[colon_pos + 1 ..], 10) catch 80;
    } else {
        conn.upstream_host = value;
        conn.upstream_port = 80;
    }
}

fn parseContentLength(value: []const u8, conn: *Connection) !void {
    conn.content_length = std.fmt.parseInt(u8, value, 10) catch {
        return ParseError.BadContentLength;
    };
}

fn parseTransferEncoding(value: []const u8, conn: *Connection) !void {
    if (std.ascii.startsWithIgnoreCase(value, "chunked")) {
        conn.transfer_encoding = .chunked;
    } else if (std.ascii.startsWithIgnoreCase(value, "none")) {
        conn.transfer_encoding = .none;
    } else {
        return ParseError.BadTransferEncoding;
    }
}

fn parseConnection(value: []const u8, conn: *Connection) !void {
    if (std.ascii.startsWithIgnoreCase(value, "keep-alive")) {
        conn.connection_state = .keep_alive;
    } else if (std.ascii.startsWithIgnoreCase(value, "close")) {
        conn.connection_state = .close;
    } else if (std.ascii.startsWithIgnoreCase(value, "upgrade")) {
        conn.connection_state = .upgrade;
    } else {
        return ParseError.BadConnectionValue;
    }
}
