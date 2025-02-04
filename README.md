# zig-xtra

Library with helpers for implementing higher level concepts and utils. This library supports only zig in version 0.14 (currently nightly).

## Quick start

Install with
```
zig fetch --save "git+https://github.com/adamuso/zig-xtra#master"
```

Add to `build.zig`
```zig
const zig_xtra = b.dependency("zig-xtra", .{
    .target = target,
    .optimize = optimize,
});

exe_mod.addImport("zig-xtra", zig_xtra.module("zig-xtra"));
```

Use in code
```zig
const xtra = @import("zig-xtra");
// ...
```

## Roadmap

- [x] Deinitialization pattern
- [x] Duplication pattern
- [x] Closures
- [ ] Any type
- [ ] Iterator
- [ ] Enumerables (like C#)
- [ ] Equality pattern
- [ ] More compile time checks and errors
- [ ] Naming: Is `raii` a good name?

## `deinit` pattern with RAII

`raii` allows for automatic and hierarchical deinitialization of the objects known from C++ destructors. Using `raii` when
`deinit` is called we can automatically iterate through each field of the struct and deinitialize it recursively.

For full example check [raii example](examples/raii-example.zig).

```zig

const Bar = struct {
    allocator: std.mem.Allocator,
    bar_data: *u32,

    // ... initialization

    // Using default implementation for deinit
    pub const deinit = xtra.raii.default(@This(), .{"bar_data"});
};

const Foo = struct {
    bar: Bar,
    foo_data: *u32,

    // ... initialization

    // Custom implementation for deinit, always declare deinit as pub
    pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
        // We need to deinitialize pointers explicitly
        xtra.raii.auto.destroy(allocator, self.foo_data);

        // Cleanup will take care of deinitializing `bar` field, because it is an owned struct
        xtra.raii.auto.externalCleanup(allocator, self);
    }
};

test {
    var foo: Foo = try Foo.init(std.testing.allocator);
    defer foo.deinit(std.testing.allocator);

    // No memory leaks
}
```

## `dupe` pattern

`duplication` allows for automatic object deep cloning and getting duping functions pointers for dynamic generic dispatching.

For full example check [duplication example](examples/duplication-example.zig).

```zig
const std = @import("std");
const xtra = @import("zig-xtra");

const Bar = struct {
    allocator: std.mem.Allocator,
    bar_data: *u32,

    // ... initialization, deinitialization

    // Using dupe default implementation
    pub const dupe = xtra.duplication.default(@This());
};

const Foo = struct {
    bar: Bar,
    foo_data: *u32,

    // ... initialization, deinitialization

    // Creating custom dupe implementation
    pub fn dupe(self: Foo, allocator: std.mem.Allocator) !Foo {
        return .{
            .bar = try self.bar.dupe(allocator),
            .foo_data = try xtra.duplication.dupe(*u32, allocator, self.foo_data),
        };
    }
};

test {
    var foo: Foo = try Foo.init(std.testing.allocator, 20);
    defer foo.deinit(std.testing.allocator);

    try std.testing.expectEqual(20, foo.foo_data.*);

    var foo2 = try foo.dupe(std.testing.allocator);
    defer foo2.deinit(std.testing.allocator);

    try std.testing.expectEqual(40, foo2.bar.bar_data.*);
    // No memory leaks
}
```

## `eql` pattern

`equality` allows for automatic deep equality check using `eql` member functions.

For full example check [equality example](examples/equality-example.zig).

```zig
const std = @import("std");
const xtra = @import("zig-xtra");

const Bar = struct {
    bar_data: u32,

    // ... initialization

    // Using eql default implementation
    pub const eql = xtra.equality.default(@This());
};

const Foo = struct {
    bar: Bar,
    foo_data: *u32,

    // ... initialization, deinitialization

    // Creating custom dupe implementation
    pub fn eql(self: Foo, other: Foo) bool {
        return self.bar.eql(other.bar) and self.foo_data.* == other.foo_data.*;
        // return self.bar.eql(other.bar) and xtra.equality.eql(*u32, self.foo_data, other.foo_data);
    }
};

test {
    var foo: Foo = try Foo.init(std.testing.allocator, 20);
    defer foo.deinit(std.testing.allocator);

    var foo2 = try Foo.init(std.testing.allocator, 40);
    defer foo2.deinit(std.testing.allocator);

    var foo3 = try Foo.init(std.testing.allocator, 20);
    defer foo3.deinit(std.testing.allocator);

    try std.testing.expect(!foo.eql(foo2));
    try std.testing.expect(!foo2.eql(foo3));
    try std.testing.expect(foo.eql(foo3));
    try std.testing.expect(!xtra.equality.eql(Foo, foo, foo2));
    try std.testing.expect(!xtra.equality.eql(Foo, foo2, foo3));
    try std.testing.expect(xtra.equality.eql(Foo, foo, foo3));
}
```

## Closures

Closures allow for storing a function with captures for later. Closures try to mimic lambda functions
created in place where possible.

For full example check [closure example](examples/closure-example.zig) and for more check [tests for closure](src/closure.zig) implementation.

```zig
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
```

## Any type

TODO

