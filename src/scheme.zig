//! Simple TOML config: colors + `[general]`.
//!
//! ```toml
//! [general]
//! refreshrate = 30
//! whitelist = false
//!
//! foreground = "#aaaaaa"
//! background = "#000000"
//! cursor = "#aaaaaa"
//!
//! [normal]
//! black = "#000000"
//! red = "#aa0000"
//! green = "#00aa00"
//! yellow = "#aa5500"
//! blue = "#0000aa"
//! magenta = "#aa00aa"
//! cyan = "#00aaaa"
//! white = "#aaaaaa"
//!
//! [bright]
//! black = "#555555"
//! red = "#ff5555"
//! green = "#55ff55"
//! yellow = "#ffff55"
//! blue = "#5555ff"
//! magenta = "#ff55ff"
//! cyan = "#55ffff"
//! white = "#ffffff"
//! ```
//!
//! `[colors]`, `[colors.normal]`, and `[colors.bright]` are accepted, as are
//! `fg` / `bg` and `bright_red`-style keys. `hz` is an alias for `refreshrate`.
//! `whitelist` enables ESC parsing during preparse (off by default).
//! Unknown keys are ignored.

const std = @import("std");
const Term = @import("term.zig");

pub const Scheme = Term.Scheme;

pub const Config = struct {
    scheme: Scheme = .{},
    hz: u32 = 30,
    /// Parse whitelisted ESC sequences while splitting lines. Off = NL only.
    whitelist: bool = false,
};

pub fn parse(src: []const u8) error{InvalidToml}!Config {
    var p = Parser{ .src = stripBom(src) };
    return p.parse();
}

pub fn parseScheme(src: []const u8) error{InvalidToml}!Scheme {
    return (try parse(src)).scheme;
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
















const Parser = struct {
    src: []const u8,
    i: usize = 0,
    table: []const u8 = "",

    fn parse(self: *Parser) error{InvalidToml}!Config {
        var config: Config = .{};
        while (true) {
            self.skipSpaceComments();
            if (self.i >= self.src.len) break;
            if (self.src[self.i] == '[') {
                try self.parseTable();
            } else {
                try self.parseKeyValue(&config);
            }
        }
        return config;
    }

    fn parseTable(self: *Parser) error{InvalidToml}!void {
        self.i += 1;
        self.skipSpaces();
        const start = self.i;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (isBare(c) or c == '.') {
                self.i += 1;
                continue;
            }
            break;
        }
        const name = std.mem.trim(u8, self.src[start..self.i], " \t");
        self.skipSpaces();
        if (self.i >= self.src.len or self.src[self.i] != ']') return error.InvalidToml;
        self.i += 1;
        if (!validTable(name)) return error.InvalidToml;
        self.table = name;
        try self.expectEol();
    }

    fn parseKeyValue(self: *Parser, config: *Config) error{InvalidToml}!void {
        const key = try self.parseBare();
        self.skipSpaces();
        if (self.i >= self.src.len or self.src[self.i] != '=') return error.InvalidToml;
        self.i += 1;
        self.skipSpaces();
        if (isGeneral(self.table) and isHzKey(key)) {
            const hz = try self.parseInteger();
            if (hz == 0) return error.InvalidToml;
            config.hz = hz;
        } else if (isGeneral(self.table) and isWhitelistKey(key)) {
            config.whitelist = try self.parseBool();
        } else if (self.i < self.src.len and (self.src[self.i] == '"' or self.src[self.i] == '\'')) {
            const value = try self.parseString();
            const color = try parseColor(value);
            const table = if (isGeneral(self.table)) "" else self.table;
            apply(&config.scheme, table, key, color);
        } else if (isGeneral(self.table)) {
            try self.skipValue();
        } else {
            return error.InvalidToml;
        }
        try self.expectEol();
    }

    fn parseBare(self: *Parser) error{InvalidToml}![]const u8 {
        const start = self.i;
        if (self.i >= self.src.len or !isBare(self.src[self.i])) return error.InvalidToml;
        while (self.i < self.src.len and isBare(self.src[self.i])) self.i += 1;
        return self.src[start..self.i];
    }

    fn parseString(self: *Parser) error{InvalidToml}![]const u8 {
        if (self.i >= self.src.len) return error.InvalidToml;
        const quote = self.src[self.i];
        if (quote != '"' and quote != '\'') return error.InvalidToml;
        self.i += 1;
        const start = self.i;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == quote) {
                const s = self.src[start..self.i];
                self.i += 1;
                if (std.mem.indexOfScalar(u8, s, '\\') != null) return error.InvalidToml;
                return s;
            }
            if (c == '\n' or c == '\r') return error.InvalidToml;
            self.i += 1;
        }
        return error.InvalidToml;
    }

    fn parseInteger(self: *Parser) error{InvalidToml}!u32 {
        if (self.i >= self.src.len) return error.InvalidToml;
        if (self.src[self.i] == '+') self.i += 1;
        const start = self.i;
        if (start >= self.src.len or !std.ascii.isDigit(self.src[start])) return error.InvalidToml;
        while (self.i < self.src.len and std.ascii.isDigit(self.src[self.i])) self.i += 1;
        return std.fmt.parseInt(u32, self.src[start..self.i], 10) catch return error.InvalidToml;
    }

    fn parseBool(self: *Parser) error{InvalidToml}!bool {
        const ident = try self.parseBare();
        if (std.mem.eql(u8, ident, "true")) return true;
        if (std.mem.eql(u8, ident, "false")) return false;
        return error.InvalidToml;
    }

    fn skipValue(self: *Parser) error{InvalidToml}!void {
        if (self.i >= self.src.len) return error.InvalidToml;
        const c = self.src[self.i];
        if (c == '"' or c == '\'') {
            _ = try self.parseString();
            return;
        }
        if (c == '+' or std.ascii.isDigit(c)) {
            _ = try self.parseInteger();
            return;
        }
        if (isBare(c)) {
            _ = try self.parseBare();
            return;
        }
        return error.InvalidToml;
    }

    fn expectEol(self: *Parser) error{InvalidToml}!void {
        self.skipSpaces();
        if (self.i < self.src.len and self.src[self.i] == '#') {
            while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
        }
        if (self.i >= self.src.len) return;
        const c = self.src[self.i];
        if (c == '\n') {
            self.i += 1;
            return;
        }
        if (c == '\r') {
            self.i += 1;
            if (self.i < self.src.len and self.src[self.i] == '\n') self.i += 1;
            return;
        }
        return error.InvalidToml;
    }

    fn skipSpaceComments(self: *Parser) void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.i += 1;
                continue;
            }
            if (c == '#') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                continue;
            }
            break;
        }
    }

    fn skipSpaces(self: *Parser) void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t') {
                self.i += 1;
                continue;
            }
            break;
        }
    }
};

