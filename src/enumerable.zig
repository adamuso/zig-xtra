const std = @import("std");
const Any = @import("Any.zig");
const duplication = @import("duplication.zig");
const closure = @import("closure.zig");
const raii = @import("raii.zig");
const _iter = @import("iterator.zig");
const helpers = @import("helpers.zig");
pub const Iterator = _iter.Iterator;

inline fn AttachError(comptime Result: type) type {
    return switch (@typeInfo(Result)) {
        .error_union => |v| anyerror!v.payload,
        else => anyerror!Result,
    };
}

inline fn AttachErrorIf(comptime Result: type, comptime conidtion: bool) type {
    return if (conidtion) AttachError(Result) else Result;
}

inline fn DetachError(comptime Result: type) type {
    return switch (@typeInfo(Result)) {
        .error_union => |v| v.payload,
        else => Result,
    };
}

inline fn MakeConst(comptime Result: type) type {
    return switch (@typeInfo(Result)) {
        .pointer => |v| v.child,
        else => Result,
    };
}

inline fn derefIfNeeded(value: anytype) MakeConst(@TypeOf(value)) {
    return switch (@typeInfo(@TypeOf(value))) {
        .pointer => value.*,
        else => value,
    };
}

inline fn errorOrUnrechable(value: anytype) !switch (@typeInfo(@TypeOf(value))) {
    .error_union => anyerror,
    else => noreturn,
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .error_union => value,
        else => unreachable,
    };
}

inline fn hasError(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .error_union => true,
        else => false,
    };
}

const EnumerableOperation = union(enum) {
    Identity: void,
    Map: struct {
        func: closure.AnyClosure,
        has_index: bool,
    },
    Filter: struct {
        func: closure.AnyClosure,
        has_error: bool,
    },
    OrderBy: struct {
        allocator: std.mem.Allocator,
        func: closure.AnyClosure,
    },
};

pub fn Enumerator(comptime Result: type) type {
    return Enumerable(Result, Result);
}

