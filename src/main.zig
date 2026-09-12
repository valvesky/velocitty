const std = @import("std");
const builtin = @import("builtin");

const Platform = @import("platform/platform.zig");
const Debug = @import("debug.zig");

const CircBuffer = @import("circbuffer.zig").CircBuffer;
const Parser = @import("vt.zig").VtState;

const TypeCtx = @import("type.zig").Context;

const font_paths: []const []const u8 = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => &.{
        "/Library/Fonts/Courier New.ttf",
        "/System/Library/Fonts/Supplemental/Courier New.ttf",
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
    },
    .windows => &.{
        "C:/Windows/Fonts/consola.ttf",
        "C:/Windows/Fonts/cour.ttf",
        "C:/Windows/Fonts/lucon.ttf",
    },
    else => &.{
        "/usr/share/fonts/iosevka-term/IosevkaTermNerdFontMono-Regular.ttf",
        "/usr/share/fonts/iosevka-term/IosevkaTermNerdFont-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    },
};

const fallback_paths: []const []const u8 = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => &.{
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/Library/Fonts/Arial Unicode.ttf",
        "/System/Library/Fonts/STHeiti Light.ttc",
    },
    .windows => &.{
        "C:/Windows/Fonts/arial.ttf",
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/seguiemj.ttf",
    },
    else => &.{
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/noto/NotoSansSymbols-Regular.ttf",
        "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/gnu-free/FreeSans.otf",
    },
};


fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, absolute: bool) ![]u8 {
    const file = if (absolute)
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.length(io);
    const bytes = try gpa.alloc(u8, n);
    errdefer gpa.free(bytes);
    const got = try file.readPositionalAll(io, bytes, 0);
    if (got != n) return error.InvalidFont;
    return bytes;
}

fn loadFonts(io: std.Io, gpa: std.mem.Allocator, out: *std.ArrayList([]u8)) !void {
    var used: []const u8 = "";
    for (font_paths) |path| {
        if (loadFontPath(io, gpa, path)) |bytes| {
            try out.append(gpa, bytes);
            used = path;
            break;
        } else |_| {}
    }
    for (fallback_paths) |path| {
        if (std.mem.eql(u8, path, used)) continue;
        if (loadFontPath(io, gpa, path)) |bytes| {
            try out.append(gpa, bytes);
        } else |_| {}
    }
    if (out.items.len == 0) return error.InvalidFont;
}

fn loadFontPath(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const n = try file.length(io);
    const bytes = try gpa.alloc(u8, n);
    errdefer gpa.free(bytes);
    const got = try file.readPositionalAll(io, bytes, 0);
    if (got != n) return error.InvalidFont;
    return bytes;
}

pub fn main() !void {

    var gpa = std.heap.DebugAllocator(.{}){};

    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const cols: u16 = 80;
    const rows: u16 = 60;
    const px_w: u16 = 16;
    const px_h: u16 = 32;

    var type_ctx: TypeCtx = try TypeCtx.init(allocator, .{
        .atlas_height = 90,
        .atlas_width = 90,
        .cache_capacity = 2048,
        .color_emoji = true,
        .ligatures = true,
    });

    defer type_ctx.deinit();

    // const font_bytes = try loadFontPath(io.io(), allocator, font_paths[0]);
    // const fallback_bytes = try loadFontPath(io.io(), allocator, fallback_paths[0]);
    //
    // const font_id = try type_ctx.addFont(font_bytes, .{});
    // const fallback_id = try type_ctx.addFont(fallback_bytes, .{});


    var circbuffer: CircBuffer = try CircBuffer.create(allocator, 64 * 1024);
    defer circbuffer.destroy();

    // pass the storage slice to the parser
    var term: Parser = try Parser.init(allocator, 80, 60, 1000, circbuffer.storage);
    defer term.deinit();


    var window = try Platform.Window.open(allocator, "Velocitty", 800, 600);
    defer window.close();

    var pty: Platform.Pty = try Platform.Pty.open( .{
        .cols = cols,
        .rows = rows,
        .px_h = px_h,
        .px_w = px_w,
    });

    defer pty.close();

    var running = true;

    while (running) {
        var ev: Platform.Event = undefined;
        while (window.pollEvent(&ev)) {
            switch (ev) {
                .quit => {
                    running = false;
                },
                .resize => |r| {
                    Debug.log("Resized to: {d}x{d} (cols: {d}, rows: {d})\n", .{
                        r.px_w, r.px_h, r.cols, r.rows,
                    });
                    pty.setWinsize(r);
                },
                .key_press => |k| {
                    if (k.key == .escape) {
                        running = false;
                    }
                    Debug.log("Key pressed: {}\n", .{k.key});
                },
                .text_input => |text| {
                    Debug.log("Text input: {s}\n", .{text});
                },
                else => {},
            }
        }

        // NOTE(vasco):
        // We want something like the following:
        //
        // while(pty.wait)
        // if eof => consume; break;
        // if eagain check 1/hz clock => consume
        // else continue

        const runs = circbuffer.consumeAndGetRuns(rows);
        term.feedRuns(runs);

        const fb = window.framebuffer();
        fb.clear(0xFF1E1E1E);
        window.present();
    }
}
