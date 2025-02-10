const std = @import("std");

pub fn AnyIteratorResult(comptime T: type) type {
    return @typeInfo(@typeInfo(@TypeOf(@field(T, "next"))).@"fn".return_type.?).optional.child;
}

pub fn Iterator(comptime ResultType: type) type {
    return struct {
        const Self = @This();
        pub const Result = ResultType;
        pub const Error = error{CannotConvertToConstIterator};
        pub const DerefResult = switch (@typeInfo(Result)) {
            .pointer => |v| v.child,
            else => Result,
        };

        const is_result_mutable_pointer = switch (@typeInfo(Result)) {
            .pointer => |v| v.size == .one and !v.is_const,
            else => false,
        };

        pub fn fromSlice(slice: []const Result) @This() {
            const SliceContext = struct {
                pub fn next(self: [*]const Result, iter: *Self) ?Result {
                    if (iter.idx >= iter.len) {
                        return null;
                    }

                    iter.idx += 1;
                    return self[iter.idx - 1];
                }

                pub fn reset(_: [*]const Result, iter: *Self) void {
                    iter.idx = 0;
                }

                pub fn deinit(_: [*]const Result) void {}
            };

            var iterator = @This(){
                .ptr = @ptrCast(slice.ptr),
                .vtable = comptime &.{
                    .next = @ptrCast(&SliceContext.next),
                    .reset = @ptrCast(&SliceContext.reset),
                    .deinit = @ptrCast(&SliceContext.deinit),
                },
            };
            iterator.len = slice.len;
            return iterator;
        }

        pub fn fromMutableSlice(slice: if (is_result_mutable_pointer) []DerefResult else []Result) @This() {
            const Slice = if (is_result_mutable_pointer) [*]DerefResult else [*]Result;

            const SliceContext = struct {
                pub fn next(self: Slice, iter: *Self) ?Result {
                    if (iter.idx >= iter.len) {
                        return null;
                    }

                    iter.idx += 1;
                    return if (is_result_mutable_pointer) &self[iter.idx - 1] else self[iter.idx - 1];
                }

                pub fn reset(_: Slice, iter: *Self) void {
                    iter.idx = 0;
                }

                pub fn deinit(_: Slice) void {}
            };

            var iterator = @This(){
                .ptr = @ptrCast(slice.ptr),
                .vtable = comptime &.{
                    .next = @ptrCast(&SliceContext.next),
                    .reset = @ptrCast(&SliceContext.reset),
                    .deinit = @ptrCast(&SliceContext.deinit),
                },
            };
            iterator.len = slice.len;
            return iterator;
        }

        pub fn fromIterator(comptime T: type, iterator: *T) @This() {
            const IteratorContext = struct {
                pub fn next(self: *T, _: *const Self) ?Result {
                    return self.next();
                }

                pub fn reset(self: *T, _: *const Self) void {
                    if (@hasDecl(T, "reset")) {
                        self.reset();
                    }
                }

                pub fn deinit(self: *T) void {
                    if (@hasDecl(T, "deinit")) {
                        self.deinit();
                    }
                }

                pub fn index(self: *T, _: *const Self) usize {
                    if (@hasDecl(T, "index")) {
                        return self.index();
                    }

                    if (@hasField(T, "index")) {
                        return switch (@typeInfo(@TypeOf(self.index))) {
                            .Optional => if (self.index) |v| v else 0,
                            else => self.index,
                        };
                    }

                    return 0;
                }
            };

            return @This(){
                .ptr = iterator,
                .vtable = comptime &.{
                    .next = @ptrCast(&IteratorContext.next),
                    .reset = @ptrCast(&IteratorContext.reset),
                    .deinit = @ptrCast(&IteratorContext.deinit),
                    .index = @ptrCast(&IteratorContext.index),
                },
            };
        }

        pub fn fromAnyIterator(iterator: anytype) @This() {
            return fromIterator(@TypeOf(iterator.*), iterator);
        }

        ptr: *const anyopaque,
        vtable: *const struct {
            next: *const fn (self: *const anyopaque, iter: *Self) ?Result,
            reset: *const fn (self: *const anyopaque, iter: *Self) void,
            deinit: *const fn (self: *const anyopaque) void,
            index: ?*const fn (self: *const anyopaque, iter: *const Self) usize = null,
        },
        idx: usize = 0,
        len: usize = 0,

        pub fn next(self: *@This()) ?Result {
            return self.vtable.next(self.ptr, self);
        }

        pub fn reset(self: *@This()) void {
            self.vtable.reset(self.ptr, self);
        }

        /// Returns the index that will be read when `next()` function is called
        pub fn index(self: *const @This()) usize {
            return if (self.vtable.index) |v| v(self.ptr, self) else self.idx;
        }

        pub fn deinit(self: @This()) void {
            self.vtable.deinit(self.ptr);
        }
    };
}

