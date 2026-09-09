const std = @import("std");
const builtin = @import("builtin");
const zt = @import("ZT");
const Host = @import("host.zig").Host;
const Pty = @import("pty.zig").Pty;
const Debug = zt.Debug;

const Mode = union(enum) {
    standalone,
    daemon,
    attach: []const u8,
};

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

pub fn main(init: std.process.Init) !void {
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(init.gpa);
    while (it.next()) |a| try list.append(init.gpa, a);

    const mode = parseMode(list.items) catch {
        std.debug.print("usage: zt [--daemon | --attach [session]]\n", .{});
        return error.InvalidArg;
    };

    switch (mode) {
        .standalone => {
            const cols: u16 = 80;
            const rows: u16 = 24;
            const size_px: f32 = 16;
            var cell_w: u32 = 8;
            var cell_h: u32 = 16;
            const config = loadConfig(init.io, init.gpa);

            var font_bufs: std.ArrayList([]u8) = .empty;
            defer {
                for (font_bufs.items) |b| init.gpa.free(b);
                font_bufs.deinit(init.gpa);
            }
            loadFonts(init.io, init.gpa, &font_bufs) catch |err| {
                Debug.log("font: {}", .{err});
            };

            var type_ctx: ?zt.Type.Context = null;
            defer if (type_ctx) |*t| t.deinit();
            if (font_bufs.items.len != 0) {
                type_ctx = zt.Type.Context.init(init.gpa, .{}) catch |err| blk: {
                    Debug.log("type init: {}", .{err});
                    break :blk null;
                };
                if (type_ctx) |*t| {
                    var fallbacks: std.ArrayList(zt.Type.FontId) = .empty;
                    defer fallbacks.deinit(init.gpa);
                    var have_primary = false;
                    for (font_bufs.items) |bytes| {
                        const id = t.addFont(bytes, .{}) catch |err| {
                            Debug.log("addFont: {}", .{err});
                            continue;
                        };
                        if (!have_primary) {
                            have_primary = true;
                        } else {
                            fallbacks.append(init.gpa, id) catch {};
                        }
                    }
                    if (fallbacks.items.len != 0) {
                        t.setFallbacks(fallbacks.items) catch |err| {
                            Debug.log("fallbacks: {}", .{err});
                        };
                    }
                    if (t.metrics(size_px)) |m| {
                        const h = m.ascender - m.descender + m.line_gap;
                        cell_h = @max(1, @as(u32, @intFromFloat(@ceil(h))));
                    } else |err| Debug.log("metrics: {}", .{err});
                    if (t.glyph('M', size_px)) |g| {
                        cell_w = @max(1, @as(u32, @intFromFloat(@ceil(g.advance))));
                    } else |err| Debug.log("glyph M: {}", .{err});
                }
            } else {
                Debug.log("no monospace font found", .{});
            }

            const px_w: u32 = @as(u32, cols) * cell_w;
            const px_h: u32 = @as(u32, rows) * cell_h;
            var pty = try Pty.open(
                cols,
                rows,
                @intCast(@min(px_w, 65535)),
                @intCast(@min(px_h, 65535)),
            );
            defer pty.close();

            var host = zt.Platform.init(init.gpa);
            defer host.deinit();
            const id = try host.open(.{ .engine = .{
                .cols = cols,
                .rows = rows,
                .cell_w = cell_w,
                .cell_h = cell_h,
                .size_px = size_px,
                .hz = config.hz,
                .scheme = config.scheme,
                .whitelist = config.whitelist,
            } });
            const window = host.get(id);
            if (type_ctx) |*t| window.engine.type_ctx = t;

            var loop = try zt.Loop.init(init.gpa);
            defer loop.deinit();
            loop.engine = &window.engine;
            var display = try Host.open(window.title, window.engine.frame.width, window.engine.frame.height);
            defer display.close();
            display.pty = &pty;
            loop.userdata = &display;
            loop.on_frame = &onFrame;
            display.syncEngine(&window.engine);
            window.engine.refresh() catch |err| Debug.log("refresh: {}", .{err});
            display.present(&window.engine.frame);
            display.watch(&loop);
            try loop.run();
        },
        .daemon => {
            var loop = try zt.Loop.init(init.gpa);
            defer loop.deinit();
            var server = zt.Daemon.Server.init(init.gpa, &loop, .{});
            defer server.deinit();
            try server.listen();
            std.debug.print("zt daemon\n", .{});
            try loop.run();
        },
        .attach => |session| {
            var loop = try zt.Loop.init(init.gpa);
            defer loop.deinit();
            const reply = try zt.Daemon.request(init.gpa, &loop, zt.Daemon.default_port, .attach, session);
            defer init.gpa.free(reply);
            std.debug.print("{s}", .{reply});
        },
    }
}

