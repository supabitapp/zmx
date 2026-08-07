const std = @import("std");
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");
const continuation_cases = @import("continuation_cases.zig");
const continuation_test = @import("continuation_test.zig");
const cross = @import("cross.zig");
const ipc = @import("ipc.zig");
const lib_posix = @import("posix.zig");
const loop = @import("loop.zig");
const socket = @import("socket.zig");
const Cfg = @import("cfg.zig");

const live_test_timeout_ms = 5_000;

const testOpenPty = if (builtin.os.tag == .macos)
    struct {
        extern "c" fn openpty(
            master_fd: *c_int,
            slave_fd: *c_int,
            name: ?[*:0]u8,
            term: ?*const cross.c.struct_termios,
            size: ?*const cross.c.struct_winsize,
        ) c_int;
    }.openpty
else
    cross.c.openpty;

fn liveDaemonMain(server_sock_fd: i32, pty_fd: i32) u8 {
    var cfg = Cfg{
        .socket_dir = "",
        .log_dir = "",
        .max_scrollback_lines = 100,
    };
    var daemon = loop.Daemon{
        .cfg = &cfg,
        .session_name = "continuation-live",
        .socket_path = "",
        .created_at = 0,
    };
    const alloc = std.heap.c_allocator;
    defer {
        daemon.shutdown(alloc);
        daemon.clients.deinit(alloc);
        daemon.labels.deinit(alloc);
        daemon.pty_write_buf.deinit(alloc);
    }
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    loop.testing.runDaemonLoop(
        &daemon,
        alloc,
        threaded.io(),
        server_sock_fd,
        pty_fd,
    ) catch return 1;
    return 0;
}

fn runLiveDaemon(server_sock_fd: i32, pty_fd: i32, notify_fd: i32, start_fd: i32) noreturn {
    var start: [1]u8 = undefined;
    const started = lib_posix.read(start_fd, &start) catch 0;
    lib_posix.close(start_fd);
    if (started != 1) std.c._exit(1);
    const status = liveDaemonMain(server_sock_fd, pty_fd);
    _ = lib_posix.write(notify_fd, &.{status}) catch 0;
    std.c._exit(status);
}

