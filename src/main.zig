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

fn resolveFamilyFile(io: std.Io, gpa: std.mem.Allocator, family: []const u8) ?[]u8 {
    // fontconfig reads HOME / FONTCONFIG_* from the child environment.
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "fc-match", "-f", "%{file}", family },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0 or path[0] != '/') return null;
    return gpa.dupe(u8, path) catch null;
}

fn loadFonts(io: std.Io, gpa: std.mem.Allocator, out: *std.ArrayList([]u8), family: ?[]const u8) !void {
    var used_buf: [std.fs.max_path_bytes]u8 = undefined;
    var used_len: usize = 0;

    const append_path = struct {
        fn go(
            io_: std.Io,
            gpa_: std.mem.Allocator,
            out_: *std.ArrayList([]u8),
            path: []const u8,
            used_buf_: []u8,
            used_len_: *usize,
        ) bool {
            const bytes = loadFontPath(io_, gpa_, path) catch return false;
            out_.append(gpa_, bytes) catch {
                gpa_.free(bytes);
                return false;
            };
            const n = @min(path.len, used_buf_.len);
            @memcpy(used_buf_[0..n], path[0..n]);
            used_len_.* = n;
            return true;
        }
    }.go;

    if (family) |fam| {
        if (resolveFamilyFile(io, gpa, fam)) |path| {
            defer gpa.free(path);
            _ = append_path(io, gpa, out, path, &used_buf, &used_len);
        }
    }
    if (out.items.len == 0) {
        if (resolveFamilyFile(io, gpa, "monospace")) |path| {
            defer gpa.free(path);
            _ = append_path(io, gpa, out, path, &used_buf, &used_len);
        }
    }
    if (out.items.len == 0) {
        for (font_paths) |path| {
            if (append_path(io, gpa, out, path, &used_buf, &used_len)) break;
        }
    }
    const used = used_buf[0..used_len];
    for (fallback_paths) |path| {
        if (std.mem.eql(u8, path, used)) continue;
        const bytes = loadFontPath(io, gpa, path) catch continue;
        out.append(gpa, bytes) catch gpa.free(bytes);
    }
    if (out.items.len == 0) return error.InvalidFont;
}

fn bindFonts(gpa: std.mem.Allocator, type_ctx: *TypeCtx, blobs: []const []u8) !void {
    type_ctx.clearFonts();
    var fallbacks: std.ArrayList(@import("type.zig").FontId) = .empty;
    defer fallbacks.deinit(gpa);
    for (blobs, 0..) |bytes, i| {
        const id = try type_ctx.addFont(bytes, .{});
        if (i != 0) try fallbacks.append(gpa, id);
    }
    if (fallbacks.items.len != 0) try type_ctx.setFallbacks(fallbacks.items);
}

fn pointsToPixels(pt: f32, dpi: f32) f32 {
    return @max(1, pt * dpi / 72.0);
}

fn jsonFloatAfter(obj: []const u8, key: []const u8) ?f32 {
    const at = std.mem.indexOf(u8, obj, key) orelse return null;
    var p = at + key.len;
    while (p < obj.len and (obj[p] == ' ' or obj[p] == '\t')) p += 1;
    const start = p;
    if (p < obj.len and obj[p] == '-') p += 1;
    while (p < obj.len and (std.ascii.isDigit(obj[p]) or obj[p] == '.')) p += 1;
    if (p == start) return null;
    return std.fmt.parseFloat(f32, obj[start..p]) catch null;
}

