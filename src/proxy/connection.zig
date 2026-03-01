const std = @import("std");
const http = @import("../http.zig");
const posix = std.posix;

const BUF_SIZE = 16384; // 16 KB

pub const TunnelOp = enum(u4) {
    none = 0,
    read_client = 1,
    write_upstream = 2,
    read_upstream = 3,
    write_client = 4,
};

pub const Connection = struct {
    client_fd: posix.socket_t,
    upstream_fd: ?posix.socket_t = null,

    client_buf: [BUF_SIZE]u8 = undefined,
    client_buf_len: usize = 0,
    client_buf_sent: usize = 0,

    upstream_buf: [BUF_SIZE]u8 = undefined,
    upstream_buf_len: usize = 0,
    upstream_buf_sent: usize = 0,

    state: State = .reading_client_request,
    user_data: u64,
    closing: bool = false,

    pending_ops: u32 = 0,

    body_bytes_spliced: usize = 0,
    using_splice: bool = false,

    upstream_addr: posix.sockaddr.in = undefined,

    request: http.Request = .{},
    response: http.Response = .{},

    is_tunnel: bool = false,

    tun_c2u_buf: [BUF_SIZE]u8 = undefined,
    tun_c2u_len: usize = 0,

    tun_u2c_buf: [BUF_SIZE]u8 = undefined,
    tun_u2c_len: usize = 0,

    pub fn encodeUserData(ptr: *Connection, op: TunnelOp) u64 {
        const addr = @intFromPtr(ptr);
        const op_bits: u64 = @intFromEnum(op);
        return (addr & 0xFFFFFFFFFFFFFFF0) | op_bits;
    }

    pub fn decodeUserData(user_data: u64) struct { ptr: *Connection, op: TunnelOp } {
        const addr = user_data & 0xFFFFFFFFFFFFFFF0;
        const op_bits: u4 = @truncate(user_data & 0xF);
        return .{
            .ptr = @ptrFromInt(addr),
            .op = @enumFromInt(op_bits),
        };
    }

    pub const State = enum {
        reading_client_request,
        connecting_upstream,
        forwarding_to_upstream,
        reading_upstream_response,
        forwarding_to_client,
        splicing_to_client,
        tunneling,
    };

    pub fn init(fd: posix.socket_t, user_data: u64) Connection {
        return .{
            .client_fd = fd,
            .user_data = user_data,
        };
    }
};
