const std = @import("std");
const xtra = @import("zig-xtra");

const Bar = struct {
    allocator: std.mem.Allocator,
    bar_data: *u32,

    fn init(allocator: std.mem.Allocator) !Bar {
        const data = try allocator.create(u32);
        data.* = 10;

        return .{
            .allocator = allocator,
            .bar_data = data,
        };
    }

    // Always declare deinit as pub
    pub fn deinit(self: *Bar) void {
        // We need to deinitialize pointers explicitly
        xtra.raii.auto.destroy(self.allocator, self.bar_data);
        xtra.raii.auto.selfCleanup(self);
    }
};

const Foo = struct {
    bar: Bar,
    foo_data: *u32,

    fn init(allocator: std.mem.Allocator) !Foo {
        const data = try allocator.create(u32);
        data.* = 20;

        return .{
            .bar = try Bar.init(allocator),
            .foo_data = data,
        };
    }

    // Always declare deinit as pub
    pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
        // We need to deinitialize pointers explicitly
        xtra.raii.auto.destroy(allocator, self.foo_data);

        // Cleanup will take care of deinitializing `bar` field, because it is an owned struct
        xtra.raii.auto.externalCleanup(allocator, self);
    }
};

test "raii - example" {
    var foo: Foo = try Foo.init(std.testing.allocator);
    defer foo.deinit(std.testing.allocator);

    // No memory leaks
}