fn loadConfig(io: std.Io, gpa: std.mem.Allocator) zt.Config {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (userSchemePath(&buf)) |path| {
        if (readConfig(io, gpa, path, true)) |s| return s;
    }
    if (exeSchemePath(io, &buf)) |path| {
        if (readConfig(io, gpa, path, true)) |s| return s;
    }
    if (builtin.os.tag != .windows) {
        if (xdgDirConfigs(io, gpa, &buf)) |s| return s;
        if (readConfig(io, gpa, "/etc/zt/config.toml", true)) |s| return s;
    }
    if (readConfig(io, gpa, "config.toml", false)) |s| return s;
    return .{};
}

fn readConfig(io: std.Io, gpa: std.mem.Allocator, path: []const u8, absolute: bool) ?zt.Config {
    const bytes = readFile(io, gpa, path, absolute) catch return null;
    defer gpa.free(bytes);
    return zt.parseConfig(bytes) catch {
        std.debug.print("zt: invalid config {s}\n", .{path});
        Debug.log("invalid config {s}", .{path});
        return .{};
    };
}

fn userSchemePath(buf: []u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = envSpan("APPDATA") orelse return null;
        return joinScheme(buf, appdata);
    }
    if (envSpan("XDG_CONFIG_HOME")) |xdg| return joinScheme(buf, xdg);
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/zt/config.toml", .{home}) catch null;
    }
    return null;
}

fn exeSchemePath(io: std.Io, buf: []u8) ?[]u8 {
    const n = std.process.executableDirPath(io, buf) catch return null;
    const name = "config.toml";
    if (n + 1 + name.len > buf.len) return null;
    buf[n] = std.fs.path.sep;
    @memcpy(buf[n + 1 ..][0..name.len], name);
    return buf[0 .. n + 1 + name.len];
}

fn xdgDirConfigs(io: std.Io, gpa: std.mem.Allocator, buf: []u8) ?zt.Config {
    const dirs = envSpan("XDG_CONFIG_DIRS") orelse "/etc/xdg";
    var it = std.mem.splitScalar(u8, dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const path = joinScheme(buf, dir) orelse continue;
        if (readConfig(io, gpa, path, true)) |s| return s;
    }
    return null;
}

fn joinScheme(buf: []u8, dir: []const u8) ?[]u8 {
    const trimmed = std.mem.trimEnd(u8, dir, &[_]u8{ '/', '\\' });
    return std.fmt.bufPrint(buf, "{s}{c}zt{c}config.toml", .{
        trimmed,
        std.fs.path.sep,
        std.fs.path.sep,
    }) catch null;
}

fn envSpan(key: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(key) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

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

fn onFrame(loop: *zt.Loop) void {
    const display: *Host = @ptrCast(@alignCast(loop.userdata.?));
    display.present(&loop.engine.?.frame);
}

fn parseMode(args: []const []const u8) error{InvalidArg}!Mode {
    if (args.len <= 1) return .standalone;
    if (std.mem.eql(u8, args[1], "--daemon")) {
        if (args.len != 2) return error.InvalidArg;
        return .daemon;
    }
    if (std.mem.eql(u8, args[1], "--attach")) {
        if (args.len == 2) return .{ .attach = "" };
        if (args.len == 3) return .{ .attach = args[2] };
        return error.InvalidArg;
    }
    return error.InvalidArg;
}

test "parseMode" {
    try std.testing.expectEqual(Mode.standalone, try parseMode(&.{"zt"}));
    try std.testing.expectEqual(Mode.daemon, try parseMode(&.{ "zt", "--daemon" }));
    const attached = try parseMode(&.{ "zt", "--attach", "dev" });
    try std.testing.expectEqualStrings("dev", attached.attach);
    try std.testing.expectError(error.InvalidArg, parseMode(&.{ "zt", "--nope" }));
}

test "joinScheme" {
    var buf: [64]u8 = undefined;
    const path = joinScheme(&buf, "/home/raw/.config").?;
    try std.testing.expectEqualStrings("/home/raw/.config/zt/config.toml", path);
}
