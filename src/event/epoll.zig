const std = @import("std");
const posix = std.posix;

pub fn create(socket: posix.socket_t) (posix.EpollCreateError || posix.EpollCtlError)!i32 {
    const efd = posix.epoll_create1(posix.SOCK.CLOEXEC);

    var event: std.os.linux.epoll_event = undefined;
    event.events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET;
    event.data.fd = socket;

    try posix.epoll_ctl(
        efd,
        std.os.linux.EPOLL.CTL_ADD,
        socket,
        &event,
    );

    return efd;
}
