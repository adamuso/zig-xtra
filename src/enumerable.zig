const std = @import("std");
const Any = @import("Any.zig");
const duplication = @import("duplication.zig");
const closure = @import("closure.zig");
const raii = @import("raii.zig");
const _iter = @import("iterator.zig");
const helpers = @import("helpers.zig");
pub const Iterator = _iter.Iterator;

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

    pub fn dupe(self: *const EnumerableOperation, allocator: std.mem.Allocator) !EnumerableOperation {
        return switch (self.*) {
            .Identity => self.*,
            .Map => |v| .{
                .Map = .{
                    .func = try v.func.dupe(allocator),
                    .has_index = v.has_index,
                },
            },
            .Filter => |v| .{
                .Filter = .{
                    .func = try v.func.dupe(allocator),
                    .has_error = v.has_error,
                },
            },
            .OrderBy => |v| .{
                .OrderBy = .{
                    .allocator = allocator,
                    .func = try v.func.dupe(allocator),
                },
            },
        };
    }
};

pub fn Enumerable(comptime Result: type, comptime Source: type) type {
    return struct {
        const Self = @This();
        const Iter = Iterator(helpers.AttachError(Result));
        const is_internal = helpers.canHaveDecls(Source) and @hasDecl(Source, "iterator");
        const UnwrappedSource = if (is_internal) Source.UnwrappedSource else helpers.AttachError(Source);

        const result_has_error: bool = switch (@typeInfo(Result)) {
            .error_union => true,
            else => false,
        };

        const can_result_be_deinitialized_without_an_allocator =
            helpers.canBeDeinitializedWithoutAllocator(@typeInfo(Iter.Result).error_union.payload);

        const IteratorImplementation = if (is_internal) Source else union(enum) {
            external: *Iterator(Source),
            external_copy: struct {
                allocator: std.mem.Allocator,
                iterator: *Iterator(Source),
            },

            fn reset(self: @This()) void {
                switch (self) {
                    .external => |v| v.reset(),
                    .external_copy => |v| v.iterator.reset(),
                }
            }

            fn deinit(self: @This()) void {
                switch (self) {
                    .external => {},
                    .external_copy => |v| {
                        v.allocator.destroy(v.iterator);
                    },
                }
            }

            fn index(self: @This()) usize {
                return switch (self) {
                    .external => |v| v.index(),
                    .external_copy => |v| v.iterator.index(),
                };
            }
        };

        const IteratorContext = struct {
            pub fn next(self: *const Self, _: *Iter) ?Iter.Result {
                const it_impl = self.prev_source catch |err| {
                    return err;
                };

                var it_copy = if (is_internal) it_impl.iterator() else {};

                const it = blk: {
                    if (is_internal) {
                        break :blk &it_copy;
                    }

                    break :blk switch (it_impl) {
                        .external => |v| v,
                        .external_copy => |v| v.iterator,
                    };
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
                        .Identity => return if (Result == Source or anyerror!Result == Source) item else unreachable,
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

                            return if (Iter.Result == UnwrappedSource) item else unreachable;
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
                            return if (Iter.Result == UnwrappedSource) context.list.items[context.current - 1] else unreachable;
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
                if (is_internal) {
                    if (self.prev_source) |v| {
                        var it = v.iterator();
                        it.reset();
                    } else |_| {}
                    return;
                }

                if (self.prev_source) |v| {
                    v.reset();
                } else |_| {}
            }

            pub fn deinit(self: *const Self) void {
                self.deinit();
            }

            pub fn index(self: *const Self, _: *const Iter) usize {
                if (is_internal) {
                    return if (self.prev_source) |v| v.iterator().index() else |_| 0;
                }

                return if (self.prev_source) |v| v.index() else |_| 0;
            }
        };

        pub fn init(prev_iterator: *Iterator(Source)) @This() {
            return .{
                .prev_source = .{ .external = prev_iterator },
                .operation = .{ .Identity = {} },
            };
        }

        pub fn initCopy(allocator: std.mem.Allocator, prev_iterator: Iterator(Source)) @This() {
            const x = allocator.create(Iterator(Source)) catch unreachable;
            x.* = prev_iterator;

            return .{
                .prev_source = .{ .external_copy = .{ .allocator = allocator, .iterator = x } },
                .operation = .{ .Identity = {} },
            };
        }

        fn chain(
            self: Self,
            comptime NextResult: type,
            operation: EnumerableOperation,
        ) Enumerable(NextResult, Self) {
            return .{
                .prev_source = self,
                .operation = operation,
            };
        }

        fn chainWithContext(
            self: Self,
            comptime NextResult: type,
            allocator: std.mem.Allocator,
            operation: EnumerableOperation,
        ) Enumerable(NextResult, Self) {
            const context = allocator.create(?Any);

            if (context) |v| {
                v.* = null;
            } else |_| {}

            return .{
                .prev_source = if (context) |_| self else |err| err,
                .operation = operation,
                .context = if (context) |v| v else |_| null,
            };
        }

        prev_source: anyerror!IteratorImplementation,
        operation: EnumerableOperation,
        context: ?*?Any = null,

        // Operations
        pub fn map(self: *const Self, function: anytype) Enumerable(@TypeOf(function).Return, Self) {
            return self.chain(@TypeOf(function).Return, .{
                .Map = .{
                    .func = function.closure,
                    .has_index = @typeInfo(@TypeOf(function).Function).@"fn".params.len == 2,
                },
            });
        }

        pub fn mapTo(
            self: *const Self,
            comptime MapResult: type,
            function: closure.OpaqueClosure(fn (item: helpers.DetachError(Iter.Result)) MapResult),
        ) Enumerable(MapResult, Self) {
            return self.chain(MapResult, .{
                .Map = .{
                    .func = function.closure,
                    .has_index = false,
                },
            });
        }

        pub fn mapToWithIndex(
            self: *const Self,
            comptime MapResult: type,
            function: closure.OpaqueClosure(fn (item: helpers.DetachError(Iter.Result), index: usize) MapResult),
        ) Enumerable(MapResult, Self) {
            return self.chain(MapResult, .{
                .Map = .{
                    .func = function.closure,
                    .has_index = true,
                },
            });
        }

        pub fn filter(self: *const Self, function: anytype) Enumerable(Result, Self) {
            return self.chain(Result, .{
                .Filter = .{
                    .func = function.closure,
                    .has_error = switch (@typeInfo(@TypeOf(function).Return)) {
                        .error_union => true,
                        else => false,
                    },
                },
            });
        }

        pub fn filterBy(self: *const Self, function: closure.OpaqueClosure(fn (helpers.DetachError(Result)) bool)) Enumerable(Result, Self) {
            return self.chain(Result, .{
                .Filter = .{
                    .func = function.closure,
                    .has_error = switch (@typeInfo(@TypeOf(function).Return)) {
                        .error_union => true,
                        else => false,
                    },
                },
            });
        }

        pub fn filterByWithError(self: *const Self, function: closure.OpaqueClosure(fn (Result) anyerror!bool)) Enumerable(Result, Self) {
            return self.chain(Result, .{
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
            self: *const Self,
            allocator: std.mem.Allocator,
            lessThanFn: closure.OpaqueClosure(fn (Result, Result) bool),
        ) Enumerable(Result, Self) {
            return self.chainWithContext(Result, allocator, .{
                .OrderBy = .{
                    .allocator = allocator,
                    .func = lessThanFn.closure,
                },
            });
        }

        // Finalizers
        pub fn toArrayList(self: @This(), allocator: std.mem.Allocator) !std.ArrayList(Iter.FinalizerResult) {
            var it = self.iterator();

            return try it.toArrayList(allocator);
        }

        pub fn toArray(self: @This(), allocator: std.mem.Allocator) ![]const Iter.FinalizerResult {
            var list = try self.toArrayList(allocator);
            return list.toOwnedSlice();
        }

        pub fn destroyAll(self: @This(), allocator: std.mem.Allocator) helpers.AttachErrorIf(void, result_has_error) {
            var it = self.iterator();

            return it.destroyAll(allocator);
        }

        pub fn deinitAll(
            self: @This(),
            // allocator: if (can_result_be_deinitialized_without_an_allocator) void else std.mem.Allocator,
            allocator: std.mem.Allocator,
        ) helpers.AttachErrorIf(void, result_has_error) {
            var it = self.iterator();

            return it.deinitAll(allocator);
        }

        pub fn forEach(self: @This(), func: closure.OpaqueClosure(fn (Iter.FinalizerResult) void)) helpers.AttachErrorIf(void, result_has_error) {
            var it = self.iterator();

            return it.forEach(func) catch |err| helpers.errorOrUnrechable(err);
        }

        pub fn first(self: @This()) helpers.AttachErrorIf(?Result, Iter.result_has_error) {
            var it = self.iterator();

            return it.first();
        }

        pub fn last(self: @This()) helpers.AttachErrorIf(?Result, Iter.result_has_error) {
            var it = self.iterator();

            return it.last();
        }

        pub fn findEql(self: @This(), other: helpers.MakeConst(helpers.DetachError(Result))) helpers.AttachErrorIf(?Result, result_has_error) {
            var it = self.iterator();

            return it.findEql(other);
        }

        pub fn findIndexEql(self: @This(), other: helpers.MakeConst(helpers.DetachError(Result))) helpers.AttachErrorIf(?usize, result_has_error) {
            var it = self.iterator();

            return it.findIndexEql(other);
        }

        // Other methods
        pub fn deinit(self: Self) void {
            if (self.context) |context| {
                switch (self.operation) {
                    .OrderBy => |o| {
                        if (context.*) |v| {
                            v.deinit(o.allocator);
                        }
                        o.allocator.destroy(context);
                    },
                    else => {},
                }
            }

            if (self.prev_source) |v| {
                v.deinit();
            } else |_| {}
        }

        pub fn dupe(self: *const Self, allocator: std.mem.Allocator) !Self {
            return .{
                .prev_source = self.prev_source,
                .operation = try self.operation.dupe(allocator),
                .context = self.context,
            };
        }

        pub fn iterator(self: *const Self) Iter {
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

        pub fn enumerator(self: Self, allocator: std.mem.Allocator) !Enumerator(Result) {
            return .{
                .allocator = allocator,
                .source_enumerable = try .create(Self, allocator, try self.dupe(allocator)),
                .vtable = comptime &.{
                    .iterator = @ptrCast(&Self.iterator),
                },
            };
        }
    };
}

pub fn Enumerator(comptime Result: type) type {
    return struct {
        const Iter = Iterator(helpers.AttachError(Result));

        allocator: std.mem.Allocator,
        source_enumerable: Any,
        vtable: *const struct {
            iterator: *const fn (self: *const anyopaque) Iter,
        },

        pub fn enumerable(
            self: @This(),
            allocator: std.mem.Allocator,
        ) Enumerable(Result, Iter.Result) {
            return Enumerable(Result, Iter.Result)
                .initCopy(allocator, self.iterator());
        }

        pub fn toArrayList(self: @This(), allocator: std.mem.Allocator) !std.ArrayList(Iter.FinalizerResult) {
            var it = self.iterator();

            return try it.toArrayList(allocator);
        }

        pub fn toArray(self: @This(), allocator: std.mem.Allocator) ![]const Iter.FinalizerResult {
            var list = try self.toArrayList(allocator);
            return list.toOwnedSlice();
        }

        pub fn destroyAll(self: @This(), allocator: std.mem.Allocator) helpers.AttachErrorIf(void, Iter.result_has_error) {
            var it = self.iterator();

            return it.destroyAll(allocator);
        }

        pub fn deinitAll(
            self: @This(),
            // allocator: if (can_result_be_deinitialized_without_an_allocator) void else std.mem.Allocator,
            allocator: std.mem.Allocator,
        ) helpers.AttachErrorIf(void, Iter.result_has_error) {
            var it = self.iterator();

            return it.deinitAll(allocator);
        }

        pub fn forEach(self: @This(), func: closure.OpaqueClosure(fn (Iter.FinalizerResult) void)) helpers.AttachErrorIf(void, Iter.result_has_error) {
            var it = self.iterator();

            return it.forEach(func) catch |err| helpers.errorOrUnrechable(err);
        }

        pub fn first(self: @This()) helpers.AttachErrorIf(?Result, Iter.result_has_error) {
            var it = self.iterator();

            return it.first();
        }

        pub fn last(self: @This()) helpers.AttachErrorIf(?Result, Iter.result_has_error) {
            var it = self.iterator();

            return it.last();
        }

        pub fn findEql(self: @This(), other: helpers.MakeConst(helpers.DetachError(Result))) helpers.AttachErrorIf(?Result, Iter.result_has_error) {
            var it = self.iterator();

            return it.findEql(other);
        }

        pub fn findIndexEql(self: @This(), other: helpers.MakeConst(helpers.DetachError(Result))) helpers.AttachErrorIf(?usize, Iter.result_has_error) {
            var it = self.iterator();

            return it.findIndexEql(other);
        }

        // Other methods
        pub fn iterator(self: @This()) Iter {
            return self.vtable.iterator(self.source_enumerable.ptr);
        }

        pub const deinit = raii.default(@This(), .{});
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
    ).init(
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

    const y = try x.orderBy(allocator, .fromStruct(struct {
        pub fn do(_: void, left: u32, right: u32) bool {
            return left < right;
        }
    }, {})).filter(closure.fromStruct(struct {
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

    const y = try x.filter(closure.fromStruct(struct {
        pub fn filter(_: void, item: Foo) bool {
            return item.data.* % 2 == 0;
        }
    }, {}).toOpaque()).orderBy(allocator, .fromStruct(struct {
        pub fn do(_: void, left: Foo, right: Foo) bool {
            return left.data.* < right.data.*;
        }
    }, {})).mapTo(u32, .fromStruct(struct {
        pub fn map(_: void, item: Foo) u32 {
            return item.data.*;
        }
    }, {})).toArray(allocator);

    defer allocator.free(y);

    var slice: []Foo = &array;
    raii.deinit([]Foo, allocator, &slice);

    try std.testing.expectEqualDeep(@as([]const u32, &.{ 2, 4, 6 }), y);
}

test "Enumerable temporary value with destroyed scope" {
    const X = struct {
        pub fn v(x: Enumerable(u32, u32)) Enumerable(f32, Enumerable(f32, Enumerable(u32, Enumerable(u32, u32)))) {
            return x.filter(closure.fromStruct(struct {
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
            }, {}).toOpaque());
        }
    };

    const allocator = std.testing.allocator;

    var enumerable: Enumerable(f32, Enumerable(f32, Enumerable(u32, Enumerable(u32, u32)))) = undefined;
    var iterator = Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6 });
    const x = Enumerable(u32, u32).init(&iterator);

    {
        enumerable = X.v(x);
    }

    var a: u32 = 10;
    a = 20;

    const y = try enumerable.toArray(allocator);
    defer allocator.free(y);

    try std.testing.expectEqualDeep(@as([]const f32, &.{ 16, 32, 48 }), y);
}

test "Enumerator" {
    const Foo = struct {
        pub fn createSource(iterator: *Iterator(u32), allocator: std.mem.Allocator) !Enumerator(f32) {
            var x = fromIterator(u32, iterator);

            return try x.filter(closure.fromStruct(struct {
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
            }, {}).toOpaque()).enumerator(allocator);
        }
    };

    const allocator = std.testing.allocator;

    var iterator = Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6 });

    var source = try Foo.createSource(&iterator, allocator);
    defer source.deinit();

    const y = try source.enumerable(allocator).mapTo(f32, .fromStruct(struct {
        pub fn map(_: void, item: f32) f32 {
            return item * 2;
        }
    }, {})).toArray(allocator);
    defer allocator.free(y);

    try std.testing.expectEqualDeep(@as([]const f32, &.{ 32, 64, 96 }), y);
}
