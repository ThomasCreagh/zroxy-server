const std = @import("std");
const posix = std.posix;

const BUF_SIZE = 16384; // 16 KB

pub const Connection = struct {
    client_fd: posix.socket_t,
    upstream_fd: ?posix.socket_t,

    client_buf: [BUF_SIZE]u8,
    upstream_buf: [BUF_SIZE]u8,

    client_data_len: usize,
    client_data_sent: usize,
    upstream_data_len: usize,
    upstream_data_sent: usize,

    state: State,
    user_data: u64,
    closing: bool,

    upstream_host: ?[]const u8,
    upstream_port: u16,

    pub const State = enum {
        reading_client_request,
        connecting_upstream,
        forwarding_to_upstream,
        reading_upstream_response,
        forwarding_to_client,
    };

    pub fn init(fd: posix.socket_t, user_data: u64) Connection {
        return .{
            .client_fd = fd,
            .upstream_fd = null,
            .client_buf = undefined,
            .upstream_buf = undefined,
            .client_data_len = 0,
            .client_data_sent = 0,
            .upstream_data_len = 0,
            .upstream_data_sent = 0,
            .state = .reading_client_request,
            .user_data = user_data,
            .closing = false,
            .upstream_host = null,
            .upstream_port = 80,
        };
    }

    pub fn parseHost(self: *Connection) !void {
        const request = self.client_buf[0..self.client_data_len];

        var lines = std.mem.tokenizeAny(u8, request, "\r\n");
        _ = lines.next();

        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "host:")) {
                const host_value = std.mem.trim(u8, line[5..], "\t ");

                if (std.mem.indexOf(u8, host_value, ":")) |colon_pos| {
                    self.upstream_host = host_value[0..colon_pos];
                    self.upstream_port = std.fmt.parseInt(u8, host_value[colon_pos + 1 ..], 10) catch 80;
                } else {
                    self.upstream_host = host_value;
                    self.upstream_port = 80;
                }
                return;
            }
        }
        return error.NoHostHeader;
    }
};
