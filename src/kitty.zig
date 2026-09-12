//! Kitty graphics protocol. Decode and place images on the CPU grid.

const std = @import("std");

const c = struct {
    extern fn zt_stbi_load_rgba(data: [*]const u8, len: c_int, w: *c_int, h: *c_int, out: *?[*]u8) callconv(.c) c_int;
    extern fn zt_stbi_free(p: [*]u8) callconv(.c) void;
};

const max_dim: u32 = 4096;
const max_bytes: usize = 16 * 1024 * 1024;
const max_bitmap_bytes: usize = 16 * 1024 * 1024;
const max_images: usize = 64;
const max_placements: usize = 64;
const max_header: usize = 256;

pub const Command = struct {
    action: u8 = 't',
    format: u32 = 32,
    transmission: u8 = 'd',
    id: u32 = 0,
    place_id: u32 = 0,
    more: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    delete: u8 = 'a',
    quiet: u32 = 0,
    cursor_move: bool = true,
    payload: []const u8 = &.{},
};

pub const Bitmap = struct {
    width: u32,
    height: u32,
    rgba: []u8,
};

pub const Image = struct {
    id: u32,
    width: u32,
    height: u32,
    rgba: []u8,
};

pub const Placement = struct {
    image_id: u32,
    place_id: u32,
    col: i32,
    row: i32,
    columns: u32,
    rows: u32,
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    screen: u1,
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
};

pub fn isPrefix(s: []const u8) bool {
    return s.len >= 3 and s[0] == 0x1b and s[1] == '_' and s[2] == 'G';
}

/// `bytes` is an APC kitty body (`Gkey=value;payload`) or a full `ESC _ G ... ST`.
pub fn parse(bytes: []const u8) ?Command {
    var s = bytes;
    if (s.len >= 3 and s[0] == 0x1b and s[1] == '_' and s[2] == 'G') {
        s = s[3..];
        if (s.len >= 2 and s[s.len - 2] == 0x1b and s[s.len - 1] == '\\') {
            s = s[0 .. s.len - 2];
        }
    } else if (s.len >= 1 and s[0] == 'G') {
        s = s[1..];
    }
    const semi = std.mem.indexOfScalar(u8, s, ';');
    const keys = if (semi) |n| s[0..n] else s;
    const payload = if (semi) |n| s[n + 1 ..] else &.{};
    var cmd: Command = .{ .payload = payload };
    var it = std.mem.splitScalar(u8, keys, ',');
    while (it.next()) |pair| {
        if (pair.len < 3 or pair[1] != '=') continue;
        const v = pair[2..];
        switch (pair[0]) {
            'a' => if (v.len == 1) {
                cmd.action = v[0];
            },
            'f' => cmd.format = std.fmt.parseUnsigned(u32, v, 10) catch cmd.format,
            't' => if (v.len == 1) {
                cmd.transmission = v[0];
            },
            'i' => cmd.id = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'p' => cmd.place_id = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'm' => cmd.more = v.len == 1 and v[0] == '1',
            's' => cmd.width = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'v' => cmd.height = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'c' => cmd.columns = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'r' => cmd.rows = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'x' => cmd.src_x = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'y' => cmd.src_y = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'w' => cmd.src_w = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'h' => cmd.src_h = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'C' => cmd.cursor_move = !(v.len == 1 and v[0] == '1'),
            'q' => cmd.quiet = std.fmt.parseUnsigned(u32, v, 10) catch 0,
            'd' => if (v.len == 1) {
                cmd.delete = v[0];
            },
            else => {},
        }
    }
    return cmd;
}

const Stream = enum { idle, header, payload };

