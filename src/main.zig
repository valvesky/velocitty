const std = @import("std");
const builtin = @import("builtin");

const Platform = @import("platform/platform.zig");
const Debug = @import("debug.zig");

const CircBuffer = @import("circbuffer.zig").CircBuffer;
const VtState = @import("vt.zig").VtState;
const Draw = @import("draw.zig");
const TypeCtx = @import("type.zig").Context;
const Scheme = @import("scheme.zig");
const Select = @import("select.zig");

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
        "/usr/share/fonts/noto/NotoColorEmoji.ttf",
    },
};

const FontBlob = struct {
    bytes: []u8,
    style: @import("type.zig").Style = .{},
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

fn loadFonts(io: std.Io, gpa: std.mem.Allocator, out: *std.ArrayList(FontBlob), family: ?[]const u8) !void {
    var seen: [16][std.fs.max_path_bytes]u8 = undefined;
    var seen_len: [16]usize = @splat(0);
    var seen_n: usize = 0;

    const already = struct {
        fn go(path: []const u8, seen_buf: [][std.fs.max_path_bytes]u8, seen_l: []usize, n: usize) bool {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (std.mem.eql(u8, seen_buf[i][0..seen_l[i]], path)) return true;
            }
            return false;
        }
    }.go;

    const remember = struct {
        fn go(path: []const u8, seen_buf: [][std.fs.max_path_bytes]u8, seen_l: []usize, n: *usize) void {
            if (n.* >= seen_buf.len) return;
            const i = n.*;
            const k = @min(path.len, seen_buf[i].len);
            @memcpy(seen_buf[i][0..k], path[0..k]);
            seen_l[i] = k;
            n.* = i + 1;
        }
    }.go;

    const append_path = struct {
        fn go(
            io_: std.Io,
            gpa_: std.mem.Allocator,
            out_: *std.ArrayList(FontBlob),
            path: []const u8,
            style: @import("type.zig").Style,
            seen_buf: [][std.fs.max_path_bytes]u8,
            seen_l: []usize,
            n: *usize,
        ) bool {
            if (already(path, seen_buf, seen_l, n.*)) return false;
            const bytes = loadFontPath(io_, gpa_, path) catch return false;
            out_.append(gpa_, .{ .bytes = bytes, .style = style }) catch {
                gpa_.free(bytes);
                return false;
            };
            remember(path, seen_buf, seen_l, n);
            return true;
        }
    }.go;

    const try_pattern = struct {
        fn go(
            io_: std.Io,
            gpa_: std.mem.Allocator,
            out_: *std.ArrayList(FontBlob),
            pattern: []const u8,
            style: @import("type.zig").Style,
            seen_buf: [][std.fs.max_path_bytes]u8,
            seen_l: []usize,
            n: *usize,
        ) void {
            const path = resolveFamilyFile(io_, gpa_, pattern) orelse return;
            defer gpa_.free(path);
            _ = append_path(io_, gpa_, out_, path, style, seen_buf, seen_l, n);
        }
    }.go;

    const fam = family orelse "monospace";
    try_pattern(io, gpa, out, fam, .{}, &seen, seen_len[0..], &seen_n);
    var pat_buf: [192]u8 = undefined;
    if (std.fmt.bufPrint(&pat_buf, "{s}:weight=bold", .{fam})) |p| {
        try_pattern(io, gpa, out, p, .{ .bold = true }, &seen, seen_len[0..], &seen_n);
    } else |_| {}
    if (std.fmt.bufPrint(&pat_buf, "{s}:slant=italic", .{fam})) |p| {
        try_pattern(io, gpa, out, p, .{ .italic = true }, &seen, seen_len[0..], &seen_n);
    } else |_| {}
    if (std.fmt.bufPrint(&pat_buf, "{s}:weight=bold:slant=italic", .{fam})) |p| {
        try_pattern(io, gpa, out, p, .{ .bold = true, .italic = true }, &seen, seen_len[0..], &seen_n);
    } else |_| {}

    if (out.items.len == 0) {
        for (font_paths) |path| {
            if (append_path(io, gpa, out, path, .{}, &seen, seen_len[0..], &seen_n)) break;
        }
    }
    for (fallback_paths) |path| {
        _ = append_path(io, gpa, out, path, .{}, &seen, seen_len[0..], &seen_n);
    }
    try_pattern(io, gpa, out, "Noto Color Emoji", .{}, &seen, seen_len[0..], &seen_n);
    if (out.items.len == 0) return error.InvalidFont;
}

