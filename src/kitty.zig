//! Kitty graphics protocol. Decode and place images on the CPU grid.

const std = @import("std");
const Sixel = @import("sixel.zig");

const c = struct {
    extern fn zt_stbi_load_rgba(data: [*]const u8, len: c_int, w: *c_int, h: *c_int, out: *?[*]u8) callconv(.c) c_int;
    extern fn zt_stbi_free(p: [*]u8) callconv(.c) void;
};

/// Largest image side and payload/pixel size of one image (kitty's limits).
const max_dim: u32 = 10000;
const max_bytes: usize = 320 * 1024 * 1024;
const max_images: usize = 64;
const max_placements: usize = 64;
const max_header: usize = 256;

/// A buffer holding the APC string being fed that the owner can give away
/// (see `Store.feedDonor`): `take` returns the whole allocation (made with
/// the allocator passed) that holds the string at `off..off + len`, or null.
pub const Donor = struct {
    ctx: *anyopaque,
    off: usize,
    len: usize,
    take: *const fn (ctx: *anyopaque, off: usize, len: usize, allocator: std.mem.Allocator) ?[]u8,
};

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
    /// Decoded pixels; empty until the image is first drawn (`decodeVisible`)
    /// or when decoding failed.
    rgba: []u8,
    /// The payload as transmitted, freed once decoded. Images that are
    /// deleted or scroll away before a frame shows them are never decoded.
    pending: ?Pending = null,
    /// Has been placed at least once: freed as soon as no placement is left
    /// (scrolled off, cleared, deleted). Transmitted-only images wait for
    /// their a=p (bounded by `max_images`).
    placed: bool = false,
    /// The id was assigned here (sixel, or a transfer without `i=`).
    assigned: bool = false,
};

pub const Pending = struct {
    /// Base64 text (direct transmission), file bytes, or a sixel body.
    data: []u8,
    /// The whole allocation `data` lies in when it was handed over with its
    /// spill buffer (empty: `data` is the allocation).
    owned: []u8 = &.{},
    b64: bool = false,
    format: u32 = 0,
    /// Set for a sixel body (decoded with the default palette).
    sixel: ?SixelParams = null,

    pub fn free(self: Pending, allocator: std.mem.Allocator) void {
        allocator.free(if (self.owned.len != 0) self.owned else self.data);
    }
};

pub const SixelParams = struct {
    transparent: bool,
    max_w: u32,
    max_h: u32,
    registers: u16,
};

