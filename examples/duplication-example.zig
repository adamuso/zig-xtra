const std = @import("std");
const xtra = @import("zig-xtra");

const Bar = struct {
    allocator: std.mem.Allocator,
    bar_data: *u32,

    fn init(allocator: std.mem.Allocator, value: u32) !Bar {
        const data = try allocator.create(u32);
        data.* = value;

        return .{
            .allocator = allocator,
            .bar_data = data,
        };
    }

    // Using dupe default implementation
    pub const dupe = xtra.duplication.default(@This());
    pub const deinit = xtra.raii.default(@This(), "allocator", .{"bar_data"});
};

const Foo = struct {
    bar: Bar,
    foo_data: *u32,

    fn init(allocator: std.mem.Allocator, value: u32) !Foo {
        const data = try allocator.create(u32);
        data.* = value;

        return .{
            .bar = try Bar.init(allocator, value * 2),
            .foo_data = data,
        };
    }

    // Creating custom dupe implementation
    pub fn dupe(self: Foo, allocator: std.mem.Allocator) !Foo {
        return .{
            .bar = try self.bar.dupe(allocator),
            .foo_data = try xtra.duplication.dupe(*u32, allocator, self.foo_data),
        };
    }

    pub const deinit = xtra.raii.defaultWithAllocator(@This(), .{"foo_data"});
};

test {
    var foo: Foo = try Foo.init(std.testing.allocator, 20);
    defer foo.deinit(std.testing.allocator);

    try std.testing.expectEqual(20, foo.foo_data.*);

    var foo2 = try foo.dupe(std.testing.allocator);
    defer foo2.deinit(std.testing.allocator);

    try std.testing.expectEqual(40, foo2.bar.bar_data.*);
    // No memory leaks
}
