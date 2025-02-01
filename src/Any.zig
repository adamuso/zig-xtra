//! Any represents an owned pointer which can be of any type. Under the hood Any keeps
//! the pointer for a value and a vtable with functions that can deinit and destroy the
//! pointer. The type held by any can be changed using a `set` function. Any has additional
//! checks when accessing the value that will fail if a user requests different type than
//! Any is currenly holding.
//!
//! Any does not support directly copying itself. Assigning Any to another Any will result in
//! memory leak because memory in overriden Any will not be freed.

const std = @import("std");
const raii = @import("raii.zig");
const helpers = @import("helpers.zig");

const Any = @This();

const VTable = struct {
    destroy: *const raii.Destroy,
    deinit: *const raii.Deinit,
};

pub const Error = error{
    DifferentType,
};

pub fn create(comptime T: type, allocator: std.mem.Allocator, value: T) !Any {
    const result = try allocator.create(T);
    result.* = value;

    return init(T, result);
}

pub fn fromOwned(comptime T: type, value: *T) Any {
    return init(T, value);
}

fn init(comptime T: type, value: *T) Any {
    return .{
        .ptr = @ptrCast(value),
        .vtable = createVTable(T),
    };
}

ptr: *anyopaque,
vtable: *const VTable,

pub fn set(self: *Any, comptime T: type, allocator: std.mem.Allocator, value: T) !void {
    self.destroyData(allocator);

    const result = try allocator.create(T);
    result.* = value;

    self.ptr = @ptrCast(result);
    self.vtable = createVTable(T);
}

pub fn replace(self: Any, comptime T: type, allocator: std.mem.Allocator, value: T) Error!void {
    if (self.vtable.destroy != raii.destroyFn(T)) {
        return Error.DifferentType;
    }

    self.deinitData(allocator);
    @as(*T, @alignCast(@ptrCast(self.ptr))).* = value;
}

pub fn get(self: Any, comptime T: type) Error!*T {
    if (self.vtable.destroy != raii.destroyFn(T)) {
        return Error.DifferentType;
    }

    return @as(*T, @alignCast(@ptrCast(self.ptr)));
}

pub fn has(self: Any, comptime T: type) bool {
    return self.vtable.destroy == raii.destroyFn(T);
}

pub fn deinit(self: Any, allocator: std.mem.Allocator) void {
    self.destroyData(allocator);
}

fn deinitData(self: Any, allocator: std.mem.Allocator) void {
    self.vtable.deinit(allocator, self.ptr);
}

fn destroyData(self: Any, allocator: std.mem.Allocator) void {
    self.vtable.destroy(allocator, self.ptr);
}

fn createVTable(comptime T: type) *const VTable {
    return comptime v: {
        break :v &.{
            .destroy = raii.destroyFn(T),
            .deinit = raii.deinitFn(T),
        };
    };
}

test "Any holding an u32" {
    var any: Any = try .create(u32, std.testing.allocator, 1234);
    defer any.deinit(std.testing.allocator);

    try std.testing.expectError(Error.DifferentType, any.get(i32));
    try std.testing.expectEqual(1234, (try any.get(u32)).*);
}

test "Any holding a struct" {
    const TestData = struct {
        data: []usize,

        fn init(allocator: std.mem.Allocator) !@This() {
            const data = try allocator.alloc(usize, 10);

            for (data, 0..) |*d, i| {
                d.* = i;
            }

            return .{ .data = data };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            raii.auto.destroy(allocator, &self.data);
        }
    };

    var any: Any = try .create(TestData, std.testing.allocator, try TestData.init(std.testing.allocator));
    defer any.deinit(std.testing.allocator);

    try std.testing.expectError(Error.DifferentType, any.get(i32));
    try std.testing.expectEqual(5, (try any.get(TestData)).data[5]);
}

test "Any holding Any holding a struct" {
    const TestData = struct {
        data: *u32,

        fn init(allocator: std.mem.Allocator) !@This() {
            const data = try allocator.create(u32);
            data.* = 1234;

            return .{ .data = data };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            raii.auto.destroy(allocator, self.data);
        }
    };

    var any: Any = try .create(
        Any,
        std.testing.allocator,
        try Any.create(TestData, std.testing.allocator, try TestData.init(std.testing.allocator)),
    );
    defer any.deinit(std.testing.allocator);

    try std.testing.expectError(Error.DifferentType, any.get(i32));
    try std.testing.expectEqual(1234, (try (try any.get(Any)).get(TestData)).data.*);
}

test "Replacing value and setting different type in Any" {
    const TestData = struct {
        data: *u32,

        fn init(allocator: std.mem.Allocator, value: u32) !@This() {
            const data = try allocator.create(u32);
            data.* = value;

            return .{ .data = data };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            raii.auto.destroy(allocator, self.data);
        }
    };

    const TestData2 = struct {
        data: []usize,

        fn init(allocator: std.mem.Allocator) !@This() {
            const data = try allocator.alloc(usize, 10);

            for (data, 0..) |*d, i| {
                d.* = i;
            }

            return .{ .data = data };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            raii.auto.destroy(allocator, &self.data);
        }
    };

    var any: Any = try .create(TestData, std.testing.allocator, try TestData.init(std.testing.allocator, 1234));
    defer any.deinit(std.testing.allocator);

    try std.testing.expectError(Error.DifferentType, any.get(TestData2));
    try std.testing.expectEqual(1234, (try any.get(TestData)).data.*);

    // Replace will error when different type is passed, previous data will be deinitialized but pointer will not be destroyed in this case
    try any.replace(TestData, std.testing.allocator, try TestData.init(std.testing.allocator, 4321));

    try std.testing.expect(any.has(TestData));
    try std.testing.expectEqual(4321, (try any.get(TestData)).data.*);

    // When set is used, previous data will be deinitialized and heap pointer will be destroyed before overriding it with new data
    try any.set(TestData2, std.testing.allocator, try TestData2.init(std.testing.allocator));

    try std.testing.expectError(Error.DifferentType, any.get(TestData));
    try std.testing.expectEqual(5, (try any.get(TestData2)).data[5]);
}
