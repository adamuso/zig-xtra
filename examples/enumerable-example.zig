const std = @import("std");
const xtra = @import("zig-xtra");

test {
    const slice: []i32 = &.{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var iterator = xtra.iterator.Iterator(i32).fromSlice(slice);
    xtra.enumerable.fromIterator(u32, &iterator);
}
