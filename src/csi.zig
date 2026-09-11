///| CSI stands for Control Sequence Introducer
///! It's one of the most common ANSI escape sequences.
///! 
///! Used for styling, cursor movement, bracketed paste,
///! mode switching, deleting lines and more.
///! 
///! Invoked via ESC[

const std = @import("std");
const assert = std.debug.assert;
const Term = @import("term.zig").Term;

pub const CsiSeq = struct {
    intermediate: u8 = 0,
    seq: []const u8 = "",
    params: []u16 = &.{},
    final: u8,
    private: u8 = 0,

    /// Returns valid CSI sequences, otherwise null.
    pub fn parse(seq: []const u8, param_buf: []u16) ?CsiSeq {
        if (seq.len < 3) return null; // Ran out of bytes.
        assert(seq[0] == 0x1b and seq[1] == '['); // Must be an actual CSI.

        // Branchless detection of private prefix byte 
        const c2 = seq[2];
        const is_priv: u8 = @intFromBool((c2 & 0xFC) == 0x3C);
        const priv = c2 * is_priv;

        var i: usize = 2 + is_priv;
        var n: usize = 0;
        var val: u16 = 0;
        var have = false;
        var intermediate: u8 = 0;

        while (i + 1 < seq.len) : (i += 1) {
            const c = seq[i];
            switch (c) {
                '0'...'9' => {
                    have = true;
                    val = val *% 10 +% (c - '0');
                },
                ';', ':' => {
                    if (n < param_buf.len) param_buf[n] = if (have) val else 0;
                    n += 1;
                    val = 0;
                    have = false;
                },
                0x20...0x2f => {
                    intermediate = c;
                },
                else => return null,
            }
        }

        if (have or n > 0 or seq.len > 3 + is_priv) {
            if (n < param_buf.len) param_buf[n] = if (have) val else 0;
            n += 1;
        }

        return .{
            .intermediate = intermediate,
            .seq = seq,
            .final = seq[seq.len - 1],
            .params = param_buf[0..@min(n, param_buf.len)],
            .private = priv,
        };
    }

    /// Only accepts valid CSI sequences.
    /// Valid as in "well-structured" not necessarily
    /// those we implement.
    ///
    /// Applies the sequence to the terminal.
    pub fn apply(self: CsiSeq, term: *Term) void {
        assert(self.seq.len >= 3);
        assert(self.seq[0] == 0x1b and self.seq[1] == '[');
        assert(self.final >= 0x40 and self.final <= 0x7e);

        const params = self.params;
        const final = self.final;
        const inter = self.intermediate;
        const priv = self.private;

        const p0 = if (params.len > 0) params[0] else 0;
        const n1: u16 = if (p0 == 0) 1 else p0;

        // NOTE(vasco):
        // Do not be afraid to extend this switch statement.
        // Yes, it's long.
        // Yes, it edits terminal state directly.
        // That's the point.

        switch (final) {
            // --- Queries ---
            'c' => switch (priv) {
                0 => term.respond("\x1b[?62;c"),
                '>' => term.respond("\x1b[>0;10;0c"),
                else => {},
            },

            'n' => switch (priv) {
                0, '?' => if (p0 == 6) {
                    var buf: [32]u8 = undefined;
                    const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                        term.grid().cursor.row + 1,
                        term.grid().cursor.col + 1,
                    }) catch return;
                    term.respond(resp);
                },
                else => {},
            },
            
            // --- SGR ---
            'm' => switch (priv) {
                '>' => term.setModifyKeys(params),
                0 => self.sgr(term),
                else => {},
            },

            // --- Modes & Extensions ---
            'h' => switch (priv) {
                '?' => term.setPrivate(params, true),
                0 => term.setMode(params, true),
                else => {},
            },
            'l' => switch (priv) {
                '?' => term.setPrivate(params, false),
                0 => term.setMode(params, false),
                else => {},
            },
            's' => switch (priv) {
                '?' => term.savePrivate(params),
                0 => term.saveCursor(),
                else => {},
            },
            'r' => switch (priv) {
                '?' => term.restorePrivate(params),
                0 => term.decstbm(p0, if (params.len > 1) params[1] else 0),
                else => {},
            },

            // --- Resets ---
            'p' => if (inter == '!') term.softReset(),
            'q' => if (inter == ' ' or inter == 0) term.setCursorStyle(p0),

            // --- Standard Cursor Movement ---
            'H', 'f' => if (priv == 0) term.cup(n1, if (params.len > 1 and params[1] != 0) params[1] else 1),
            'J' => if (priv == 0) term.ed(p0),
            'K' => if (priv == 0) term.el(p0),
            'A' => if (priv == 0) term.cursorUp(n1),
            'B', 'e' => if (priv == 0) term.cursorDown(n1),
            'C', 'a' => if (priv == 0) {
                const g = term.grid();
                g.cursor.col = @min(g.cursor.col + n1, term.cols - 1);
            },
            'D' => if (priv == 0) term.grid().cursor.col -|= n1,
            'E' => if (priv == 0) {
                term.cursorDown(n1);
                term.grid().cursor.col = 0;
            },
            'F' => if (priv == 0) {
                term.cursorUp(n1);
                term.grid().cursor.col = 0;
            },
            'G', '`' => if (priv == 0) term.grid().cursor.col = @min(n1 -| 1, term.cols - 1),
            'd' => if (priv == 0) term.cup(n1, term.grid().cursor.col + 1),

            // --- Editing ---
            '@' => if (priv == 0) term.ich(n1),
            'P' => if (priv == 0) term.dch(n1),
            'X' => if (priv == 0) term.ech(n1),
            'L' => if (priv == 0) term.il(n1),
            'M' => if (priv == 0) term.dl(n1),
            'S' => if (priv == 0) term.regionScrollUp(n1),
            'T' => if (priv == 0) term.regionScrollDown(n1),
            'u' => if (priv == 0) term.restoreCursor(),
            'b' => if (priv == 0) term.rep(n1),

            // --- Tabs ---
            'I' => if (priv == 0) {
                var k: u16 = 0;
                while (k < n1) : (k += 1) {
                    const g = term.grid();
                    g.cursor.col += 8 - (g.cursor.col % 8);
                    if (g.cursor.col >= term.cols) g.cursor.col = term.cols - 1;
                }
            },
            'Z' => if (priv == 0) {
                var k: u16 = 0;
                while (k < n1) : (k += 1) {
                    const g = term.grid();
                    const col = g.cursor.col;
                    const prev = if (col == 0) 0 else col - 1;
                    g.cursor.col = prev - (prev % 8);
                }
            },

            else => {},
        }
    }

    fn sgr(self: CsiSeq, term: *Term) void {
        const params = self.params;
        const screen = term.screen();

        if (params.len == 0) {
            screen.resetPen();
            return;
        }

        var i: usize = 0;
        while (i < params.len) {
            const p = params[i];
            i += 1;
            switch (p) {
                0 => screen.resetPen(),
                1 => screen.grid().attrs.bold = true,
                2 => screen.grid().attrs.dim = true,
                3 => screen.grid().attrs.italic = true,
                4 => screen.grid().attrs.underline = true,
                5, 6 => screen.grid().attrs.blink = true,
                7 => screen.grid().attrs.inverse = true,
                8 => screen.grid().attrs.hidden = true,
                9 => screen.grid().attrs.strikethrough = true,
                21 => screen.grid().attrs.underline = true,
                22 => {
                    screen.grid().attrs.bold = false;
                    screen.grid().attrs.dim = false;
                },
                23 => screen.grid().attrs.italic = false,
                24 => screen.grid().attrs.underline = false,
                25, 26 => screen.grid().attrs.blink = false,
                27 => screen.grid().attrs.inverse = false,
                28 => screen.grid().attrs.hidden = false,
                29 => screen.grid().attrs.strikethrough = false,
                30...37 => screen.grid().fg = screen.scheme.palette[p - 30],
                39 => screen.grid().fg = screen.scheme.fg,
                40...47 => screen.grid().bg = screen.scheme.palette[p - 40],
                49 => screen.grid().bg = screen.scheme.bg,
                38 => i += screen.takeColor(params[i..], true),
                48 => i += screen.takeColor(params[i..], false),
                90...97 => screen.grid().fg = screen.scheme.palette[p - 90 + 8],
                100...107 => screen.grid().bg = screen.scheme.palette[p - 100 + 8],
                else => {},
            }
        }
    }
};


