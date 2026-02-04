const std = @import("std");
const http = @import("http.zig");
const mem = std.mem;

pub fn parse_request(allocator: mem.Allocator, raw_req: []const u8) !http.Request {
    var header_body = mem.tokenizeSequence(u8, raw_req, [_]u8{ 0xd, 0xa, 0xd, 0xa });
    const raw_header = header_body.next().?;
    var it = mem.tokenizeAny(u8, raw_header, [_]u8{ 0xa, 0xd, 0x20 });
    const method = str_to_method(it.next().?);
    const path = it.next().?;
    const version = it.next().?;
    const headers = get_headers(allocator, it.rest());

    return .{
        .method = method,
        .path = path,
        .version = version,
    };
}

fn get_headers(allocator: mem.Allocator, buf: []const u8) !std.ArrayList(http.Header) {
    var list = std.ArrayList(http.Header).initCapacity(allocator, 2);

    var lines = mem.tokenizeAny(u8, buf, [_]u8{ 0xa, 0xd });

    for (lines.next()) |line| {
        var line_it = mem.tokenizeSequence(u8, line, ": ");
        const header_ptr = allocator.create(http.Header);
        header_ptr.* = .{
            .header = line_it.next() orelse return error.BadRequest,
            .value = line_it.next() orelse return error.BadRequest,
        };
        try list.append(allocator, header_ptr.*);
    }

    return list;
}

fn str_to_method(str: []const u8) !http.Method {
    if (std.mem.eql(u8, str, "GET")) return http.Method.GET;
    if (std.mem.eql(u8, str, "POST")) return http.Method.POST;
    return error.NoMethodFound;
}
