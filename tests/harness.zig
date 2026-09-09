const std = @import("std");
const zt = @import("ZT");
const png = @import("png.zig");

pub const font_paths = [_][]const u8{
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/iosevka-term/IosevkaTermNerdFontMono-Regular.ttf",
};

pub const out_dir = "zig-out/screenshots";
pub const golden_dir = "tests/golden";

pub fn updateGolden() bool {
    const p = std.c.getenv("ZT_UPDATE_GOLDEN") orelse return false;
    const s = std.mem.span(p);
    return s.len > 0 and s[0] != '0';
}

pub fn feedScreen(gpa: std.mem.Allocator, cols: u16, rows: u16, src: []const u8) !zt.Term.Screen {
    var screen = try zt.Term.Screen.init(gpa, cols, rows);
    errdefer screen.deinit();
    var runs: std.ArrayList(zt.Runs.Run) = .empty;
    defer runs.deinit(gpa);
    try zt.Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    return screen;
}

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn loadFontPath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io(), path, .{});
    defer file.close(io());
    const n = try file.length(io());
    const bytes = try gpa.alloc(u8, n);
    errdefer gpa.free(bytes);
    const got = try file.readPositionalAll(io(), bytes, 0);
    if (got != n) return error.InvalidFont;
    return bytes;
}

pub fn loadFirstFont(gpa: std.mem.Allocator) !?[]u8 {
    for (font_paths) |path| {
        if (loadFontPath(gpa, path)) |bytes| return bytes else |_| {}
    }
    return null;
}

pub fn trimNl(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r\n");
}

pub fn expectTextFile(gpa: std.mem.Allocator, path: []const u8, actual: []const u8) !void {
    if (updateGolden()) {
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = actual });
        return;
    }
    const golden = std.Io.Dir.cwd().readFileAlloc(io(), path, gpa, .unlimited) catch |err| {
        std.debug.print("missing {s} ({s}); run ZT_UPDATE_GOLDEN=1 zig build test\n", .{ path, @errorName(err) });
        return err;
    };
    defer gpa.free(golden);
    try std.testing.expectEqualStrings(trimNl(golden), trimNl(actual));
}

pub fn expectGoldenPixels(
    gpa: std.mem.Allocator,
    name: []const u8,
    width: u32,
    height: u32,
    pixels: []const u32,
) !void {
    try std.Io.Dir.cwd().createDirPath(io(), out_dir);
    var shot_buf: [128]u8 = undefined;
    const shot = try std.fmt.bufPrint(&shot_buf, "{s}/{s}", .{ out_dir, name });
    try png.writeFile(gpa, io(), shot, width, height, pixels);

    const actual = try png.encodeRgb(gpa, width, height, pixels);
    defer gpa.free(actual);

    var gold_buf: [128]u8 = undefined;
    const gold_path = try std.fmt.bufPrint(&gold_buf, "{s}/{s}", .{ golden_dir, name });

    if (updateGolden()) {
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = gold_path, .data = actual });
        return;
    }

    const golden = std.Io.Dir.cwd().readFileAlloc(io(), gold_path, gpa, .unlimited) catch |err| {
        std.debug.print("missing {s}; wrote {s}. run ZT_UPDATE_GOLDEN=1 zig build test\n", .{ gold_path, shot });
        return err;
    };
    defer gpa.free(golden);
    if (std.mem.eql(u8, golden, actual)) return;

    const ref = png.decodeRgb(gpa, golden) catch {
        std.debug.print("golden {s} is not a ZT PNG; wrote {s}\n", .{ gold_path, shot });
        return error.GoldenMismatch;
    };
    defer gpa.free(ref.pixels);
    if (ref.width != width or ref.height != height or ref.pixels.len != pixels.len) {
        std.debug.print("size mismatch {s}: golden {d}x{d} got {d}x{d}; wrote {s}\n", .{
            name, ref.width, ref.height, width, height, shot,
        });
        return error.GoldenMismatch;
    }
    const diff = try png.diffPixels(gpa, ref.pixels, pixels);
    defer gpa.free(diff);
    var diff_buf: [160]u8 = undefined;
    const diff_path = try std.fmt.bufPrint(&diff_buf, "{s}/{s}.diff.png", .{ out_dir, name });
    try png.writeFile(gpa, io(), diff_path, width, height, diff);
    std.debug.print("golden mismatch {s}; wrote {s} and {s}\n", .{ name, shot, diff_path });
    return error.GoldenMismatch;
}

pub const ShotOpts = struct {
    cols: u16,
    rows: u16,
    text: []const u8,
    cell_w: ?u32 = null,
    cell_h: ?u32 = null,
    size_px: f32 = 16,
    buf_cap: usize = 4096,
    font: bool = true,
    font_path: ?[]const u8 = null,
};

pub fn renderShot(name: []const u8, opts: ShotOpts) !void {
    const gpa = std.testing.allocator;
    var font_bytes: ?[]u8 = null;
    defer if (font_bytes) |b| gpa.free(b);
    var type_ctx: zt.Type.Context = undefined;
    var have_ctx = false;
    defer if (have_ctx) type_ctx.deinit();

    var cell_w: u32 = opts.cell_w orelse 8;
    var cell_h: u32 = opts.cell_h orelse 16;
    var ctx_ptr: ?*zt.Type.Context = null;
    if (opts.font) {
        if (opts.font_path) |path| {
            font_bytes = loadFontPath(gpa, path) catch return;
        } else {
            font_bytes = (try loadFirstFont(gpa)) orelse return;
        }
        type_ctx = try zt.Type.Context.init(gpa, .{});
        have_ctx = true;
        _ = try type_ctx.addFont(font_bytes.?, .{});
        if (type_ctx.metrics(opts.size_px)) |m| {
            const h = m.ascender - m.descender + m.line_gap;
            cell_h = @max(1, @as(u32, @intFromFloat(@ceil(h))));
        } else |_| {}
        if (type_ctx.glyph('M', opts.size_px)) |g| {
            cell_w = @max(1, @as(u32, @intFromFloat(@ceil(g.advance))));
        } else |_| {}
        ctx_ptr = &type_ctx;
    }

    var engine = try zt.Engine.init(gpa, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .buf_cap = opts.buf_cap,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .size_px = opts.size_px,
        .hz = 60,
    });
    defer engine.deinit();
    engine.type_ctx = ctx_ptr;
    engine.ingest(opts.text);
    try engine.refresh();
    try expectGoldenPixels(gpa, name, engine.frame.width, engine.frame.height, engine.frame.pixels);
}

pub fn countInk(pixels: []const u32) usize {
    var n: usize = 0;
    for (pixels) |px| {
        const r = (px >> 16) & 0xff;
        const g = (px >> 8) & 0xff;
        const b = px & 0xff;
        if (r + g + b > 30) n += 1;
    }
    return n;
}
