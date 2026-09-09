const std = @import("std");
const zt = @import("ZT");
const harness = @import("harness.zig");
const vt_rand = @import("vt_rand.zig");

test "dirty frame matches full rebuild after random vt" {
    try vt_rand.run(std.testing.allocator, 32, 0xB0BA_CAFE);
}

test "png encode decode roundtrip" {
    const gpa = std.testing.allocator;
    const png = @import("png.zig");
    const pixels = [_]u32{ 0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff };
    const bytes = try png.encodeRgb(gpa, 2, 2, &pixels);
    defer gpa.free(bytes);
    const img = try png.decodeRgb(gpa, bytes);
    defer gpa.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    try std.testing.expectEqualSlices(u32, &pixels, img.pixels);
}

test "visualizer in-place frames match full rebuild" {
    const gpa = std.testing.allocator;
    const cols: u16 = 8;
    const rows: u16 = 4;
    const cell: u32 = 4;
    var engine = try zt.Engine.init(gpa, .{
        .cols = cols,
        .rows = rows,
        .buf_cap = 32,
        .cell_w = cell,
        .cell_h = cell,
        .hz = 60,
        .whitelist = true,
    });
    defer engine.deinit();
    var full = try zt.Draw.Frame.init(gpa, cols * cell, rows * cell);
    defer full.deinit();

    engine.ingest("\x1b[?25l\x1b[?1049h");
    try engine.refresh();

    var buf: [512]u8 = undefined;
    var frame: u32 = 0;
    while (frame < 24) : (frame += 1) {
        engine.ingest(vizFrame(&buf, frame, cols, rows));
        try engine.refresh();
        try expectVizCells(&engine.screen, frame);
        full.invalidate();
        full.render(&engine.screen, cell, cell, null, 4);
        if (!std.mem.eql(u32, engine.frame.pixels, full.pixels)) {
            std.debug.print("visualizer dirty vs full mismatch at frame {d}\n", .{frame});
            return error.DirtyMismatch;
        }
    }
}

fn vizFrame(buf: []u8, frame: u32, cols: u16, rows: u16) []u8 {
    var n: usize = 0;
    const prefix = "\x1b[s\n\x1b[u\n\x1b[H\n\x1b[2J\n\x1b[H";
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        const color: u8 = @intCast(1 + (frame + r) % 15);
        const ch: u8 = '0' + @as(u8, @intCast((frame + r) % 10));
        const head = std.fmt.bufPrint(buf[n..], "\x1b[38;5;{d}m", .{color}) catch unreachable;
        n += head.len;
        var c: u16 = 0;
        while (c < cols) : (c += 1) {
            buf[n] = ch;
            n += 1;
        }
        const tail = "\x1b[K";
        @memcpy(buf[n..][0..tail.len], tail);
        n += tail.len;
        if (r + 1 < rows) {
            buf[n] = '\n';
            n += 1;
        }
    }
    return buf[0..n];
}

fn expectVizCells(screen: *const zt.Term.Screen, frame: u32) !void {
    var r: u16 = 0;
    while (r < screen.rows) : (r += 1) {
        const ch: u21 = '0' + @as(u21, @intCast((frame + r) % 10));
        const color = zt.Term.vga_palette[1 + (frame + r) % 15];
        var c: u16 = 0;
        while (c < screen.cols) : (c += 1) {
            const cell = screen.cell(r, c);
            try std.testing.expectEqual(ch, cell.codepoint);
            try std.testing.expectEqual(color.r, cell.fg.r);
            try std.testing.expectEqual(color.g, cell.fg.g);
            try std.testing.expectEqual(color.b, cell.fg.b);
        }
    }
}

test "box atlas golden U+2500..U+257F" {
    const gpa = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, "\x1b[?25l");
    var cp: u21 = 0x2500;
    while (cp <= 0x257F) : (cp += 1) {
        var u: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &u);
        try bytes.appendSlice(gpa, u[0..n]);
    }
    var screen = try harness.feedScreen(gpa, 16, 8, bytes.items);
    defer screen.deinit();
    var frame = try zt.Draw.Frame.init(gpa, 128, 128);
    defer frame.deinit();
    frame.render(&screen, 8, 16, null, 16);
    try harness.expectGoldenPixels(gpa, "box-atlas.png", frame.width, frame.height, frame.pixels);
    try std.testing.expect(harness.countInk(frame.pixels) > 100);
}