pub const Store = struct {
    allocator: std.mem.Allocator,
    images: std.ArrayList(Image) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    chunks: std.ArrayList(u8) = .empty,
    header: std.ArrayList(u8) = .empty,
    assembling: bool = false,
    pending: Command = .{},
    next_id: u32 = 1,
    stream: Stream = .idle,
    bitmap_used: usize = 0,
    reply: [128]u8 = undefined,
    reply_len: usize = 0,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.header.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.placements.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn streaming(self: *const Store) bool {
        return self.stream != .idle;
    }

    pub fn clear(self: *Store) void {
        for (self.images.items) |img| self.allocator.free(img.rgba);
        self.images.clearRetainingCapacity();
        self.placements.clearRetainingCapacity();
        self.chunks.clearRetainingCapacity();
        self.header.clearRetainingCapacity();
        self.assembling = false;
        self.pending = .{};
        self.stream = .idle;
        self.bitmap_used = 0;
    }

    pub fn dropScreen(self: *Store, which: u1) void {
        var i: usize = self.placements.items.len;
        while (i > 0) {
            i -= 1;
            if (self.placements.items[i].screen == which) {
                _ = self.placements.orderedRemove(i);
            }
        }
        self.gcUnplaced();
    }

    fn gcUnplaced(self: *Store) void {
        var i: usize = self.images.items.len;
        while (i > 0) {
            i -= 1;
            const id = self.images.items[i].id;
            if (!self.hasPlacement(id)) self.removeImage(id);
        }
    }

    fn hasPlacement(self: *const Store, id: u32) bool {
        for (self.placements.items) |p| {
            if (p.image_id == id) return true;
        }
        return false;
    }

    /// `extra` is scrollback lines above the live grid (0 on alt).
    /// A placement is dropped when its last cell row is above that window.
    pub fn scrollUp(self: *Store, which: u1, extra: u32) void {
        const limit: i32 = -@as(i32, @intCast(extra));
        var i: usize = self.placements.items.len;
        while (i > 0) {
            i -= 1;
            const p = &self.placements.items[i];
            if (p.screen != which) continue;
            p.row -= 1;
            const h: i32 = @intCast(@max(p.rows, 1));
            if (p.row + h <= limit) {
                const id = p.image_id;
                _ = self.placements.orderedRemove(i);
                if (!self.hasPlacement(id)) self.removeImage(id);
            }
        }
    }

    pub fn find(self: *const Store, id: u32) ?*const Image {
        for (self.images.items) |*img| {
            if (img.id == id) return img;
        }
        return null;
    }

    /// Returns an updated cursor when the command moves it.
    /// Reply for icat/query is in `reply`/`reply_len` (APC `i=…;OK`).
    pub fn feed(self: *Store, bytes: []const u8, cursor: Cursor, cols: u16, rows: u16, which: u1) ?Cursor {
        self.reply_len = 0;
        const cmd = parse(bytes) orelse return null;
        if (cmd.action == 'q') {
            self.query(cmd);
            return null;
        }
        if (cmd.action == 'd') {
            self.delete(cmd, cursor, which);
            self.dirty = true;
            return null;
        }
        if (cmd.action == 'p') {
            self.place(cmd, cursor, which);
            self.dirty = true;
            return self.movedCursor(cmd, cursor, cols, rows);
        }
        // Animation / compose: icat GIFs send a=f / a=a after the first frame.
        // Do not reply — leftover APC is echoed by the shell as EINVAL:... 
        if (cmd.action == 'f' or cmd.action == 'a' or cmd.action == 'c') return null;
        if (cmd.action != 't' and cmd.action != 'T' and cmd.action != 0) return null;
        if (cmd.transmission != 'd' and cmd.transmission != 'f' and cmd.transmission != 't') return null;

        if (cmd.more) {
            if (!self.assembling) {
                self.pending = cmd;
                self.chunks.clearRetainingCapacity();
                self.assembling = true;
            }
            self.chunks.appendSlice(self.allocator, cmd.payload) catch {
                self.assembling = false;
                self.chunks.clearRetainingCapacity();
                return null;
            };
            return null;
        }

        if (self.assembling) {
            self.chunks.appendSlice(self.allocator, cmd.payload) catch {
                self.assembling = false;
                self.chunks.clearRetainingCapacity();
                return null;
            };
            self.assembling = false;
            var done = self.pending;
            done.more = false;
            done.payload = self.chunks.items;
            if (cmd.id != 0) done.id = cmd.id;
            if (cmd.action != 0 and cmd.action != 't') done.action = cmd.action;
            return self.finish(done, cursor, cols, rows, which);
        }

        self.pending = cmd;
        self.chunks.clearRetainingCapacity();
        self.chunks.appendSlice(self.allocator, cmd.payload) catch return null;
        var done = cmd;
        done.payload = self.chunks.items;
        return self.finish(done, cursor, cols, rows, which);
    }

    fn query(self: *Store, cmd: Command) void {
        switch (cmd.transmission) {
            'd' => self.ok(cmd),
            'f', 't' => {
                if (payloadPathExists(self.allocator, cmd.payload)) self.ok(cmd) else self.fail(cmd, "ENOENT");
            },
            else => self.fail(cmd, "EINVAL:unsupported transmission"),
        }
    }

    fn ok(self: *Store, cmd: Command) void {
        self.replyStatus(cmd, "OK", false);
    }

    fn fail(self: *Store, cmd: Command, msg: []const u8) void {
        self.replyStatus(cmd, msg, true);
    }

    fn replyStatus(self: *Store, cmd: Command, msg: []const u8, is_error: bool) void {
        if (cmd.quiet >= 2) return;
        if (cmd.quiet == 1 and !is_error) return;
        const out = if (cmd.id != 0)
            std.fmt.bufPrint(&self.reply, "\x1b_Gi={d};{s}\x1b\\", .{ cmd.id, msg })
        else
            std.fmt.bufPrint(&self.reply, "\x1b_G;{s}\x1b\\", .{msg});
        self.reply_len = (out catch {
            self.reply_len = 0;
            return;
        }).len;
    }

    fn finish(self: *Store, cmd: Command, cursor: Cursor, cols: u16, rows: u16, which: u1) ?Cursor {
        const bmp = decode(self.allocator, cmd) catch {
            self.fail(cmd, "EINVAL:could not load image");
            return null;
        };
        var id = cmd.id;
        if (id == 0) {
            id = self.next_id;
            self.next_id +|= 1;
            if (self.next_id == 0) self.next_id = 1;
        }
        self.upsertImage(.{
            .id = id,
            .width = bmp.width,
            .height = bmp.height,
            .rgba = bmp.rgba,
        }) catch {
            self.allocator.free(bmp.rgba);
            self.fail(cmd, "EINVAL:could not load image");
            return null;
        };
        var placed = cmd;
        placed.id = id;
        self.dirty = true;
        self.ok(placed);
        if (cmd.action == 'T') {
            self.place(placed, cursor, which);
            return self.movedCursor(placed, cursor, cols, rows);
        }
        return null;
    }

    fn upsertImage(self: *Store, img: Image) std.mem.Allocator.Error!void {
        for (self.images.items, 0..) |*old, i| {
            if (old.id == img.id) {
                self.allocator.free(old.rgba);
                old.* = img;
                _ = i;
                return;
            }
        }
        if (self.images.items.len >= max_images) {
            const old = self.images.orderedRemove(0);
            self.allocator.free(old.rgba);
            self.dropImagePlacements(old.id);
        }
        try self.images.append(self.allocator, img);
    }

    fn place(self: *Store, cmd: Command, cursor: Cursor, which: u1) void {
        if (self.find(cmd.id) == null) return;
        const p = Placement{
            .image_id = cmd.id,
            .place_id = cmd.place_id,
            .col = cursor.col,
            .row = cursor.row,
            .columns = cmd.columns,
            .rows = cmd.rows,
            .src_x = cmd.src_x,
            .src_y = cmd.src_y,
            .src_w = cmd.src_w,
            .src_h = cmd.src_h,
            .screen = which,
        };
        if (cmd.place_id != 0) {
            for (self.placements.items) |*old| {
                if (old.image_id == cmd.id and old.place_id == cmd.place_id) {
                    old.* = p;
                    return;
                }
            }
        }
        if (self.placements.items.len >= max_placements) {
            _ = self.placements.orderedRemove(0);
        }
        self.placements.append(self.allocator, p) catch {};
    }

    fn delete(self: *Store, cmd: Command, cursor: Cursor, which: u1) void {
        const free_data = cmd.delete >= 'A' and cmd.delete <= 'Z';
        const kind: u8 = if (free_data) cmd.delete + ('a' - 'A') else cmd.delete;
        switch (kind) {
            'a' => if (free_data) self.clear() else self.placements.clearRetainingCapacity(),
            'i' => if (free_data) self.removeImage(cmd.id) else self.dropImagePlacements(cmd.id),
            'p' => {
                self.removePlacement(cmd.id, cmd.place_id);
                if (free_data) self.removeImage(cmd.id);
            },
            'c' => self.removeAtCursor(cursor, which),
            else => if (free_data) self.clear() else self.placements.clearRetainingCapacity(),
        }
    }

    fn removeImage(self: *Store, id: u32) void {
        var i: usize = self.images.items.len;
        while (i > 0) {
            i -= 1;
            if (self.images.items[i].id == id) {
                self.allocator.free(self.images.items[i].rgba);
                _ = self.images.orderedRemove(i);
            }
        }
        self.dropImagePlacements(id);
    }

    fn dropImagePlacements(self: *Store, id: u32) void {
        var i: usize = self.placements.items.len;
        while (i > 0) {
            i -= 1;
            if (self.placements.items[i].image_id == id) {
                _ = self.placements.orderedRemove(i);
            }
        }
    }

    fn removePlacement(self: *Store, id: u32, place_id: u32) void {
        var i: usize = self.placements.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.placements.items[i];
            if (p.image_id == id and (place_id == 0 or p.place_id == place_id)) {
                _ = self.placements.orderedRemove(i);
            }
        }
    }

    fn removeAtCursor(self: *Store, cursor: Cursor, which: u1) void {
        var i: usize = self.placements.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.placements.items[i];
            if (p.screen == which and p.col == cursor.col and p.row == cursor.row) {
                _ = self.placements.orderedRemove(i);
            }
        }
    }

    fn movedCursor(self: *const Store, cmd: Command, cursor: Cursor, cols: u16, rows: u16) ?Cursor {
        _ = self;
        if (!cmd.cursor_move) return null;
        const dc: u16 = std.math.cast(u16, cmd.columns) orelse 0;
        const dr: u16 = std.math.cast(u16, cmd.rows) orelse 0;
        if (dc == 0 and dr == 0) return null;
        var next = cursor;
        next.row = @min(rows - 1, cursor.row +| @max(dr, 1) -| 1);
        next.col = @min(cols - 1, cursor.col +| dc);
        return next;
    }
};

