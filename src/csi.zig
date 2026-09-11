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
    final: u8 = 0, // 0 indicates an invalid stub sequence
    private: u8 = 0,

    // LUTs for character classification
    const CharKind = enum(u3) { digit, sep, inter, final, invalid };

    const CHAR_MAP: [256]CharKind = initMap: {
        var map = [_]CharKind{.invalid} ** 256;
        for ('0'..'9' + 1) |c| map[c] = .digit;
        map[';'] = .sep;
        map[':'] = .sep;
        for (0x20..0x2F + 1) |c| map[c] = .inter;
        for (0x40..0x7E + 1) |c| map[c] = .final;
        break :initMap map;
    };

    pub fn parse(seq: []const u8, param_buf: []u16) CsiSeq {
        // Stub default returned on early failure
        const STUB = CsiSeq{ .final = 0, .seq = seq };

        const valid_header = @intFromBool(
            seq.len >= 3 and seq[0] == 0x1b and seq[1] == '['
        );
        if (valid_header == 0) return STUB;

        // Branchless private byte identification ('?', '>', '=', '<')
        const c2 = seq[2];
        const is_priv: u8 = @intFromBool(c2 >= 0x3C and c2 <= 0x3F);
        const priv = c2 * is_priv;

        var i: usize = 2 + is_priv;
        var n: usize = 0;
        var val: u16 = 0;
        var have: u16 = 0;
        var intermediate: u8 = 0;
        var is_valid: u8 = 1;

        const max_body = seq.len - 1; // Exclude the final byte

        while (i < max_body) : (i += 1) {
            const c = seq[i];
            const kind = CHAR_MAP[c];

            // Branchless state updates via mask/mul
            const is_dig = @intFromBool(kind == .digit);
            const is_sep = @intFromBool(kind == .sep);
            const is_mid = @intFromBool(kind == .inter);
            const is_bad = @intFromBool(kind == .invalid or kind == .final);

            // Invalidate if unexpected final/invalid character occurs early in body
            is_valid &= (is_bad ^ 1);

            // Accumulate digits
            have |= is_dig;
            val = (val *% 10 +% (c -% '0')) * is_dig + val * (is_dig ^ 1);

            // Push param on delimiter
            if (is_sep != 0) {
                if (n < param_buf.len) param_buf[n] = val;
                n += 1;
                val = 0;
                have = 0;
            }

            // Capture intermediate byte
            intermediate = c * is_mid + intermediate * (is_mid ^ 1);
        }

        const push_last = (have | @intFromBool(n > 0) | @intFromBool(seq.len > 3 + is_priv));
        if (push_last != 0 and n < param_buf.len) {
            param_buf[n] = val;
            n += 1;
        }

        const final_byte = seq[seq.len - 1];
        const valid_final = @intFromBool(CHAR_MAP[final_byte] == .final);
        const ok = is_valid & valid_final;

        return .{
            .intermediate = intermediate * ok,
            .seq = seq,
            .final = final_byte * ok,
            .params = param_buf[0..(@min(n, param_buf.len) * ok)],
            .private = priv * ok,
        };
    }

    pub fn apply(self: CsiSeq, term: *Term) void {

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

        switch (priv) {
            // --- Standard ANSI / VT100 Sequences ---
            0 => switch (final) {
                0 => return,

                // Queries & Reports
                'c' => term.respond("\x1b[?62;c"),
                'n' => if (p0 == 6) {
                    var buf: [32]u8 = undefined;
                    const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                        term.grid().cursor.row + 1,
                        term.grid().cursor.col + 1,
                    }) catch return;
                    term.respond(resp);
                },

                // Modes & Styling
                'm' => self.sgr(term),
                'h' => term.setMode(params, true),
                'l' => term.setMode(params, false),
                's' => term.saveCursor(),
                'r' => term.decstbm(p0, if (params.len > 1) params[1] else 0),

                // Resets & Cursor Properties
                'p' => switch (inter) {
                    '!' => term.softReset(),
                    else => {},
                },
                'q' => switch (inter) {
                    0, ' ' => term.setCursorStyle(p0),
                    else => {},
                },

                // Cursor Movement
                'H', 'f' => term.cup(n1, if (params.len > 1 and params[1] != 0) params[1] else 1),
                'J' => term.ed(p0),
                'K' => term.el(p0),
                'A' => term.cursorUp(n1),
                'B', 'e' => term.cursorDown(n1),
                'C', 'a' => {
                    const g = term.grid();
                    g.cursor.col = @min(g.cursor.col + n1, term.cols - 1);
                },
                'D' => term.cursor().col -|= n1,
                'E' => {
                    term.cursorDown(n1);
                    term.grid().cursor.col = 0;
                },
                'F' => {
                    term.cursorUp(n1);
                    term.grid().cursor.col = 0;
                },
                'G', '`' => term.grid().cursor.col = @min(n1 -| 1, term.cols - 1),
                'd' => term.cup(n1, term.grid().cursor.col + 1),

                // Text Editing & Scrolling
                '@' => term.ich(n1),
                'P' => term.dch(n1),
                'X' => term.ech(n1),
                'L' => term.il(n1),
                'M' => term.dl(n1),
                'S' => term.regionScrollUp(n1),
                'T' => term.regionScrollDown(n1),
                'u' => term.restoreCursor(),
                'b' => term.rep(n1),

                // Tabs
                'I' => {
                    var k: u16 = 0;
                    while (k < n1) : (k += 1) {
                        const g = term.grid();
                        g.cursor.col += 8 - (g.cursor.col % 8);
                        if (g.cursor.col >= term.cols) g.cursor.col = term.cols - 1;
                    }
                },
                'Z' => {
                    var k: u16 = 0;
                    while (k < n1) : (k += 1) {
                        const g = term.grid();
                        const col = g.cursor.col;
                        const prev = if (col == 0) 0 else col - 1;
                        g.cursor.col = prev - (prev % 8);
                    }
                },

                else => {},
            },

            // --- DEC Private Extensions ('?') ---
            '?' => switch (final) {
                'n' => if (p0 == 6) {
                    var buf: [32]u8 = undefined;
                    const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                        term.grid().cursor.row + 1,
                        term.grid().cursor.col + 1,
                    }) catch return;
                    term.respond(resp);
                },
                'h' => term.setPrivate(params, true),
                'l' => term.setPrivate(params, false),
                's' => term.savePrivate(params),
                'r' => term.restorePrivate(params),
                else => {},
            },

            // --- Secondary Device / Modifier Extensions ('>') ---
            '>' => switch (final) {
                'c' => term.respond("\x1b[>0;10;0c"),
                'm' => term.setModifyKeys(params),
                else => {},
            },

            else => {},
        }
    }

    fn applyStandard(self: CsiSeq, term: *Term) void {
        const params = self.params;
        const p0 = if (params.len > 0) params[0] else 0;
        const n1: u16 = if (p0 == 0) 1 else p0;

        switch (self.final) {
            0 => return,
            'c' => term.respond("\x1b[?62;c"),
            'n' => if (p0 == 6) respondCursorPosition(term),
            'm' => self.sgr(term),
            'h' => term.setMode(params, true),
            'l' => term.setMode(params, false),
            's' => term.saveCursor(),
            'r' => term.decstbm(p0, if (params.len > 1) params[1] else 0),
            'p' => if (self.intermediate == '!') term.softReset(),
            'q' => if (self.intermediate == 0 or self.intermediate == ' ') term.setCursorStyle(p0),
            'H', 'f' => term.cup(n1, if (params.len > 1 and params[1] != 0) params[1] else 1),
            'J' => term.ed(p0),
            'K' => term.el(p0),
            'A' => term.cursorUp(n1),
            'B', 'e' => term.cursorDown(n1),
            'C', 'a' => {
                const g = term.grid();
                g.cursor.col = @min(g.cursor.col + n1, term.cols - 1);
            },
            'D' => term.cursor().col -|= n1,
            'E' => {
                term.cursorDown(n1);
                term.grid().cursor.col = 0;
            },
            'F' => {
                term.cursorUp(n1);
                term.grid().cursor.col = 0;
            },
            'G', '`' => term.grid().cursor.col = @min(n1 -| 1, term.cols - 1),
            'd' => term.cup(n1, term.grid().cursor.col + 1),

            // Text Editing & Scrolling
            '@' => term.ich(n1),
            'P' => term.dch(n1),
            'X' => term.ech(n1),
            'L' => term.il(n1),
            'M' => term.dl(n1),
            'S' => term.regionScrollUp(n1),
            'T' => term.regionScrollDown(n1),
            'u' => term.restoreCursor(),
            'b' => term.rep(n1),
            'I' => stepTabForward(term, n1),
            'Z' => stepTabBackward(term, n1),
            else => {},
        }
    }

    fn applyDecPrivate(self: CsiSeq, term: *Term) void {
        const params = self.params;
        const p0 = if (params.len > 0) params[0] else 0;

        switch (self.final) {
            'n' => if (p0 == 6) respondCursorPosition(term),
            'h' => term.setPrivate(params, true),
            'l' => term.setPrivate(params, false),
            's' => term.savePrivate(params),
            'r' => term.restorePrivate(params),
            else => {},
        }
    }

    fn applySecondary(self: CsiSeq, term: *Term) void {
        switch (self.final) {
            'c' => term.respond("\x1b[>0;10;0c"),
            'm' => term.setModifyKeys(self.params),
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

    fn respondCursorPosition(term: *Term) void {
        var buf: [32]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
            term.grid().cursor.row + 1,
            term.grid().cursor.col + 1,
        }) catch return;
        term.respond(resp);
    }

    fn stepTabForward(term: *Term, count: u16) void {
        var k: u16 = 0;
        while (k < count) : (k += 1) {
            const g = term.grid();
            g.cursor.col += 8 - (g.cursor.col % 8);
            if (g.cursor.col >= term.cols) g.cursor.col = term.cols - 1;
        }
    }

    fn stepTabBackward(term: *Term, count: u16) void {
        var k: u16 = 0;
        while (k < count) : (k += 1) {
            const g = term.grid();
            const col = g.cursor.col;
            const prev = if (col == 0) 0 else col - 1;
            g.cursor.col = prev - (prev % 8);
        }
    }

};
