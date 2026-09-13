//! Simple TOML config: colors + `[general]` + `[font]`.
//!
//! ```toml
//! [general]
//! refreshrate = 30
//! whitelist = false
//! pad = 14
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
//!
//! [font]
//! family = "monospace"
//! size = 16
//! ```
//!
//! `[colors]`, `[colors.primary]`, `[colors.cursor]`, `[colors.normal]`, and
//! `[colors.bright]` are accepted, as are `fg` / `bg` and `bright_red`-style
//! keys. Omarchy `colors.toml` (`muted`, `bright_foreground`, root ANSI) is
//! accepted. `hz` is an alias for `refreshrate`.
//! `whitelist` enables ESC parsing during preparse (off by default).
//! `pad` / `padding` is inner window margin in pixels (default 14).
//! Unknown keys are ignored.
//!
//! `load` overlays user config then the current Omarchy theme so SIGUSR can
//! re-read colors and font without a restart. Unset family uses fontconfig
//! `monospace` (`omarchy font current`). Size falls back to Alacritty, then 9.

const std = @import("std");
const builtin = @import("builtin");
const Grid = @import("grid.zig");

pub const Scheme = Grid.Scheme;

pub const max_font_family = 128;

pub const Config = struct {
    scheme: Scheme = .{},
    hz: u32 = 30,
    /// Parse whitelisted ESC sequences while splitting lines. Off = NL only.
    whitelist: bool = false,
    /// Inner window margin in pixels (all sides).
    pad_px: u32 = 14,
    font_family: [max_font_family]u8 = @splat(0),
    font_family_len: u8 = 0,
    /// Point size (Alacritty/Foot/Ghostty). 0 = unspecified (caller default).
    font_size: f32 = 0,

    pub fn family(self: *const Config) ?[]const u8 {
        if (self.font_family_len == 0) return null;
        return self.font_family[0..self.font_family_len];
    }
};

pub fn parse(src: []const u8) error{InvalidToml}!Config {
    return parseInto(src, .{});
}

pub fn parseInto(src: []const u8, base: Config) error{InvalidToml}!Config {
    var p = Parser{ .src = stripBom(src) };
    return p.run(base);
}

pub fn parseScheme(src: []const u8) error{InvalidToml}!Scheme {
    return (try parse(src)).scheme;
}

pub fn loadFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?Config {
    var cfg: Config = .{};
    overlayFile(io, gpa, path, &cfg);
    return cfg;
}

/// User config, then Omarchy current theme (theme colors win when present).
pub fn load(io: std.Io, gpa: std.mem.Allocator) Config {
    var cfg: Config = .{};
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (userConfigPath(&buf)) |path| overlayFile(io, gpa, path, &cfg);
    overlayFile(io, gpa, "config.toml", &cfg);
    if (omarchyThemePath(&buf, "colors.toml")) |path| overlayFile(io, gpa, path, &cfg);
    if (omarchyThemePath(&buf, "alacritty.toml")) |path| overlayFile(io, gpa, path, &cfg);
    fillUnsetFont(io, gpa, &buf, &cfg);
    return cfg;
}

fn fillUnsetFont(io: std.Io, gpa: std.mem.Allocator, buf: []u8, cfg: *Config) void {
    // Omarchy's source of truth is fontconfig `monospace` (`omarchy font current`).
    // Copy size from Alacritty when unset; leave family empty so loadFonts fc-matches
    // monospace (user fonts.conf + ~/.local/share/fonts) instead of a stale terminal config.
    var tmp: Config = .{};
    if (xdgConfigPath(buf, "alacritty/alacritty.toml")) |path| overlayFile(io, gpa, path, &tmp);
    if (cfg.font_size == 0 and tmp.font_size != 0) cfg.font_size = tmp.font_size;
    if (cfg.font_size == 0 and omarchyThemePath(buf, "colors.toml") != null) cfg.font_size = 9;
}

/// Fingerprint of config/theme/font files. Changes when Omarchy swaps the theme.
pub fn watchStamp(io: std.Io) u64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var stamp: u64 = 0;
    stamp ^= fileStamp(io, "config.toml");
    if (userConfigPath(&buf)) |path| stamp = mix(stamp, fileStamp(io, path));
    if (omarchyCurrentPath(&buf, "theme.name")) |path| stamp = mix(stamp, fileStamp(io, path));
    if (omarchyThemePath(&buf, "colors.toml")) |path| stamp = mix(stamp, fileStamp(io, path));
    if (omarchyThemePath(&buf, "alacritty.toml")) |path| stamp = mix(stamp, fileStamp(io, path));
    if (fontconfigPath(&buf)) |path| stamp = mix(stamp, fileStamp(io, path));
    if (xdgConfigPath(&buf, "alacritty/alacritty.toml")) |path| stamp = mix(stamp, fileStamp(io, path));
    return stamp;
}

