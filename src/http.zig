const std = @import("std");
const log = std.log;
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
pub const Method = std.http.Method;

fn parseMethod(s: []const u8) ?std.http.Method {
    if (mem.eql(u8, s, "GET")) return Method.GET;
    if (std.mem.eql(u8, s, "POST")) return Method.POST;
    if (mem.eql(u8, s, "PUT")) return Method.PUT;
    if (mem.eql(u8, s, "DELETE")) return Method.DELETE;
    if (mem.eql(u8, s, "HEAD")) return Method.HEAD;
    if (mem.eql(u8, s, "PATCH")) return Method.PATCH;
    if (mem.eql(u8, s, "OPTIONS")) return Method.OPTIONS;
    if (mem.eql(u8, s, "CONNECT")) return Method.CONNECT;
    if (mem.eql(u8, s, "TRACE")) return Method.TRACE;
    return null;
}

pub const Request = struct {
    host: ?[]const u8 = null,
    port: u16 = 80,
    path: []const u8 = undefined,
    method: Method = Method.GET,
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
        self.method = parseMethod(status_it.next().?).?;
        self.path = status_it.next().?;
    }

    fn parseHeader(self: *Request, line: []const u8) !void {
        if (startsWithIgnoreCase(line, "content-length:")) {
            try self.parseContentLength(mem.trim(u8, line[15..], "\t "));
        } else if (startsWithIgnoreCase(line, "transfer-encoding:")) {
            try self.parseTransferEncoding(mem.trim(u8, line[18..], "\t "));
        } else if (startsWithIgnoreCase(line, "connection:")) {
            try self.parseConnection(mem.trim(u8, line[11..], "\t "));
        } else if (startsWithIgnoreCase(line, "host:")) {
            try self.parseHost(mem.trim(u8, line[5..], "\t "));
        }
    }

    fn parseContentLength(self: *Request, value: []const u8) !void {
        self.content_length = std.fmt.parseInt(usize, value, 10) catch {
            return ParseError.BadContentLength;
        };
    }

    fn parseTransferEncoding(self: *Request, value: []const u8) !void {
        self.is_chunked = mem.eql(u8, value, "chunked");
    }

    fn parseConnection(self: *Request, value: []const u8) !void {
        self.keep_alive = mem.eql(u8, value, "keep-alive");
    }

    fn parseHost(self: *Request, value: []const u8) !void {
        if (mem.indexOf(u8, value, ":")) |colon_pos| {
            self.host = value[0..colon_pos];
            self.port = std.fmt.parseInt(u16, value[colon_pos + 1 ..], 10) catch 80;
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
        var headers_end: usize = undefined;
        var headers_end_len: usize = undefined;

        if (mem.indexOf(u8, data, "\r\n\r\n")) |num_4| {
            headers_end = num_4;
            headers_end_len = 4;
        } else {
            if (mem.indexOf(u8, data, "\n\n")) |num_2| {
                headers_end = num_2;
                headers_end_len = 2;
            } else {
                self.headers_complete = false;
                return;
            }
        }

        self.headers_complete = true;
        self.headers_end_pos = headers_end + headers_end_len; // + \r\n\r\n or \n\n

        const headers = data[0..headers_end];
        var lines = mem.splitScalar(u8, headers, '\n');

        const status_line = lines.next() orelse return ParseError.InvalidResponse;
        try self.parseStatusLine(status_line);

        while (lines.next()) |line| {
            var trimmed: []const u8 = undefined;
            if (headers_end_len == 4) {
                trimmed = line[0 .. line.len - 1];
            } else {
                trimmed = line[0..line.len];
            }
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
            try self.parseConnection(mem.trim(u8, line[11..], "\t "));
        }
    }

    fn parseContentLength(self: *Response, value: []const u8) !void {
        self.content_length = std.fmt.parseInt(usize, value, 10) catch {
            return ParseError.BadContentLength;
        };
    }

    fn parseTransferEncoding(self: *Response, value: []const u8) !void {
        self.is_chunked = mem.eql(u8, value, "chunked");
    }

    fn parseConnection(self: *Response, value: []const u8) !void {
        self.keep_alive = mem.eql(u8, value, "keep-alive");
    }
};
