//! Loading of fonts and such.
//!
//!
//!

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

test "joinScheme" {
    var buf: [64]u8 = undefined;
    const path = joinScheme(&buf, "/home/raw/.config").?;
    try std.testing.expectEqualStrings("/home/raw/.config/zt/config.toml", path);
}