pub const Placement = struct {
    image_id: u32,
    place_id: u32,
    col: i32,
    /// Absolute line (`Cursor.base` + screen row at placement time).
    row: i64,
    columns: u32,
    rows: u32,
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    screen: u1,

    /// One past the last absolute line the placement covers.
    fn end(self: Placement) i64 {
        return self.row + @max(self.rows, 1);
    }
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    /// Absolute line of screen row 0 (`Grid.base`).
    base: i64 = 0,
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
    discarding: bool = false,
    pending: Command = .{},
    next_id: u32 = 1,
    stream: Stream = .idle,
    /// Largest transfer (base64 or path) accepted.
    max_transfer: usize = max_bytes,
    reply: [128]u8 = undefined,
    reply_len: usize = 0,
    dirty: bool = false,
    /// Lower bound of `Placement.end()` per screen: history scrolls only
    /// scan placements once the oldest kept line reaches it.
    min_end: [2]i64 = @splat(std.math.maxInt(i64)),

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
        for (self.images.items) |img| self.release(img);
        self.images.clearRetainingCapacity();
        self.placements.clearRetainingCapacity();
        self.min_end = @splat(std.math.maxInt(i64));
        self.chunks.clearRetainingCapacity();
        self.header.clearRetainingCapacity();
        self.assembling = false;
        self.discarding = false;
        self.pending = .{};
        self.stream = .idle;
        self.chunks.clearAndFree(self.allocator);
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

    /// Free placed images that no placement shows any more.
    fn gcUnplaced(self: *Store) void {
        var i: usize = self.images.items.len;
        while (i > 0) {
            i -= 1;
            const img = self.images.items[i];
            if (!img.placed or self.hasPlacement(img.id)) continue;
            self.release(img);
            _ = self.images.orderedRemove(i);
        }
    }

    /// Free image `id` if it was placed and its last placement is gone.
    fn freeIfOrphan(self: *Store, id: u32) void {
        const img = self.find(id) orelse return;
        if (img.placed and !self.hasPlacement(id)) self.removeImage(id);
    }

    fn hasPlacement(self: *const Store, id: u32) bool {
        for (self.placements.items) |p| {
            if (p.image_id == id) return true;
        }
        return false;
    }

    /// History scrolled: drops placements whose last line is older than
    /// `oldest`. O(1) until the oldest kept line reaches `min_end`.
    pub fn expire(self: *Store, which: u1, oldest: i64) void {
        if (oldest < self.min_end[which]) return;
        var low: i64 = std.math.maxInt(i64);
        var i: usize = self.placements.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.placements.items[i];
            if (p.screen != which) continue;
            if (p.end() <= oldest) {
                _ = self.placements.orderedRemove(i);
                self.freeIfOrphan(p.image_id);
            } else {
                low = @min(low, p.end());
            }
        }
        self.min_end[which] = low;
    }

    /// Rows `top..bottom` (screen rows from `base`) scrolled up by `n`
    /// without entering history: placements starting there move with them,
    /// and are dropped once they leave the top of the region. A placement
    /// partly above the region keeps moving until it is fully out.
    pub fn scrollRegion(self: *Store, which: u1, base: i64, top: u16, bottom: u16, n: u16) void {
        const lo = base + top;
        const hi = base + bottom;
        var i: usize = self.placements.items.len;
        while (i > 0) {
            i -= 1;
            const p = &self.placements.items[i];
            if (p.screen != which or p.end() <= lo or p.row > hi) continue;
            p.row -= n;
            if (p.end() <= lo) {
                const id = p.image_id;
                _ = self.placements.orderedRemove(i);
                self.freeIfOrphan(id);
            } else {
                self.min_end[which] = @min(self.min_end[which], p.end());
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
        return self.feedPlace(bytes, cursor, cols, rows, which, true);
    }

    /// `place == false` turns a=T into a=t: the transfer is kept for later
    /// a=p, but its own placement already scrolled away.
    pub fn feedPlace(self: *Store, bytes: []const u8, cursor: Cursor, cols: u16, rows: u16, which: u1, placing: bool) ?Cursor {
        return self.feedDonor(bytes, cursor, cols, rows, which, placing, null);
    }

    /// `feedPlace` for `bytes` that are the run `donor.off..+len` of a buffer
    /// the donor can hand over: a complete direct transmission then keeps
    /// that buffer (its base64 stays where read(2) wrote it) instead of
    /// copying the payload into `chunks`. `bytes` must not be used after.
    pub fn feedDonor(self: *Store, bytes: []const u8, cursor: Cursor, cols: u16, rows: u16, which: u1, placing: bool, donor: ?Donor) ?Cursor {
        self.reply_len = 0;
        var cmd = parse(bytes) orelse return null;
        if (!placing and cmd.action == 'T') cmd.action = 't';
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

        // Once a multipart transfer exceeds the limit, ignore its remaining
        // chunks through m=0 so that a tail cannot become a new image.
        if (self.discarding) {
            if (!cmd.more) self.discarding = false;
            return null;
        }
        if (!self.assembling) {
            self.pending = cmd;
            self.chunks.clearRetainingCapacity();
        }
        if (cmd.payload.len > self.max_transfer -| self.chunks.items.len) {
            self.fail(self.pending, "EINVAL:transfer too large");
            self.assembling = false;
            self.discarding = cmd.more;
            self.chunks.clearAndFree(self.allocator);
            self.pending = .{};
            return null;
        }
        if (donor) |d| if (!self.assembling and !cmd.more and cmd.transmission == 'd' and cmd.payload.len != 0) {
            const at = @intFromPtr(cmd.payload.ptr) -% @intFromPtr(bytes.ptr);
            if (at <= bytes.len and cmd.payload.len <= bytes.len - at) {
                if (d.take(d.ctx, d.off, d.len, self.allocator)) |buf| {
                    var done = cmd;
                    done.payload = buf[d.off + at ..][0..cmd.payload.len];
                    return self.finish(done, buf, cursor, cols, rows, which);
                }
            }
        };
        self.chunks.appendSlice(self.allocator, cmd.payload) catch {
            self.assembling = false;
            self.discarding = cmd.more;
            self.chunks.clearRetainingCapacity();
            self.pending = .{};
            return null;
        };
        if (cmd.more) {
            self.assembling = true;
            return null;
        }
        self.assembling = false;
        var done = self.pending;
        done.more = false;
        done.payload = self.chunks.items;
        if (cmd.id != 0) done.id = cmd.id;
        if (cmd.action != 0 and cmd.action != 't') done.action = cmd.action;
        return self.finish(done, null, cursor, cols, rows, which);
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

    /// `owned`: the allocation `cmd.payload` lies in (a taken spill buffer);
    /// the image keeps it, or it is freed on failure.
    fn finish(self: *Store, cmd: Command, owned: ?[]u8, cursor: Cursor, cols: u16, rows: u16, which: u1) ?Cursor {
        const img = self.load(cmd, owned) catch {
            self.chunks.clearAndFree(self.allocator);
            self.fail(cmd, "EINVAL:could not load image");
            return null;
        };
        const id = if (cmd.id != 0) cmd.id else self.takeId();
        var stored = img;
        stored.id = id;
        stored.assigned = cmd.id == 0;
        self.upsertImage(stored) catch {
            self.release(stored);
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

    fn release(self: *Store, img: Image) void {
        self.allocator.free(img.rgba);
        if (img.pending) |p| p.free(self.allocator);
    }

    /// Image dimensions and its payload, without decoding pixels: raw formats
    /// take `s`/`v`, PNG its IHDR. Other encoded formats decode now. A
    /// direct transfer's base64 moves out of `chunks` instead of being copied.
    fn load(self: *Store, cmd: Command, owned: ?[]u8) error{InvalidImage}!Image {
        const allocator = self.allocator;
        // A handed-over buffer is freed on every failure (and kept on success).
        errdefer if (owned) |o| allocator.free(o);
        if (cmd.payload.len == 0) return error.InvalidImage;
        const b64 = cmd.transmission == 'd';
        const data: []u8 = if (owned) |o|
            o[@intFromPtr(cmd.payload.ptr) - @intFromPtr(o.ptr) ..][0..cmd.payload.len]
        else if (b64)
            self.chunks.toOwnedSlice(allocator) catch return error.InvalidImage
        else
            loadPayload(allocator, cmd) catch return error.InvalidImage;
        errdefer if (owned == null) allocator.free(data);
        if (!b64) self.chunks.clearAndFree(allocator);
        var w = cmd.width;
        var h = cmd.height;
        switch (cmd.format) {
            24, 32 => if (!pngSize(data, b64, &w, &h) and (w == 0 or h == 0 or w > max_dim or h > max_dim)) return error.InvalidImage,
            else => if (!pngSize(data, b64, &w, &h)) {
                // JPEG, GIF, ...: no cheap header parse; decode now.
                const raw = if (b64) try decodeB64(allocator, data) else allocator.dupe(u8, data) catch return error.InvalidImage;
                const bmp = try decodeLoaded(allocator, raw, cmd.format, w, h);
                allocator.free(owned orelse data);
                return .{ .id = 0, .width = bmp.width, .height = bmp.height, .rgba = bmp.rgba };
            },
        }
        return .{ .id = 0, .width = w, .height = h, .rgba = &.{}, .pending = .{ .data = data, .owned = owned orelse &.{}, .b64 = b64, .format = cmd.format } };
    }

    /// Decode the images of placements visible on `which`'s view: rows
    /// `0..rows` counted from absolute line `base`.
    pub fn decodeVisible(self: *Store, which: u1, base: i64, rows: u16, cell_h: u32) void {
        var ids: [max_placements]u32 = undefined;
        var n: usize = 0;
        for (self.placements.items) |p| {
            if (p.screen != which) continue;
            const img = self.find(p.image_id) orelse continue;
            if (img.pending == null) continue;
            const span: i64 = if (p.rows != 0) p.rows else (img.height + @max(cell_h, 1) - 1) / @max(cell_h, 1);
            const row = p.row - base;
            if (row >= rows or row + @max(span, 1) <= 0) continue;
            if (std.mem.indexOfScalar(u32, ids[0..n], p.image_id) != null) continue;
            ids[n] = p.image_id;
            n += 1;
        }
        for (ids[0..n]) |id| {
            const img = self.findMut(id) orelse continue;
            const pend = img.pending orelse continue;
            img.pending = null;
            defer pend.free(self.allocator);
            const bmp = if (pend.sixel) |sp| blk: {
                var pal = Sixel.defaultPalette();
                const b = Sixel.decode(self.allocator, pend.data, .{
                    .transparent = sp.transparent,
                    .max_w = sp.max_w,
                    .max_h = sp.max_h,
                    .palette = &pal,
                    .registers = sp.registers,
                }) catch {
                    self.removeImage(id);
                    continue;
                };
                break :blk Bitmap{ .width = b.width, .height = b.height, .rgba = b.rgba };
            } else blk: {
                const raw = if (pend.b64) decodeB64(self.allocator, pend.data) catch {
                    self.removeImage(id);
                    continue;
                } else self.allocator.dupe(u8, pend.data) catch {
                    self.removeImage(id);
                    continue;
                };
                break :blk decodeLoaded(self.allocator, raw, pend.format, img.width, img.height) catch {
                    self.removeImage(id);
                    continue;
                };
            };
            const now = self.findMut(id) orelse {
                self.allocator.free(bmp.rgba);
                continue;
            };
            now.rgba = bmp.rgba;
            now.width = bmp.width;
            now.height = bmp.height;
            self.dirty = true;
        }
    }

    fn findMut(self: *Store, id: u32) ?*Image {
        for (self.images.items) |*img| {
            if (img.id == id) return img;
        }
        return null;
    }

    fn upsertImage(self: *Store, img: Image) std.mem.Allocator.Error!void {
        for (self.images.items) |*old| {
            if (old.id == img.id) {
                const id = old.id;
                self.release(old.*);
                old.* = img;
                self.dropImagePlacements(id);
                return;
            }
        }
        if (self.images.items.len >= max_images) {
            const old = self.images.orderedRemove(0);
            self.release(old);
            self.dropImagePlacements(old.id);
        }
        try self.images.append(self.allocator, img);
    }

    fn place(self: *Store, cmd: Command, cursor: Cursor, which: u1) void {
        const img = self.findMut(cmd.id) orelse return;
        img.placed = true;
        const p = Placement{
            .image_id = cmd.id,
            .place_id = cmd.place_id,
            .col = cursor.col,
            .row = cursor.base + cursor.row,
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
                    self.min_end[which] = @min(self.min_end[which], p.end());
                    return;
                }
            }
        }
        if (self.placements.items.len >= max_placements) {
            _ = self.placements.orderedRemove(0);
            self.gcUnplaced();
        }
        self.placements.append(self.allocator, p) catch return;
        self.min_end[which] = @min(self.min_end[which], p.end());
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
        self.gcUnplaced();
    }

    /// The screen was cleared: drop placements that cover any of its rows
    /// (absolute lines `base..base + rows`).
    pub fn dropVisible(self: *Store, which: u1, base: i64, rows: u16, cell_h: u32) void {
        var i: usize = self.placements.items.len;
        var any = false;
        while (i > 0) {
            i -= 1;
            const p = self.placements.items[i];
            if (p.screen != which) continue;
            const img = self.find(p.image_id);
            const span: i64 = if (p.rows != 0) p.rows else if (img) |m| (m.height + @max(cell_h, 1) - 1) / @max(cell_h, 1) else 1;
            if (p.row >= base + rows or p.row + @max(span, 1) <= base) continue;
            _ = self.placements.orderedRemove(i);
            any = true;
        }
        if (any) {
            self.gcUnplaced();
            self.dirty = true;
        }
    }

    fn removeImage(self: *Store, id: u32) void {
        var i: usize = self.images.items.len;
        while (i > 0) {
            i -= 1;
            if (self.images.items[i].id == id) {
                self.release(self.images.items[i]);
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
            if (p.screen == which and p.col == cursor.col and p.row == cursor.base + cursor.row) {
                _ = self.placements.orderedRemove(i);
            }
        }
    }

    pub fn placeBitmap(
        self: *Store,
        rgba: []u8,
        width: u32,
        height: u32,
        cursor: Cursor,
        which: u1,
        columns: u32,
        rows: u32,
    ) void {
        self.placeImage(.{ .id = 0, .width = width, .height = height, .rgba = rgba }, cursor, which, columns, rows);
    }

    fn takeId(self: *Store) u32 {
        const id = self.next_id;
        self.next_id +|= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    /// Store `img` (owned) under a fresh id and place it at `cursor`.
    pub fn placeImage(self: *Store, img: Image, cursor: Cursor, which: u1, columns: u32, rows: u32) void {
        const id = self.takeId();
        var stored = img;
        stored.id = id;
        stored.assigned = true;
        self.upsertImage(stored) catch {
            self.release(stored);
            return;
        };
        self.place(.{
            .id = id,
            .columns = columns,
            .rows = rows,
            .cursor_move = false,
        }, cursor, which);
        self.dirty = true;
    }

    /// Drops placements starting above screen row 0 (`base`).
    pub fn dropHistory(self: *Store, which: u1, base: i64) void {
        var i: usize = self.placements.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.placements.items[i];
            if (p.screen == which and p.row < base) {
                const id = p.image_id;
                _ = self.placements.orderedRemove(i);
                self.freeIfOrphan(id);
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
    return decodeLoaded(allocator, raw, cmd.format, cmd.width, cmd.height);
}

/// Width and height from a PNG IHDR at the start of `data`.
fn pngSize(data: []const u8, b64: bool, w: *u32, h: *u32) bool {
    var head: [33]u8 = undefined;
    const bytes: []const u8 = if (b64) blk: {
        if (data.len < 44) return false;
        std.base64.standard.Decoder.decode(&head, data[0..44]) catch return false;
        break :blk &head;
    } else data;
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, bytes[12..16], "IHDR")) return false;
    const pw = std.mem.readInt(u32, bytes[16..20], .big);
    const ph = std.mem.readInt(u32, bytes[20..24], .big);
    if (pw == 0 or ph == 0 or pw > max_dim or ph > max_dim) return false;
    w.* = pw;
    h.* = ph;
    return true;
}

/// Pixels from a loaded payload (takes ownership of `raw`).
fn decodeLoaded(allocator: std.mem.Allocator, raw: []u8, format: u32, width: u32, height: u32) error{InvalidImage}!Bitmap {
    errdefer allocator.free(raw);
    if (raw.len == 0 or raw.len > max_bytes) return error.InvalidImage;
    if (isEncodedImage(raw) or format == 100) {
        const bmp = decodeEncoded(allocator, raw) catch return error.InvalidImage;
        allocator.free(raw);
        return bmp;
    }
    switch (format) {
        24 => {
            const w = width;
            const h = height;
            if (w == 0 or h == 0 or w > max_dim or h > max_dim) return error.InvalidImage;
            if (raw.len < @as(usize, w) * @as(usize, h) * 3) return error.InvalidImage;
            const rgba = rgbToRgba(allocator, raw, w, h) catch return error.InvalidImage;
            allocator.free(raw);
            return .{ .width = w, .height = h, .rgba = rgba };
        },
        32 => {
            const w = width;
            const h = height;
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
    const dec = std.base64.standard.Decoder;
    if (src.len != 0 and src.len % 4 == 0 and std.mem.indexOfAny(u8, src, " \n\r\t") == null) {
        const n = dec.calcSizeForSlice(src) catch return error.InvalidImage;
        const out = allocator.alloc(u8, n) catch return error.InvalidImage;
        errdefer allocator.free(out);
        dec.decode(out, src) catch return error.InvalidImage;
        return out;
    }
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    clean.ensureTotalCapacity(allocator, src.len + 3) catch return error.InvalidImage;
    for (src) |ch| {
        switch (ch) {
            ' ', '\n', '\r', '\t' => {},
            else => clean.appendAssumeCapacity(ch),
        }
    }
    if (clean.items.len == 0) return error.InvalidImage;
    const rem = clean.items.len % 4;
    if (rem != 0) clean.appendNTimesAssumeCapacity('=', 4 - rem);
    const n = dec.calcSizeForSlice(clean.items) catch return error.InvalidImage;
    const out = allocator.alloc(u8, n) catch return error.InvalidImage;
    errdefer allocator.free(out);
    dec.decode(out, clean.items) catch return error.InvalidImage;
    return out;
}

// Temporary files are unlinked only in trusted, directly named temporary
// directories and only when their basename contains the protocol marker.
// Restricting this to a single path component also rules out traversal and
// path traversal through the supplied filename.
const TempName = struct { dir: []const u8, name: []const u8 };

fn tempInDir(path: []const u8, dir_raw: []const u8) ?TempName {
    const dir = std.mem.trimEnd(u8, dir_raw, "/");
    if (dir.len == 0 or dir[0] != '/' or std.mem.indexOfScalar(u8, dir, 0) != null) return null;
    var parts = std.mem.splitScalar(u8, dir[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
    }
    if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') return null;
    const name = path[dir.len + 1 ..];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.indexOf(u8, name, "tty-graphics-protocol") == null) return null;
    return .{ .dir = dir, .name = name };
}

fn tempName(path: []const u8) ?TempName {
    for ([_][]const u8{ "/tmp", "/var/tmp", "/dev/shm" }) |dir| {
        if (tempInDir(path, dir)) |result| return result;
    }
    if (std.c.getenv("TMPDIR")) |dir| return tempInDir(path, std.mem.span(dir));
    return null;
}

fn toZ(path: []const u8, buf: []u8) ?[:0]u8 {
    if (path.len == 0 or path.len >= buf.len or std.mem.indexOfScalar(u8, path, 0) != null) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn regularFd(fd: i32) bool {
    var info: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true }, &info);
    return std.os.linux.errno(rc) == .SUCCESS and info.mask.TYPE and std.os.linux.S.ISREG(info.mode);
}

fn openRegularAt(dirfd: i32, path: []const u8, nofollow: bool) ?i32 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(path, &buf) orelse return null;
    // O_PATH does not open a device or FIFO for I/O. Inspect the object first,
    // then reopen that exact descriptor through procfs, not the mutable path.
    const rc = std.os.linux.openat(dirfd, z.ptr, .{ .PATH = true, .CLOEXEC = true, .NOFOLLOW = nofollow }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    const pathfd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(pathfd);
    if (!regularFd(pathfd)) return null;
    var proc_buf: [64]u8 = undefined;
    const proc_path = std.fmt.bufPrint(&proc_buf, "/proc/self/fd/{d}", .{pathfd}) catch return null;
    var proc_zbuf: [64]u8 = undefined;
    const proc_z = toZ(proc_path, &proc_zbuf) orelse return null;
    const read_rc = std.os.linux.open(proc_z.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(read_rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(read_rc);
    if (!regularFd(fd)) {
        _ = std.os.linux.close(fd);
        return null;
    }
    return fd;
}

fn openRegular(path: []const u8, nofollow: bool) ?i32 {
    return openRegularAt(std.os.linux.AT.FDCWD, path, nofollow);
}

fn loadPayload(allocator: std.mem.Allocator, cmd: Command) error{InvalidImage}![]u8 {
    switch (cmd.transmission) {
        'd' => return decodeB64(allocator, cmd.payload),
        'f', 't' => {
            if (@import("builtin").os.tag != .linux) return error.InvalidImage;
            const path_raw = decodeB64(allocator, cmd.payload) catch return error.InvalidImage;
            defer allocator.free(path_raw);
            const path = std.mem.trim(u8, path_raw, " \t\r\n");
            if (cmd.transmission == 't') {
                const temp = tempName(path) orelse return error.InvalidImage;
                var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
                const dir_path = toZ(temp.dir, &dir_buf) orelse return error.InvalidImage;
                const dir_rc = std.os.linux.open(dir_path.ptr, .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
                if (std.os.linux.errno(dir_rc) != .SUCCESS) return error.InvalidImage;
                const dirfd: i32 = @intCast(dir_rc);
                defer _ = std.os.linux.close(dirfd);
                const fd = openRegularAt(dirfd, temp.name, true) orelse return error.InvalidImage;
                defer _ = std.os.linux.close(fd);
                const data = try readFd(allocator, fd);
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                if (toZ(temp.name, &buf)) |name| {
                    var opened: std.os.linux.Statx = undefined;
                    var named: std.os.linux.Statx = undefined;
                    const mask: std.os.linux.STATX = .{ .TYPE = true, .INO = true };
                    const a = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, mask, &opened);
                    const b = std.os.linux.statx(dirfd, name.ptr, std.os.linux.AT.SYMLINK_NOFOLLOW, mask, &named);
                    if (std.os.linux.errno(a) == .SUCCESS and std.os.linux.errno(b) == .SUCCESS and
                        opened.mask.INO and named.mask.INO and named.mask.TYPE and std.os.linux.S.ISREG(named.mode) and
                        opened.ino == named.ino and opened.dev_major == named.dev_major and opened.dev_minor == named.dev_minor)
                        _ = std.os.linux.unlinkat(dirfd, name.ptr, 0);
                }
                return data;
            }
            const fd = openRegular(path, false) orelse return error.InvalidImage;
            defer _ = std.os.linux.close(fd);
            const data = try readFd(allocator, fd);
            return data;
        },
        else => return error.InvalidImage,
    }
}

fn payloadPathExists(allocator: std.mem.Allocator, payload: []const u8) bool {
    if (@import("builtin").os.tag != .linux) return false;
    const path_raw = decodeB64(allocator, payload) catch return false;
    defer allocator.free(path_raw);
    const path = std.mem.trim(u8, path_raw, " \t\r\n");
    const fd = openRegular(path, false) orelse return false;
    _ = std.os.linux.close(fd);
    return true;
}

fn readFd(allocator: std.mem.Allocator, fd: i32) error{InvalidImage}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const k = std.os.linux.read(fd, &chunk, chunk.len);
        if (std.os.linux.errno(k) != .SUCCESS) return error.InvalidImage;
        if (k == 0) break;
        if (k > max_bytes - out.items.len) return error.InvalidImage;
        out.appendSlice(allocator, chunk[0..k]) catch return error.InvalidImage;
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

test "delete a frees placed images" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    const seq = "\x1b_Ga=T,f=100,i=4,C=1;" ++ png_1x1_b64 ++ "\x1b\\";
    _ = store.feed(seq, .{}, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.placements.items.len);
    _ = store.feed("\x1b_Ga=d,d=a,q=2\x1b\\", .{}, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 0), store.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.placements.items.len);
    _ = store.feed("\x1b_Ga=t,f=100,i=4,q=2;" ++ png_1x1_b64 ++ "\x1b\\", .{}, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
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

test "multipart transfer cap discards through final chunk and recovers" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    store.max_transfer = 64 * 1024;
    const payload = try gpa.alloc(u8, store.max_transfer);
    defer gpa.free(payload);
    @memset(payload, 'A');
    const first = try std.fmt.allocPrint(gpa, "a=t,i=42,m=1;{s}", .{payload});
    defer gpa.free(first);
    _ = store.feed(first, .{}, 8, 8, 0);
    try std.testing.expectEqual(store.max_transfer, store.chunks.items.len);
    _ = store.feed("m=1;AAAA", .{}, 8, 8, 0);
    try std.testing.expect(!store.assembling and store.discarding);
    try std.testing.expectEqual(@as(usize, 0), store.chunks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, store.reply[0..store.reply_len], "EINVAL") != null);
    _ = store.feed("m=0;AAAA", .{}, 8, 8, 0);
    try std.testing.expect(!store.discarding);
    _ = store.feed("a=T,f=100,i=4,C=1;" ++ png_1x1_b64, .{}, 8, 8, 0);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
}

test "file transfer rejects FIFO and unsafe temporary deletion" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ordinary_buf: [128]u8 = undefined;
    var fifo_buf: [128]u8 = undefined;
    var temp_buf: [128]u8 = undefined;
    var link_buf: [128]u8 = undefined;
    const pid = std.os.linux.getpid();
    const ordinary = try std.fmt.bufPrint(ordinary_buf[0 .. ordinary_buf.len - 1], "/tmp/velocitty-kitty-ordinary-{d}", .{pid});
    const fifo = try std.fmt.bufPrint(fifo_buf[0 .. fifo_buf.len - 1], "/tmp/velocitty-kitty-fifo-{d}", .{pid});
    const temp = try std.fmt.bufPrint(temp_buf[0 .. temp_buf.len - 1], "/tmp/tty-graphics-protocol-{d}", .{pid});
    const link = try std.fmt.bufPrint(link_buf[0 .. link_buf.len - 1], "/tmp/tty-graphics-protocol-link-{d}", .{pid});
    ordinary_buf[ordinary.len] = 0;
    const ordinary_z = ordinary_buf[0..ordinary.len :0];
    fifo_buf[fifo.len] = 0;
    const fifo_z = fifo_buf[0..fifo.len :0];
    temp_buf[temp.len] = 0;
    const temp_z = temp_buf[0..temp.len :0];
    link_buf[link.len] = 0;
    const link_z = link_buf[0..link.len :0];
    const rc = std.os.linux.open(ordinary_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    defer _ = std.os.linux.unlink(ordinary_z.ptr);
    const fd: i32 = @intCast(rc);
    try std.testing.expectEqual(@as(usize, 4), std.os.linux.write(fd, "abcd", 4));
    _ = std.os.linux.close(fd);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mknod(fifo_z.ptr, std.os.linux.S.IFIFO | 0o600, 0)));
    defer _ = std.os.linux.unlink(fifo_z.ptr);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.symlink(ordinary_z.ptr, link_z.ptr)));
    defer _ = std.os.linux.unlink(link_z.ptr);
    try std.testing.expect(openRegular(fifo, false) == null);
    try std.testing.expect(openRegular(link, true) == null);
    const followed = openRegular(link, false) orelse return error.TestUnexpectedResult;
    _ = std.os.linux.close(followed);
    for ([_][]const u8{ ordinary, fifo, link }) |path| {
        const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(path.len));
        defer gpa.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, path);
        try std.testing.expectError(error.InvalidImage, loadPayload(gpa, .{ .transmission = 't', .payload = encoded }));
    }
    const check = openRegular(ordinary, false) orelse return error.TestUnexpectedResult;
    _ = std.os.linux.close(check);
    try std.testing.expect(tempName("/tmp/../etc/tty-graphics-protocol-x") == null);
    try std.testing.expect(tempName("/tmp/sub/tty-graphics-protocol-x") == null);
    const tmp_fd_rc = std.os.linux.open(temp_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(tmp_fd_rc));
    defer _ = std.os.linux.unlink(temp_z.ptr);
    const tmp_fd: i32 = @intCast(tmp_fd_rc);
    try std.testing.expectEqual(@as(usize, 4), std.os.linux.write(tmp_fd, "abcd", 4));
    _ = std.os.linux.close(tmp_fd);
    const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(temp.len));
    defer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, temp);
    const data = try loadPayload(gpa, .{ .transmission = 't', .payload = encoded });
    defer gpa.free(data);
    try std.testing.expectEqualStrings("abcd", data);
    try std.testing.expect(openRegular(temp, false) == null);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "temporary transfer honors absolute TMPDIR and anchors its directory" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const old = if (std.c.getenv("TMPDIR")) |p| try allocator.dupeSentinel(u8, std.mem.span(p), 0) else null;
    defer if (old) |value| {
        _ = setenv("TMPDIR", value.ptr, 1);
        allocator.free(value);
    } else {
        _ = unsetenv("TMPDIR");
    };
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(dir_buf[0 .. dir_buf.len - 1], "/tmp/velocitty-kitty-dir-{d}", .{std.os.linux.getpid()});
    dir_buf[dir.len] = 0;
    const dir_z = dir_buf[0..dir.len :0];
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mkdir(dir_z.ptr, 0o700)));
    defer _ = std.os.linux.rmdir(dir_z.ptr);
    try std.testing.expectEqual(@as(c_int, 0), setenv("TMPDIR", dir_z.ptr, 1));
    const path = try std.fmt.allocPrint(allocator, "{s}/tty-graphics-protocol-test", .{dir});
    defer allocator.free(path);
    var path_buf: [256]u8 = undefined;
    const path_z = toZ(path, &path_buf) orelse unreachable;
    const rc = std.os.linux.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    defer _ = std.os.linux.unlink(path_z.ptr);
    const fd: i32 = @intCast(rc);
    try std.testing.expectEqual(@as(usize, 4), std.os.linux.write(fd, "data", 4));
    _ = std.os.linux.close(fd);
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(path.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, path);
    const data = try loadPayload(allocator, .{ .transmission = 't', .payload = encoded });
    defer allocator.free(data);
    try std.testing.expectEqualStrings("data", data);
    try std.testing.expect(openRegular(path, false) == null);
    try std.testing.expect(tempInDir("/some/tty-graphics-protocol-x", "relative") == null);
    try std.testing.expect(tempInDir("/some/tty-graphics-protocol-x", "/some/../some") == null);
    try std.testing.expect(openRegular("/dev/null", false) == null);
}