fn mix(a: u64, b: u64) u64 {
    return a *% 0x9e3779b97f4a7c15 ^ b;
}

fn fileStamp(io: std.Io, path: []const u8) u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer file.close(io);
    const st = file.stat(io) catch return 0;
    const ns = st.mtime.nanoseconds;
    const mt: u64 = if (ns >= 0) @truncate(@as(u128, @intCast(ns))) else 0;
    return mix(mt, st.size);
}

fn overlayFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, cfg: *Config) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return;
    defer gpa.free(bytes);
    cfg.* = parseInto(bytes, cfg.*) catch {
        std.debug.print("zt: invalid config {s}\n", .{path});
        return;
    };
}

fn envSpan(key: [:0]const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    if (!builtin.link_libc) return null;
    const p = std.c.getenv(key) orelse return null;
    return std.mem.sliceTo(p, 0);
}

fn xdgConfigPath(buf: []u8, rel: []const u8) ?[]u8 {
    if (envSpan("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ xdg, rel }) catch null;
    }
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/{s}", .{ home, rel }) catch null;
    }
    return null;
}

fn userConfigPath(buf: []u8) ?[]u8 {
    return xdgConfigPath(buf, "velocitty/config.toml");
}

fn omarchyCurrentPath(buf: []u8, name: []const u8) ?[]u8 {
    if (envSpan("XDG_STATE_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/omarchy/current/{s}", .{ xdg, name }) catch null;
    }
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.local/state/omarchy/current/{s}", .{ home, name }) catch null;
    }
    return null;
}

fn omarchyThemePath(buf: []u8, name: []const u8) ?[]u8 {
    if (envSpan("XDG_STATE_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/omarchy/current/theme/{s}", .{ xdg, name }) catch null;
    }
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.local/state/omarchy/current/theme/{s}", .{ home, name }) catch null;
    }
    return null;
}

fn fontconfigPath(buf: []u8) ?[]u8 {
    if (envSpan("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/fontconfig/fonts.conf", .{xdg}) catch null;
    }
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/fontconfig/fonts.conf", .{home}) catch null;
    }
    return null;
}

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    table: []const u8 = "",

    fn run(self: *Parser, base: Config) error{InvalidToml}!Config {
        var config = base;
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
        const key = try self.parseKey();
        self.skipSpaces();
        if (self.i >= self.src.len or self.src[self.i] != '=') return error.InvalidToml;
        self.i += 1;
        self.skipSpaces();
        const general = isGeneral(self.table);
        const font_table = isFontTable(self.table);
        const settings = general or font_table or self.table.len == 0;
        if (general and isHzKey(key)) {
            const hz = try self.parseInteger();
            if (hz == 0) return error.InvalidToml;
            config.hz = hz;
        } else if (general and isWhitelistKey(key)) {
            config.whitelist = try self.parseBool();
        } else if (general and isPadKey(key)) {
            config.pad_px = try self.parseInteger();
        } else if (settings and isFontSizeKey(key)) {
            const size = try self.parseNumber();
            if (size <= 0) return error.InvalidToml;
            config.font_size = size;
        } else if (settings and isFontFamilyKey(key)) {
            const value = try self.parseString();
            setFamily(config, value);
        } else if (font_table and self.i < self.src.len and self.src[self.i] == '{') {
            try self.parseFontInline(config);
        } else if (self.i < self.src.len and (self.src[self.i] == '"' or self.src[self.i] == '\'')) {
            const value = try self.parseString();
            if (parseColor(value)) |color| {
                const table = if (isGeneral(self.table)) "" else self.table;
                apply(&config.scheme, table, key, color);
            } else |_| {}
        } else {
            try self.skipValue();
        }
        try self.expectEol();
    }

    fn parseKey(self: *Parser) error{InvalidToml}![]const u8 {
        const start = self.i;
        _ = try self.parseBare();
        while (self.i < self.src.len and self.src[self.i] == '.') {
            self.i += 1;
            _ = try self.parseBare();
        }
        return self.src[start..self.i];
    }

    fn parseFontInline(self: *Parser, config: *Config) error{InvalidToml}!void {
        if (self.i >= self.src.len or self.src[self.i] != '{') return error.InvalidToml;
        self.i += 1;
        while (true) {
            self.skipSpaces();
            if (self.i >= self.src.len) return error.InvalidToml;
            if (self.src[self.i] == '}') {
                self.i += 1;
                return;
            }
            if (self.src[self.i] == ',') {
                self.i += 1;
                continue;
            }
            const key = try self.parseBare();
            self.skipSpaces();
            if (self.i >= self.src.len or self.src[self.i] != '=') return error.InvalidToml;
            self.i += 1;
            self.skipSpaces();
            if (isFontFamilyKey(key) and (self.i < self.src.len and (self.src[self.i] == '"' or self.src[self.i] == '\''))) {
                const value = try self.parseString();
                if (config.font_family_len == 0) setFamily(config, value);
            } else if (isFontSizeKey(key)) {
                const size = try self.parseNumber();
                if (size > 0 and config.font_size == 0) config.font_size = size;
            } else {
                try self.skipValue();
            }
        }
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
        const n = try self.parseNumber();
        if (n != @floor(n) or n > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidToml;
        return @intFromFloat(n);
    }

    fn parseNumber(self: *Parser) error{InvalidToml}!f32 {
        if (self.i >= self.src.len) return error.InvalidToml;
        if (self.src[self.i] == '+') self.i += 1;
        const start = self.i;
        if (start >= self.src.len or !std.ascii.isDigit(self.src[start])) return error.InvalidToml;
        while (self.i < self.src.len and std.ascii.isDigit(self.src[self.i])) self.i += 1;
        if (self.i < self.src.len and self.src[self.i] == '.') {
            self.i += 1;
            if (self.i >= self.src.len or !std.ascii.isDigit(self.src[self.i])) return error.InvalidToml;
            while (self.i < self.src.len and std.ascii.isDigit(self.src[self.i])) self.i += 1;
        }
        return std.fmt.parseFloat(f32, self.src[start..self.i]) catch return error.InvalidToml;
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
            _ = try self.parseNumber();
            return;
        }
        if (c == '{' or c == '[') {
            try self.skipBracketed();
            return;
        }
        if (isBare(c)) {
            _ = try self.parseBare();
            return;
        }
        return error.InvalidToml;
    }

    fn skipBracketed(self: *Parser) error{InvalidToml}!void {
        const open = self.src[self.i];
        const close: u8 = if (open == '{') '}' else ']';
        self.i += 1;
        var depth: u32 = 1;
        var quote: u8 = 0;
        while (self.i < self.src.len and depth > 0) {
            const c = self.src[self.i];
            if (quote != 0) {
                if (c == quote) quote = 0;
                self.i += 1;
                continue;
            }
            if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == open) {
                depth += 1;
            } else if (c == close) {
                depth -= 1;
            }
            self.i += 1;
        }
        if (depth != 0) return error.InvalidToml;
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

