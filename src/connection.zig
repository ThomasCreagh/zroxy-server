const std = @import("std");
const posix = std.posix;

const BUF_SIZE = 16384; // 16 KB

pub const Connection = struct {
    fd: posix.socket_t,
    buf: [BUF_SIZE]u8,
    state: State,
    user_data: u64,
    bytes_to_write: usize,
    bytes_written: usize,
    closing: bool,

    pub const State = enum {
        reading,
        writing,
    };

    pub fn init(fd: posix.socket_t, user_data: u64) Connection {
        return .{
            .fd = fd,
            .buf = undefined,
            .state = .reading,
            .user_data = user_data,
            .bytes_to_write = 0,
            .bytes_written = 0,
            .closing = false,
        };
    }
};
