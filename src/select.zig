//! Cell-stream selection and copy from the visible grid.

const std = @import("std");
const Term = @import("vt.zig");

pub const Point = struct {
    col: u16 = 0,
    row: u16 = 0,

    pub fn idx(self: Point, cols: u16) u32 {
        return @as(u32, self.row) * cols + self.col;
    }
};

pub const Kind = enum { cell, word, line };

pub const State = struct {
    on: bool = false,
    a: Point = .{},
    b: Point = .{},
    anchor: Point = .{},
    kind: Kind = .cell,

    pub fn clear(self: *State) void {
        self.* = .{};
    }

    pub fn begin(self: *State, col: u16, row: u16) void {
        const p = Point{ .col = col, .row = row };
        self.* = .{ .on = true, .a = p, .b = p, .anchor = p, .kind = .cell };
    }

    pub fn extend(self: *State, col: u16, row: u16) void {
        if (!self.on) {
            self.begin(col, row);
            return;
        }
        self.b = .{ .col = col, .row = row };
    }

    pub fn grab(self: *State, screen: *const Term.Screen, col: u16, row: u16, kind: Kind) void {
        const span = spanAt(screen, col, row, kind);
        self.* = .{
            .on = true,
            .a = span.a,
            .b = span.b,
            .anchor = clampPoint(screen, col, row),
            .kind = kind,
        };
    }

    pub fn drag(self: *State, screen: *const Term.Screen, col: u16, row: u16) void {
        if (!self.on) {
            self.grab(screen, col, row, .cell);
            return;
        }
        const head = spanAt(screen, self.anchor.col, self.anchor.row, self.kind);
        const tail = spanAt(screen, col, row, self.kind);
        const cols = screen.cols;
        var lo = minPt(head.a, head.b, cols);
        lo = minPt(lo, tail.a, cols);
        lo = minPt(lo, tail.b, cols);
        var hi = maxPt(head.a, head.b, cols);
        hi = maxPt(hi, tail.a, cols);
        hi = maxPt(hi, tail.b, cols);
        self.a = lo;
        self.b = hi;
    }

    pub fn sameCell(self: State) bool {
        return self.a.col == self.b.col and self.a.row == self.b.row;
    }

    pub fn bounds(self: State, cols: u16) struct { lo: Point, hi: Point } {
        if (self.a.idx(cols) <= self.b.idx(cols)) return .{ .lo = self.a, .hi = self.b };
        return .{ .lo = self.b, .hi = self.a };
    }

    pub fn contains(self: State, col: u16, row: u16, cols: u16) bool {
        if (!self.on) return false;
        const b = self.bounds(cols);
        const i = Point.idx(.{ .col = col, .row = row }, cols);
        return i >= b.lo.idx(cols) and i <= b.hi.idx(cols);
    }

    pub fn coversRow(self: State, row: u16, cols: u16) bool {
        if (!self.on) return false;
        const b = self.bounds(cols);
        return row >= b.lo.row and row <= b.hi.row;
    }

    pub fn overlapsRows(self: State, start: u16, end: u16, cols: u16) bool {
        if (!self.on or start >= end) return false;
        const b = self.bounds(cols);
        return b.lo.row < end and b.hi.row >= start;
    }
};

pub fn spanAt(screen: *const Term.Screen, col: u16, row: u16, kind: Kind) State {
    const p = clampPoint(screen, col, row);
    return switch (kind) {
        .cell => cellAt(p.col, p.row),
        .word => wordAt(screen, p.col, p.row),
        .line => lineAt(screen, p.row),
    };
}

fn clampPoint(screen: *const Term.Screen, col: u16, row: u16) Point {
    return .{
        .col = @min(col, screen.cols -| 1),
        .row = @min(row, screen.rows -| 1),
    };
}

fn minPt(p: Point, q: Point, cols: u16) Point {
    return if (p.idx(cols) <= q.idx(cols)) p else q;
}

fn maxPt(p: Point, q: Point, cols: u16) Point {
    return if (p.idx(cols) >= q.idx(cols)) p else q;
}

pub fn wordAt(screen: *const Term.Screen, col: u16, row: u16) State {
    const line = screen.rowCells(row);
    const c = @min(col, screen.cols -| 1);
    if (line.len == 0) return .{ .on = true, .a = .{ .col = 0, .row = row }, .b = .{ .col = 0, .row = row } };
    if (!isWord(line[c].codepoint)) {
        return cellAt(c, row);
    }
    var l = c;
    var r = c;
    while (l > 0 and isWord(line[l - 1].codepoint)) l -= 1;
    while (r + 1 < line.len and isWord(line[r + 1].codepoint)) r += 1;
    return .{
        .on = true,
        .a = .{ .col = l, .row = row },
        .b = .{ .col = r, .row = row },
    };
}

