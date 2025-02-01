const std = @import("std");

const raiiExample = @import("raii-example.zig");

comptime {
    std.testing.refAllDecls(@This());
}
