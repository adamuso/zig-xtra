const std = @import("std");
const xtra = @import("zig-xtra");

const Bar = struct {
    bar_data: u32,

    fn init(value: u32) Bar {
        return .{
            .bar_data = value,
        };
    }

    // Using eql default implementation
    pub const eql = xtra.equality.default(@This());
    pub const deinit = xtra.raii.defaultWithoutAllocator(@This(), .{});
};

const Foo = struct {
    bar: Bar,
    foo_data: *u32,

    fn init(allocator: std.mem.Allocator, value: u32) !Foo {
        const data = try allocator.create(u32);
        data.* = value;

        return .{
            .bar = Bar.init(value * 2),
            .foo_data = data,
        };
    }

    // Creating custom dupe implementation
    pub fn eql(self: Foo, other: Foo) bool {
        return self.bar.eql(other.bar) and self.foo_data.* == other.foo_data.*;
        // return self.bar.eql(other.bar) and xtra.equality.eql(*u32, self.foo_data, other.foo_data);
    }

    pub const deinit = xtra.raii.defaultWithoutAllocator(@This(), .{"foo_data"});
};

test {
    var foo: Foo = try Foo.init(std.testing.allocator, 20);
    defer foo.deinit(std.testing.allocator);

    var foo2 = try Foo.init(std.testing.allocator, 40);
    defer foo2.deinit(std.testing.allocator);

    var foo3 = try Foo.init(std.testing.allocator, 20);
    defer foo3.deinit(std.testing.allocator);

    try std.testing.expect(!foo.eql(foo2));
    try std.testing.expect(!foo2.eql(foo3));
    try std.testing.expect(foo.eql(foo3));
    try std.testing.expect(!xtra.equality.eql(Foo, foo, foo2));
    try std.testing.expect(!xtra.equality.eql(Foo, foo2, foo3));
    try std.testing.expect(xtra.equality.eql(Foo, foo, foo3));
}