pub fn Enumerable(comptime Result: type, comptime Source: type) type {
    return struct {
        const Self = @This();
        const Iter = Iterator(AttachError(Result));

        const result_has_error: bool = switch (@typeInfo(Result)) {
            .error_union => true,
            else => false,
        };

        const can_result_be_deinitialized_without_an_allocator =
            helpers.canBeDeinitializedWithoutAllocator(@typeInfo(Iter.Result).error_union.payload);

        const IteratorImplementation = union(enum) {
            internal: Iterator(Source),
            external: *Iterator(Source),
            external_copy: struct {
                allocator: std.mem.Allocator,
                iterator: *Iterator(Source),
            },

            fn reset(self: IteratorImplementation) void {
                switch (self) {
                    .internal => |v| {
                        var copy = v;
                        copy.reset();
                    },
                    .external => |v| v.reset(),
                    .external_copy => |v| v.iterator.reset(),
                }
            }

            fn deinit(self: IteratorImplementation) void {
                switch (self) {
                    .internal => |v| v.deinit(),
                    .external => {},
                    .external_copy => |v| {
                        v.iterator.deinit();
                        v.allocator.destroy(v.iterator);
                    },
                }
            }

            fn index(self: IteratorImplementation) usize {
                return switch (self) {
                    .internal => |v| v.index(),
                    .external => |v| v.index(),
                    .external_copy => |v| v.iterator.index(),
                };
            }
        };

        const IteratorContext = struct {
            pub fn next(self: *const Self, _: *Iter) ?Iter.Result {
                const it_impl = self.prev_iterator catch |err| {
                    return err;
                };
                var it_copy = switch (it_impl) {
                    .internal => |v| v,
                    else => null,
                };
                const it = if (it_copy != null) &it_copy.? else switch (it_impl) {
                    .external => |v| v,
                    .external_copy => |v| v.iterator,
                    else => unreachable,
                };

                const Item = @TypeOf(switch (@typeInfo(@TypeOf(it.next().?))) {
                    .error_union => try it.next().?,
                    else => it.next().?,
                });

                const OrderByContext = struct {
                    list: std.ArrayList(Item),
                    current: usize = 0,

                    pub const deinit = raii.defaultWithoutAllocator(@This(), .{});
                };

                while (it.next()) |errorOrItem| {
                    const item = switch (@typeInfo(@TypeOf(errorOrItem))) {
                        .error_union => try errorOrItem,
                        else => errorOrItem,
                    };

                    switch (self.operation) {
                        .Identity => return if (Result == Source) item else unreachable,
                        .Map => |v| if (v.has_index) {
                            return (v.func.toOpaque(fn (Item, usize) Result) catch @panic("These functions must match"))
                                .invoke(item, it.index() - 1);
                        } else {
                            return (v.func.toOpaque(fn (Item) Result) catch @panic("These funtions must match"))
                                .invoke(item);
                        },
                        .Filter => |v| {
                            if (v.has_error) {
                                if (!try (v.func.toOpaque(fn (Item) anyerror!bool) catch @panic("These funtions must match")).invoke(item)) {
                                    continue;
                                }
                            } else {
                                if (!(v.func.toOpaque(fn (Item) bool) catch @panic("These funtions must match")).invoke(item)) {
                                    continue;
                                }
                            }

                            return if (Iter.Result == Source) item else unreachable;
                        },
                        .OrderBy => |v| {
                            if (self.context == null) {
                                @panic("OrderBy requires enumerable to have a context");
                            }

                            const enumerable_context = self.context.?;

                            if (enumerable_context.* == null) {
                                enumerable_context.* = try Any.create(
                                    OrderByContext,
                                    v.allocator,
                                    .{ .list = std.ArrayList(Item).init(v.allocator) },
                                );
                            }

                            const context = try enumerable_context.*.?.get(OrderByContext);

                            (try context.list.addOne()).* = try duplication.dupe(Item, v.allocator, item);
                            continue;
                        },
                    }
                }

                switch (self.operation) {
                    .OrderBy => |v| {
                        if (self.context == null) {
                            @panic("OrderBy requires enumerable to have a context");
                        }

                        const enumerable_context = self.context.?;

                        if (enumerable_context.* == null) {
                            @panic("OrderBy requires enumerable context to be instantiated when iterating on ordered sequence");
                        }

                        const context = try enumerable_context.*.?.get(OrderByContext);

                        const opaque_func = try v.func.toOpaque(fn (a: Item, b: Item) bool);
                        std.mem.sort(Item, context.list.items, opaque_func, @TypeOf(opaque_func).invoke);

                        if (context.current < context.list.items.len) {
                            context.current += 1;
                            return if (Iter.Result == Source) context.list.items[context.current - 1] else unreachable;
                        }

                        for (context.list.items) |*item| {
                            raii.deinit(Item, v.allocator, item);
                        }

                        enumerable_context.*.?.deinit(v.allocator);
                        enumerable_context.* = null;
                    },
                    else => {},
                }

                return null;
            }

            pub fn reset(self: *const Self, _: *const Iter) void {
                if (self.prev_iterator) |v| {
                    v.reset();
                } else |_| {}
            }

            pub fn deinit(self: *const Self) void {
                if (self.prev_iterator) |v| {
                    v.deinit();
                } else |_| {}
            }

            pub fn index(self: *const Self, _: *const Iter) usize {
                if (self.prev_iterator) |iter| {
                    return iter.index();
                } else |_| {
                    return 0;
                }
            }
        };

        pub fn init(prev_iterator: *Iterator(Source)) @This() {
            return .{
                .prev_iterator = .{ .external = prev_iterator },
                .operation = .{ .Identity = {} },
            };
        }

        pub fn initConst(prev_iterator: Iterator(Source)) @This() {
            return .{
                .prev_iterator = .{ .internal = prev_iterator },
                .operation = .{ .Identity = {} },
            };
        }

        pub fn initCopy(allocator: std.mem.Allocator, prev_iterator: Iterator(Source)) @This() {
            const x = allocator.create(Iterator(Source)) catch unreachable;
            x.* = prev_iterator;

            return .{
                .prev_iterator = .{ .external_copy = .{ .allocator = allocator, .iterator = x } },
                .operation = .{ .Identity = {} },
            };
        }

        fn chain(prev_iterator: anyerror!Iterator(Source), operation: EnumerableOperation) @This() {
            return .{
                .prev_iterator = if (prev_iterator) |v| .{ .internal = v } else |err| err,
                .operation = operation,
            };
        }

        fn chainWithContext(allocator: std.mem.Allocator, prev_iterator: anyerror!Iterator(Source), operation: EnumerableOperation) !@This() {
            const context = try allocator.create(?Any);
            context.* = null;

            return .{
                .prev_iterator = if (prev_iterator) |v| .{ .internal = v } else |err| err,
                .operation = operation,
                .context = context,
            };
        }

        prev_iterator: anyerror!IteratorImplementation,
        operation: EnumerableOperation,
        context: ?*?Any = null,

        // Operations
        pub fn map(self: *const @This(), function: anytype) Enumerable(@TypeOf(function).Return, Iter.Result) {
            const NewResult = @TypeOf(function).Return;
            const NewSource = Iter.Result;

            return Enumerable(NewResult, NewSource).chain(self.iterator(), .{
                .Map = .{
                    .func = function.closure,
                    .has_index = @typeInfo(@TypeOf(function).Function).@"fn".params.len == 2,
                },
            });
        }

        pub fn mapTo(
            self: *const @This(),
            comptime MapResult: type,
            function: closure.OpaqueClosure(fn (item: DetachError(Iter.Result)) MapResult),
        ) Enumerable(MapResult, Iter.Result) {
            const NewSource = Iter.Result;

            return Enumerable(MapResult, NewSource).chain(self.iterator(), .{
                .Map = .{
                    .func = function.closure,
                    .has_index = false,
                },
            });
        }

        pub fn mapToWithIndex(
            self: *const @This(),
            comptime MapResult: type,
            function: closure.OpaqueClosure(fn (item: DetachError(Iter.Result), index: usize) MapResult),
        ) Enumerable(MapResult, Iter.Result) {
            const NewSource = Iter.Result;

            return Enumerable(MapResult, NewSource).chain(self.iterator(), .{
                .Map = .{
                    .func = function.closure,
                    .has_index = true,
                },
            });
        }

        pub fn filter(self: *const @This(), function: anytype) Enumerable(Result, Iter.Result) {
            return Enumerable(Result, Iter.Result).chain(self.iterator(), .{
                .Filter = .{
                    .func = function.closure,
                    .has_error = switch (@typeInfo(@TypeOf(function).Return)) {
                        .error_union => true,
                        else => false,
                    },
                },
            });
        }

        pub fn orderBy(
            self: *const @This(),
            allocator: std.mem.Allocator,
            lessThanFn: closure.OpaqueClosure(fn (Result, Result) bool),
        ) !Enumerable(Result, Iter.Result) {
            return try Enumerable(Result, Iter.Result).chainWithContext(allocator, self.iterator(), .{
                .OrderBy = .{
                    .allocator = allocator,
                    .func = lessThanFn.closure,
                },
            });
        }

        // Finalizers
        pub fn toArrayList(self: @This(), allocator: std.mem.Allocator) !std.ArrayList(Result) {
            var list = std.ArrayList(Result).init(allocator);
            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            errdefer list.deinit();
            defer it.deinit();

            while (it.next()) |v| {
                (try list.addOne()).* = try v;
            }

            return list;
        }

        pub fn toArray(self: @This(), allocator: std.mem.Allocator) ![]const Result {
            var list = try self.toArrayList(allocator);
            return list.toOwnedSlice();
        }

        pub fn destroyAll(self: @This(), allocator: std.mem.Allocator) AttachErrorIf(void, result_has_error) {
            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            defer it.deinit();

            while (it.next()) |v| {
                const value = v catch |err| return errorOrUnrechable(err);

                raii.destroy(@TypeOf(value.*), allocator, value);
            }
        }

        pub fn deinitAll(
            self: @This(),
            // allocator: if (can_result_be_deinitialized_without_an_allocator) void else std.mem.Allocator,
            allocator: std.mem.Allocator,
        ) AttachErrorIf(void, result_has_error) {
            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            defer it.deinit();

            while (it.next()) |v| {
                const value = v catch |err| return errorOrUnrechable(err);

                // if (can_result_be_deinitialized_without_an_allocator) {
                //     auto_deinit.autoDeinitWithoutAllocator(@TypeOf(value), value);
                // } else {
                //     auto_deinit.autoDeinit(@TypeOf(value), value, allocator);
                // }

                raii.deinit(@TypeOf(value.*), allocator, value);
            }
        }

        pub fn deinitAndDestroyAll(self: @This(), allocator: std.mem.Allocator) AttachErrorIf(void, result_has_error) {
            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            defer it.deinit();

            while (it.next()) |v| {
                const value = v catch |err| return errorOrUnrechable(err);

                raii.deinitAndDestroy(@TypeOf(value.*), allocator, value);
            }
        }

        pub fn forEach(self: @This(), func: closure.OpaqueClosure(fn (Result) void)) AttachErrorIf(void, result_has_error) {
            defer func.deinit();

            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            defer it.deinit();

            while (it.next()) |v| {
                func.invoke(v catch |err| return errorOrUnrechable(err));
            }
        }

        pub fn first(self: @This()) AttachErrorIf(?Result, result_has_error) {
            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            defer it.deinit();

            while (it.next()) |v| {
                return v;
            }

            return null;
        }

        pub fn last(self: @This()) AttachErrorIf(?Result, result_has_error) {
            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            defer it.deinit();

            var copy: ?Result = null;

            while (it.next()) |v| {
                copy = v catch |err| return errorOrUnrechable(err);
            }

            return copy;
        }

        pub fn findEql(self: @This(), other: MakeConst(DetachError(Result))) AttachErrorIf(?Result, result_has_error) {
            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            defer it.deinit();

            while (it.next()) |v| {
                const item = v catch |err| return errorOrUnrechable(err);

                if (std.meta.hasMethod(@TypeOf(item), "eql")) {
                    if (item.eql(other)) {
                        return item;
                    }
                } else {
                    if (std.meta.eql(derefIfNeeded(item), other)) {
                        return item;
                    }
                }
            }

            return null;
        }

        pub fn findIndexEql(self: @This(), other: MakeConst(DetachError(Result))) AttachErrorIf(?usize, result_has_error) {
            var self_copy = self;
            var it = self_copy.iterator();
            it.reset();
            defer it.deinit();

            while (it.next()) |v| {
                const item = v catch |err| return errorOrUnrechable(err);

                if (std.meta.hasMethod(@TypeOf(item), "eql")) {
                    if (item.eql(other)) {
                        return it.index() - 1;
                    }
                } else {
                    if (std.meta.eql(derefIfNeeded(item), other)) {
                        return it.index() - 1;
                    }
                }
            }

            return null;
        }

        pub fn iterator(self: *const @This()) Iter {
            return Iter{
                .ptr = self,
                .vtable = comptime &.{
                    .next = @ptrCast(&IteratorContext.next),
                    .reset = @ptrCast(&IteratorContext.reset),
                    .deinit = @ptrCast(&IteratorContext.deinit),
                    .index = @ptrCast(&IteratorContext.index),
                },
            };
        }
    };
}

