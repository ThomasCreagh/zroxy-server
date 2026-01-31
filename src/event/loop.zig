const std = @import("std");
const posix = std.posix;

const epoll = @import("epoll.zig");

const MAX_EVENTS = 64;

pub fn init(socket: posix.socket_t) !void {
    const listen_fd = socket;
    const efd = try epoll.create(socket);
    var events: [MAX_EVENTS]std.os.linux.epoll_event = undefined;

    while (true) {
        const ready_count = posix.epoll_wait(efd, events[0..], -1); // no timeout

        for (ready_count) |i| {
            const ev = events[i];
            const fd = ev.data.fd;

            if (fd == listen_fd) {
                while (true) {
                    const client_fd = get_client_socket(socket) catch break;
                    try epoll.create(client_fd);
                }
            } else {
                const buf: u8[64] = undefined;
                try read(fd, buf);
            }
        }
    }
}

fn read(fd: posix.socket_t, buf: []u8) !void {
    while (true) {
        const read_count = try posix.read(fd, &buf) catch break;
        if (read_count == 0) {
            posix.close(fd);
            break;
        }
        // not sure what todo here
    }
}

fn get_client_socket(server_socket: posix.socket_t) posix.AcceptError!posix.socket_t {
    const flags = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;

    var client_addr: posix.sockaddr.in = undefined;

    var client_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));

    const client_socket = try posix.accept(
        server_socket,
        @ptrCast(&client_addr),
        &client_len,
        flags,
    );
    return client_socket;
}