fn parseFocusedFloat(json: []const u8, key: []const u8) ?f32 {
    var fallback: ?f32 = null;
    var i: usize = 0;
    while (i < json.len) {
        if (json[i] != '{') {
            i += 1;
            continue;
        }
        const start = i;
        var depth: u32 = 0;
        while (i < json.len) {
            if (json[i] == '{') depth += 1;
            if (json[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
            i += 1;
        }
        const obj = json[start..i];
        const value = jsonFloatAfter(obj, key) orelse continue;
        fallback = value;
        if (std.mem.indexOf(u8, obj, "\"focused\":true") != null) return value;
        if (std.mem.indexOf(u8, obj, "\"focused\": true") != null) return value;
    }
    return fallback;
}

fn parseFocusedScale(json: []const u8) ?f32 {
    return parseFocusedFloat(json, "\"scale\":");
}

fn hyprlandScale(io: std.Io, gpa: std.mem.Allocator) ?f32 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "hyprctl", "monitors", "-j" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const scale = parseFocusedScale(result.stdout) orelse return null;
    if (scale < 0.25 or scale > 8) return null;
    return scale;
}

fn hyprlandRefreshHz(io: std.Io, gpa: std.mem.Allocator) ?u32 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "hyprctl", "monitors", "-j" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const hz = parseFocusedFloat(result.stdout, "\"refreshRate\":") orelse return null;
    if (hz < 20 or hz > 500) return null;
    return @max(1, @as(u32, @intFromFloat(@round(hz))));
}

fn gdkScale() f32 {
    const p = std.c.getenv("GDK_SCALE") orelse return 1;
    const s = std.mem.sliceTo(p, 0);
    const n = std.fmt.parseFloat(f32, s) catch return 1;
    if (n < 0.25 or n > 8) return 1;
    return n;
}

fn uiScale(io: std.Io, gpa: std.mem.Allocator) f32 {
    if (hyprlandScale(io, gpa)) |s| return s;
    return gdkScale();
}

fn fontPixels(config: Scheme.Config, scale: f32, fallback_dpi: f32) f32 {
    const pt: f32 = if (config.font_size > 0) config.font_size else 8;
    const dpi: f32 = if (scale != 1) 96.0 * scale else fallback_dpi;
    return pointsToPixels(pt, dpi);
}

fn cellMetrics(type_ctx: *TypeCtx, size_px: f32, cell_w: *u32, cell_h: *u32) void {
    if (type_ctx.metrics(size_px)) |m| {
        const h = m.ascender - m.descender + m.line_gap;
        cell_h.* = @max(1, @as(u32, @intFromFloat(@ceil(h))));
    } else |_| {}
    if (type_ctx.glyph('M', size_px)) |g| {
        cell_w.* = @max(1, @as(u32, @intFromFloat(@ceil(g.advance))));
    } else |_| {}
}

fn loadConfig(io: std.Io, gpa: std.mem.Allocator) Scheme.Config {
    return Scheme.load(io, gpa);
}

var reload_requested = std.atomic.Value(bool).init(false);

fn installReloadSignal() void {
    switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => {
            const act: std.posix.Sigaction = .{
                .handler = .{ .handler = struct {
                    fn handle(_: std.posix.SIG) callconv(.c) void {
                        reload_requested.store(true, .release);
                    }
                }.handle },
                .mask = std.posix.sigemptyset(),
                .flags = std.posix.SA.RESTART,
            };
            std.posix.sigaction(.USR1, &act, null);
            std.posix.sigaction(.USR2, &act, null);
        },
        else => {},
    }
}

fn gridDims(px_w: u32, px_h: u32, cell_w: u32, cell_h: u32, pad: u32) struct { cols: u16, rows: u16 } {
    const cw = @max(cell_w, 1);
    const ch = @max(cell_h, 1);
    const inner_w = px_w -| (2 * pad);
    const inner_h = px_h -| (2 * pad);
    return .{
        .cols = @intCast(@max(1, inner_w / cw)),
        .rows = @intCast(@max(1, inner_h / ch)),
    };
}

fn padColor(term: *const VtState) u32 {
    const c = if (term.flags.reverse) term.scheme.fg else term.scheme.bg;
    return Draw.Frame.pack(c);
}

fn blitFrame(dst: *Platform.Framebuffer, src: *const Draw.Frame, bg: u32) void {
    const ox: u32 = if (dst.width > src.width) (dst.width - src.width) / 2 else 0;
    const oy: u32 = if (dst.height > src.height) (dst.height - src.height) / 2 else 0;
    const w = @min(dst.width -| ox, src.width);
    const h = @min(dst.height -| oy, src.height);
    if (ox == 0 and oy == 0 and w == dst.width and w == src.width and h == dst.height and h == src.height and dst.stride == src.width) {
        @memcpy(dst.pixels, src.pixels);
        return;
    }
    if (dst.stride == dst.width) {
        @memset(dst.pixels, bg);
    } else {
        var y: u32 = 0;
        while (y < dst.height) : (y += 1) {
            @memset(dst.pixels[y * dst.stride ..][0..dst.width], bg);
        }
    }
    if (w == 0 or h == 0) return;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const d = dst.pixels[(y + oy) * dst.stride + ox ..][0..w];
        const s = src.pixels[y * src.width ..][0..w];
        @memcpy(d, s);
    }
}