pub fn fromSlice(
    allocator: std.mem.Allocator,
    comptime T: type,
    slice: @typeInfo(@TypeOf(Iterator(T).fromSlice)).@"fn".params[0].type.?,
) Enumerable(T, T) {
    return Enumerable(T, T).initCopy(allocator, Iterator(T).fromSlice(slice));
}

pub fn fromIterator(comptime T: type, iterator: *Iterator(T)) Enumerable(T, T) {
    return Enumerable(T, T).init(iterator);
}

pub fn fromExternalIterator(comptime T: type, iterator: *T) Enumerable(
    _iter.AnyIteratorResult(T),
    _iter.AnyIteratorResult(T),
) {
    return Enumerable(
        _iter.AnyIteratorResult(T),
        _iter.AnyIteratorResult(T),
    ).initConst(
        Iterator(_iter.AnyIteratorResult(T)).fromIterator(T, iterator),
    );
}

pub fn fromAnyIterator(iterator: anytype) @TypeOf(fromExternalIterator(@TypeOf(iterator.*), iterator)) {
    return fromExternalIterator(@TypeOf(iterator.*), iterator);
}

test "Enumerable" {
    const allocator = std.testing.allocator;

    var iterator = Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6 });
    var x = Enumerable(u32, u32).init(&iterator);

    const y = try x.filter(closure.fromStruct(struct {
        pub fn filter(_: void, item: u32) bool {
            return item % 2 == 0;
        }
    }, {}).toOpaque()).map(closure.fromStruct(struct {
        pub fn map(_: void, item: u32) f32 {
            return @as(f32, @floatFromInt(item)) * 2;
        }
    }, {}).toOpaque()).map(closure.fromStruct(struct {
        pub fn map(_: void, item: f32) f32 {
            return item * 4;
        }
    }, {}).toOpaque()).toArray(allocator);

    defer allocator.free(y);

    try std.testing.expectEqualDeep(@as([]const f32, &.{ 16, 32, 48 }), y);
}

