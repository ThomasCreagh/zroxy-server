const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const epoll = @import("epoll.zig");

const MAX_EVENTS = 64;
const BUFFER_SIZE = 16 * 1024;
const MAX_ACCEPTS_PER_LOOP = 128;

pub fn init(socket: posix.socket_t, allocator: std.mem.Allocator) !void {
    const listen_fd: posix.socket_t = socket;
    const efd: i32 = try epoll.create(socket, allocator);

    var clients: std.AutoHashMap(posix.socket_t, *epoll.ClientState) = .init(allocator);
    defer {
        var it = clients.valueIterator();
        while (it.next()) |state| {
            state.*.read_buf.deinit(allocator);
            state.*.write_buf.deinit(allocator);
            allocator.destroy(state.*);
        }
        clients.deinit();
    }

    var events: [MAX_EVENTS]linux.epoll_event = undefined;

    while (true) {
        const ready_count = posix.epoll_wait(efd, events[0..], -1); // no timeout

        for (0..ready_count) |i| {
            const ev = events[i];
            const state_ptr: ?*epoll.ClientState = @ptrFromInt(ev.data.ptr);

            if (state_ptr) |state| {
                if (state.fd == listen_fd) {
                    var accept_count: usize = 0;
                    while (accept_count < MAX_ACCEPTS_PER_LOOP) : (accept_count += 1) {
                        const client_fd = get_client_socket(socket) catch break;
                        const new_state = try epoll.add(efd, client_fd, allocator);
                        try clients.put(client_fd, new_state);
                    }
                } else {
                    const has_err = (ev.events & linux.EPOLL.ERR) != 0;
                    const has_hup = (ev.events & linux.EPOLL.HUP) != 0;

                    if (has_err or has_hup) {
                        try cleanup_client(efd, state, &clients, allocator);
                        continue;
                    }

                    if ((ev.events & linux.EPOLL.IN) != 0) {
                        try handle_read(allocator, efd, state);
                    }

                    if ((ev.events & linux.EPOLL.OUT) != 0) {
                        try handle_write(allocator, efd, state);
                    }

                    if (state.closed) {
                        try cleanup_client(efd, state, &clients, allocator);
                    }
                }
            }
        }
    }
}

fn handle_read(allocator: std.mem.Allocator, efd: i32, state: *epoll.ClientState) !void {
    if (!state.shouldRead()) return;

    var buf: [BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes_read = posix.read(state.fd, buf[0..]) catch |err| {
            switch (err) {
                error.WouldBlock => break,
                else => {
                    state.closed = true;
                    return;
                },
            }
        };

        if (bytes_read == 0) {
            state.closed = true;
            return;
        }

        try state.write_buf.appendSlice(allocator, buf[0..bytes_read]);

        if (state.isWriteBufFull()) {
            state.read_paused = true;
            try epoll.modify(efd, state, std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET);
            break;
        }
    }

    if (state.write_buf.items.len > 0) {
        try epoll.modify(efd, state, linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET);
    }
}

fn handle_write(allocator: std.mem.Allocator, efd: i32, state: *epoll.ClientState) !void {
    _ = allocator;
    while (state.write_offset < state.write_buf.items.len) {
        const bytes_written = posix.write(
            state.fd,
            state.write_buf.items[state.write_offset..],
        ) catch |err| {
            switch (err) {
                error.WouldBlock => break,
                else => {
                    state.closed = true;
                    return;
                },
            }
        };

        state.write_offset += bytes_written;
    }

    if (state.write_offset >= state.write_buf.items.len) {
        state.write_buf.clearRetainingCapacity();
        state.write_offset = 0;
        try epoll.modify(efd, state, linux.EPOLL.IN | linux.EPOLL.ET);
    }

    if (state.read_paused and state.isWriteBufDrained()) {
        state.read_paused = false;
        try epoll.modify(efd, state, std.os.linux.EPOLL.IN | std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET);
    }
}

fn cleanup_client(
    efd: i32,
    state: *epoll.ClientState,
    clients: *std.AutoHashMap(posix.socket_t, *epoll.ClientState),
    allocator: std.mem.Allocator,
) !void {
    posix.epoll_ctl(efd, linux.EPOLL.CTL_DEL, state.fd, null) catch {};
    posix.close(state.fd);

    state.read_buf.deinit(allocator);
    state.write_buf.deinit(allocator);
    allocator.destroy(state);
    _ = clients.remove(state.fd);
}

fn get_client_socket(server_socket: posix.socket_t) posix.AcceptError!posix.socket_t {
    const flags = posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;

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