pub fn decode(allocator: std.mem.Allocator, cmd: Command) error{InvalidImage}!Bitmap {
    if (cmd.payload.len == 0) return error.InvalidImage;
    const raw = loadPayload(allocator, cmd) catch return error.InvalidImage;
    errdefer allocator.free(raw);
    if (raw.len == 0 or raw.len > max_bytes) return error.InvalidImage;
    if (isEncodedImage(raw) or cmd.format == 100) {
        const bmp = decodeEncoded(allocator, raw) catch return error.InvalidImage;
        allocator.free(raw);
        return bmp;
    }
    switch (cmd.format) {
        24 => {
            const w = cmd.width;
            const h = cmd.height;
            if (w == 0 or h == 0 or w > max_dim or h > max_dim) return error.InvalidImage;
            if (raw.len < @as(usize, w) * @as(usize, h) * 3) return error.InvalidImage;
            const rgba = rgbToRgba(allocator, raw, w, h) catch return error.InvalidImage;
            allocator.free(raw);
            return .{ .width = w, .height = h, .rgba = rgba };
        },
        32 => {
            const w = cmd.width;
            const h = cmd.height;
            if (w == 0 or h == 0 or w > max_dim or h > max_dim) return error.InvalidImage;
            if (raw.len < @as(usize, w) * @as(usize, h) * 4) return error.InvalidImage;
            const n = @as(usize, w) * @as(usize, h) * 4;
            if (raw.len == n) return .{ .width = w, .height = h, .rgba = raw };
            const rgba = allocator.dupe(u8, raw[0..n]) catch return error.InvalidImage;
            allocator.free(raw);
            return .{ .width = w, .height = h, .rgba = rgba };
        },
        else => return error.InvalidImage,
    }
}