test "Enumerable with error" {
    const TestError = error{Test};
    const allocator = std.testing.allocator;

    var x = Enumerable(u32, u32)
        .initCopy(allocator, Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6 }));

    const y = x.filter(closure.fromStruct(struct {
        pub fn filter(_: void, item: u32) bool {
            return item % 2 == 0;
        }
    }, {}).toOpaque()).map(closure.fromStruct(struct {
        pub fn map(_: void, _: u32) !f32 {
            return TestError.Test;
        }
    }, {}).toOpaque()).toArray(allocator);

    defer {
        if (y) |v| {
            allocator.free(v);
        } else |_| {}
    }

    try std.testing.expectError(TestError.Test, y);
}

test "Enumerable with possible error in .map" {
    const allocator = std.testing.allocator;

    var x = Enumerable(u32, u32)
        .initCopy(allocator, Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6 }));

    const y = try x.filter(closure.fromStruct(struct {
        pub fn filter(_: void, item: u32) bool {
            return item % 2 == 0;
        }
    }, {}).toOpaque()).map(closure.fromStruct(struct {
        pub fn map(_: void, item: u32) !f32 {
            return @as(f32, @floatFromInt(item)) * 2;
        }
    }, {}).toOpaque()).map(closure.fromStruct(struct {
        pub fn map(_: void, item: f32) f32 {
            return item * 4;
        }
    }, {}).toOpaque()).toArray(allocator);

    defer allocator.free(y);

    try std.testing.expectEqualDeep(@as([]const f32, &.{ 16, 32, 48 }), y);
}

