const std = @import("std");
const builtin = @import("builtin");

const Platform = @import("platform/platform.zig");
const Debug = @import("debug.zig");

const CircBuffer = @import("circbuffer.zig").CircBuffer;
const VtState = @import("vt.zig").VtState;
const Draw = @import("draw.zig");
const TypeCtx = @import("type.zig").Context;
const Scheme = @import("scheme.zig");

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

fn loadConfig(io: std.Io, gpa: std.mem.Allocator) Scheme.Config {
    return Scheme.loadFile(io, gpa, "config.toml") orelse .{};
}

fn blitFrame(dst: *Platform.Framebuffer, src: *const Draw.Frame) void {
    const w = @min(dst.width, src.width);
    const h = @min(dst.height, src.height);
    if (w == 0 or h == 0) return;
    if (w == dst.width and w == src.width and h == dst.height and h == src.height and dst.stride == src.width) {
        @memcpy(dst.pixels, src.pixels);
        return;
    }
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const d = dst.pixels[y * dst.stride ..][0..w];
        const s = src.pixels[y * src.width ..][0..w];
        @memcpy(d, s);
    }
}

fn encodeKey(key: Platform.Event.KeyCode, mods: Platform.Event.KeyMod, app_cursor: bool) []const u8 {
    _ = mods;
    return switch (key) {
        .enter => "\r",
        .backspace => "\x7f",
        .tab => "\t",
        .escape => "\x1b",
        .arrow_up => if (app_cursor) "\x1bOA" else "\x1b[A",
        .arrow_down => if (app_cursor) "\x1bOB" else "\x1b[B",
        .arrow_right => if (app_cursor) "\x1bOC" else "\x1b[C",
        .arrow_left => if (app_cursor) "\x1bOD" else "\x1b[D",
        .home => if (app_cursor) "\x1bOH" else "\x1b[H",
        .end => if (app_cursor) "\x1bOF" else "\x1b[F",
        .insert => "\x1b[2~",
        .delete => "\x1b[3~",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
        .f1 => "\x1bOP",
        .f2 => "\x1bOQ",
        .f3 => "\x1bOR",
        .f4 => "\x1bOS",
        .f5 => "\x1b[15~",
        .f6 => "\x1b[17~",
        .f7 => "\x1b[18~",
        .f8 => "\x1b[19~",
        .f9 => "\x1b[20~",
        .f10 => "\x1b[21~",
        .f11 => "\x1b[23~",
        .f12 => "\x1b[24~",
        else => "",
    };
}

fn textLen(text: [32]u8) usize {
    return std.mem.indexOfScalar(u8, &text, 0) orelse text.len;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const config = loadConfig(io.io(), allocator);
    const hz: u32 = if (config.hz == 0) 30 else config.hz;

    var cols: u16 = 80;
    var rows: u16 = 24;
    var cell_w: u32 = 8;
    var cell_h: u32 = 16;
    const size_px: f32 = 16;

    var type_ctx: TypeCtx = try TypeCtx.init(allocator, .{
        .atlas_height = 1024,
        .atlas_width = 1024,
        .cache_capacity = 2048,
        .color_emoji = true,
        .ligatures = true,
    });
    defer type_ctx.deinit();

    var font_blobs: std.ArrayList([]u8) = .empty;
    defer {
        for (font_blobs.items) |b| allocator.free(b);
        font_blobs.deinit(allocator);
    }

    var type_ptr: ?*TypeCtx = null;
    if (loadFonts(io.io(), allocator, &font_blobs)) |_| {
        var fallbacks: std.ArrayList(@import("type.zig").FontId) = .empty;
        defer fallbacks.deinit(allocator);
        for (font_blobs.items, 0..) |bytes, i| {
            const id = try type_ctx.addFont(bytes, .{});
            if (i != 0) try fallbacks.append(allocator, id);
        }
        if (fallbacks.items.len != 0) try type_ctx.setFallbacks(fallbacks.items);
        if (type_ctx.metrics(size_px)) |m| {
            const h = m.ascender - m.descender + m.line_gap;
            cell_h = @max(1, @as(u32, @intFromFloat(@ceil(h))));
        } else |_| {}
        if (type_ctx.glyph('M', size_px)) |g| {
            cell_w = @max(1, @as(u32, @intFromFloat(@ceil(g.advance))));
        } else |_| {}
        type_ptr = &type_ctx;
    } else |_| {
        Debug.log("no fonts found; drawing without glyphs\n", .{});
    }

    var circbuffer: CircBuffer = try CircBuffer.create(allocator, 64 * 1024);
    defer circbuffer.destroy();

    var term: VtState = try VtState.init(allocator, cols, rows, 1000, circbuffer.storage);
    defer term.deinit();
    term.scheme = config.scheme;
    term.grids[0].reset(cols, rows, config.scheme);
    term.grids[1].reset(cols, rows, config.scheme);

    const win_w = @as(u32, cols) * cell_w;
    const win_h = @as(u32, rows) * cell_h;
    var window = try Platform.Window.open(allocator, "Velocitty", win_w, win_h);
    defer window.close();

    var frame = try Draw.Frame.init(allocator, win_w, win_h);
    defer frame.deinit();

    var pty: Platform.Pty = try Platform.Pty.open(.{
        .cols = cols,
        .rows = rows,
        .px_h = @intCast(win_h),
        .px_w = @intCast(win_w),
    });
    defer pty.close();

    var running = true;

    while (running) {
        var ev: Platform.Event = undefined;
        while (window.pollEvent(&ev)) {
            switch (ev) {
                .quit => running = false,
                .resize => |r| {
                    const next_cols: u16 = @intCast(@max(1, @as(u32, r.px_w) / cell_w));
                    const next_rows: u16 = @intCast(@max(1, @as(u32, r.px_h) / cell_h));
                    if (next_cols != cols or next_rows != rows) {
                        cols = next_cols;
                        rows = next_rows;
                        term.resize(cols, rows) catch {};
                        frame.resize(@as(u32, cols) * cell_w, @as(u32, rows) * cell_h) catch {};
                        pty.setWinsize(.{
                            .cols = cols,
                            .rows = rows,
                            .px_w = r.px_w,
                            .px_h = r.px_h,
                        });
                        frame.invalidate();
                    }
                },
                .key_press => |k| {
                    const bytes = encodeKey(k.key, k.mods, term.flags.app_cursor);
                    if (bytes.len != 0) pty.write(bytes);
                },
                .text_input => |text| {
                    const n = textLen(text);
                    if (n != 0) pty.write(text[0..n]);
                },
                else => {},
            }
        }

        if (!running) break;

        var hangup = false;
        circbuffer.readPTY(pty.impl.master, hz) catch {
            hangup = true;
        };

        if (circbuffer.pending()) {
            const runs = circbuffer.consumeAndGetRuns(std.math.maxInt(usize));
            if (runs.len != 0) term.feedRuns(runs);
            if (term.reply.items.len != 0) {
                pty.write(term.reply.items);
                term.reply.clearRetainingCapacity();
            }
        }
        frame.render(&term, cell_w, cell_h, type_ptr, size_px);
        term.clearDirty();
        const fb = window.framebuffer();
        blitFrame(fb, &frame);
        window.present();

        if (hangup) running = false;
    }
}