test "placements are anchored to absolute lines and expire with history" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // Screen row 1 when 100 lines were already in history: line 101..102.
    store.placeBitmap(try gpa.alloc(u8, 4), 1, 1, .{ .row = 1, .base = 100 }, 0, 1, 2);
    _ = store.feed("\x1b_Ga=T,f=32,s=1,v=1,i=900,r=1,q=2;/wAA/w==\x1b\\", .{ .row = 3, .base = 100 }, 4, 4, 0);
    try std.testing.expectEqual(@as(i64, 101), store.placements.items[0].row);
    try std.testing.expectEqual(@as(i64, 103), store.min_end[0]);
    store.expire(0, 102);
    try std.testing.expectEqual(@as(usize, 2), store.images.items.len);
    store.expire(0, 103);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
    try std.testing.expectEqual(@as(u32, 900), store.images.items[0].id);
    try std.testing.expectEqual(@as(i64, 104), store.min_end[0]);
    store.dropHistory(0, 104);
    try std.testing.expectEqual(@as(usize, 0), store.images.items.len);
}

test "region scroll moves only placements inside the region" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    store.placeBitmap(try gpa.alloc(u8, 4), 1, 1, .{ .row = 0 }, 1, 1, 1);
    store.placeBitmap(try gpa.alloc(u8, 4), 1, 1, .{ .row = 3 }, 1, 1, 2);
    store.scrollRegion(1, 0, 2, 5, 1);
    try std.testing.expectEqual(@as(i64, 0), store.placements.items[0].row);
    try std.testing.expectEqual(@as(i64, 2), store.placements.items[1].row);
    store.scrollRegion(1, 0, 2, 5, 2);
    try std.testing.expectEqual(@as(usize, 1), store.placements.items.len);
    try std.testing.expectEqual(@as(i64, 0), store.placements.items[0].row);
}

