const std = @import("std");

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vec_len, u8);
const Mask = std.meta.Int(.unsigned, vec_len);

comptime {
    std.debug.assert(vec_len <= 64);
}

pub const ScanOp = enum {
    less_than,
    greater_than,
    equal,
    equal_either,
    in_range,  // inclusive
    out_range, // exclusive
};

pub inline fn skipToLowerThan(slice: []const u8, threshold: u8) u32 {
    return skipUntil(.less_than, slice, threshold, 0);
}

pub inline fn skipToGreaterThan(slice: []const u8, threshold: u8) u32 {
    return skipUntil(.greater_than, slice, threshold, 0);
}

pub inline fn skipEqual(slice: []const u8, target: u8) u32 {
    return skipUntil(.equal, slice, target, 0);
}

pub inline fn skipEqualEither(slice: []const u8, target_a: u8, target_b: u8) u32 {
    return skipUntil(.equal_either, slice, target_a, target_b);
}

pub inline fn skipInRange(slice: []const u8, min: u8, max: u8) u32 {
    return skipUntil(.in_range, slice, min, max);
}

pub inline fn skipOutRange(slice: []const u8, min: u8, max: u8) u32 {
    return skipUntil(.out_range, slice, min, max);
}

pub inline fn skipUntil(
    comptime op: ScanOp,
    slice: []const u8,
    threshold: u8,
    secondary_threshold: u8,
) u32 {
    var offset: u32 = 0;
    const slice_len: u32 = @intCast(slice.len);

    const target_vec: Vec = @splat(threshold);
    const sec_vec: Vec = @splat(secondary_threshold);

    while (offset + vec_len <= slice_len) {
        const chunk: Vec = slice[offset..][0..vec_len].*;

        const matches: @Vector(vec_len, bool) = switch (op) {
            .less_than => chunk < target_vec,
            .greater_than => chunk > target_vec,
            .equal => chunk == target_vec,
            .equal_either => (chunk == target_vec) | (chunk == sec_vec),
            .in_range => (chunk >= target_vec) & (chunk <= sec_vec),
            .out_range => (chunk < target_vec) | (chunk > sec_vec),
        };

        const mask: Mask = @bitCast(matches);
        if (mask != 0) {
            return offset + @ctz(mask);
        }

        offset += vec_len;
    }

    while (offset < slice_len) {
        const b = slice[offset];
        const matched = switch (op) {
            .less_than => b < threshold,
            .greater_than => b > threshold,
            .equal => b == threshold,
            .equal_either => b == threshold or b == secondary_threshold,
            .in_range => b >= threshold and b <= secondary_threshold,
            .out_range => b < threshold or b > secondary_threshold,
        };

        if (matched) break;
        offset += 1;
    }

    return offset;
}