fn stripBom(src: []const u8) []const u8 {
    if (src.len >= 3 and src[0] == 0xef and src[1] == 0xbb and src[2] == 0xbf) return src[3..];
    return src;
}

fn isBare(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => true,
        else => false,
    };
}

fn isGeneral(table: []const u8) bool {
    return std.mem.eql(u8, table, "general");
}

fn isHzKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "refreshrate") or std.mem.eql(u8, key, "hz");
}

fn isWhitelistKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "whitelist");
}

fn validTable(name: []const u8) bool {
    if (name.len == 0) return false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= name.len) : (i += 1) {
        if (i != name.len and name[i] != '.') continue;
        const part = name[start..i];
        if (part.len == 0) return false;
        for (part) |c| {
            if (!isBare(c)) return false;
        }
        start = i + 1;
    }
    return true;
}

fn parseColor(s: []const u8) error{InvalidToml}!Term.Color {
    var t = s;
    if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len == 3) {
        const r = try hexNibble(t[0]);
        const g = try hexNibble(t[1]);
        const b = try hexNibble(t[2]);
        return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
    }
    if (t.len == 6 or t.len == 8) {
        return .{
            .r = try hexByte(t[0..2]),
            .g = try hexByte(t[2..4]),
            .b = try hexByte(t[4..6]),
            .a = if (t.len == 8) try hexByte(t[6..8]) else 255,
        };
    }
    return error.InvalidToml;
}

fn hexByte(s: []const u8) error{InvalidToml}!u8 {
    return (try hexNibble(s[0])) * 16 + (try hexNibble(s[1]));
}

fn hexNibble(c: u8) error{InvalidToml}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidToml,
    };
}

const ansi_names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

fn ansiIndex(key: []const u8) ?u8 {
    for (ansi_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, key)) return @intCast(i);
    }
    return null;
}