fn cellAt(px: i32, cell: u32, max_cells: u16) u16 {
    if (cell == 0 or px < 0) return 1;
    const c = @as(u32, @intCast(px)) / cell + 1;
    return @intCast(@min(c, @as(u32, max_cells)));
}

fn encodeMouseWheel(
    term: *const VtState,
    w: Platform.Event.MouseWheel,
    ox: u32,
    oy: u32,
    cell_w: u32,
    cell_h: u32,
    buf: *[64]u8,
) []const u8 {
    var btn: u16 = if (w.up) 64 else 65;
    if (w.mods.shift) btn += 4;
    if (w.mods.alt) btn += 8;
    if (w.mods.ctrl) btn += 16;

    const rel_x = w.x - @as(i32, @intCast(ox));
    const rel_y = w.y - @as(i32, @intCast(oy));

    if (term.flags.mouse_pixels) {
        const x: u32 = @intCast(@max(1, rel_x + 1));
        const y: u32 = @intCast(@max(1, rel_y + 1));
        return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}M", .{ btn, x, y }) catch "";
    }

    const col = cellAt(rel_x, cell_w, term.cols);
    const row = cellAt(rel_y, cell_h, term.rows);
    if (term.flags.mouse_sgr) {
        return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}M", .{ btn, col, row }) catch "";
    }
    if (term.flags.mouse_urxvt) {
        return std.fmt.bufPrint(buf, "\x1b[{d};{d};{d}M", .{ btn, col, row }) catch "";
    }
    if (col > 223 or row > 223) return "";
    buf[0] = 0x1b;
    buf[1] = '[';
    buf[2] = 'M';
    buf[3] = @intCast(btn + 32);
    buf[4] = @intCast(col + 32);
    buf[5] = @intCast(row + 32);
    return buf[0..6];
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

const EventLoop = struct {
    window: *Platform.Window,
    pty: *Platform.Pty,
    term: *VtState,
    frame: *Draw.Frame,
    allocator: std.mem.Allocator,
    cols: *u16,
    rows: *u16,
    cell_w: u32,
    cell_h: u32,
    pad_px: u32,
    running: *bool,
    need_draw: *bool,

    fn pump(ptr: *anyopaque) void {
        const self: *EventLoop = @ptrCast(@alignCast(ptr));
        self.drain();
    }

    fn drain(self: *EventLoop) void {
        var ev: Platform.Event = undefined;
        while (self.window.pollEvent(&ev)) {
            self.dispatch(ev);
        }
    }

    fn dispatch(self: *EventLoop, ev: Platform.Event) void {
        switch (ev) {
            .quit => self.running.* = false,
            .resize => |r| {
                const next = gridDims(r.px_w, r.px_h, self.cell_w, self.cell_h, self.pad_px);
                if (next.cols != self.cols.* or next.rows != self.rows.*) {
                    self.cols.* = next.cols;
                    self.rows.* = next.rows;
                    self.term.resize(self.cols.*, self.rows.*) catch {};
                    self.frame.resize(@as(u32, self.cols.*) * self.cell_w, @as(u32, self.rows.*) * self.cell_h) catch {};
                    self.pty.setWinsize(.{
                        .cols = self.cols.*,
                        .rows = self.rows.*,
                        .px_w = r.px_w,
                        .px_h = r.px_h,
                    });
                    self.frame.invalidate();
                }
                self.need_draw.* = true;
            },
            .key_press => |k| {
                const bytes = encodeKey(k.key, k.mods, self.term.flags.app_cursor);
                if (bytes.len != 0) self.pty.write(bytes);
            },
            .mouse_wheel => |w| {
                const ticks: u8 = @max(1, w.steps);
                var t: u8 = 0;
                if (self.term.mouse != .off) {
                    const fb = self.window.framebuffer();
                    const ox: u32 = if (fb.width > self.frame.width) (fb.width - self.frame.width) / 2 else 0;
                    const oy: u32 = if (fb.height > self.frame.height) (fb.height - self.frame.height) / 2 else 0;
                    var buf: [64]u8 = undefined;
                    const bytes = encodeMouseWheel(self.term, w, ox, oy, self.cell_w, self.cell_h, &buf);
                    while (t < ticks) : (t += 1) {
                        if (bytes.len != 0) self.pty.write(bytes);
                    }
                } else if (self.term.which == 1) {
                    const key: Platform.Event.KeyCode = if (w.up) .arrow_up else .arrow_down;
                    const bytes = encodeKey(key, w.mods, self.term.flags.app_cursor);
                    while (t < ticks) : (t += 1) {
                        if (bytes.len != 0) self.pty.write(bytes);
                    }
                } else {
                    const delta: i32 = if (w.up) @as(i32, ticks) else -@as(i32, ticks);
                    self.term.viewScroll(delta);
                    self.need_draw.* = true;
                }
            },
            .paste_request => self.window.requestPaste(),
            .paste => |text| writePaste(self.pty, self.term, self.allocator, text),
            .text_input => |text| {
                const n = textLen(text);
                if (n != 0) self.pty.write(text[0..n]);
            },
            else => {},
        }
    }
};