fn decodeB64(allocator: std.mem.Allocator, src: []const u8) error{InvalidImage}![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    for (src) |ch| {
        switch (ch) {
            ' ', '\n', '\r', '\t' => {},
            else => clean.append(allocator, ch) catch return error.InvalidImage,
        }
    }
    if (clean.items.len == 0) return error.InvalidImage;
    const rem = clean.items.len % 4;
    if (rem != 0) {
        clean.appendNTimes(allocator, '=', 4 - rem) catch return error.InvalidImage;
    }
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(clean.items) catch return error.InvalidImage;
    const out = allocator.alloc(u8, n) catch return error.InvalidImage;
    errdefer allocator.free(out);
    dec.decode(out, clean.items) catch return error.InvalidImage;
    return out;
}

fn loadPayload(allocator: std.mem.Allocator, cmd: Command) error{InvalidImage}![]u8 {
    switch (cmd.transmission) {
        'd' => return decodeB64(allocator, cmd.payload),
        'f', 't' => {
            const path_raw = decodeB64(allocator, cmd.payload) catch return error.InvalidImage;
            defer allocator.free(path_raw);
            const path = std.mem.trim(u8, path_raw, " \t\r\n\x00");
            const data = readPath(allocator, path) catch return error.InvalidImage;
            if (cmd.transmission == 't') unlinkPath(path);
            return data;
        },
        else => return error.InvalidImage,
    }
}