pub fn lineAt(screen: *const Term.Screen, row: u16) State {
    const last = screen.cols -| 1;
    return .{
        .on = true,
        .a = .{ .col = 0, .row = row },
        .b = .{ .col = last, .row = row },
    };
}

pub fn cellAt(col: u16, row: u16) State {
    const p = Point{ .col = col, .row = row };
    return .{ .on = true, .a = p, .b = p };
}

pub fn copyAlloc(allocator: std.mem.Allocator, screen: *const Term.Screen, sel: State) std.mem.Allocator.Error![]u8 {
    if (!sel.on or screen.cols == 0 or screen.rows == 0) return allocator.alloc(u8, 0);
    const b = sel.bounds(screen.cols);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var row = b.lo.row;
    while (row <= b.hi.row) : (row += 1) {
        if (row != b.lo.row) try out.append(allocator, '\n');
        const line = screen.rowCells(row);
        const start: u16 = if (row == b.lo.row) b.lo.col else 0;
        const stop: u16 = if (row == b.hi.row) b.hi.col else screen.cols - 1;
        try appendLine(allocator, &out, line, start, stop);
        if (row == b.hi.row) break;
    }
    return out.toOwnedSlice(allocator);
}

fn appendLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const Term.Cell, start: u16, stop: u16) std.mem.Allocator.Error!void {
    if (line.len == 0 or start > stop) return;
    const last: u16 = @intCast(@min(@as(usize, stop), line.len - 1));
    const first: u16 = @min(start, last);
    var end: i32 = last;
    while (end >= first) : (end -= 1) {
        const cp = line[@intCast(end)].codepoint;
        if (cp != 0 and cp != ' ') break;
    }
    if (end < first) return;
    var c: u16 = first;
    const lim: u16 = @intCast(end);
    while (c <= lim) : (c += 1) {
        const cp = line[c].codepoint;
        if (cp == 0) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch {
            try out.append(allocator, '?');
            continue;
        };
        try out.appendSlice(allocator, buf[0..n]);
    }
}

fn isWord(cp: u21) bool {
    if (cp == 0 or cp == ' ') return false;
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
    return true;
}

fn putLine(screen: *Term.Screen, row: u16, text: []const u8) void {
    const line = screen.grid().rowSlice(row, screen.cols);
    const n = @min(text.len, line.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        line[i].codepoint = text[i];
    }
}

test "bounds and contains" {
    var sel: State = .{};
    sel.begin(2, 1);
    sel.extend(5, 2);
    try std.testing.expect(sel.contains(2, 1, 8));
    try std.testing.expect(sel.contains(0, 2, 8));
    try std.testing.expect(sel.contains(5, 2, 8));
    try std.testing.expect(!sel.contains(1, 1, 8));
    try std.testing.expect(!sel.contains(6, 2, 8));
    try std.testing.expect(sel.coversRow(1, 8));
    try std.testing.expect(sel.coversRow(2, 8));
    try std.testing.expect(!sel.coversRow(0, 8));
}

test "copyAlloc trims trailing spaces and joins rows" {
    var vt = try Term.VtState.init(std.testing.allocator, 8, 2, 4, &.{});
    defer vt.deinit();
    putLine(&vt, 0, "hello   ");
    putLine(&vt, 1, "wo rld  ");
    var sel: State = .{};
    sel.begin(0, 0);
    sel.extend(7, 1);
    const text = try copyAlloc(std.testing.allocator, &vt, sel);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello\nwo rld", text);
}

test "word and line grab" {
    var vt = try Term.VtState.init(std.testing.allocator, 12, 1, 2, &.{});
    defer vt.deinit();
    putLine(&vt, 0, "ab_cd ef!");
    var sel: State = .{};
    sel.grab(&vt, 3, 0, .word);
    try std.testing.expectEqual(@as(u16, 0), sel.a.col);
    try std.testing.expectEqual(@as(u16, 4), sel.b.col);
    sel.drag(&vt, 7, 0);
    const text = try copyAlloc(std.testing.allocator, &vt, sel);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ab_cd ef", text);
    sel.grab(&vt, 2, 0, .line);
    try std.testing.expectEqual(@as(u16, 0), sel.a.col);
    try std.testing.expectEqual(@as(u16, 11), sel.b.col);
}