fn writePaste(pty: *Platform.Pty, term: *const VtState, allocator: std.mem.Allocator, raw: []const u8) void {
    var buf = allocator.alloc(u8, raw.len) catch {
        if (term.flags.bracket_paste) pty.write("\x1b[200~");
        pty.write(raw);
        if (term.flags.bracket_paste) pty.write("\x1b[201~");
        return;
    };
    defer allocator.free(buf);
    var n: usize = 0;
    for (raw) |b| {
        if (b == 0) continue;
        if (b == '\n') {
            if (n == 0 or buf[n - 1] != '\r') {
                buf[n] = '\r';
                n += 1;
            }
            continue;
        }
        buf[n] = b;
        n += 1;
    }
    if (term.flags.bracket_paste) pty.write("\x1b[200~");
    if (n != 0) pty.write(buf[0..n]);
    if (term.flags.bracket_paste) pty.write("\x1b[201~");
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Empty environ makes fc-match ignore Omarchy's fonts.conf (and ~/.local/share/fonts).
    var io = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer io.deinit();

    installReloadSignal();

    var config = loadConfig(io.io(), allocator);
    const display_hz: u32 = hyprlandRefreshHz(io.io(), allocator) orelse 60;
    var hz: u32 = display_hz;
    var pad_px: u32 = config.pad_px;

    var cols: u16 = 80;
    var rows: u16 = 24;
    var cell_w: u32 = 8;
    var cell_h: u32 = 16;
    const dpi = Platform.screenDpi();
    const scale = uiScale(io.io(), allocator);
    var size_px: f32 = fontPixels(config, scale, dpi);

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
    if (loadFonts(io.io(), allocator, &font_blobs, config.family())) |_| {
        bindFonts(allocator, &type_ctx, font_blobs.items) catch {};
        cellMetrics(&type_ctx, size_px, &cell_w, &cell_h);
        type_ptr = &type_ctx;
    } else |_| {
        Debug.log("no fonts found; drawing without glyphs\n", .{});
    }

    var circbuffer: CircBuffer = try CircBuffer.create(allocator, 64 * 1024);
    defer circbuffer.destroy();

    var term: VtState = try VtState.init(allocator, cols, rows, 1000, circbuffer.storage);
    defer term.deinit();
    term.applyScheme(config.scheme);
    term.grids[0].reset(cols, rows, config.scheme);
    term.grids[1].reset(cols, rows, config.scheme);
    term.cell_px_w = @intCast(@min(cell_w, std.math.maxInt(u16)));
    term.cell_px_h = @intCast(@min(cell_h, std.math.maxInt(u16)));

    const win_w = @as(u32, cols) * cell_w + 2 * pad_px;
    const win_h = @as(u32, rows) * cell_h + 2 * pad_px;
    var window = try Platform.Window.open(allocator, "Velocitty", win_w, win_h);
    defer window.close();

    var frame = try Draw.Frame.init(allocator, @as(u32, cols) * cell_w, @as(u32, rows) * cell_h);
    defer frame.deinit();

    var pty: Platform.Pty = try Platform.Pty.open(.{
        .cols = cols,
        .rows = rows,
        .px_h = @intCast(win_h),
        .px_w = @intCast(win_w),
    });
    defer pty.close();

    const x_fd = window.eventFd();
    const pty_fd = pty.impl.master;

    var running = true;
    var theme_stamp = Scheme.watchStamp(io.io());
    var need_draw = true;

    var eloop = EventLoop{
        .window = &window,
        .pty = &pty,
        .term = &term,
        .frame = &frame,
        .allocator = allocator,
        .cols = &cols,
        .rows = &rows,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .pad_px = pad_px,
        .running = &running,
        .need_draw = &need_draw,
    };

    while (running) {
        eloop.drain();

        if (!running) break;

        const stamp = Scheme.watchStamp(io.io());
        if (stamp != theme_stamp) reload_requested.store(true, .release);

        if (reload_requested.swap(false, .acq_rel)) {
            config = loadConfig(io.io(), allocator);
            hz = display_hz;
            pad_px = config.pad_px;
            size_px = fontPixels(config, scale, dpi);
            term.applyScheme(config.scheme);

            var new_blobs: std.ArrayList([]u8) = .empty;
            if (loadFonts(io.io(), allocator, &new_blobs, config.family())) |_| {
                if (bindFonts(allocator, &type_ctx, new_blobs.items)) |_| {
                    for (font_blobs.items) |b| allocator.free(b);
                    font_blobs.deinit(allocator);
                    font_blobs = new_blobs;
                    cellMetrics(&type_ctx, size_px, &cell_w, &cell_h);
                    type_ptr = &type_ctx;
                    term.cell_px_w = @intCast(@min(cell_w, std.math.maxInt(u16)));
                    term.cell_px_h = @intCast(@min(cell_h, std.math.maxInt(u16)));
                } else |_| {
                    bindFonts(allocator, &type_ctx, font_blobs.items) catch {};
                    for (new_blobs.items) |b| allocator.free(b);
                    new_blobs.deinit(allocator);
                }
            } else |_| {
                for (new_blobs.items) |b| allocator.free(b);
                new_blobs.deinit(allocator);
            }
            {
                const fb = window.framebuffer();
                const next = gridDims(fb.width, fb.height, cell_w, cell_h, pad_px);
                if (next.cols != cols or next.rows != rows) {
                    cols = next.cols;
                    rows = next.rows;
                    term.resize(cols, rows) catch {};
                    frame.resize(@as(u32, cols) * cell_w, @as(u32, rows) * cell_h) catch {};
                    pty.setWinsize(.{
                        .cols = cols,
                        .rows = rows,
                        .px_w = @intCast(fb.width),
                        .px_h = @intCast(fb.height),
                    });
                }
            }
            frame.invalidate();
            theme_stamp = Scheme.watchStamp(io.io());
            need_draw = true;
            eloop.cell_w = cell_w;
            eloop.cell_h = cell_h;
            eloop.pad_px = pad_px;
        }

        var hangup = false;
        circbuffer.readPTYPump(pty_fd, hz, .{
            .fd = x_fd,
            .ctx = @ptrCast(&eloop),
            .tick = EventLoop.pump,
        }) catch {
            hangup = true;
        };

        if (circbuffer.pending()) {
            const runs = circbuffer.consumeAndGetRuns(std.math.maxInt(usize));
            if (runs.len != 0) term.feedRuns(runs);
            if (term.reply.items.len != 0) {
                pty.write(term.reply.items);
                term.reply.clearRetainingCapacity();
            }
            need_draw = true;
        }

        if (need_draw) {
            frame.render(&term, cell_w, cell_h, type_ptr, size_px);
            term.clearDirty();
            const fb = window.framebuffer();
            blitFrame(fb, &frame, padColor(&term));
            window.present();
            need_draw = false;
        }

        if (hangup) running = false;
    }
}

