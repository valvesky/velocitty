//! ZT is a lightning-fast cross-platform terminal multiplexor.
//!
//! Bytes in, pixels out. Standalone, daemon, or attach.

const std = @import("std");

pub const CircBuffer = @import("circbuffer.zig").CircBuffer;
pub const Preparse = @import("preparse.zig");
pub const Runs = @import("runs.zig");
pub const Term = @import("term.zig");
pub const Scheme = Term.Scheme;
pub const Config = @import("scheme.zig").Config;
pub const parseConfig = @import("scheme.zig").parse;
pub const parseScheme = @import("scheme.zig").parseScheme;
pub const Draw = @import("draw.zig");
pub const Type = @import("type.zig");
pub const Events = @import("events.zig");
pub const Select = @import("select.zig");
pub const Kitty = @import("kitty.zig");


pub const Engine = @import("engine.zig").Engine;
pub const Platform = @import("platform.zig").Platform;
pub const Loop = @import("loop.zig").Loop;
pub const Debug = @import("debug.zig");

pub const Error = error{
    InvalidArg,
    InvalidProtocol,
    Unimplemented,
} || std.mem.Allocator.Error;

test {
    _ = CircBuffer;
    _ = Preparse;
    _ = Runs;
    _ = Term;
    _ = @import("scheme.zig");
    _ = Draw;
    _ = Type;
    _ = Events;
    _ = Select;
    _ = Kitty;
    _ = Daemon;
    _ = Mux;
    _ = Engine;
    _ = Platform;
    _ = Loop;
    _ = Debug;
}
