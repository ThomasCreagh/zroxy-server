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
    upstream_addr: posix.sockaddr.in,

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
            .upstream_addr = undefined,
        };
    }
};