fn bindFonts(gpa: std.mem.Allocator, type_ctx: *TypeCtx, blobs: []const FontBlob) !void {
    type_ctx.clearFonts();
    var fallbacks: std.ArrayList(@import("type.zig").FontId) = .empty;
    defer fallbacks.deinit(gpa);
    for (blobs, 0..) |blob, i| {
        const id = type_ctx.addFont(blob.bytes, .{ .style = blob.style }) catch continue;
        const styled = blob.style.bold or blob.style.italic;
        if (i != 0 and !styled) try fallbacks.append(gpa, id);
    }
    if (type_ctx.primary == null) return error.InvalidFont;
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

const HyprMonitor = struct {
    scale: ?f32 = null,
    hz: ?u32 = null,
};

fn hyprlandFocusedMonitor(io: std.Io, gpa: std.mem.Allocator) HyprMonitor {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "hyprctl", "monitors", "-j" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
    }) catch return .{};
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return .{},
        else => return .{},
    }
    var mon: HyprMonitor = .{};
    if (parseFocusedScale(result.stdout)) |scale| {
        if (scale >= 0.25 and scale <= 8) mon.scale = scale;
    }
    if (parseFocusedFloat(result.stdout, "\"refreshRate\":")) |hz| {
        if (hz >= 20 and hz <= 500) mon.hz = @max(1, @as(u32, @intFromFloat(@round(hz))));
    }
    return mon;
}

fn envScale(name: [:0]const u8) ?f32 {
    const p = std.c.getenv(name) orelse return null;
    const n = std.fmt.parseFloat(f32, std.mem.sliceTo(p, 0)) catch return null;
    if (n < 0.25 or n > 8) return null;
    return n;
}

fn gdkScale() f32 {
    return envScale("GDK_SCALE") orelse envScale("QT_SCALE_FACTOR") orelse 1;
}

fn uiScale(io: std.Io, gpa: std.mem.Allocator) f32 {
    if (hyprlandFocusedMonitor(io, gpa).scale) |s| return s;
    return gdkScale();
}

var scale_cache: f32 = 0;
var scale_cache_ms: i64 = 0;

fn uiScaleCached(io: std.Io, gpa: std.mem.Allocator, force: bool) f32 {
    const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, 1_000_000));
    if (!force and scale_cache != 0 and now_ms -| scale_cache_ms < 500) return scale_cache;
    scale_cache = uiScale(io, gpa);
    scale_cache_ms = now_ms;
    return scale_cache;
}

fn scaleChanged(a: f32, b: f32) bool {
    return @abs(a - b) > 0.01;
}

/// CSS/Wayland px: 1px = 1/96 in, times the compositor scale. X11 mm-DPI is the
/// panel's physical density and does not move when the Wayland scale changes
/// (`xwayland.force_zero_scaling`), so it must not be the font baseline.
fn fontPixels(config: Scheme.Config, scale: f32) f32 {
    const pt: f32 = if (config.font_size > 0) config.font_size else 8;
    const s = if (std.math.isFinite(scale) and scale >= 0.25) scale else 1;
    return pointsToPixels(pt, 96.0 * s);
}

fn scalePx(v: u32, scale: f32) u32 {
    if (v == 0) return 0;
    const s = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    return @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(v)) * s))));
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