test "images decode when first drawn, not when transmitted" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = store.feed("\x1b_Ga=T,f=100,i=1,q=2;" ++ png_1x1_b64 ++ "\x1b\\", .{ .row = 1 }, 8, 4, 0);
    _ = store.feed("\x1b_Ga=t,f=100,i=2,q=2;" ++ png_1x1_b64 ++ "\x1b\\", .{}, 8, 4, 0);
    const shown = store.find(1).?;
    // Size comes from the IHDR; pixels wait for a frame.
    try std.testing.expectEqual(@as(u32, 1), shown.width);
    try std.testing.expect(shown.pending != null and shown.rgba.len == 0);
    // Placed below the view: still not decoded.
    store.decodeVisible(0, -10, 4, 16);
    try std.testing.expect(store.find(1).?.pending != null);
    store.decodeVisible(0, 0, 4, 16);
    try std.testing.expect(store.find(1).?.pending == null);
    try std.testing.expectEqual(@as(u8, 255), store.find(1).?.rgba[0]);
    // Image 2 has no placement: never decoded, freed with the store.
    try std.testing.expect(store.find(2).?.pending != null);
}

test "clearing the screen drops its placements and frees unplaced images" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // On screen (lines 100..103), above it, and an image with an explicit id.
    store.placeBitmap(try gpa.alloc(u8, 4), 1, 1, .{ .row = 1, .base = 100 }, 0, 1, 1);
    store.placeBitmap(try gpa.alloc(u8, 4), 1, 1, .{ .row = 0, .base = 90 }, 0, 1, 1);
    _ = store.feed("\x1b_Ga=T,f=32,s=1,v=1,i=7,q=2;/wAA/w==\x1b\\", .{ .row = 2, .base = 100 }, 4, 4, 0);
    try std.testing.expectEqual(@as(usize, 3), store.images.items.len);
    store.dropVisible(0, 100, 4, 16);
    // The history placement stays; image 7 lost its only placement.
    try std.testing.expectEqual(@as(usize, 1), store.placements.items.len);
    try std.testing.expectEqual(@as(i64, 90), store.placements.items[0].row);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
    try std.testing.expect(store.find(7) == null);
}