test "Enumerable with possible error in .filter" {
    const allocator = std.testing.allocator;

    var x = Enumerable(u32, u32)
        .initCopy(allocator, Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6 }));

    const y = try x.filter(closure.fromStruct(struct {
        pub fn filter(_: void, item: u32) anyerror!bool {
            return item % 2 == 0;
        }
    }, {}).toOpaque()).map(closure.fromStruct(struct {
        pub fn map(_: void, item: u32) !f32 {
            return @as(f32, @floatFromInt(item)) * 2;
        }
    }, {}).toOpaque()).map(closure.fromStruct(struct {
        pub fn map(_: void, item: f32) f32 {
            return item * 4;
        }
    }, {}).toOpaque()).toArray(allocator);

    defer allocator.free(y);

    try std.testing.expectEqualDeep(@as([]const f32, &.{ 16, 32, 48 }), y);
}

test "Enumerable allow traversing multiple times" {
    const values: [5]i32 = .{ 2, 4, 6, 8, 10 };
    var iterator = Iterator(i32).fromSlice(&values);
    var enumerable = fromIterator(i32, &iterator);

    var sum: i32 = 0;
    enumerable.forEach(.fromStruct(struct {
        pub fn run(s: *i32, item: i32) void {
            s.* += item;
        }
    }, &sum));

    try std.testing.expectEqual(30, sum);

    var sum2: i32 = 0;
    enumerable.map(closure.fromStruct(struct {
        pub fn map(_: void, item: i32) i32 {
            return item * 2;
        }
    }, {}).toOpaque()).forEach(.fromStruct(struct {
        pub fn run(s: *i32, item: i32) void {
            s.* += item;
        }
    }, &sum2));

    try std.testing.expectEqual(60, sum2);
}

