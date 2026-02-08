const std = @import("std");
const http = @import("../http.zig");
const posix = std.posix;

const BUF_SIZE = 16384; // 16 KB

const WaitingStats = struct {
    total_ns: i128 = 0,
    count: usize = 0,
};

pub const Connection = struct {
    client_fd: posix.socket_t,
    upstream_fd: ?posix.socket_t = null,

    client_buf: [BUF_SIZE]u8 = undefined,
    upstream_buf: [BUF_SIZE]u8 = undefined,

    client_buf_len: usize = 0,
    client_buf_sent: usize = 0,
    upstream_buf_len: usize = 0,
    upstream_buf_sent: usize = 0,

    state: State = .reading_client_request,
    user_data: u64,
    closing: bool = false,

    body_bytes_spliced: usize = 0,
    using_splice: bool = false,

    upstream_addr: posix.sockaddr.in = undefined,

    request: http.Request = .{},
    response: http.Response = .{},

    pub const State = enum {
        reading_client_request,
        connecting_upstream,
        forwarding_to_upstream,
        reading_upstream_response,
        forwarding_to_client,
        splicing_to_client,
    };

    pub fn init(fd: posix.socket_t, user_data: u64) Connection {
        return .{
            .client_fd = fd,
            .user_data = user_data,
        };
    }
};