fn applyMetrics(
    type_ptr: ?*TypeCtx,
    size_px: f32,
    scale: f32,
    base_pad: u32,
    cell_w: *u32,
    cell_h: *u32,
    pad_px: *u32,
) void {
    cell_w.* = scalePx(8, scale);
    cell_h.* = scalePx(16, scale);
    pad_px.* = scalePx(base_pad, scale);
    if (type_ptr) |ctx| cellMetrics(ctx, size_px, cell_w, cell_h);
}

fn syncGrid(
    window: *Platform.Window,
    term: *VtState,
    frame: *Draw.Frame,
    pty: *Platform.Pty,
    cols: *u16,
    rows: *u16,
    cell_w: u32,
    cell_h: u32,
    pad_px: u32,
) void {
    term.cell_px_w = @intCast(@min(cell_w, std.math.maxInt(u16)));
    term.cell_px_h = @intCast(@min(cell_h, std.math.maxInt(u16)));
    const fb = window.framebuffer();
    term.win_px_w = @intCast(@min(fb.width, std.math.maxInt(u16)));
    term.win_px_h = @intCast(@min(fb.height, std.math.maxInt(u16)));
    const next = gridDims(fb.width, fb.height, cell_w, cell_h, pad_px);
    const new_fw = @as(u32, next.cols) * cell_w;
    const new_fh = @as(u32, next.rows) * cell_h;
    if (next.cols != cols.* or next.rows != rows.*) {
        cols.* = next.cols;
        rows.* = next.rows;
        term.resize(cols.*, rows.*) catch {};
        pty.setWinsize(.{
            .cols = cols.*,
            .rows = rows.*,
            .px_w = @intCast(@min(fb.width, std.math.maxInt(u16))),
            .px_h = @intCast(@min(fb.height, std.math.maxInt(u16))),
        });
        if (term.flags.size_notifications) {
            term.respondFmt("\x1b[48;{d};{d};{d};{d}t", .{ rows.*, cols.*, fb.height, fb.width });
        }
        frame.invalidate();
    }
    if (frame.width != new_fw or frame.height != new_fh) {
        frame.resize(new_fw, new_fh) catch {};
        frame.invalidate();
    }
}

fn flushReply(pty: *Platform.Pty, term: *VtState) void {
    if (term.reply.items.len == 0) return;
    pty.write(term.reply.items);
    term.reply.clearRetainingCapacity();
}