test "placed images are freed with their last placement, unplaced ones wait" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = store.feed("\x1b_Ga=T,f=32,s=1,v=1,i=1,q=2;/wAA/w==\x1b\\", .{ .row = 0 }, 8, 4, 0);
    _ = store.feed("\x1b_Ga=t,f=32,s=1,v=1,i=2,q=2;/wAA/w==\x1b\\", .{}, 8, 4, 0);
    _ = store.feed("\x1b_Ga=T,f=32,s=1,v=1,i=3,q=2;/wAA/w==\x1b\\", .{ .row = 2 }, 8, 4, 0);
    _ = store.feed("\x1b_Ga=T,f=32,s=1,v=1,i=4,q=2;/wAA/w==\x1b\\", .{ .row = 3 }, 8, 4, 0);
    // History scroll: image 1 (line 0) expires.
    store.expire(0, 1);
    try std.testing.expect(store.find(1) == null);
    try std.testing.expect(store.find(2) != null);
    // Deleting placements (lowercase) frees a placed image too.
    _ = store.feed("\x1b_Ga=d,d=i,i=3\x1b\\", .{}, 8, 4, 0);
    try std.testing.expect(store.find(3) == null);
    // Image 2 is placed later, then a screen drop frees it.
    _ = store.feed("\x1b_Ga=p,i=2\x1b\\", .{ .row = 1 }, 8, 4, 0);
    try std.testing.expectEqual(@as(usize, 2), store.placements.items.len);
    store.dropScreen(0);
    try std.testing.expectEqual(@as(usize, 0), store.images.items.len);
}