const LiveDaemon = struct {
    alloc: std.mem.Allocator,
    socket_path: []u8,
    slave_fd: i32,
    notify_fd: i32,
    start_fd: i32,
    pid: i32,
    reaped: bool = false,

    fn init(alloc: std.mem.Allocator) !LiveDaemon {
        const socket_path = try std.fmt.allocPrint(
            alloc,
            "/tmp/zmx-continuation-{d}",
            .{std.c.getpid()},
        );
        errdefer alloc.free(socket_path);
        std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
        errdefer std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};

        var master_fd: c_int = undefined;
        var slave_fd: c_int = undefined;
        const size = cross.c.struct_winsize{
            .ws_row = 10,
            .ws_col = 40,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (testOpenPty(&master_fd, &slave_fd, null, null, &size) != 0) return error.OpenPtyFailed;
        errdefer lib_posix.close(master_fd);
        errdefer lib_posix.close(slave_fd);

        const server_sock_fd = try socket.createSocket(socket_path);
        errdefer lib_posix.close(server_sock_fd);
        const notify_fds = try lib_posix.pipe2(.{ .CLOEXEC = true });
        errdefer lib_posix.close(notify_fds[0]);
        errdefer lib_posix.close(notify_fds[1]);
        const start_fds = try lib_posix.pipe2(.{ .CLOEXEC = true });
        errdefer lib_posix.close(start_fds[0]);
        errdefer lib_posix.close(start_fds[1]);

        const pid = try lib_posix.fork();
        if (pid == 0) {
            lib_posix.close(slave_fd);
            lib_posix.close(notify_fds[0]);
            lib_posix.close(start_fds[1]);
            runLiveDaemon(server_sock_fd, master_fd, notify_fds[1], start_fds[0]);
        }

        lib_posix.close(master_fd);
        lib_posix.close(server_sock_fd);
        lib_posix.close(notify_fds[1]);
        lib_posix.close(start_fds[0]);
        return .{
            .alloc = alloc,
            .socket_path = socket_path,
            .slave_fd = slave_fd,
            .notify_fd = notify_fds[0],
            .start_fd = start_fds[1],
            .pid = pid,
        };
    }

    fn deinit(self: *LiveDaemon) void {
        if (!self.reaped) {
            lib_posix.kill(self.pid, lib_posix.SIG.KILL) catch {};
            _ = lib_posix.waitpid(self.pid, 0);
        }
        lib_posix.close(self.slave_fd);
        lib_posix.close(self.notify_fd);
        lib_posix.close(self.start_fd);
        std.Io.Dir.deleteFileAbsolute(std.testing.io, self.socket_path) catch {};
        self.alloc.free(self.socket_path);
    }

    fn connect(self: *LiveDaemon) !i32 {
        return socket.sessionConnect(self.socket_path);
    }

    fn write(self: *LiveDaemon, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            offset += try lib_posix.write(self.slave_fd, bytes[offset..]);
        }
    }

    fn start(self: *LiveDaemon) !void {
        try std.testing.expectEqual(@as(usize, 1), try lib_posix.write(self.start_fd, &.{1}));
    }

    fn stop(self: *LiveDaemon, client_fd: i32) !void {
        try ipc.send(client_fd, .Kill, "");
        var poll_fds = [_]lib_posix.pollfd{.{
            .fd = self.notify_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        }};
        try std.testing.expectEqual(
            @as(usize, 1),
            try lib_posix.poll(&poll_fds, live_test_timeout_ms),
        );
        var status: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try lib_posix.read(self.notify_fd, &status));
        try std.testing.expectEqual(@as(u8, 0), status[0]);
        try std.testing.expectEqual(self.pid, lib_posix.waitpid(self.pid, 0).pid);
        self.reaped = true;
    }
};

fn readMessage(buffer: *ipc.SocketBuffer, socket_fd: i32) !ipc.SocketMsg {
    const io = std.testing.io;
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(
        std.Io.Duration.fromMilliseconds(live_test_timeout_ms),
    );
    while (true) {
        if (buffer.next()) |message| return message;
        const remaining = std.Io.Timestamp.now(io, .awake).durationTo(deadline).toMilliseconds();
        if (remaining <= 0) return error.Timeout;
        var poll_fds = [_]lib_posix.pollfd{.{
            .fd = socket_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        }};
        if (try lib_posix.poll(&poll_fds, @intCast(remaining)) == 0) return error.Timeout;
        if (poll_fds[0].revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
            return error.ConnectionClosed;
        }
        if (try buffer.read(socket_fd) == 0) return error.ConnectionClosed;
    }
}

fn readTag(buffer: *ipc.SocketBuffer, socket_fd: i32, tag: ipc.Tag) ![]const u8 {
    while (true) {
        const message = try readMessage(buffer, socket_fd);
        if (message.header.tag == tag) return message.payload;
    }
}

const AttachedTerminal = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    buffer: ipc.SocketBuffer,
    terminal: ghostty_vt.Terminal,
    stream: ghostty_vt.TerminalStream,

    fn create(
        alloc: std.mem.Allocator,
        daemon: *LiveDaemon,
        resize: ipc.Resize,
    ) !*AttachedTerminal {
        const self = try alloc.create(AttachedTerminal);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.socket_fd = try daemon.connect();
        errdefer lib_posix.close(self.socket_fd);
        self.buffer = try ipc.SocketBuffer.init(alloc);
        errdefer self.buffer.deinit();
        self.terminal = try ghostty_vt.Terminal.init(std.testing.io, alloc, .{
            .cols = resize.cols,
            .rows = resize.rows,
        });
        errdefer self.terminal.deinit(alloc);
        self.stream = self.terminal.vtStream();
        errdefer self.stream.deinit();

        try ipc.send(self.socket_fd, .Init, std.mem.asBytes(&resize));
        self.stream.nextSlice(try readTag(&self.buffer, self.socket_fd, .Output));
        self.stream.nextSlice(try readTag(&self.buffer, self.socket_fd, .Output));
        return self;
    }

    fn destroy(self: *AttachedTerminal) void {
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
        self.buffer.deinit();
        lib_posix.close(self.socket_fd);
        self.alloc.destroy(self);
    }

    fn readOutput(self: *AttachedTerminal) ![]const u8 {
        const output = try readTag(&self.buffer, self.socket_fd, .Output);
        self.stream.nextSlice(output);
        return output;
    }
};