fn payloadPathExists(allocator: std.mem.Allocator, payload: []const u8) bool {
    const path_raw = decodeB64(allocator, payload) catch return false;
    defer allocator.free(path_raw);
    const path = std.mem.trim(u8, path_raw, " \t\r\n\x00");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(path, &buf) orelse return false;
    const rc = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return false;
    _ = std.os.linux.close(@intCast(rc));
    return true;
}

fn toZ(path: []const u8, buf: []u8) ?[:0]u8 {
    if (path.len == 0 or path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn unlinkPath(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(path, &buf) orelse return;
    _ = std.os.linux.unlink(z.ptr);
}

fn readPath(allocator: std.mem.Allocator, path: []const u8) error{InvalidImage}![]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(path, &pbuf) orelse return error.InvalidImage;
    const rc = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.InvalidImage;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const k = std.os.linux.read(fd, &chunk, chunk.len);
        if (std.os.linux.errno(k) != .SUCCESS) return error.InvalidImage;
        if (k == 0) break;
        out.appendSlice(allocator, chunk[0..k]) catch return error.InvalidImage;
        if (out.items.len > max_bytes) return error.InvalidImage;
    }
    if (out.items.len == 0) return error.InvalidImage;
    return out.toOwnedSlice(allocator) catch return error.InvalidImage;
}

fn rgbToRgba(allocator: std.mem.Allocator, rgb: []const u8, w: u32, h: u32) error{InvalidImage}![]u8 {
    const n = @as(usize, w) * @as(usize, h);
    const rgba = allocator.alloc(u8, n * 4) catch return error.InvalidImage;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        rgba[i * 4 + 0] = rgb[i * 3 + 0];
        rgba[i * 4 + 1] = rgb[i * 3 + 1];
        rgba[i * 4 + 2] = rgb[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
    }
    return rgba;
}

fn isPng(data: []const u8) bool {
    const mag = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
    return data.len >= mag.len and std.mem.eql(u8, data[0..mag.len], &mag);
}

fn isJpeg(data: []const u8) bool {
    return data.len >= 3 and data[0] == 0xff and data[1] == 0xd8 and data[2] == 0xff;
}

fn isGif(data: []const u8) bool {
    return data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"));
}

fn isEncodedImage(data: []const u8) bool {
    return isPng(data) or isJpeg(data) or isGif(data);
}

fn decodeEncoded(allocator: std.mem.Allocator, data: []const u8) error{InvalidImage}!Bitmap {
    var w: c_int = 0;
    var h: c_int = 0;
    var ptr: ?[*]u8 = null;
    if (c.zt_stbi_load_rgba(data.ptr, @intCast(data.len), &w, &h, &ptr) == 0) return error.InvalidImage;
    const src = ptr orelse return error.InvalidImage;
    defer c.zt_stbi_free(src);
    if (w <= 0 or h <= 0) return error.InvalidImage;
    const uw: u32 = @intCast(w);
    const uh: u32 = @intCast(h);
    if (uw > max_dim or uh > max_dim) return error.InvalidImage;
    const n = @as(usize, uw) * @as(usize, uh) * 4;
    const rgba = allocator.dupe(u8, src[0..n]) catch return error.InvalidImage;
    return .{ .width = uw, .height = uh, .rgba = rgba };
}

test "parse transmit" {
    const cmd = parse("\x1b_Ga=T,f=24,i=3;QQ\x1b\\").?;
    try std.testing.expectEqual(@as(u8, 'T'), cmd.action);
    try std.testing.expectEqual(@as(u32, 3), cmd.id);
    try std.testing.expectEqual(@as(u32, 24), cmd.format);
    try std.testing.expectEqualStrings("QQ", cmd.payload);
    try std.testing.expect(!cmd.more);
}

test "decode rgb 1x1" {
    const gpa = std.testing.allocator;
    const cmd = parse("a=T,f=24,s=1,v=1;/wAA").?;
    const bmp = try decode(gpa, cmd);
    defer gpa.free(bmp.rgba);
    try std.testing.expectEqual(@as(u32, 1), bmp.width);
    try std.testing.expectEqual(@as(u32, 1), bmp.height);
    try std.testing.expectEqual(@as(u8, 255), bmp.rgba[0]);
    try std.testing.expectEqual(@as(u8, 0), bmp.rgba[1]);
    try std.testing.expectEqual(@as(u8, 0), bmp.rgba[2]);
    try std.testing.expectEqual(@as(u8, 255), bmp.rgba[3]);
}

const png_1x1_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";

