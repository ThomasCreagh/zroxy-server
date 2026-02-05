const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) !Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return error.InvalidMethod;
    }
};

pub const Status = enum(u16) {
    ok = 200,
    bad_request = 400,
    not_found = 404,
    internal_server_error = 500,
    bad_gateway = 502,
};

pub const Header = struct {
    header: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    version: []const u8,
    headers: std.ArrayList(Header),
    body: ?[]const u8,

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }
    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }
};

pub const Response = struct {
    status: Status,
    reason: []const u8,
    version: []const u8,
    header: std.ArrayList(Header),
    body: ?[]const u8,
};
