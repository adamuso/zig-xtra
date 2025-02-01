const std = @import("std");

inline fn canHaveDecls(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .@"union" => true,
        .@"enum" => true,
        .@"opaque" => true,
        else => false,
    };
}

inline fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |v| v.size == .slice,
        else => false,
    };
}

inline fn isStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        else => false,
    };
}

inline fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |v| v.is_tuple,
        else => false,
    };
}

inline fn isPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        else => false,
    };
}

pub const Free = *const fn (std.mem.Allocator, *const anyopaque) void;
pub const Deinit = *const fn (std.mem.Allocator, *anyopaque) void;
pub const Destroy = *const fn (std.mem.Allocator, *anyopaque) void;

pub fn noFree(_: std.mem.Allocator, _: *const anyopaque) void {}
pub fn noDeinit(_: std.mem.Allocator, _: *anyopaque) void {}
pub fn noDestroy(_: std.mem.Allocator, _: *anyopaque) void {}

pub inline fn free(comptime T: type, allocator: std.mem.Allocator, value: *const T) void {
    freeFn(T)(allocator, @ptrCast(value));
}

pub inline fn freeFn(comptime T: type) Free {
    return struct {
        fn destroyImpl(allocator: std.mem.Allocator, value: *const anyopaque) void {
            if (isSlice(T)) {
                allocator.free(@as(*const T, @alignCast(@ptrCast(value))).*);
            } else {
                allocator.destroy(@as(*const T, @alignCast(@ptrCast(value))));
            }
        }
    }.destroyImpl;
}

pub inline fn deinit(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    comptime if (!canHaveDecls(T) and !isSlice(T)) {
        return;
    };

    deinitFn(T)(allocator, @ptrCast(value));
}

pub inline fn deinitFn(comptime T: type) Deinit {
    comptime if (!canHaveDecls(T) and !isSlice(T)) {
        return noDeinit;
    };

    return struct {
        fn deinitImpl(allocator: std.mem.Allocator, value: *anyopaque) void {
            const t_value: *T = @alignCast(@ptrCast(value));

            if (isSlice(T)) {
                cleanup(T, allocator, t_value);
            } else if (isTuple(T)) {
                cleanup(T, allocator, t_value);
            } else if (canHaveDecls(T) and @hasDecl(T, "deinit") and @typeInfo(@TypeOf(T.deinit)).@"fn".params.len == 1) {
                t_value.deinit();
            } else if (canHaveDecls(T) and @hasDecl(T, "deinit") and @typeInfo(@TypeOf(T.deinit)).@"fn".params.len == 2) {
                t_value.deinit(allocator);
            } else if (isStruct(T)) {
                // TODO: Should we go deeper when struct does not have its own deinit?
                cleanup(T, allocator, t_value);
            }
        }
    }.deinitImpl;
}

pub inline fn destroy(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    destroyFn(T)(allocator, @ptrCast(value));
}

pub inline fn destroyFn(comptime T: type) Destroy {
    return struct {
        fn deinitAndDestroyImpl(allocator: std.mem.Allocator, value: *anyopaque) void {
            deinit(T, allocator, @alignCast(@ptrCast(value)));
            free(T, allocator, @alignCast(@ptrCast(value)));
        }
    }.deinitAndDestroyImpl;
}

pub inline fn cleanup(comptime T: type, allocator: std.mem.Allocator, self: *T) void {
    switch (@typeInfo(T)) {
        .@"struct" => |v| inline for (v.fields) |field| {
            if (isPointer(field.type)) {
                continue;
            }

            deinit(@TypeOf(@field(self, field.name)), allocator, &@field(self, field.name));
        },
        .pointer => |v| if (v.size == .slice) {
            const slice = self.*;
            const SliceItem: type = @TypeOf(slice[0]);

            if (isPointer(SliceItem)) {
                return;
            }

            for (slice) |*item| {
                deinit(SliceItem, allocator, item);
            }
        },
        else => {},
    }
}

pub const auto = struct {
    pub inline fn free(allocator: std.mem.Allocator, value: anytype) void {
        freeFn(@TypeOf(value.*))(allocator, @ptrCast(value));
    }

    pub inline fn deinit(allocator: std.mem.Allocator, value: anytype) void {
        deinitFn(@TypeOf(value.*))(allocator, @ptrCast(value));
    }

    pub inline fn destroy(allocator: std.mem.Allocator, value: anytype) void {
        destroyFn(@TypeOf(value.*))(allocator, @ptrCast(value));
    }

    pub inline fn selfCleanup(value: anytype) void {
        cleanup(@TypeOf(value.*), value.allocator, value);
    }

    pub inline fn externalCleanup(allocator: std.mem.Allocator, value: anytype) void {
        cleanup(@TypeOf(value.*), allocator, value);
    }
};

// Tests
test "Check if compile time generated functions are equal or different based on types" {
    try std.testing.expect(freeFn(u32) == freeFn(u32));
    try std.testing.expect(freeFn(i32) != freeFn(u32));
}

test "Free a pointer" {
    const value = try std.testing.allocator.create(u32);

    free(u32, std.testing.allocator, value);
}

test "Free a slice" {
    const value = try std.testing.allocator.alloc(u32, 10);

    free([]u32, std.testing.allocator, &value);
}

const InnerTestData = struct {
    allocator: std.mem.Allocator,
    allocated_float: *f32,

    fn init(allocator: std.mem.Allocator) !InnerTestData {
        return .{
            .allocator = allocator,
            .allocated_float = try allocator.create(f32),
        };
    }

    // Deinit schema: run cleanup first, then deallocate all data allocated in 'init'
    fn deinit(self: *InnerTestData) void {
        auto.selfCleanup(self);
        auto.destroy(self.allocator, self.allocated_float);
    }
};

const TestData = struct {
    allocated_u32: *u32,
    inner: InnerTestData,

    fn init(allocator: std.mem.Allocator) !TestData {
        return .{
            .allocated_u32 = try allocator.create(u32),
            .inner = try InnerTestData.init(allocator),
        };
    }

    fn deinit(self: *TestData, allocator: std.mem.Allocator) void {
        auto.externalCleanup(allocator, self);
        auto.destroy(allocator, self.allocated_u32);
    }
};

test "Deinit a pointer to struct with allocated data" {
    var value = try TestData.init(std.testing.allocator);
    value.deinit(std.testing.allocator);
}

test "Deinit and free a pointer to struct with allocated data" {
    const value = try std.testing.allocator.create(TestData);
    value.* = try .init(std.testing.allocator);

    auto.destroy(std.testing.allocator, value);
}

test "Deinit and free a structs slice with allocated data" {
    var value = try std.testing.allocator.alloc(TestData, 10);

    for (value) |*item| {
        item.* = try .init(std.testing.allocator);
    }

    auto.destroy(std.testing.allocator, &value);
}

test "Deinit and free an ArrayList with structs inside" {
    var value = std.ArrayList(TestData).init(std.testing.allocator);

    for (0..10) |_| {
        (try value.addOne()).* = try .init(std.testing.allocator);
    }

    auto.deinit(std.testing.allocator, &value.items);
    auto.deinit(value.allocator, &value);
}
