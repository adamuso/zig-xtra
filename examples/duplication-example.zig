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

    pub fn dupe(self: Bar, allocator: std.mem.Allocator) !Bar {
        return .{
            .allocator = allocator,
            .bar_data = try xtra.duplication.dupe(*u32, allocator, self.bar_data),
        };
    }

    pub fn deinit(self: *Bar) void {
        xtra.raii.auto.destroy(self.allocator, self.bar_data);
        xtra.raii.auto.selfCleanup(self);
    }
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

    pub fn dupe(self: Foo, allocator: std.mem.Allocator) !Foo {
        return .{
            .bar = try self.bar.dupe(allocator),
            .foo_data = try xtra.duplication.dupe(*u32, allocator, self.foo_data),
        };
    }

    pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
        xtra.raii.auto.destroy(allocator, self.foo_data);
        xtra.raii.auto.externalCleanup(allocator, self);
    }
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
