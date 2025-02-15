const std = @import("std");

pub const closureExample = @import("closure-example.zig");
pub const duplicationExample = @import("duplication-example.zig");
pub const equalityExample = @import("equality-example.zig");
pub const raiiExample = @import("raii-example.zig");
pub const enumerableExample = @import("enumerable-example.zig");

comptime {
    std.testing.refAllDecls(@This());
}
