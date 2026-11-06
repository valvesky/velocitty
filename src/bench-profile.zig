//! Opt-in predicate instrumentation for the benchmark executable.
const bench = @import("bench.zig");
pub const main = bench.main;
pub const obsolescenceSpanSample = bench.benchSpanSample;
pub const obsolescencePrefixSample = bench.benchPrefixSample;