test "decode png 1x1" {
    const gpa = std.testing.allocator;
    const cmd = parse("a=T,f=100;" ++ png_1x1_b64).?;
    const bmp = try decode(gpa, cmd);
    defer gpa.free(bmp.rgba);
    try std.testing.expectEqual(@as(u32, 1), bmp.width);
    try std.testing.expectEqual(@as(u32, 1), bmp.height);
    try std.testing.expectEqual(@as(u8, 255), bmp.rgba[0]);
    try std.testing.expectEqual(@as(u8, 0), bmp.rgba[1]);
    try std.testing.expectEqual(@as(u8, 0), bmp.rgba[2]);
}

test "decode png without f=100" {
    const gpa = std.testing.allocator;
    const cmd = parse("a=T;" ++ png_1x1_b64).?;
    const bmp = try decode(gpa, cmd);
    defer gpa.free(bmp.rgba);
    try std.testing.expectEqual(@as(u32, 1), bmp.width);
    try std.testing.expectEqual(@as(u8, 255), bmp.rgba[0]);
}

test "chunked png transmit places" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const mid = png_1x1_b64.len / 2;
    var buf: [256]u8 = undefined;
    const first = std.fmt.bufPrint(&buf, "\x1b_Ga=T,f=100,i=7,C=1,c=2,r=3,m=1;{s}\x1b\\", .{png_1x1_b64[0..mid]}) catch unreachable;
    try std.testing.expect(store.feed(first, .{}, 8, 8, 0) == null);
    const second = std.fmt.bufPrint(&buf, "\x1b_Gm=0;{s}\x1b\\", .{png_1x1_b64[mid..]}) catch unreachable;
    try std.testing.expect(store.feed(second, .{}, 8, 8, 0) == null);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.placements.items.len);
    try std.testing.expectEqual(@as(u32, 7), store.placements.items[0].image_id);
    try std.testing.expectEqual(@as(u32, 2), store.placements.items[0].columns);
    try std.testing.expectEqual(@as(u32, 3), store.placements.items[0].rows);
}

test "delete a keeps image data" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const seq = "\x1b_Ga=T,f=100,i=4,C=1;" ++ png_1x1_b64 ++ "\x1b\\";
    _ = store.feed(seq, .{}, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.placements.items.len);
    _ = store.feed("\x1b_Ga=d,d=a,q=2\x1b\\", .{}, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.placements.items.len);
    _ = store.feed("\x1b_Ga=p,i=4,c=3,r=2,C=1\x1b\\", .{ .col = 1, .row = 1 }, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 1), store.placements.items.len);
    try std.testing.expectEqual(@as(i32, 1), store.placements.items[0].col);
    _ = store.feed("\x1b_Ga=d,d=A,q=2\x1b\\", .{}, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 0), store.images.items.len);
}

test "query direct replies ok" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = store.feed("\x1b_Ga=q,t=d,i=31;AAAA\x1b\\", .{}, 8, 8, 0);
    try std.testing.expectEqualStrings("\x1b_Gi=31;OK\x1b\\", store.reply[0..store.reply_len]);
    try std.testing.expect(!store.dirty);
}

test "query unknown medium errors" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = store.feed("\x1b_Ga=q,t=s,i=2;AAAA\x1b\\", .{}, 8, 8, 0);
    try std.testing.expect(std.mem.indexOf(u8, store.reply[0..store.reply_len], "EINVAL") != null);
}

test "file transmit places png" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const raw = try decodeB64(gpa, png_1x1_b64);
    defer gpa.free(raw);
    const path = "/tmp/velocitty-kitty-test.png";
    {
        const rc = std.os.linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const fd: i32 = @intCast(rc);
        defer _ = std.os.linux.close(fd);
        const w = std.os.linux.write(fd, raw.ptr, raw.len);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(w));
    }
    defer _ = std.os.linux.unlink(path);

    var b64_buf: [128]u8 = undefined;
    const n = std.base64.standard.Encoder.calcSize(path.len);
    _ = std.base64.standard.Encoder.encode(b64_buf[0..n], path);

    var seq_buf: [256]u8 = undefined;
    const seq = std.fmt.bufPrint(&seq_buf, "\x1b_Ga=T,f=100,t=f,i=9,C=1,c=1,r=1;{s}\x1b\\", .{b64_buf[0..n]}) catch unreachable;

    var store = Store.init(gpa);
    defer store.deinit();
    _ = store.feed(seq, .{}, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.placements.items.len);
    try std.testing.expectEqualStrings("\x1b_Gi=9;OK\x1b\\", store.reply[0..store.reply_len]);
}
