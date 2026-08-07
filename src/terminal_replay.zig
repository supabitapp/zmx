const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const util = @import("util.zig");

pub fn append(
    alloc: std.mem.Allocator,
    output: *std.ArrayList(u8),
    terminal: *ghostty_vt.Terminal,
    stream: *ghostty_vt.TerminalStream,
) void {
    const snapshot = util.serializeTerminalState(alloc, terminal) orelse return;
    defer alloc.free(snapshot);
    const restore = util.rewritePromptRedraw(alloc, snapshot) orelse snapshot;
    defer if (restore.ptr != snapshot.ptr) alloc.free(restore);
    ipc.appendMessage(alloc, output, .Output, restore) catch |err| {
        std.log.warn("failed to buffer terminal state for client err={s}", .{@errorName(err)});
        return;
    };

    var continuation: std.Io.Writer.Allocating = .init(alloc);
    defer continuation.deinit();
    stream.writeContinuation(&continuation.writer) catch |err| {
        std.log.warn("failed to buffer terminal continuation err={s}", .{@errorName(err)});
        return;
    };
    if (continuation.writer.buffered().len == 0) return;
    ipc.appendMessage(alloc, output, .Output, continuation.writer.buffered()) catch |err| {
        std.log.warn("failed to buffer terminal continuation err={s}", .{@errorName(err)});
    };
}