fn zcopy(buf: []u8, src: []const u8) [:0]u8 {
    const n = @min(src.len, buf.len - 1);
    @memcpy(buf[0..n], src[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

fn drainHost(window: *Platform.Window, term: *VtState, allocator: std.mem.Allocator) void {
    window.setAllMotion(term.mouse == .any);
    if (term.title_dirty) {
        var buf: [256]u8 = undefined;
        window.setTitle(zcopy(&buf, term.title.items));
        term.title_dirty = false;
    }
    if (term.app_id_dirty) {
        var buf: [128]u8 = undefined;
        window.setClass(zcopy(&buf, term.app_id.items));
        term.app_id_dirty = false;
    }
    if (term.pointer_dirty) {
        window.setPointer(term.pointer);
        term.pointer_dirty = false;
    }
    if (term.clip_kind != 0) {
        if (term.clip_kind & 1 != 0) window.setClipboard(term.clip.items);
        if (term.clip_kind & 2 != 0) window.setPrimary(term.clip.items);
        term.clip_kind = 0;
        term.clip.clearRetainingCapacity();
    }
    if (term.notify_pending) {
        spawnNotify(allocator, term.notify_title.items, term.notify_body.items);
        term.notify_pending = false;
        term.notify_title.clearRetainingCapacity();
        term.notify_body.clearRetainingCapacity();
    }
}

fn spawnNotify(_: std.mem.Allocator, title: []const u8, body: []const u8) void {
    const t = if (title.len == 0) "Velocitty" else title;
    var tbuf: [128]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    const tz = zcopy(&tbuf, t);
    const bz = zcopy(&bbuf, body);
    const rc = std.os.linux.fork();
    const errno = std.os.linux.errno(rc);
    if (errno != .SUCCESS) return;
    if (rc != 0) return;
    const argv = [_:null]?[*:0]const u8{ "notify-send", tz, bz, null };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    _ = std.c.execve("/usr/bin/notify-send", &argv, envp);
    std.os.linux.exit(127);
}

fn layoutIfNeeded(
    need_layout: *bool,
    need_draw: *bool,
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Scheme.Config,
    scale: *f32,
    size_px: *f32,
    type_ptr: ?*TypeCtx,
    cell_w: *u32,
    cell_h: *u32,
    pad_px: *u32,
    eloop: *EventLoop,
    window: *Platform.Window,
    term: *VtState,
    frame: *Draw.Frame,
    pty: *Platform.Pty,
    cols: *u16,
    rows: *u16,
) void {
    if (!need_layout.*) return;
    const next_scale = uiScaleCached(io, allocator, false);
    var changed = false;
    if (scaleChanged(next_scale, scale.*)) {
        scale.* = next_scale;
        size_px.* = fontPixels(config, scale.*);
        applyMetrics(type_ptr, size_px.*, scale.*, config.pad_px, cell_w, cell_h, pad_px);
        eloop.cell_w = cell_w.*;
        eloop.cell_h = cell_h.*;
        eloop.pad_px = pad_px.*;
        frame.invalidate();
        changed = true;
    }
    const old_cols = cols.*;
    const old_rows = rows.*;
    const old_fw = frame.width;
    const old_fh = frame.height;
    syncGrid(window, term, frame, pty, cols, rows, cell_w.*, cell_h.*, pad_px.*);
    need_layout.* = false;
    if (changed or cols.* != old_cols or rows.* != old_rows or frame.width != old_fw or frame.height != old_fh) {
        need_draw.* = true;
    }
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
    } else {
        if (dst.stride == dst.width) {
            @memset(dst.pixels, bg);
        } else {
            var y: u32 = 0;
            while (y < dst.height) : (y += 1) {
                @memset(dst.pixels[y * dst.stride ..][0..dst.width], bg);
            }
        }
        if (w != 0 and h != 0) {
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                const d = dst.pixels[(y + oy) * dst.stride + ox ..][0..w];
                const s = src.pixels[y * src.width ..][0..w];
                @memcpy(d, s);
            }
        }
    }
}

fn cellAt(px: i32, cell: u32, max_cells: u16) u16 {
    if (cell == 0 or px < 0) return 1;
    const c = @as(u32, @intCast(px)) / cell + 1;
    return @intCast(@min(c, @as(u32, max_cells)));
}

const MouseReport = struct {
    btn: u16,
    press: bool,
    motion: bool,
    x: i32,
    y: i32,
    mods: Platform.Event.KeyMod,
};

fn encodeMouse(
    term: *const VtState,
    r: MouseReport,
    ox: u32,
    oy: u32,
    cell_w: u32,
    cell_h: u32,
    buf: *[64]u8,
) []const u8 {
    var btn = r.btn;
    if (r.mods.shift) btn += 4;
    if (r.mods.alt) btn += 8;
    if (r.mods.ctrl) btn += 16;
    if (r.motion) btn += 32;

    const rel_x = r.x - @as(i32, @intCast(ox));
    const rel_y = r.y - @as(i32, @intCast(oy));
    const final: u8 = if (term.flags.mouse_sgr or term.flags.mouse_pixels) (if (r.press or r.motion) 'M' else 'm') else 'M';

    if (term.flags.mouse_pixels) {
        const x: u32 = @intCast(@max(1, rel_x + 1));
        const y: u32 = @intCast(@max(1, rel_y + 1));
        return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{ btn, x, y, final }) catch "";
    }

    const col = cellAt(rel_x, cell_w, term.cols);
    const row = cellAt(rel_y, cell_h, term.rows);
    if (term.flags.mouse_sgr) {
        return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{ btn, col, row, final }) catch "";
    }
    if (term.flags.mouse_urxvt) {
        const b = if (r.press or r.motion) btn else @as(u16, 3);
        return std.fmt.bufPrint(buf, "\x1b[{d};{d};{d}M", .{ b, col, row }) catch "";
    }
    if (col > 223 or row > 223) return "";
    const legacy: u16 = if (r.press or r.motion) btn else 3;
    buf[0] = 0x1b;
    buf[1] = '[';
    buf[2] = 'M';
    buf[3] = @intCast(@min(legacy + 32, 255));
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
    need_layout: *bool,
    sel: Select.State = .{},
    dragging: bool = false,
    drag_moved: bool = false,
    clicks: u8 = 0,
    click_time: u32 = 0,
    click_col: u16 = 0,
    click_row: u16 = 0,
    mouse_held: u8 = 0,

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
            .resize => {
                self.clearSel();
                self.need_layout.* = true;
                self.need_draw.* = true;
            },
            .redraw => self.need_draw.* = true,
            .focus_gained => {
                self.need_layout.* = true;
                if (self.term.flags.focus_event) self.pty.write("\x1b[I");
                self.term.setVisible(true);
                flushReply(self.pty, self.term);
            },
            .focus_lost => {
                if (self.term.flags.focus_event) self.pty.write("\x1b[O");
                self.term.setVisible(false);
                flushReply(self.pty, self.term);
            },
            .key_press => |k| {
                self.clearSel();
                const bytes = encodeKey(k.key, k.mods, self.term.flags.app_cursor);
                if (bytes.len != 0) self.pty.write(bytes);
            },
            .mouse_down => |m| self.onMouseDown(m),
            .mouse_up => |m| self.onMouseUp(m),
            .mouse_move => |m| self.onMouseMove(m),
            .copy_request => self.copyClipboard(),
            .mouse_wheel => |w| {
                const ticks: u8 = @max(1, w.steps);
                var t: u8 = 0;
                if (self.term.mouse != .off) {
                    while (t < ticks) : (t += 1) {
                        self.reportMouse(.{ .btn = if (w.up) 64 else 65, .press = true, .motion = false, .x = w.x, .y = w.y, .mods = w.mods });
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
            .paste_request => |src| self.window.requestPasteFrom(src),
            .paste => |text| writePaste(self.pty, self.term, self.allocator, text),
            .text_input => |text| {
                const n = textLen(text);
                if (n != 0) {
                    self.clearSel();
                    self.pty.write(text[0..n]);
                }
            },
            else => {},
        }
    }

    fn hit(self: *const EventLoop, x: i32, y: i32) Select.Point {
        const fb = self.window.framebuffer();
        const ox: i32 = if (fb.width > self.frame.width) @intCast((fb.width - self.frame.width) / 2) else 0;
        const oy: i32 = if (fb.height > self.frame.height) @intCast((fb.height - self.frame.height) / 2) else 0;
        return .{
            .col = clampCell(x - ox, self.cell_w, self.term.cols),
            .row = clampCell(y - oy, self.cell_h, self.term.rows),
        };
    }

    fn reportMouse(self: *EventLoop, r: MouseReport) void {
        const fb = self.window.framebuffer();
        const ox: u32 = if (fb.width > self.frame.width) (fb.width - self.frame.width) / 2 else 0;
        const oy: u32 = if (fb.height > self.frame.height) (fb.height - self.frame.height) / 2 else 0;
        var buf: [64]u8 = undefined;
        const bytes = encodeMouse(self.term, r, ox, oy, self.cell_w, self.cell_h, &buf);
        if (bytes.len != 0) self.pty.write(bytes);
    }

    fn reporting(self: *const EventLoop, mods: Platform.Event.KeyMod) bool {
        return self.term.mouse != .off and !mods.shift;
    }

    fn onMouseDown(self: *EventLoop, m: Platform.Event.Mouse) void {
        if (self.reporting(m.mods)) {
            if (m.button >= 1 and m.button <= 3) {
                self.mouse_held = m.button;
                self.reportMouse(.{ .btn = m.button - 1, .press = true, .motion = false, .x = m.x, .y = m.y, .mods = m.mods });
            }
            return;
        }
        if (m.button == 2) {
            self.window.requestPasteFrom(.primary);
            return;
        }
        if (m.button != 1) return;
        const p = self.hit(m.x, m.y);
        const chained = p.col == self.click_col and p.row == self.click_row and m.time -% self.click_time < 500;
        self.clicks = if (chained) self.clicks % 3 + 1 else 1;
        self.click_time = m.time;
        self.click_col = p.col;
        self.click_row = p.row;
        const kind: Select.Kind = switch (self.clicks) {
            2 => .word,
            3 => .line,
            else => .cell,
        };
        if (m.mods.shift and self.sel.on) {
            self.sel.drag(self.term, p.col, p.row);
        } else {
            self.sel.grab(self.term, p.col, p.row, kind);
        }
        self.dragging = true;
        self.drag_moved = kind != .cell;
        self.need_draw.* = true;
    }

    fn onMouseMove(self: *EventLoop, m: Platform.Event.Mouse) void {
        if (self.term.mouse == .any or (self.term.mouse == .drag and self.mouse_held != 0)) {
            if (!m.mods.shift) {
                const btn: u16 = if (self.mouse_held != 0) self.mouse_held - 1 else 0;
                self.reportMouse(.{ .btn = btn, .press = true, .motion = true, .x = m.x, .y = m.y, .mods = m.mods });
                return;
            }
        }
        if (!self.dragging) return;
        const p = self.hit(m.x, m.y);
        if (p.col != self.click_col or p.row != self.click_row) self.drag_moved = true;
        const prev_a = self.sel.a;
        const prev_b = self.sel.b;
        self.sel.drag(self.term, p.col, p.row);
        if (self.sel.a.col == prev_a.col and self.sel.a.row == prev_a.row and
            self.sel.b.col == prev_b.col and self.sel.b.row == prev_b.row) return;
        self.need_draw.* = true;
    }

    fn onMouseUp(self: *EventLoop, m: Platform.Event.Mouse) void {
        if (self.reporting(m.mods) and m.button >= 1 and m.button <= 3) {
            self.reportMouse(.{ .btn = m.button - 1, .press = false, .motion = false, .x = m.x, .y = m.y, .mods = m.mods });
            if (self.mouse_held == m.button) self.mouse_held = 0;
            return;
        }
        if (m.button != 1 or !self.dragging) return;
        self.dragging = false;
        const p = self.hit(m.x, m.y);
        self.sel.drag(self.term, p.col, p.row);
        if (!self.drag_moved and self.sel.kind == .cell) {
            self.clearSel();
            return;
        }
        self.commitPrimary();
        self.need_draw.* = true;
    }

    fn clearSel(self: *EventLoop) void {
        if (!self.sel.on and !self.dragging) return;
        self.sel.clear();
        self.dragging = false;
        self.need_draw.* = true;
    }

    fn commitPrimary(self: *EventLoop) void {
        const text = Select.copyAlloc(self.allocator, self.term, self.sel) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        self.window.setPrimary(text);
    }

    fn copyClipboard(self: *EventLoop) void {
        if (!self.sel.on) return;
        const text = Select.copyAlloc(self.allocator, self.term, self.sel) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        self.window.setClipboard(text);
    }
};

