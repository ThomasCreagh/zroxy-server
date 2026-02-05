const std = @import("std");
const Connection = @import("proxy/connection.zig").Connection;

pub fn parseHost(conn: *Connection) !void {
    _ = conn;
}
pub fn futureParseHost(conn: *Connection) !void {
    const request = conn.client_buf[0..conn.client_data_len];

    var lines = std.mem.tokenizeAny(u8, request, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "host:")) {
            const host_value = std.mem.trim(u8, line[5..], "\t ");

            if (std.mem.indexOf(u8, host_value, ":")) |colon_pos| {
                conn.upstream_host = host_value[0..colon_pos];
                conn.upstream_port = std.fmt.parseInt(u8, host_value[colon_pos + 1 ..], 10) catch 80;
            } else {
                conn.upstream_host = host_value;
                conn.upstream_port = 80;
            }
            return;
        }
    }
    return error.NoHostHeader;
}