test "a placement partly above the region keeps scrolling out" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    // 3 rows tall at line 4; region 2..8.
    store.placeBitmap(try gpa.alloc(u8, 4), 1, 1, .{ .row = 4 }, 1, 1, 3);
    store.scrollRegion(1, 0, 2, 8, 3); // row 1, end 4: partly above lo=2
    try std.testing.expectEqual(@as(i64, 1), store.placements.items[0].row);
    store.scrollRegion(1, 0, 2, 8, 1); // row 0, end 3
    try std.testing.expectEqual(@as(usize, 1), store.placements.items.len);
    store.scrollRegion(1, 0, 2, 8, 1); // end 2 <= lo: gone
    try std.testing.expectEqual(@as(usize, 0), store.placements.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.images.items.len);
}

test "failed lazy decode removes the image and its placements" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = store.feed("\x1b_Ga=T,f=32,s=1,v=1,i=1;AAAA\x1b\\", .{ .row = 0 }, 8, 4, 0);
    try std.testing.expect(store.find(1) != null);
    store.decodeVisible(0, 0, 4, 16);
    try std.testing.expect(store.find(1) == null);
    try std.testing.expectEqual(@as(usize, 0), store.placements.items.len);
}

test "retransmitting an id drops the old placements" {
    const gpa = std.testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = store.feed("\x1b_Ga=T,f=32,s=1,v=1,i=1,q=2;/wAA/w==\x1b\\", .{ .row = 0 }, 8, 4, 0);
    _ = store.feed("\x1b_Ga=t,f=32,s=1,v=1,i=1,q=2;/wAA/w==\x1b\\", .{}, 8, 4, 0);
    try std.testing.expectEqual(@as(usize, 0), store.placements.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.images.items.len);
}