fn apply(scheme: *Scheme, table: []const u8, key: []const u8, color: Term.Color) void {
    const kind: enum { meta, normal, bright, skip } = blk: {
        if (table.len == 0 or std.mem.eql(u8, table, "colors")) break :blk .meta;
        if (std.mem.eql(u8, table, "normal") or std.mem.eql(u8, table, "colors.normal")) break :blk .normal;
        if (std.mem.eql(u8, table, "bright") or std.mem.eql(u8, table, "colors.bright")) break :blk .bright;
        break :blk .skip;
    };
    switch (kind) {
        .skip => {},
        .normal => if (ansiIndex(key)) |i| {
            scheme.palette[i] = color;
        },
        .bright => if (ansiIndex(key)) |i| {
            scheme.palette[8 + i] = color;
        },
        .meta => {
            if (std.mem.eql(u8, key, "foreground") or std.mem.eql(u8, key, "fg")) {
                scheme.fg = color;
            } else if (std.mem.eql(u8, key, "background") or std.mem.eql(u8, key, "bg")) {
                scheme.bg = color;
            } else if (std.mem.eql(u8, key, "cursor")) {
                scheme.cursor = color;
            } else if (ansiIndex(key)) |i| {
                scheme.palette[i] = color;
            } else if (std.mem.startsWith(u8, key, "bright_")) {
                if (ansiIndex(key["bright_".len..])) |i| scheme.palette[8 + i] = color;
            } else if (std.mem.startsWith(u8, key, "bright-")) {
                if (ansiIndex(key["bright-".len..])) |i| scheme.palette[8 + i] = color;
            }
        },
    }
}

test "empty is default" {
    const cfg = try parse("");
    try std.testing.expectEqual(Term.Color.default_fg, cfg.scheme.fg);
    try std.testing.expectEqual(Term.Color.default_bg, cfg.scheme.bg);
    try std.testing.expectEqual(Term.vga_palette[1].r, cfg.scheme.palette[1].r);
    try std.testing.expectEqual(@as(u32, 30), cfg.hz);
    try std.testing.expectEqual(false, cfg.whitelist);
}

test "alacritty tables" {
    const cfg = try parse(
        \\# comment
        \\[colors]
        \\foreground = "#fefefe"
        \\background = "#010203"
        \\cursor = "#aabbcc"
        \\
        \\[colors.normal]
        \\red = "#ff0000"
        \\black = "#111111"
        \\
        \\[colors.bright]
        \\white = "#f0f0f0"
        \\
    );
    const s = cfg.scheme;
    try std.testing.expectEqual(@as(u8, 0xfe), s.fg.r);
    try std.testing.expectEqual(@as(u8, 0x01), s.bg.r);
    try std.testing.expectEqual(@as(u8, 0x02), s.bg.g);
    try std.testing.expectEqual(@as(u8, 0x03), s.bg.b);
    try std.testing.expectEqual(@as(u8, 0xaa), s.cursor.r);
    try std.testing.expectEqual(@as(u8, 0xff), s.palette[1].r);
    try std.testing.expectEqual(@as(u8, 0x11), s.palette[0].r);
    try std.testing.expectEqual(@as(u8, 0xf0), s.palette[15].r);
}

test "short hex and aliases" {
    const s = try parseScheme(
        \\fg = '#abc'
        \\bg = "#123"
        \\bright_red = "#f00"
        \\
        \\[normal]
        \\green = "#0f0"
        \\
    );
    try std.testing.expectEqual(@as(u8, 0xaa), s.fg.r);
    try std.testing.expectEqual(@as(u8, 0xbb), s.fg.g);
    try std.testing.expectEqual(@as(u8, 0xcc), s.fg.b);
    try std.testing.expectEqual(@as(u8, 0x11), s.bg.r);
    try std.testing.expectEqual(@as(u8, 0xff), s.palette[9].r);
    try std.testing.expectEqual(@as(u8, 0x00), s.palette[2].r);
    try std.testing.expectEqual(@as(u8, 0xff), s.palette[2].g);
}

test "general refreshrate" {
    const cfg = try parse(
        \\[general]
        \\refreshrate = 144
        \\foreground = "#ffffff"
        \\
    );
    try std.testing.expectEqual(@as(u32, 144), cfg.hz);
    try std.testing.expectEqual(@as(u8, 0xff), cfg.scheme.fg.r);

    const alias = try parse(
        \\[general]
        \\hz = 30
        \\
    );
    try std.testing.expectEqual(@as(u32, 30), alias.hz);
    try std.testing.expectEqual(false, alias.whitelist);

    const wl = try parse(
        \\[general]
        \\whitelist = true
        \\
    );
    try std.testing.expect(wl.whitelist);

    const wl_off = try parse(
        \\[general]
        \\whitelist = false
        \\
    );
    try std.testing.expectEqual(false, wl_off.whitelist);
}

test "invalid" {
    try std.testing.expectError(error.InvalidToml, parse("foreground = 1\n"));
    try std.testing.expectError(error.InvalidToml, parse("foreground = \"#gg0000\"\n"));
    try std.testing.expectError(error.InvalidToml, parse("[]\n"));
    try std.testing.expectError(error.InvalidToml, parse("foreground = \"#ffff\"\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nrefreshrate = 0\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nrefreshrate = \"60\"\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nwhitelist = 1\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nwhitelist = \"true\"\n"));
}
