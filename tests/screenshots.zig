const std = @import("std");
const harness = @import("harness.zig");
const png = @import("png.zig");

test {
    _ = png;
}

test "png roundtrip header" {
    const gpa = std.testing.allocator;
    const pixels = [_]u32{ 0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff };
    const bytes = try png.encodeRgb(gpa, 2, 2, &pixels);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(u8, 137), bytes[0]);
    try std.testing.expectEqualSlices(u8, "IHDR", bytes[12..16]);
}

test "engine screenshot Hello ZT" {
    try harness.renderShot("hello.png", .{
        .cols = 20,
        .rows = 4,
        .text = "Hello, ZT!\nABC abc 012\nygpq QWERTY",
    });
}

test "engine screenshot alphabet" {
    try harness.renderShot("alphabet.png", .{
        .cols = 32,
        .rows = 3,
        .text = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 !@#$%^&*()[]{}",
    });
}

test "engine screenshot iosevka if present" {
    try harness.renderShot("iosevka.png", .{
        .cols = 24,
        .rows = 3,
        .font_path = "/usr/share/fonts/iosevka-term/IosevkaTermNerdFontMono-Regular.ttf",
        .text = "Hello, ZT!\nABC abc gypq 012\nIosevkaTerm Mono",
    });
}

test "engine screenshot sgr" {
    try harness.renderShot("sgr.png", .{
        .cols = 24,
        .rows = 3,
        .text = "\x1b[?25l\x1b[1;31mRed \x1b[0;32mGreen\n\x1b[38;2;255;128;0mOrange \x1b[7minv\x1b[0m\n\x1b[4munder\x1b[0m #",
    });
}

test "engine screenshot cup-ed" {
    try harness.renderShot("cup-ed.png", .{
        .cols = 16,
        .rows = 3,
        .text = "\x1b[?25lABCD\x1b[41mEF\x1b[H\x1b[2KXY\x1b[2;1H\x1b[Kdone",
    });
}

test "engine screenshot wrap-scroll" {
    try harness.renderShot("wrap-scroll.png", .{
        .cols = 4,
        .rows = 2,
        .text = "\x1b[?25lAAAA\nBBBB\nCCCC",
    });
}

test "engine screenshot cjk" {
    try harness.renderShot("cjk.png", .{
        .cols = 12,
        .rows = 2,
        .text = "\x1b[?25l日本語 ABC\n字 wide",
    });
}

test "engine screenshot box acs" {
    try harness.renderShot("box.png", .{
        .cols = 8,
        .rows = 3,
        .text = "\x1b[?25l\x1b(0lqqqk\x1b(B\n\x1b(0x  x\x1b(B\n\x1b(0mqqqj\x1b(B",
    });
}

test "engine screenshot kitty rgb" {
    try harness.renderShot("kitty.png", .{
        .cols = 4,
        .rows = 2,
        .cell_w = 4,
        .cell_h = 4,
        .size_px = 4,
        .buf_cap = 256,
        .font = false,
        .text = "\x1b[?25l\x1b_Ga=T,f=24,s=1,v=1,C=1;/wAA\x1b\\",
    });
}
