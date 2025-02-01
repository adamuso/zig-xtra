//! Allows for duplicating (deep cloning) objects using `dupe` pattern.

const std = @import("std");
const helpers = @import("helpers.zig");

/// Type of the function returned by `dupePtrFn`
pub const DupePtr = *const fn (allocator: std.mem.Allocator, value: *const anyopaque) anyerror!*anyopaque;

/// Type of the function returned by `dupeSliceFn`
pub fn DupeSlice(comptime T: type) type {
    return *const fn (allocator: std.mem.Allocator, value: []const T) anyerror![]T;
}

/// Type of the function returned by `dupeFn`
pub fn Dupe(comptime T: type) type {
    return *const fn (allocator: std.mem.Allocator, value: T) anyerror!T;
}

pub const Error = error{
    DupeIsNotSupported,
};

/// Create a duplicate of the `value`. This function will try to create a deep clone of the
/// object. If value is a pointer or slice, new memory will be allocated and pointed object
/// will be duped. If value is a tuple then this function will iterate through all fields
/// and copy them recursively using dupe function. If a field is a struct, union, enum or
/// opaque and has `dupe` function, then it will be used to dupe an object. When no `dupe`
/// function is available then `value` is returned as a result (and this can create a shallow
/// copy).
///
/// Copied object should implement `dupe` function with an `allocator` as a parameter.
pub fn dupe(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    return try dupeFn(T)(allocator, value);
}

/// Returns a function which can be used to dupe an object using an allocator for specified type.
pub fn dupeFn(comptime T: type) Dupe(T) {
    return struct {
        fn dupeImpl(allocator: std.mem.Allocator, value: T) !T {
            switch (@typeInfo(T)) {
                .pointer => |v| if (v.size == .slice) {
                    return try dupeSlice(@TypeOf(value[0]), allocator, value);
                } else {
                    return try dupePtr(@TypeOf(value.*), allocator, value);
                },
                .@"struct" => |v| if (v.is_tuple) {
                    var result: T = undefined;

                    inline for (@typeInfo(T).@"struct".fields) |field| {
                        const FieldType = @TypeOf(@field(value, field.name));

                        if (field.is_comptime) {
                            @field(result, field.name) = @field(value, field.name);
                            continue;
                        }

                        if (helpers.isPointer(FieldType)) {
                            @field(result, field.name) = @field(value, field.name);
                        } else {
                            @field(result, field.name) =
                                try dupe(FieldType, allocator, @field(value, field.name));
                        }
                    }

                    return result;
                } else {
                    if (@hasDecl(T, "dupe") and @typeInfo(@TypeOf(T.dupe)).@"fn".params.len == 2) {
                        return try value.dupe(allocator);
                    }
                },
                .@"union", .@"enum", .@"opaque" => {
                    if (@hasDecl(T, "dupe") and @typeInfo(@TypeOf(T.dupe)).@"fn".params.len == 2) {
                        return try value.dupe(allocator);
                    }
                },
                else => return value,
            }

            return value;
        }
    }.dupeImpl;
}

pub fn noDupe(comptime T: type) Dupe(T) {
    return &struct {
        fn do(_: std.mem.Allocator, _: T) Error!*T {
            return Error.DupeIsNotSupported;
        }
    }.do;
}

pub fn dupePtr(comptime T: type, allocator: std.mem.Allocator, value: *const T) !*T {
    return @alignCast(@ptrCast(try dupePtrFn(T)(allocator, value)));
}

pub fn dupePtrFn(comptime T: type) DupePtr {
    return struct {
        fn dupePtrImpl(allocator: std.mem.Allocator, value: *const anyopaque) !*anyopaque {
            const new_value = try allocator.create(T);
            new_value.* = try dupe(T, allocator, @as(*const T, @alignCast(@ptrCast(value))).*);
            return new_value;
        }
    }.dupePtrImpl;
}

pub fn noDupePtr(_: std.mem.Allocator, _: *const anyopaque) !*anyopaque {
    return Error.DupeIsNotSupported;
}

pub fn dupeSlice(comptime T: type, allocator: std.mem.Allocator, value: []const T) ![]T {
    return try dupeSliceFn(T)(allocator, value);
}

pub fn dupeSliceFn(comptime T: type) DupeSlice(T) {
    return struct {
        fn dupeSliceImpl(allocator: std.mem.Allocator, value: []const T) ![]T {
            const new_value = try allocator.dupe(T, value);

            for (new_value, 0..) |*item, i| {
                const ItemType = @TypeOf(value[0]);

                if (helpers.isPointer(ItemType)) {
                    item.* = value[i];
                } else {
                    item.* = try dupe(ItemType, allocator, value[i]);
                }
            }

            return new_value;
        }
    }.dupeSliceImpl;
}

pub fn noDupeSlice(_: std.mem.Allocator, _: []const anyopaque) ![]anyopaque {
    return Error.DupeIsNotSupported;
}

pub fn default(comptime Self: type) fn (self: Self, allocator: std.mem.Allocator) anyerror!Self {
    return struct {
        fn do(self: Self, allocator: std.mem.Allocator) !Self {
            var copy: Self = undefined;

            inline for (@typeInfo(Self).@"struct".fields) |field| {
                @field(copy, field.name) = try dupe(field.type, allocator, @field(self, field.name));
            }

            return copy;
        }
    }.do;
}

test "Basic duplication" {
    const a: u32 = 10;
    const b = try dupe(u32, std.testing.allocator, a);

    try std.testing.expectEqual(a, b);

    const c = [_]u32{ 1, 2, 3 };
    const d = try dupe([]const u32, std.testing.allocator, &c);
    defer std.testing.allocator.free(d);

    try std.testing.expectEqualDeep(&c, d);

    const e: struct { u32, []const u8, f32 } = .{ 10, "asd", 20.0 };
    const f = try dupe(@TypeOf(e), std.testing.allocator, e);

    try std.testing.expectEqualDeep(e, f);
}

test "Struct default copy" {
    const Foo = struct {
        allocator: std.mem.Allocator,
        foo_data: *u32,

        fn init(allocator: std.mem.Allocator, value: u32) !@This() {
            const data = try allocator.create(u32);
            data.* = value;

            return .{
                .allocator = allocator,
                .foo_data = data,
            };
        }

        pub const dupe = default(@This());

        fn deinit(self: @This()) void {
            self.allocator.destroy(self.foo_data);
        }
    };

    const Bar = struct {
        foo: Foo,
        bar_data: *u32,

        fn init(allocator: std.mem.Allocator, value: u32) !@This() {
            const data = try allocator.create(u32);
            data.* = value;

            return .{
                .foo = try .init(allocator, value * 2),
                .bar_data = data,
            };
        }

        pub const dupe = default(@This());

        fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.destroy(self.bar_data);
            self.foo.deinit();
        }
    };

    const foo: Foo = try .init(std.testing.allocator, 10);
    const foo2 = try foo.dupe(std.testing.allocator);

    defer foo.deinit();
    defer foo2.deinit();

    const bar: Bar = try .init(std.testing.allocator, 10);
    const bar2 = try bar.dupe(std.testing.allocator);

    defer bar.deinit(std.testing.allocator);
    defer bar2.deinit(std.testing.allocator);

    try std.testing.expectEqual(bar.bar_data.*, bar2.bar_data.*);
    try std.testing.expectEqual(bar.foo.foo_data.*, bar2.foo.foo_data.*);
    try std.testing.expect(bar.bar_data != bar2.bar_data);
    try std.testing.expect(bar.foo.foo_data != bar2.foo.foo_data);
}
