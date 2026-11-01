//! Platform font discovery and owned file bytes; no hardcoded primary font.
const std = @import("std");
const builtin = @import("builtin");

pub const fallback_families: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ "Segoe UI Emoji", "Segoe UI Symbol", "Microsoft YaHei" },
    .macos, .ios, .tvos, .watchos, .visionos => &.{ "Apple Color Emoji", "Apple Symbols", "PingFang SC" },
    else => &.{ "Noto Color Emoji", "DejaVu Sans Mono", "Noto Sans Symbols", "Noto Sans Symbols 2", "Noto Sans CJK JP" },
};

pub fn isEmojiFamily(name: []const u8) bool {
    return std.mem.eql(u8, name, "Noto Color Emoji") or std.mem.eql(u8, name, "Apple Color Emoji") or std.mem.eql(u8, name, "Segoe UI Emoji");
}

pub fn matchPath(output: []const u8, required_family: ?[]const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    const path = std.mem.trim(u8, lines.next() orelse return null, " \t\r");
    if (path.len == 0 or path[0] != '/') return null;
    if (required_family) |family| {
        const matched = lines.next() orelse return null;
        var names = std.mem.splitScalar(u8, matched, ',');
        while (names.next()) |name| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t\r"), family)) return path;
        }
        return null;
    }
    return path;
}

pub fn resolveFamilyFile(io: std.Io, gpa: std.mem.Allocator, family: []const u8, exact: bool) ?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "fc-match", "-f", "%{file}\n%{family}\n", family },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = matchPath(result.stdout, if (exact) family else null) orelse return null;
    return gpa.dupe(u8, path) catch null;
}

pub fn loadFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    if (len > 64 * 1024 * 1024) return error.FileTooLarge;
    const bytes = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidFont;
    return bytes;
}

pub extern fn velocitty_font_load(family: [*:0]const u8, bold: c_int, italic: c_int, exact: c_int, len: *usize) ?[*]u8;
pub extern fn velocitty_font_free(data: [*]u8) void;

pub fn loadFamily(gpa: std.mem.Allocator, io: std.Io, family: []const u8, bold: bool, italic: bool, exact: bool) anyerror![]u8 {
    if (builtin.os.tag == .linux) {
        var buf: [256]u8 = undefined;
        const pattern = try std.fmt.bufPrint(&buf, "{s}{s}{s}", .{
            family, if (bold) ":weight=bold" else "", if (italic) ":slant=italic" else "",
        });
        const path = resolveFamilyFile(io, gpa, pattern, exact) orelse return error.InvalidFont;
        defer gpa.free(path);
        return loadFile(io, gpa, path);
    }
    var name: [256]u8 = undefined;
    if (family.len >= name.len or std.mem.indexOfScalar(u8, family, 0) != null) return error.InvalidFont;
    @memcpy(name[0..family.len], family);
    name[family.len] = 0;
    var n: usize = 0;
    const data = velocitty_font_load(@ptrCast(&name), @intFromBool(bold), @intFromBool(italic), @intFromBool(exact), &n) orelse return error.InvalidFont;
    defer velocitty_font_free(data);
    return gpa.dupe(u8, data[0..n]);
}