fn writeAndRead(
    daemon: *LiveDaemon,
    tail: *ipc.SocketBuffer,
    tail_fd: i32,
    attached: []const *AttachedTerminal,
    bytes: []const u8,
) !void {
    try daemon.write(bytes);
    try std.testing.expectEqualStrings(bytes, try readTag(tail, tail_fd, .Output));
    for (attached) |client| {
        try std.testing.expectEqualStrings(bytes, try client.readOutput());
    }
}

fn writeBytewise(
    daemon: *LiveDaemon,
    tail: *ipc.SocketBuffer,
    tail_fd: i32,
    attached: []const *AttachedTerminal,
    bytes: []const u8,
) !void {
    for (0..bytes.len) |index| {
        try writeAndRead(
            daemon,
            tail,
            tail_fd,
            attached,
            bytes[index .. index + 1],
        );
    }
}

fn runLiveCase(case: continuation_cases.Case) !void {
    const alloc = std.testing.allocator;
    var daemon = try LiveDaemon.init(alloc);
    defer daemon.deinit();

    const tail_fd = try daemon.connect();
    defer lib_posix.close(tail_fd);
    var tail = try ipc.SocketBuffer.init(alloc);
    defer tail.deinit();
    try ipc.send(tail_fd, .Tail, "");
    try daemon.write(case.prefix);
    try daemon.start();
    try std.testing.expectEqualStrings(case.prefix, try readTag(&tail, tail_fd, .Output));

    const first_fd = try daemon.connect();
    defer lib_posix.close(first_fd);
    var first = try ipc.SocketBuffer.init(alloc);
    defer first.deinit();
    const resize = ipc.Resize{ .rows = 10, .cols = 40 };
    try ipc.send(first_fd, .Init, std.mem.asBytes(&resize));
    _ = try readTag(&first, first_fd, .Resize);

    const cut = case.sequence.len / 2;
    try writeBytewise(&daemon, &tail, tail_fd, &.{}, case.sequence[0..cut]);

    const second = try AttachedTerminal.create(alloc, &daemon, resize);
    defer second.destroy();
    const third = try AttachedTerminal.create(alloc, &daemon, resize);
    defer third.destroy();
    const attached = [_]*AttachedTerminal{ second, third };

    try writeBytewise(&daemon, &tail, tail_fd, &attached, case.sequence[cut..]);
    try writeBytewise(&daemon, &tail, tail_fd, &attached, case.suffix);

    var uninterrupted = try ghostty_vt.Terminal.init(std.testing.io, alloc, .{
        .cols = resize.cols,
        .rows = resize.rows,
    });
    defer uninterrupted.deinit(alloc);
    var uninterrupted_stream = uninterrupted.vtStream();
    defer uninterrupted_stream.deinit();
    const input = try case.input(alloc);
    defer alloc.free(input);
    uninterrupted_stream.nextSlice(input);

    try continuation_test.expectTerminalsEqual(alloc, &uninterrupted, &second.terminal);
    try continuation_test.expectTerminalsEqual(alloc, &uninterrupted, &third.terminal);
    try daemon.stop(third.socket_fd);
}

test "live repeated attach preserves continuation cases across byte boundaries" {
    for (continuation_cases.all) |case| {
        runLiveCase(case) catch |err| {
            std.debug.print("live continuation case {s} failed\n", .{case.name});
            return err;
        };
    }
}
