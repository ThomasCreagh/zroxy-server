const std = @import("std");
const http = @import("../http.zig");

pub const CacheEntry = struct {
    response_headers: []u8,
    response_body: []u8,
    content_length: usize,
    status_code: u16,
    timestamp: i64,
    last_accessed: i64 = 0,
    max_age: i64 = 300,

    pub const CacheStats = struct {
        hits: std.atomic.Value(u64) = .init(0),
        misses: std.atomic.Value(u64) = .init(0),
        total_hit_ns: std.atomic.Value(u64) = .init(0),
        total_miss_ns: std.atomic.Value(u64) = .init(0),

        pub fn recordHit(self: *CacheStats, ns: u64) void {
            _ = self.hits.fetchAdd(1, .monotonic);
            _ = self.total_hit_ns.fetchAdd(ns, .monotonic);
        }

        pub fn recordMiss(self: *CacheStats, ns: u64) void {
            _ = self.misses.fetchAdd(1, .monotonic);
            _ = self.total_miss_ns.fetchAdd(ns, .monotonic);
        }

        pub fn report(self: *CacheStats) void {
            const h = self.hits.load(.monotonic);
            const m = self.misses.load(.monotonic);
            const avg_hit = if (h > 0) self.total_hit_ns.load(.monotonic) / h else 0;
            const avg_miss = if (m > 0) self.total_miss_ns.load(.monotonic) / m else 0;
            std.log.info("Cache hits = {d}", .{h});
            std.log.info("Misses = {d}", .{m});
            std.log.info("Avg_hit = {d}us", .{avg_hit / 1000});
            std.log.info("Avg_miss = {d}us", .{avg_miss / 1000});
        }
    };

    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.response_headers);
        allocator.free(self.response_body);
    }
};

pub const Cache = struct {
    entries: std.AutoHashMap(u64, CacheEntry),
    allocator: std.mem.Allocator,
    max_size: usize,
    current_size: usize,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !Cache {
        return .{
            .entries = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .allocator = allocator,
            .max_size = max_size,
            .current_size = 0,
        };
    }

    pub fn get(self: *Cache, key: u64) ?*CacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.getPtr(key)) |entry| {
            if (isExpired(entry)) {
                var removed = self.entries.fetchRemove(key).?;
                const entry_size = removed.value.response_headers.len + removed.value.response_body.len;
                removed.value.deinit(self.allocator);
                self.current_size -= entry_size;
                return null;
            }

            entry.last_accessed = std.time.timestamp();
            return entry;
        }
        return null;
    }

    pub fn put(self: *Cache, key: u64, entry: CacheEntry) !void { // ← u64 key
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry_size = entry.response_headers.len + entry.response_body.len;

        while (self.current_size + entry_size > self.max_size) {
            try self.evictUnused();
        }

        try self.entries.put(key, entry);
        self.current_size += entry_size;
    }

    pub fn evictUnused(self: *Cache) !void {
        if (self.entries.count() == 0) return error.CacheCountZero;

        var unused_key: ?u64 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_accessed < oldest_time) {
                oldest_time = kv.value_ptr.last_accessed;
                unused_key = kv.key_ptr.*;
            }
        }

        if (unused_key) |key| {
            var removed = self.entries.fetchRemove(key).?;
            const entry_size = removed.value.response_headers.len + removed.value.response_body.len;

            removed.value.deinit(self.allocator);
            self.current_size -= entry_size;
        }
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
    }
};

pub fn makeCacheKey(host: []const u8, path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(host);
    hasher.update(path);
    return hasher.final();
}

pub fn isExpired(entry: *const CacheEntry) bool {
    const now = std.time.timestamp();
    return (now - entry.timestamp) > entry.max_age;
}

pub fn shouldCache(status: http.Status, method: http.Method) bool {
    if (method != .GET) return false;
    return switch (status) {
        .ok => true,
        .moved_permanently => true,
        .not_found => true,
        else => false,
    };
}
