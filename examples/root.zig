const std = @import("std");

pub const raiiExample = @import("raii-example.zig");
pub const duplicationExample = @import("duplication-example.zig");

comptime {
    std.testing.refAllDecls(@This());
}
