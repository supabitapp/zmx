const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const continuation_cases = @import("continuation_cases.zig");
const ipc = @import("ipc.zig");
const loop = @import("loop.zig");
const terminal_replay = @import("terminal_replay.zig");
const util = @import("util.zig");
const Client = loop.Client;

const continuation_max_bytes = 1024;

fn initTerminal(alloc: std.mem.Allocator) !ghostty_vt.Terminal {
    return ghostty_vt.Terminal.init(std.testing.io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
}

fn initTrackedStream(
    alloc: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    max_bytes: usize,
) ghostty_vt.TerminalStream {
    return ghostty_vt.TerminalStream.init(.{
        .allocator = alloc,
        .handler = terminal.vtHandler(),
        .continuation_max_bytes = max_bytes,
    });
}

fn feedChunked(
    stream: *ghostty_vt.TerminalStream,
    input: []const u8,
    seed: usize,
) void {
    var offset: usize = 0;
    while (offset < input.len) {
        const len = @min(1 + (seed +% offset) % 7, input.len - offset);
        stream.nextSlice(input[offset .. offset + len]);
        offset += len;
    }
}

fn feedReplay(
    alloc: std.mem.Allocator,
    stream: *ghostty_vt.TerminalStream,
    replay: []const u8,
) !void {
    var messages = try ipc.SocketBuffer.init(alloc);
    defer messages.deinit();
    try messages.buf.appendSlice(alloc, replay);

    var count: usize = 0;
    while (messages.next()) |message| {
        try std.testing.expectEqual(ipc.Tag.Output, message.header.tag);
        stream.nextSlice(message.payload);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

fn expectContinuationsEqual(
    alloc: std.mem.Allocator,
    expected: *ghostty_vt.TerminalStream,
    actual: *ghostty_vt.TerminalStream,
) !void {
    var expected_bytes: std.Io.Writer.Allocating = .init(alloc);
    defer expected_bytes.deinit();
    try expected.writeContinuation(&expected_bytes.writer);

    var actual_bytes: std.Io.Writer.Allocating = .init(alloc);
    defer actual_bytes.deinit();
    try actual.writeContinuation(&actual_bytes.writer);

    try std.testing.expectEqualSlices(
        u8,
        expected_bytes.writer.buffered(),
        actual_bytes.writer.buffered(),
    );
}

pub fn expectTerminalsEqual(
    alloc: std.mem.Allocator,
    expected: *ghostty_vt.Terminal,
    actual: *ghostty_vt.Terminal,
) !void {
    const expected_plain = try expected.plainString(alloc);
    defer alloc.free(expected_plain);
    const actual_plain = try actual.plainString(alloc);
    defer alloc.free(actual_plain);
    try std.testing.expectEqualStrings(expected_plain, actual_plain);

    const expected_state = util.serializeTerminalState(alloc, expected) orelse
        return error.SerializationFailed;
    defer alloc.free(expected_state);
    const actual_state = util.serializeTerminalState(alloc, actual) orelse
        return error.SerializationFailed;
    defer alloc.free(actual_state);
    try std.testing.expectEqualStrings(expected_state, actual_state);
}

fn expectCaseAtCut(
    case: continuation_cases.Case,
    case_index: usize,
    sequence_cut: usize,
) !void {
    const alloc = std.testing.allocator;
    const input = try case.input(alloc);
    defer alloc.free(input);
    const cut = case.prefix.len + sequence_cut;

    var uninterrupted = try initTerminal(alloc);
    defer uninterrupted.deinit(alloc);
    var uninterrupted_stream = uninterrupted.vtStream();
    defer uninterrupted_stream.deinit();
    uninterrupted_stream.nextSlice(input);

    var source = try initTerminal(alloc);
    defer source.deinit(alloc);
    var source_stream = initTrackedStream(alloc, &source, continuation_max_bytes);
    defer source_stream.deinit();
    feedChunked(&source_stream, input[0..cut], case_index +% cut);

    for (0..2) |replay_index| {
        var replay: std.ArrayList(u8) = .empty;
        defer replay.deinit(alloc);
        terminal_replay.append(alloc, &replay, &source, &source_stream);

        var attached = try initTerminal(alloc);
        defer attached.deinit(alloc);
        var attached_stream = initTrackedStream(alloc, &attached, continuation_max_bytes);
        defer attached_stream.deinit();

        try feedReplay(alloc, &attached_stream, replay.items);
        try expectContinuationsEqual(alloc, &source_stream, &attached_stream);
        feedChunked(
            &attached_stream,
            input[cut..],
            case_index +% cut +% replay_index +% 1,
        );
        try expectTerminalsEqual(alloc, &uninterrupted, &attached);
    }

    feedChunked(&source_stream, input[cut..], case_index +% cut +% input.len);
    try expectTerminalsEqual(alloc, &uninterrupted, &source);
}

test "raw output waits for subscription" {
    const alloc = std.testing.allocator;
    var client = Client{
        .alloc = alloc,
        .socket_fd = -1,
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = .empty,
    };
    defer {
        client.read_buf.deinit();
        client.write_buf.deinit(alloc);
    }

    try loop.testing.appendOutput(&client, "before");
    try std.testing.expectEqual(@as(usize, 0), client.write_buf.items.len);

    client.receives_pty_output = true;
    try loop.testing.appendOutput(&client, "after");
    try std.testing.expect(client.has_pending_output);

    var messages = try ipc.SocketBuffer.init(alloc);
    defer messages.deinit();
    try messages.buf.appendSlice(alloc, client.write_buf.items);
    const message = messages.next().?;
    try std.testing.expectEqual(ipc.Tag.Output, message.header.tag);
    try std.testing.expectEqualStrings("after", message.payload);
    try std.testing.expect(messages.next() == null);
}

test "attach replay matches uninterrupted parsing at every sequence cut" {
    for (continuation_cases.all, 0..) |case, case_index| {
        for (1..case.sequence.len) |sequence_cut| {
            expectCaseAtCut(case, case_index, sequence_cut) catch |err| {
                std.debug.print(
                    "continuation case {s} cut {d} failed\n",
                    .{ case.name, sequence_cut },
                );
                return err;
            };
        }
    }
}

test "attach replay recovers after continuation cap" {
    const alloc = std.testing.allocator;

    var source = try initTerminal(alloc);
    defer source.deinit(alloc);
    var source_stream = initTrackedStream(alloc, &source, 4);
    defer source_stream.deinit();
    source_stream.nextSlice("\x1b]2;overflow");

    var unavailable_buffer: [1]u8 = undefined;
    var unavailable_writer: std.Io.Writer = .fixed(&unavailable_buffer);
    try std.testing.expectError(
        error.ContinuationUnavailable,
        source_stream.writeContinuation(&unavailable_writer),
    );

    source_stream.nextSlice("\x07");
    source_stream.nextSlice("\x1b[3");

    var replay: std.ArrayList(u8) = .empty;
    defer replay.deinit(alloc);
    terminal_replay.append(alloc, &replay, &source, &source_stream);

    var attached = try initTerminal(alloc);
    defer attached.deinit(alloc);
    var attached_stream = initTrackedStream(alloc, &attached, 4);
    defer attached_stream.deinit();
    try feedReplay(alloc, &attached_stream, replay.items);
    try expectContinuationsEqual(alloc, &source_stream, &attached_stream);

    source_stream.nextSlice("1mX");
    attached_stream.nextSlice("1mX");
    try expectTerminalsEqual(alloc, &source, &attached);
}
