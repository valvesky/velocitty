const std = @import("std");
const zt = @import("ZT");

pub fn run(gpa: std.mem.Allocator, iters: u32, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var screen = try zt.Term.Screen.init(gpa, 20, 8);
    defer screen.deinit();
    var runs: std.ArrayList(zt.Runs.Run) = .empty;
    defer runs.deinit(gpa);
    try applyBytes(&screen, gpa, &runs, "\x1b[?25l");

    var dirty = try zt.Draw.Frame.init(gpa, 80, 32);
    defer dirty.deinit();
    var full = try zt.Draw.Frame.init(gpa, 80, 32);
    defer full.deinit();

    var buf: [64]u8 = undefined;
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        const ops = rand.intRangeAtMost(usize, 1, 6);
        var o: usize = 0;
        while (o < ops) : (o += 1) {
            try applyOp(&screen, gpa, &runs, rand, &buf);
        }
        try applyBytes(&screen, gpa, &runs, "\x1b[?25l");
        dirty.render(&screen, 4, 4, null, 4);
        full.invalidate();
        full.render(&screen, 4, 4, null, 4);
        if (!std.mem.eql(u32, dirty.pixels, full.pixels)) {
            std.debug.print("dirty vs full mismatch at iter {d}\n", .{i});
            return error.DirtyMismatch;
        }
    }
}

fn applyOp(
    screen: *zt.Term.Screen,
    gpa: std.mem.Allocator,
    runs: *std.ArrayList(zt.Runs.Run),
    rand: std.Random,
    buf: *[64]u8,
) !void {
    const src: []const u8 = switch (rand.intRangeAtMost(u8, 0, 17)) {
        0, 1, 2 => blk: {
            const n = rand.intRangeAtMost(usize, 1, 30);
            var i: usize = 0;
            while (i < n) : (i += 1) buf[i] = rand.intRangeAtMost(u8, 'A', 'Z');
            break :blk buf[0..n];
        },
        3, 4 => "x\r\n",
        5 => try std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{
            rand.intRangeAtMost(u16, 1, 8),
            rand.intRangeAtMost(u16, 1, 20),
        }),
        6 => switch (rand.intRangeAtMost(u8, 0, 3)) {
            0 => "\x1b[1m",
            1 => "\x1b[48;2;30;60;90m",
            2 => "\x1b[38;5;120m",
            else => "\x1b[0m",
        },
        7 => switch (rand.intRangeAtMost(u8, 0, 4)) {
            0 => "\x1b[K",
            1 => "\x1b[1K",
            2 => "\x1b[J",
            3 => "\x1b[2J",
            else => "\x1b[3J",
        },
        8 => try std.fmt.bufPrint(buf, "\x1b[{d}L", .{rand.intRangeAtMost(u16, 1, 4)}),
        9 => try std.fmt.bufPrint(buf, "\x1b[{d}M", .{rand.intRangeAtMost(u16, 1, 4)}),
        10 => try std.fmt.bufPrint(buf, "\x1b[{d}S", .{rand.intRangeAtMost(u16, 1, 4)}),
        11 => try std.fmt.bufPrint(buf, "\x1b[{d}T", .{rand.intRangeAtMost(u16, 1, 4)}),
        12 => blk: {
            const top = rand.intRangeAtMost(u16, 1, 4);
            const bot = rand.intRangeAtMost(u16, top + 1, 8);
            break :blk try std.fmt.bufPrint(buf, "\x1b[{d};{d}r", .{ top, bot });
        },
        13 => try std.fmt.bufPrint(buf, "\x1b[{d}@", .{rand.intRangeAtMost(u16, 1, 5)}),
        14 => try std.fmt.bufPrint(buf, "\x1b[{d}P", .{rand.intRangeAtMost(u16, 1, 5)}),
        15 => "\x1bM",
        16 => "字",
        else => if (rand.boolean()) "\x1b[?1049h" else "\x1b[?1049l",
    };
    try applyBytes(screen, gpa, runs, src);
}

fn applyBytes(
    screen: *zt.Term.Screen,
    gpa: std.mem.Allocator,
    runs: *std.ArrayList(zt.Runs.Run),
    src: []const u8,
) !void {
    runs.clearRetainingCapacity();
    try zt.Runs.split(gpa, src, runs);
    screen.feed(runs.items, src);
}
