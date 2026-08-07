const std = @import("std");

pub const Case = struct {
    name: []const u8,
    prefix: []const u8,
    sequence: []const u8,
    suffix: []const u8,

    pub fn input(self: Case, alloc: std.mem.Allocator) ![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.prefix, self.sequence, self.suffix });
    }
};

pub const all = [_]Case{
    .{
        .name = "utf8",
        .prefix = "utf8 ",
        .sequence = "\xF0\x9F\x98\x84",
        .suffix = " complete",
    },
    .{
        .name = "csi",
        .prefix = "csi ",
        .sequence = "\x1b[38;5;196m",
        .suffix = "red\x1b[0m",
    },
    .{
        .name = "osc",
        .prefix = "osc ",
        .sequence = "\x1b]2;continuation title\x1b\\",
        .suffix = " titled",
    },
    .{
        .name = "dcs",
        .prefix = "dcs ",
        .sequence = "\x1bP$qm\x1b\\",
        .suffix = " queried",
    },
    .{
        .name = "apc",
        .prefix = "apc ",
        .sequence = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;QUFB\x1b\\",
        .suffix = " queried",
    },
};
