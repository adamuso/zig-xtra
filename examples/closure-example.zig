const std = @import("std");
const xtra = @import("zig-xtra");

fn bar(param: u32) u32 {
    return param * 2;
}

test {
    // Parameter binding
    const bound_bar = xtra.closure.bind(bar, .{10});

    try std.testing.expectEqual(20, bound_bar.invoke());
}

test {
    // Creating closures in place
    var value: u32 = 0;

    const closure = xtra.closure.fromFn(struct {
        fn run(context: *u32) void {
            context.* += 1;
        }
    }.run, &value);

    closure.invoke();

    try std.testing.expectEqual(1, value);
}

test {
    // Saving a closure for later

    var value: u32 = 5;

    // Closures created this way cannot be stored because they have complex typw
    const closure = xtra.closure.fromFn(struct {
        fn run(context: *u32, a: u32) void {
            context.* += a;
        }
    }.run, &value);

    // For storing closure we can use more friendly type OpaqueClosure (allocated on the heap
    // if needed, opaque closure have an optimalization when captures are void or simple pointer
    // then opaque closure does not need to use heap for its storage). OpaqueClosure is a simple
    // type that can be specified by hand in contrast to Closure which needs whole function body
    // to declare its type.
    const stored_closure: xtra.closure.OpaqueClosure(fn (u32) void) = closure.toOpaque();

    stored_closure.invoke(10);

    try std.testing.expectEqual(15, value);
}
