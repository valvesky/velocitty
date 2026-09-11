//! Cell-stream selection and copy from the visible grid.

const std = @import("std");
const Term = @import("term.zig");

pub const Point = struct {
    col: u16 = 0,
    row: u16 = 0,

    pub fn idx(self: Point, cols: u16) u32 {
        return @as(u32, self.row) * cols + self.col;
    }
};

pub const State = struct {
    on: bool = false,
    a: Point = .{},
    b: Point = .{},

    pub fn clear(self: *State) void {
        self.* = .{};
    }

    pub fn begin(self: *State, col: u16, row: u16) void {
        const p = Point{ .col = col, .row = row };
        self.* = .{ .on = true, .a = p, .b = p };
    }

    pub fn extend(self: *State, col: u16, row: u16) void {
        if (!self.on) {
            self.begin(col, row);
            return;
        }
        self.b = .{ .col = col, .row = row };
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

