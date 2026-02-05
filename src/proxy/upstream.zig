const std = @import("std");
const posix = std.posix;

pub const UpstreamManager = struct {
    target_host: []const u8,
    target_port: u16,

    pub fn init(host: []const u8, port: u16) UpstreamManager {
        return .{
            .target_host = host,
            .target_port = port,
        };
    }

    pub fn createSocket(self: *const UpstreamManager) !posix.socket_t {
        _ = self;
        return try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
    }

    pub fn getAddress(self: *const UpstreamManager) posix.sockaddr.in {
        return .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.target_port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
            .zero = [_]u8{0} ** 8,
        };
    }
};