test "Enumerable mapTo" {
    const allocator = std.testing.allocator;

    var iterator = Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6 });
    var x = Enumerable(u32, u32).init(&iterator);

    const y = try x.filter(closure.fromStruct(struct {
        pub fn filter(_: void, item: u32) bool {
            return item % 2 == 0;
        }
    }, {}).toOpaque()).mapTo(f32, .fromStruct(struct {
        pub fn map(_: void, item: u32) f32 {
            return @as(f32, @floatFromInt(item)) * 2;
        }
    }, {})).mapTo(f32, .fromStruct(struct {
        pub fn map(_: void, item: f32) f32 {
            return item * 4;
        }
    }, {})).toArray(allocator);

    defer allocator.free(y);

    try std.testing.expectEqualDeep(@as([]const f32, &.{ 16, 32, 48 }), y);
}

test "Enumerable orderBy" {
    const allocator = std.testing.allocator;

    var iterator = Iterator(u32).fromSlice(&.{ 5, 4, 2, 3, 1, 6 });
    var x = Enumerable(u32, u32).init(&iterator);

    const y = try (try x.orderBy(allocator, .fromStruct(struct {
        pub fn do(_: void, left: u32, right: u32) bool {
            return left < right;
        }
    }, {}))).filter(closure.fromStruct(struct {
        pub fn filter(_: void, item: u32) bool {
            return item % 2 == 0;
        }
    }, {}).toOpaque()).toArray(allocator);

    defer allocator.free(y);

    try std.testing.expectEqualDeep(@as([]const u32, &.{ 2, 4, 6 }), y);
}

test "Enumerable orderBy on structs with allocated data" {
    const Foo = struct {
        data: *u32,

        fn init(allocator: std.mem.Allocator, value: u32) !@This() {
            const data = try allocator.create(u32);
            data.* = value;

            return .{
                .data = data,
            };
        }

        pub const dupe = duplication.default(@This(), .{"data"});
        pub const deinit = raii.defaultWithoutAllocator(@This(), .{"data"});
    };

    const allocator = std.testing.allocator;

    var array = [_]Foo{
        try Foo.init(allocator, 5),
        try Foo.init(allocator, 4),
        try Foo.init(allocator, 2),
        try Foo.init(allocator, 3),
        try Foo.init(allocator, 1),
        try Foo.init(allocator, 6),
    };

    var iterator = Iterator(Foo).fromSlice(&array);

    var x = Enumerable(Foo, Foo).init(&iterator);

    const y = try (try x.filter(closure.fromStruct(struct {
        pub fn filter(_: void, item: Foo) bool {
            return item.data.* % 2 == 0;
        }
    }, {}).toOpaque()).orderBy(allocator, .fromStruct(struct {
        pub fn do(_: void, left: Foo, right: Foo) bool {
            return left.data.* < right.data.*;
        }
    }, {}))).mapTo(u32, .fromStruct(struct {
        pub fn map(_: void, item: Foo) u32 {
            return item.data.*;
        }
    }, {})).toArray(allocator);

    defer allocator.free(y);

    var slice: []Foo = &array;
    raii.deinit([]Foo, allocator, &slice);

    try std.testing.expectEqualDeep(@as([]const u32, &.{ 2, 4, 6 }), y);
}