fn clampCell(px: i32, cell: u32, max_cells: u16) u16 {
    if (max_cells == 0) return 0;
    if (px < 0) return 0;
    const c = @as(u32, @intCast(px)) / @max(cell, 1);
    return @intCast(@min(c, @as(u32, max_cells - 1)));
}

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

const Cli = struct {
    title: [:0]const u8 = "Velocitty",
    class: [:0]const u8 = "velocitty",
    cwd: ?[:0]const u8 = null,
    cmd: []const [*:0]const u8 = &.{},
};

fn takePrefixed(arg: [:0]const u8, prefix: []const u8) ?[:0]const u8 {
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return arg[prefix.len..];
}

fn parseCli(argv: []const [*:0]const u8) Cli {
    var cli: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--")) {
            cli.cmd = argv[i + 1 ..];
            break;
        } else if (takePrefixed(a, "--class=")) |v| {
            cli.class = v;
        } else if (std.mem.eql(u8, a, "--class") and i + 1 < argv.len) {
            i += 1;
            cli.class = std.mem.span(argv[i]);
        } else if (takePrefixed(a, "--title=")) |v| {
            cli.title = v;
        } else if (std.mem.eql(u8, a, "--title") and i + 1 < argv.len) {
            i += 1;
            cli.title = std.mem.span(argv[i]);
        } else if (takePrefixed(a, "--working-directory=")) |v| {
            cli.cwd = v;
        } else if (std.mem.eql(u8, a, "--working-directory") and i + 1 < argv.len) {
            i += 1;
            cli.cwd = std.mem.span(argv[i]);
        }
    }
    return cli;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const cli = parseCli(init.args.vector);

    // Empty environ makes fc-match ignore Omarchy's fonts.conf (and ~/.local/share/fonts).
    var io = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer io.deinit();

    installReloadSignal();

    var config = loadConfig(io.io(), allocator);
    const hypr = hyprlandFocusedMonitor(io.io(), allocator);
    const display_hz: u32 = hypr.hz orelse 60;
    var hz: u32 = display_hz;
    var scale: f32 = hypr.scale orelse gdkScale();
    scale_cache = scale;
    scale_cache_ms = @intCast(@divTrunc(std.Io.Timestamp.now(io.io(), .awake).nanoseconds, 1_000_000));
    var pad_px: u32 = scalePx(config.pad_px, scale);

    var cols: u16 = 80;
    var rows: u16 = 24;
    var cell_w: u32 = scalePx(8, scale);
    var cell_h: u32 = scalePx(16, scale);
    var size_px: f32 = fontPixels(config, scale);

    var type_ctx: TypeCtx = try TypeCtx.init(allocator, .{
        .atlas_height = 1024,
        .atlas_width = 1024,
        .cache_capacity = 2048,
        .color_emoji = true,
        .ligatures = true,
    });
    defer type_ctx.deinit();

    var font_blobs: std.ArrayList(FontBlob) = .empty;
    defer {
        for (font_blobs.items) |b| allocator.free(b.bytes);
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
    var window = try Platform.Window.open(allocator, cli.title, cli.class, win_w, win_h);
    defer window.close();

    var frame = try Draw.Frame.init(allocator, @as(u32, cols) * cell_w, @as(u32, rows) * cell_h);
    defer frame.deinit();

    var pty: Platform.Pty = try Platform.Pty.open(.{
        .cols = cols,
        .rows = rows,
        .px_h = @intCast(win_h),
        .px_w = @intCast(win_w),
    }, .{ .argv = cli.cmd, .cwd = if (cli.cwd) |d| d.ptr else null });
    defer pty.close();

    const x_fd = window.eventFd();
    const pty_fd = pty.impl.master;

    var running = true;
    var theme_stamp = Scheme.watchStamp(io.io());
    var need_draw = true;
    var need_layout = true;
    var last_alpha: u8 = 255;
    var last_watch_ns: i128 = 0;
    var sync_hold: u32 = 0;

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
        .need_layout = &need_layout,
    };

    while (running) {
        eloop.drain();

        if (!running) break;

        const now_ns: i128 = @intCast(std.Io.Timestamp.now(io.io(), .awake).nanoseconds);
        if (now_ns -| last_watch_ns >= 250_000_000) {
            last_watch_ns = now_ns;
            const stamp = Scheme.watchStamp(io.io());
            if (stamp != theme_stamp) reload_requested.store(true, .release);
        }

        if (reload_requested.swap(false, .acq_rel)) {
            config = loadConfig(io.io(), allocator);
            hz = display_hz;
            scale = uiScaleCached(io.io(), allocator, true);
            size_px = fontPixels(config, scale);
            term.applyScheme(config.scheme);

            var new_blobs: std.ArrayList(FontBlob) = .empty;
            if (loadFonts(io.io(), allocator, &new_blobs, config.family())) |_| {
                if (bindFonts(allocator, &type_ctx, new_blobs.items)) |_| {
                    for (font_blobs.items) |b| allocator.free(b.bytes);
                    font_blobs.deinit(allocator);
                    font_blobs = new_blobs;
                    type_ptr = &type_ctx;
                } else |_| {
                    bindFonts(allocator, &type_ctx, font_blobs.items) catch {};
                    for (new_blobs.items) |b| allocator.free(b.bytes);
                    new_blobs.deinit(allocator);
                }
            } else |_| {
                for (new_blobs.items) |b| allocator.free(b.bytes);
                new_blobs.deinit(allocator);
            }
            applyMetrics(type_ptr, size_px, scale, config.pad_px, &cell_w, &cell_h, &pad_px);
            syncGrid(&window, &term, &frame, &pty, &cols, &rows, cell_w, cell_h, pad_px);
            frame.invalidate();
            theme_stamp = Scheme.watchStamp(io.io());
            need_draw = true;
            need_layout = false;
            eloop.cell_w = cell_w;
            eloop.cell_h = cell_h;
            eloop.pad_px = pad_px;
        }

        layoutIfNeeded(
            &need_layout,
            &need_draw,
            io.io(),
            allocator,
            config,
            &scale,
            &size_px,
            type_ptr,
            &cell_w,
            &cell_h,
            &pad_px,
            &eloop,
            &window,
            &term,
            &frame,
            &pty,
            &cols,
            &rows,
        );

        var hangup = false;
        circbuffer.readPTYPump(pty_fd, hz, .{
            .fd = x_fd,
            .ctx = @ptrCast(&eloop),
            .tick = EventLoop.pump,
        }) catch {
            hangup = true;
        };

        layoutIfNeeded(
            &need_layout,
            &need_draw,
            io.io(),
            allocator,
            config,
            &scale,
            &size_px,
            type_ptr,
            &cell_w,
            &cell_h,
            &pad_px,
            &eloop,
            &window,
            &term,
            &frame,
            &pty,
            &cols,
            &rows,
        );

        if (circbuffer.pending()) {
            const runs = circbuffer.consumeAndGetRuns(std.math.maxInt(usize));
            if (runs.len != 0) term.feedRuns(runs);
            need_draw = true;
        }
        drainHost(&window, &term, allocator);
        if (term.scheme.bg.a != last_alpha) {
            last_alpha = term.scheme.bg.a;
            window.setOpacity(last_alpha);
        }
        flushReply(&pty, &term);

        const hold_sync = term.flags.sync_output and sync_hold < hz;
        if (need_draw and !hold_sync) {
            frame.renderSel(&term, cell_w, cell_h, type_ptr, size_px, eloop.sel);
            term.clearDirty();
            const fb = window.framebuffer();
            blitFrame(fb, &frame, padColor(&term));
            window.present();
            need_draw = false;
            sync_hold = 0;
        } else if (need_draw and hold_sync) {
            sync_hold += 1;
        }

        if (hangup) running = false;
    }
}

