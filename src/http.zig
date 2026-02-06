const std = @import("std");
const mem = std.mem;
const startsWithIgnoreCase = std.ascii.startsWithIgnoreCase;
const Connection = @import("proxy/connection.zig").Connection;

const ParseError = error{
    InvalidRequest,
    InvalidResponse,
    NoHostHeader,
    BadContentLength,
    BadTransferEncoding,
    BadConnectionValue,
};

pub const Status = std.http.Status;

pub const Request = struct {
    host: ?[]const u8 = null,
    port: u16 = 80,
    path: []const u8 = undefined,
    headers_complete: bool = false,
    content_length: ?usize = null,
    is_chunked: bool = false,
    keep_alive: bool = true, // HTTP/1.1 default
    bytes_received: usize = 0,
    headers_end_pos: usize = 0,

    pub fn parse(self: *Request, data: []const u8) !void {
        const headers_end = mem.indexOf(u8, data, "\r\n\r\n") orelse {
            self.headers_complete = false;
            return;
        };

        self.headers_complete = true;
        self.headers_end_pos = headers_end + 4; // + \r\n\r\n

        const headers = data[0..headers_end];
        var lines = mem.splitScalar(u8, headers, '\n');

        const status_line = lines.next() orelse return ParseError.InvalidResponse;
        try self.parseStatusLine(status_line);

        while (lines.next()) |line| {
            const trimmed = line[0 .. line.len - 1];
            if (trimmed.len == 0) continue;
            try self.parseHeader(trimmed);
        }
    }

    fn parseStatusLine(self: *Request, line: []const u8) !void {
        var status_it = mem.splitScalar(u8, line, ' ');
        _ = status_it.next().?; // skip HTTP method

        self.path = try std.fmt.parseInt(u16, status_it.next().?, 10);
    }

    fn parseHeader(self: *Request, line: []const u8) !void {
        if (startsWithIgnoreCase(line, "content-length:")) {
            try self.parseContentLength(mem.trim(u8, line[15..], "\t "));
        } else if (startsWithIgnoreCase(line, "transfer-encoding:")) {
            try self.parseTransferEncoding(mem.trim(u8, line[18..], "\t "));
        } else if (startsWithIgnoreCase(line, "connection:")) {
            try self.parseResponseConnection(mem.trim(u8, line[11..], "\t "));
        } else if (startsWithIgnoreCase(line, "host:")) {
            try self.parseResponseConnection(mem.trim(u8, line[5..], "\t "));
        }
    }

    fn parseContentLength(self: *Request, value: []const u8) !void {
        self.content_length = std.fmt.parseInt(u8, value, 10) catch {
            return ParseError.BadContentLength;
        };
    }

    fn parseTransferEncoding(self: *Request, value: []const u8) !void {
        self.is_chunked = mem.eql(u8, value, "chunked");
    }

    fn parseConnection(self: *Request, value: []const u8) !void {
        self.keep_alive = mem.eq(u8, value, "keep-alive");
    }

    fn parseHost(self: *Request, value: []const u8) !void {
        if (mem.indexOf(u8, value, ":")) |colon_pos| {
            self.host = value[0..colon_pos];
            self.port = std.fmt.parseInt(u8, value[colon_pos + 1 ..], 10) catch 80;
        } else {
            self.host = value;
            self.port = 80;
        }
    }
};

pub const Response = struct {
    status: Status = undefined,
    headers_complete: bool = false,
    content_length: ?usize = null,
    is_chunked: bool = false,
    keep_alive: bool = true, // HTTP/1.1 default
    bytes_received: usize = 0,
    headers_end_pos: usize = 0,

    pub fn parse(self: *Response, data: []const u8) !void {
        const headers_end = mem.indexOf(u8, data, "\r\n\r\n") orelse {
            self.headers_complete = false;
            return;
        };

        self.headers_complete = true;
        self.headers_end_pos = headers_end + 4; // + \r\n\r\n

        const headers = data[0..headers_end];
        var lines = mem.splitScalar(u8, headers, '\n');

        const status_line = lines.next() orelse return ParseError.InvalidResponse;
        try self.parseStatusLine(status_line);

        while (lines.next()) |line| {
            const trimmed = line[0 .. line.len - 1];
            if (trimmed.len == 0) continue;
            try self.parseHeader(trimmed);
        }
    }

    fn parseStatusLine(self: *Response, line: []const u8) !void {
        var status_it = mem.splitScalar(u8, line, ' ');
        _ = status_it.next().?; // skip HTTP version

        const status_code = try std.fmt.parseInt(u16, status_it.next().?, 10);
        self.status = @enumFromInt(status_code);
    }

    fn parseHeader(self: *Response, line: []const u8) !void {
        if (startsWithIgnoreCase(line, "content-length:")) {
            try self.parseContentLength(mem.trim(u8, line[15..], "\t "));
        } else if (startsWithIgnoreCase(line, "transfer-encoding:")) {
            try self.parseTransferEncoding(mem.trim(u8, line[18..], "\t "));
        } else if (startsWithIgnoreCase(line, "connection:")) {
            try self.parseResponseConnection(mem.trim(u8, line[11..], "\t "));
        }
    }

    fn parseContentLength(self: *Response, value: []const u8) !void {
        self.content_length = std.fmt.parseInt(u8, value, 10) catch {
            return ParseError.BadContentLength;
        };
    }

    fn parseTransferEncoding(self: *Response, value: []const u8) !void {
        self.is_chunked = mem.eql(u8, value, "chunked");
    }

    fn parseConnection(self: *Response, value: []const u8) !void {
        self.keep_alive = mem.eq(u8, value, "keep-alive");
    }
};
