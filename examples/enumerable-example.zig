const std = @import("std");
const xtra = @import("zig-xtra");

test {
    var iterator = xtra.iterator.Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });

    // strict type version
    const result = try xtra.enumerable.fromIterator(u32, &iterator)
        .filterBy(.fromStruct(struct {
        pub fn filter(_: void, item: u32) bool {
            return item % 2 == 0;
        }
    }, {}))
        .mapTo(u32, .fromStruct(struct {
        pub fn map(_: void, item: u32) u32 {
            return item * 2;
        }
    }, {})).toArray(std.testing.allocator);

    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u32, &.{ 4, 8, 12, 16 }, result);

    // inferred types
    const result2 = try xtra.enumerable.fromIterator(u32, &iterator)
        .filter(xtra.closure.fromStruct(struct {
        pub fn filter(_: void, item: u32) bool {
            return item % 2 == 0;
        }
    }, {}).toOpaque())
        .map(xtra.closure.fromStruct(struct {
        pub fn map(_: void, item: u32) u32 {
            return item * 2;
        }
    }, {}).toOpaque()).toArray(std.testing.allocator);

    defer std.testing.allocator.free(result2);

    try std.testing.expectEqualSlices(u32, &.{ 4, 8, 12, 16 }, result2);
}

test {
    const Foo = struct {
        pub fn onlyEven(enumerable: anytype) xtra.enumerable.Enumerable(u32, @TypeOf(enumerable)) {
            return enumerable.filterBy(.fromStruct(struct {
                pub fn filter(_: void, item: u32) bool {
                    return item % 2 == 0;
                }
            }, {}));
        }

        pub fn doubleAll(enumerable: anytype) xtra.enumerable.Enumerable(u32, @TypeOf(enumerable)) {
            return enumerable.mapTo(u32, .fromStruct(struct {
                pub fn map(_: void, item: u32) u32 {
                    return item * 2;
                }
            }, {}));
        }
    };

    var iterator = xtra.iterator.Iterator(u32).fromSlice(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const enumerable = xtra.enumerable.fromIterator(u32, &iterator);
    const enumerable_even = Foo.onlyEven(enumerable);
    const enumerable_double = Foo.doubleAll(enumerable_even);

    const result = try enumerable_double.toArray(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u32, &.{ 4, 8, 12, 16 }, result);
}