test "Iterator result is a mutable pointer" {
    var array = [_]usize{ 10, 20, 30 };
    var iterator = Iterator(*usize).fromMutableSlice(&array);

    while (iterator.next()) |v| {
        v.* *= 2;
    }

    try std.testing.expectEqualDeep(@as([]const usize, &.{ 20, 40, 60 }), &array);
}

test "Iterator result is a mutable pointer from array list" {
    var list = std.ArrayList(usize).init(std.testing.allocator);
    defer list.deinit();

    try list.insertSlice(0, &.{ 10, 20, 30 });

    var iterator = Iterator(*usize).fromMutableSlice(list.items);

    while (iterator.next()) |v| {
        v.* *= 2;
    }

    try std.testing.expectEqualDeep(@as([]const usize, &.{ 20, 40, 60 }), list.items);
}

test "Iterator result is a const data" {
    var list = std.ArrayList(usize).init(std.testing.allocator);
    defer list.deinit();

    try list.insertSlice(0, &.{ 10, 20, 30 });

    var iterator = Iterator(usize).fromSlice(list.items);
    var result: [3]usize = undefined;
    var index: usize = 0;

    while (iterator.next()) |v| {
        result[index] = v * 2;
        index += 1;
    }

    try std.testing.expectEqualDeep(@as([]const usize, &.{ 20, 40, 60 }), &result);
}

test "Iterator result is a slice of pointers" {
    var a: usize = 10;
    var b: usize = 20;
    var c: usize = 30;
    const array = [_]*usize{ &a, &b, &c };
    var iterator = Iterator(*usize).fromSlice(&array);

    while (iterator.next()) |v| {
        v.* *= 2;
    }

    try std.testing.expectEqualDeep(@as([]const usize, &.{ 20, 40, 60 }), &.{ array[0].*, array[1].*, array[2].* });
}

test "Iterator result is a slice of slices" {
    var a = [_]u8{'a'};
    var b = [_]u8{'b'};
    var c = [_]u8{'c'};
    const array = [_][]u8{ &a, &b, &c };
    var iterator = Iterator([]u8).fromSlice(&array);

    while (iterator.next()) |v| {
        v[0] = 'd';
    }

    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "d", "d", "d" }), &.{ array[0], array[1], array[2] });
}

test "Iterator result is a string" {
    const array = [_][]const u8{"hello"};
    var iterator = Iterator([]const u8).fromSlice(&array);

    while (iterator.next()) |v| {
        try std.testing.expectEqualStrings("hello", v);
    }
}

test "Iterator from hash map iterator" {
    var map = std.StringHashMap(usize).init(std.testing.allocator);
    defer map.deinit();

    try map.put("test", 10);
    try map.put("test2", 20);
    try map.put("test3", 30);

    var map_iterator = map.valueIterator();
    var iterator = Iterator(*usize).fromAnyIterator(&map_iterator);
    var result: [3]usize = undefined;
    var index: usize = 0;

    while (iterator.next()) |v| {
        result[index] = v.* * 2;
        index += 1;
    }

    try std.testing.expectEqualDeep(@as([]const usize, &.{ 20, 40, 60 }), &result);
}
