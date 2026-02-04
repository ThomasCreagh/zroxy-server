const std = @import("std");
const net = std.net;
const Thread = std.Thread;

const THREADS = 6;
const CLIENTS_PER_THREAD = 125;
const MSG_SIZE = 1024 * 1024;
const ROUNDS = 10;

const Stats = struct {
    bytes: std.atomic.Value(u64),
    start_time: i64,

    fn init() Stats {
        return .{
            .bytes = std.atomic.Value(u64).init(0),
            .start_time = std.time.milliTimestamp(),
        };
    }

    fn add(self: *Stats, n: u64) void {
        _ = self.bytes.fetchAdd(n, .monotonic);
    }

    fn report(self: *Stats) void {
        const elapsed: f64 = @floatFromInt(std.time.milliTimestamp() - self.start_time);
        const total: f64 = @floatFromInt(self.bytes.load(.monotonic));
        //const throughput = @as(f64, @floatFromInt(total)) /
        //@as(f64, @floatFromInt(elapsed)) * 1000.0 / 1024.0 / 1024.0;

        const throughput_bytes_per_sec = total / (elapsed / 1000);
        const throughput_MBps = throughput_bytes_per_sec / 1024 / 1024;
        const throughput_GBps = throughput_bytes_per_sec / 1_000_000_000;
        const throughput_Gbps = throughput_bytes_per_sec * 8 / 1_000_000_000;

        std.debug.print("\n=== Results ===\n", .{});
        std.debug.print("Total: {d:.2} MB in {}ms\n", .{
            total / 1024.0 / 1024.0,
            elapsed,
        });
        std.debug.print("Throughput: {d:.2} bytes/sec\n", .{throughput_bytes_per_sec});
        std.debug.print("Throughput: {d:.2} MB/sec\n", .{throughput_MBps});
        std.debug.print("Throughput: {d:.2} GB/sec\n", .{throughput_GBps});
        std.debug.print("Throughput: {d:.2} Gbps/sec\n", .{throughput_Gbps});
        std.debug.print("Messages/sec: {d:.0}\n", .{(THREADS * CLIENTS_PER_THREAD * ROUNDS * 2) / (elapsed / 1000.0)});
    }
};

fn workerThread(thread_id: usize, stats: *Stats) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var msg_buf: [MSG_SIZE]u8 = undefined;
    @memset(&msg_buf, 'A');
    const msg = msg_buf[0..];

    var clients = try std.ArrayList(net.Stream).initCapacity(allocator, CLIENTS_PER_THREAD);
    defer {
        for (clients.items) |client| client.close();
        clients.deinit(allocator);
    }

    for (0..CLIENTS_PER_THREAD) |_| {
        const stream = try net.tcpConnectToHost(allocator, "127.0.0.1", 8081);
        try clients.append(allocator, stream);
    }

    std.debug.print("Thread {}: {} clients connected\n", .{ thread_id, clients.items.len });

    for (0..ROUNDS) |round| {
        for (clients.items) |client| {
            var sent: usize = 0;
            while (sent < msg.len) {
                const n = try client.write(msg[sent..]);
                sent += n;
                stats.add(n);
            }
        }

        for (clients.items) |client| {
            var received: usize = 0;
            var buf: [8192]u8 = undefined;

            while (received < MSG_SIZE) {
                const n = try client.read(&buf);
                if (n == 0) return error.EndOfStream;
                received += n;
                stats.add(n);
            }
        }

        if ((round + 1) % 2 == 0) {
            std.debug.print("Thread {}: round {}/{}\n", .{ thread_id, round + 1, ROUNDS });
        }
    }

    std.debug.print("Thread {} done\n", .{thread_id});
}

pub fn main() !void {
    std.debug.print("Multi-threaded benchmark:\n", .{});
    std.debug.print("  Threads: {}\n", .{THREADS});
    std.debug.print("  Clients per thread: {}\n", .{CLIENTS_PER_THREAD});
    std.debug.print("  Total clients: {}\n", .{THREADS * CLIENTS_PER_THREAD});
    std.debug.print("  Message size: {} bytes\n", .{MSG_SIZE});
    std.debug.print("  Rounds: {}\n\n", .{ROUNDS});

    var stats = Stats.init();
    var threads: [THREADS]Thread = undefined;

    // Spawn threads
    for (&threads, 0..) |*thread, i| {
        thread.* = try Thread.spawn(.{}, workerThread, .{ i, &stats });
    }

    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }

    stats.report();
}
