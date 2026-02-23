const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const UpstreamManager = struct {
    allocator: std.mem.Allocator,
    dns_cache: std.AutoHashMap(u64, CachedAddress),

    const CachedAddress = struct {
        addr: posix.sockaddr.in,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator) UpstreamManager {
        return .{
            .allocator = allocator,
            .dns_cache = std.AutoHashMap(u64, CachedAddress).init(allocator),
        };
    }

    pub fn resolveHost(self: *UpstreamManager, host: []const u8, port: u16) !posix.sockaddr.in {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(host);
        hasher.update(std.mem.asBytes(&port));
        const cache_key = hasher.final();

        if (self.dns_cache.get(cache_key)) |cached| {
            const now = std.time.timestamp();
            if (now - cached.timestamp < 300) {
                return cached.addr;
            }
        }

        if (parseIpv4(host)) |ip_addr| {
            const addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = ip_addr,
                .zero = [_]u8{0} ** 8,
            };
            try self.dns_cache.put(cache_key, .{ .addr = addr, .timestamp = std.time.timestamp() });
            return addr;
        }

        const addr = try self.dnsLookup(host, port);
        try self.dns_cache.put(cache_key, .{ .addr = addr, .timestamp = std.time.timestamp() });
        return addr;
    }

    fn dnsLookup(self: *UpstreamManager, host: []const u8, port: u16) !posix.sockaddr.in {
        const address_list = try std.net.getAddressList(self.allocator, host, port);
        defer address_list.deinit();

        if (address_list.addrs.len == 0) return error.NoDnsResults;

        for (address_list.addrs) |addr| {
            if (addr.any.family == posix.AF.INET) {
                return addr.in.sa;
            }
        }

        return error.NoIpv4Address;
    }

    fn parseIpv4(host: []const u8) ?u32 {
        var octets: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, host, '.');
        var i: usize = 0;

        while (iter.next()) |part| : (i += 1) {
            if (i >= 4) return null;
            octets[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        }

        if (i != 4) return null;

        return std.mem.nativeToBig(u32, @as(u32, octets[0]) << 24 |
            @as(u32, octets[1]) << 16 |
            @as(u32, octets[2]) << 8 |
            @as(u32, octets[3]));
    }

    pub fn createSocket(self: *UpstreamManager) !posix.socket_t {
        _ = self;
        return try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
    }

    pub fn deinit(self: *UpstreamManager) void {
        self.dns_cache.deinit();
    }
};
