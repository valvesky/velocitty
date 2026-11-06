//! Platform font discovery and owned file bytes; no hardcoded primary font.
const std = @import("std");
const builtin = @import("builtin");

/// A selected face and allocator-owned bytes. Native loaders return one sfnt;
/// Fontconfig may select a member of a shared TrueType/OpenType collection.
pub const Loaded = struct {
    bytes: []u8,
    index: u32 = 0,
};

pub const Match = struct { path: []const u8, index: u32 };
pub const Resolved = struct { path: []u8, index: u32 };

pub const fallback_families: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ "Segoe UI Emoji", "Segoe UI Symbol", "Microsoft YaHei", "Malgun Gothic" },
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

pub fn matchFace(output: []const u8, required_family: ?[]const u8) ?Match {
    const path = matchPath(output, required_family) orelse return null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next();
    _ = lines.next() orelse return null;
    const index = std.fmt.parseUnsigned(u32, std.mem.trim(u8, lines.next() orelse return null, " \t\r"), 10) catch return null;
    // Fontconfig packs a variable-font named instance in the upper 16 bits;
    // stb renders the default variation, but still needs the selected member.
    return .{ .path = path, .index = index & 0xffff };
}

pub fn resolveFamily(io: std.Io, gpa: std.mem.Allocator, family: []const u8, exact: bool) ?Resolved {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "fc-match", "-f", "%{file}\n%{family}\n%{index}\n", family },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const face = matchFace(result.stdout, if (exact) family else null) orelse return null;
    return .{ .path = gpa.dupe(u8, face.path) catch return null, .index = face.index };
}

pub fn resolveFamilyFile(io: std.Io, gpa: std.mem.Allocator, family: []const u8, exact: bool) ?[]u8 {
    return (resolveFamily(io, gpa, family, exact) orelse return null).path;
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

pub extern fn velocitty_font_load(family: [*:0]const u8, bold: c_int, italic: c_int, exact: c_int, len: *usize, index: *c_uint) ?[*]u8;
pub extern fn velocitty_ttc_member(ttc: [*]const u8, ttc_len: usize, dir: [*]const u8, dir_len: usize, index: *c_uint) c_int;
pub extern fn velocitty_font_free(data: [*]u8) void;

pub fn loadFamily(gpa: std.mem.Allocator, io: std.Io, family: []const u8, bold: bool, italic: bool, exact: bool) anyerror!Loaded {
    if (builtin.os.tag == .linux) {
        var buf: [256]u8 = undefined;
        const pattern = try std.fmt.bufPrint(&buf, "{s}{s}{s}", .{
            family, if (bold) ":weight=bold" else "", if (italic) ":slant=italic" else "",
        });
        const face = resolveFamily(io, gpa, pattern, exact) orelse return error.InvalidFont;
        defer gpa.free(face.path);
        return .{ .bytes = try loadFile(io, gpa, face.path), .index = face.index };
    }
    var name: [256]u8 = undefined;
    if (family.len >= name.len or std.mem.indexOfScalar(u8, family, 0) != null) return error.InvalidFont;
    @memcpy(name[0..family.len], family);
    name[family.len] = 0;
    var n: usize = 0;
    var index: c_uint = 0;
    const data = velocitty_font_load(@ptrCast(&name), @intFromBool(bold), @intFromBool(italic), @intFromBool(exact), &n, &index) orelse return error.InvalidFont;
    defer velocitty_font_free(data);
    return .{ .bytes = try gpa.dupe(u8, data[0..n]), .index = index };
}

test "fontconfig matches retain collection members and family validation" {
    const output = "/fonts/cjk.ttc\nNoto Sans CJK SC,Noto Sans CJK SC Regular\n2\n";
    const face = matchFace(output, "Noto Sans CJK SC").?;
    try std.testing.expectEqualStrings("/fonts/cjk.ttc", face.path);
    try std.testing.expectEqual(@as(u32, 2), face.index);
    try std.testing.expect(matchFace(output, "Noto Sans CJK JP") == null);
    try std.testing.expectEqual(@as(u32, 2), matchFace("/fonts/cjk.ttc\nSubstitute\n65538\n", null).?.index);
    try std.testing.expect(matchFace("/fonts/cjk.ttc\nFamily\ninvalid\n", null) == null);
    try std.testing.expect(matchFace("/fonts/cjk.ttc\nFamily\n", null) == null);
}

test "ttc member selection matches the sfnt directory" {
    const ttc = &@import("type/truetype.zig").testing.collection;
    var idx: c_uint = 99;
    // Member 1 directory: 12-byte header + 7 entries at offset 144.
    try std.testing.expectEqual(@as(c_int, 1), velocitty_ttc_member(ttc, ttc.len, ttc[144..].ptr, 124, &idx));
    try std.testing.expectEqual(@as(c_uint, 1), idx);
    try std.testing.expectEqual(@as(c_int, 1), velocitty_ttc_member(ttc, ttc.len, ttc[20..].ptr, 124, &idx));
    try std.testing.expectEqual(@as(c_uint, 0), idx);
    var bad: [124]u8 = undefined;
    @memcpy(&bad, ttc[144..268]);
    bad[40] ^= 1;
    try std.testing.expectEqual(@as(c_int, 0), velocitty_ttc_member(ttc, ttc.len, &bad, bad.len, &idx));
    // Directory running past the end of the collection never matches.
    try std.testing.expectEqual(@as(c_int, 0), velocitty_ttc_member(ttc, ttc.len, ttc[144..].ptr, 124 + 4096, &idx));
    // Not a collection.
    try std.testing.expectEqual(@as(c_int, 0), velocitty_ttc_member(ttc[20..].ptr, 508, ttc[20..].ptr, 124, &idx));
}
