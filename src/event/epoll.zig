const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const ClientState = struct {
    fd: posix.socket_t,
    read_buf: std.ArrayList(u8),
    write_buf: std.ArrayList(u8),
    write_offset: usize = 0,
    closed: bool = false,
    read_paused: bool = false,

    const MAX_BUFFER_SIZE = 64 * 1024;

    pub fn shouldRead(self: *ClientState) bool {
        return !self.read_paused and self.read_buf.items.len < MAX_BUFFER_SIZE;
    }

    pub fn shouldWrite(self: *ClientState) bool {
        return self.write_buf.items.len > 0;
    }

    pub fn isWriteBufFull(self: *ClientState) bool {
        return self.write_buf.items.len >= MAX_BUFFER_SIZE;
    }

    pub fn isWriteBufDrained(self: *ClientState) bool {
        return self.write_buf.items.len < MAX_BUFFER_SIZE / 2;
    }
};

pub fn create(socket: posix.socket_t, allocator: std.mem.Allocator) !i32 {
    const efd = try posix.epoll_create1(posix.SOCK.CLOEXEC);
    _ = try add(efd, socket, allocator);
    return efd;
}

pub fn add(efd: i32, socket: posix.socket_t, allocator: std.mem.Allocator) !*ClientState {
    const state = try allocator.create(ClientState);
    state.* = .{
        .fd = socket,
        .read_buf = try std.ArrayList(u8).initCapacity(allocator, 8192),
        .write_buf = try std.ArrayList(u8).initCapacity(allocator, 8192),
    };
    //try state.read_buf.ensureTotalCapacity(8192);
    //try state.write_buf.ensureTotalCapacity(8192);

    var event: std.os.linux.epoll_event = undefined;
    event.events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET;
    event.data.ptr = @intFromPtr(state);

    try posix.epoll_ctl(
        efd,
        std.os.linux.EPOLL.CTL_ADD,
        socket,
        &event,
    );
    return state;
}

pub fn modify(efd: i32, state: *ClientState, events: u32) !void {
    var event: linux.epoll_event = undefined;
    event.events = events;
    event.data.ptr = @intFromPtr(state);
    const fd = state.fd;
    try posix.epoll_ctl(efd, linux.EPOLL.CTL_MOD, fd, &event);
}
