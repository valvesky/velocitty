//! libxev loop. Waits on events. 1/hz timer only after EAGAIN.

const std = @import("std");
const xev = @import("xev");

/// The loop struct exists so that it's easier to understand
/// and test very specific behaviour of VT.
pub const Loop = struct {

    allocator: std.mem.Allocator,
    pool: *xev.ThreadPool,
    inner: xev.Loop,
    timer: xev.Timer,
    timer_c: xev.Completion = .{},
    userdata: ?*anyopaque = null,
    on_frame: ?*const fn (*Loop) void = null,
    armed: bool = false,
    stopped: bool = false,

};