fn isFontTable(table: []const u8) bool {
    return std.mem.eql(u8, table, "font") or std.mem.eql(u8, table, "fonts");
}

fn isHzKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "refreshrate") or std.mem.eql(u8, key, "hz");
}

fn isWhitelistKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "whitelist");
}

fn isPadKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "pad") or
        std.mem.eql(u8, key, "padding") or
        std.mem.eql(u8, key, "padding.x") or
        std.mem.eql(u8, key, "padding.y");
}

fn isFontFamilyKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "family") or
        std.mem.eql(u8, key, "font") or
        std.mem.eql(u8, key, "font_family") or
        std.mem.eql(u8, key, "font-family");
}

fn isFontSizeKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "size") or
        std.mem.eql(u8, key, "font_size") or
        std.mem.eql(u8, key, "font-size");
}

fn setFamily(config: *Config, value: []const u8) void {
    const n = @min(value.len, max_font_family);
    @memcpy(config.font_family[0..n], value[0..n]);
    config.font_family_len = @intCast(n);
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

fn parseColor(s: []const u8) error{InvalidToml}!Grid.Color {
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

fn isMetaTable(table: []const u8) bool {
    return table.len == 0 or
        std.mem.eql(u8, table, "colors") or
        std.mem.eql(u8, table, "colors.primary") or
        std.mem.eql(u8, table, "primary") or
        std.mem.eql(u8, table, "colors.cursor") or
        std.mem.eql(u8, table, "cursor");
}

fn apply(scheme: *Scheme, table: []const u8, key: []const u8, color: Grid.Color) void {
    const kind: enum { meta, normal, bright, skip } = blk: {
        if (isMetaTable(table)) break :blk .meta;
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
                scheme.palette[7] = color;
            } else if (std.mem.eql(u8, key, "background") or std.mem.eql(u8, key, "bg")) {
                scheme.bg = color;
                scheme.palette[0] = color;
            } else if (std.mem.eql(u8, key, "cursor")) {
                scheme.cursor = color;
            } else if (std.mem.eql(u8, key, "muted")) {
                scheme.palette[8] = color;
            } else if (std.mem.eql(u8, key, "bright_foreground") or std.mem.eql(u8, key, "bright-foreground")) {
                scheme.palette[15] = color;
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
    try std.testing.expectEqual(Grid.Color.default_fg, cfg.scheme.fg);
    try std.testing.expectEqual(Grid.Color.default_bg, cfg.scheme.bg);
    try std.testing.expectEqual(Grid.vga_palette[1].r, cfg.scheme.palette[1].r);
    try std.testing.expectEqual(@as(u32, 30), cfg.hz);
    try std.testing.expectEqual(false, cfg.whitelist);
    try std.testing.expectEqual(@as(u8, 0), cfg.font_family_len);
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

test "alacritty primary cursor" {
    const s = try parseScheme(
        \\[colors.primary]
        \\background = "#010203"
        \\foreground = "#fefefe"
        \\
        \\[colors.cursor]
        \\text = "#010203"
        \\cursor = "#aabbcc"
        \\
        \\[colors.normal]
        \\black = "#111111"
        \\white = "#eeeeee"
        \\
    );
    try std.testing.expectEqual(@as(u8, 0xfe), s.fg.r);
    try std.testing.expectEqual(@as(u8, 0x01), s.bg.r);
    try std.testing.expectEqual(@as(u8, 0xaa), s.cursor.r);
    try std.testing.expectEqual(@as(u8, 0x11), s.palette[0].r);
    try std.testing.expectEqual(@as(u8, 0xee), s.palette[7].r);
}

test "omarchy colors.toml" {
    const cfg = try parse(
        \\mode = "dark"
        \\accent = "#89b4fa"
        \\muted = "#585b70"
        \\background = "#1e1e2e"
        \\foreground = "#cdd6f4"
        \\bright_foreground = "#ffffff"
        \\red = "#f38ba8"
        \\bright_red = "#f38ba8"
        \\
    );
    const s = cfg.scheme;
    try std.testing.expectEqual(@as(u8, 0x1e), s.bg.r);
    try std.testing.expectEqual(@as(u8, 0xcd), s.fg.r);
    try std.testing.expectEqual(@as(u8, 0xff), s.cursor.r);
    try std.testing.expectEqual(@as(u8, 0x1e), s.palette[0].r);
    try std.testing.expectEqual(@as(u8, 0xcd), s.palette[7].r);
    try std.testing.expectEqual(@as(u8, 0x58), s.palette[8].r);
    try std.testing.expectEqual(@as(u8, 0xff), s.palette[15].r);
    try std.testing.expectEqual(@as(u8, 0xf3), s.palette[1].r);
    try std.testing.expectEqual(@as(u8, 0xf3), s.palette[9].r);
}

test "font table" {
    const cfg = try parse(
        \\[font]
        \\family = "Terminess Nerd Font Mono"
        \\size = 8.5
        \\
    );
    try std.testing.expectEqualStrings("Terminess Nerd Font Mono", cfg.family().?);
    try std.testing.expectEqual(@as(f32, 8.5), cfg.font_size);
}

test "alacritty font inline" {
    const cfg = try parse(
        \\general.import = [ "~/.local/state/omarchy/current/theme/alacritty.toml" ]
        \\
        \\[font]
        \\normal = { family = "Terminess Nerd Font Mono", style = "Regular" }
        \\bold = { family = "Other", style = "Bold" }
        \\size = 8
        \\
        \\[window]
        \\padding.x = 14
        \\decorations = "None"
        \\
        \\[keyboard]
        \\bindings = [
        \\{ key = "Return", chars = "\u001B[13;2u" }
        \\]
        \\
    );
    try std.testing.expectEqualStrings("Terminess Nerd Font Mono", cfg.family().?);
    try std.testing.expectEqual(@as(f32, 8), cfg.font_size);
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

    const pad = try parse(
        \\[general]
        \\pad = 8
        \\
    );
    try std.testing.expectEqual(@as(u32, 8), pad.pad_px);

    const padding = try parse(
        \\[general]
        \\padding = 0
        \\
    );
    try std.testing.expectEqual(@as(u32, 0), padding.pad_px);
}

test "overlay keeps unset fields" {
    const base = try parse(
        \\[general]
        \\hz = 120
        \\[font]
        \\family = "Iosevka"
        \\size = 14
        \\
    );
    const cfg = try parseInto(
        \\foreground = "#ffffff"
        \\
    , base);
    try std.testing.expectEqual(@as(u32, 120), cfg.hz);
    try std.testing.expectEqualStrings("Iosevka", cfg.family().?);
    try std.testing.expectEqual(@as(f32, 14), cfg.font_size);
    try std.testing.expectEqual(@as(u8, 0xff), cfg.scheme.fg.r);
}

test "invalid" {
    try std.testing.expectError(error.InvalidToml, parse("[]\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nrefreshrate = 0\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nrefreshrate = \"60\"\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nwhitelist = 1\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nwhitelist = \"true\"\n"));
    const ignored = try parse("foreground = \"#gg0000\"\nmode = \"dark\"\nforeground = 1\n");
    try std.testing.expectEqual(Grid.Color.default_fg, ignored.scheme.fg);
}
