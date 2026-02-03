const std = @import("std");
const net = std.net;
const posix = std.posix;

const PORT = 8081;
const NUM_CLIENTS = 10_000;
const MSG_PER_CLIENT = 10;
const MSG_SIZE = 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var msg_buf: [MSG_SIZE]u8 = undefined;
    @memset(&msg_buf, 'A');
    const msg = msg_buf[0..];

    std.debug.print("Connecting {} clients on port {}...\n", .{ NUM_CLIENTS, PORT });

    var clients = try std.ArrayList(net.Stream).initCapacity(allocator, NUM_CLIENTS);
    defer {
        for (clients.items) |client| client.close();
        clients.deinit(allocator);
    }

    const start_connect = std.time.milliTimestamp();
    for (0..NUM_CLIENTS) |i| {
        const stream = net.tcpConnectToHost(allocator, "127.0.0.1", 8081) catch |err| {
            std.debug.print("Failed to connect client {}: {}\n", .{ i, err });
            break;
        };
        try clients.append(allocator, stream);

        if ((i + 1) % 1000 == 0) {
            std.debug.print("Connected: {}/{}\n", .{ i + 1, NUM_CLIENTS });
        }
    }
    const connect_time = std.time.milliTimestamp() - start_connect;
    std.debug.print("Connected {} clients in {}ms\n", .{ clients.items.len, connect_time });

    //const start_io = std.time.milliTimestamp();
    var total_bytes: usize = 0;

    const timeout = posix.timeval{
        .sec = 5,
        .usec = 0,
    };
    for (clients.items) |client| {
        posix.setsockopt(
            client.handle,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {};
    }

    for (0..MSG_PER_CLIENT) |round| {
        for (clients.items) |client| {
            _ = client.write(msg) catch continue;
            total_bytes += msg.len;
        }

        for (clients.items) |client| {
            var buf: [2048]u8 = undefined;
            const n = client.read(&buf) catch continue;
            total_bytes += n;
        }

        std.debug.print("Round {}/{} complete\n", .{ round + 1, MSG_PER_CLIENT });
    }

    const elapsed = std.time.milliTimestamp() - start_connect;
    const throughput = @as(f64, @floatFromInt(total_bytes)) /
        @as(f64, @floatFromInt(elapsed)) * 1000.0 / 1024.0 / 1024.0;

    std.debug.print("\nTotal: {d:.2} MB in {}ms\n", .{ @as(f64, @floatFromInt(total_bytes)) / 1024.0 / 1024.0, elapsed });
    std.debug.print("Throughput: {d:.2} MB/sec\n", .{throughput});
    std.debug.print("Messages/sec: {d:.0}\n", .{@as(f64, @floatFromInt(NUM_CLIENTS * MSG_PER_CLIENT)) /
        (@as(f64, @floatFromInt(elapsed)) / 1000.0)});
}
