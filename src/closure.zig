const std = @import("std");
const raii = @import("raii.zig");
const duplication = @import("duplication.zig");
const equality = @import("equality.zig");

const void_address: *const anyopaque = @ptrCast(&{});

fn FnWithContext(comptime Fn: type, comptime Context: type) type {
    comptime {
        const Return = @typeInfo(Fn).@"fn".return_type.?;
        const params = @typeInfo(Fn).@"fn".params;

        return switch (params.len) {
            0 => fn (Context) Return,
            1 => fn (Context, params[0].type.?) Return,
            2 => fn (Context, params[0].type.?, params[1].type.?) Return,
            3 => fn (Context, params[0].type.?, params[1].type.?, params[2].type.?) Return,
            4 => fn (Context, params[0].type.?, params[1].type.?, params[2].type.?, params[3].type.?) Return,
            else => unreachable,
        };
    }
}

fn FnWithoutContext(comptime Fn: type) type {
    comptime {
        const Return = @typeInfo(Fn).@"fn".return_type.?;
        const params = @typeInfo(Fn).@"fn".params;

        return switch (params.len) {
            1 => fn () Return,
            2 => fn (params[1].type.?) Return,
            3 => fn (params[1].type.?, params[2].type.?) Return,
            4 => fn (params[1].type.?, params[2].type.?, params[3].type.?) Return,
            5 => fn (params[1].type.?, params[2].type.?, params[3].type.?, params[4].type.?) Return,
            else => unreachable,
        };
    }
}

fn AnyContextFunc(comptime Fn: type) type {
    return FnWithContext(Fn, *anyopaque);
}

fn anyContextFunc(comptime Fn: type, comptime Context: type, comptime func: FnWithContext(Fn, Context)) AnyContextFunc(Fn) {
    const Return = @typeInfo(Fn).@"fn".return_type.?;
    const params = @typeInfo(Fn).@"fn".params;
    const is_context_ptr: bool = switch (@typeInfo(Context)) {
        .pointer => |v| v.size != .slice,
        else => false,
    };

    if (!is_context_ptr) {
        return switch (params.len) {
            0 => return struct {
                fn invoke(
                    context: *const anyopaque,
                ) Return {
                    return func(@as(*const Context, @alignCast(@ptrCast(context))).*);
                }
            }.invoke,
            1 => return struct {
                fn invoke(
                    context: *const anyopaque,
                    arg1: params[0].type.?,
                ) Return {
                    return func(@as(*const Context, @alignCast(@ptrCast(context))).*, arg1);
                }
            }.invoke,
            2 => return struct {
                fn invoke(
                    context: *const anyopaque,
                    arg1: params[0].type.?,
                    arg2: params[1].type.?,
                ) Return {
                    return func(@as(*const Context, @alignCast(@ptrCast(context))).*, arg1, arg2);
                }
            }.invoke,
            3 => return struct {
                fn invoke(
                    context: *const anyopaque,
                    arg1: params[0].type.?,
                    arg2: params[1].type.?,
                    arg3: params[2].type.?,
                ) Return {
                    return func(@as(*const Context, @alignCast(@ptrCast(context))).*, arg1, arg2, arg3);
                }
            }.invoke,
            4 => return struct {
                fn invoke(
                    context: *const anyopaque,
                    arg1: params[0].type.?,
                    arg2: params[1].type.?,
                    arg3: params[2].type.?,
                    arg4: params[3].type.?,
                ) Return {
                    return func(@as(*const Context, @alignCast(@ptrCast(context))).*, arg1, arg2, arg3, arg4);
                }
            }.invoke,
            else => unreachable,
        };
    } else {
        return switch (params.len) {
            0 => return struct {
                fn invoke(
                    context: *anyopaque,
                ) Return {
                    return func(@as(Context, @alignCast(@ptrCast(context))));
                }
            }.invoke,
            1 => return struct {
                fn invoke(
                    context: *anyopaque,
                    arg1: params[0].type.?,
                ) Return {
                    return func(@as(Context, @alignCast(@ptrCast(context))), arg1);
                }
            }.invoke,
            2 => return struct {
                fn invoke(
                    context: *anyopaque,
                    arg1: params[0].type.?,
                    arg2: params[1].type.?,
                ) Return {
                    return func(@as(Context, @alignCast(@ptrCast(context))), arg1, arg2);
                }
            }.invoke,
            3 => return struct {
                fn invoke(
                    context: *anyopaque,
                    arg1: params[0].type.?,
                    arg2: params[1].type.?,
                    arg3: params[2].type.?,
                ) Return {
                    return func(@as(Context, @alignCast(@ptrCast(context))), arg1, arg2, arg3);
                }
            }.invoke,
            4 => return struct {
                fn invoke(
                    context: *anyopaque,
                    arg1: params[0].type.?,
                    arg2: params[1].type.?,
                    arg3: params[2].type.?,
                    arg4: params[3].type.?,
                ) Return {
                    return func(@as(Context, @alignCast(@ptrCast(context))), arg1, arg2, arg3, arg4);
                }
            }.invoke,
            else => unreachable,
        };
    }
}

pub const AnyClosure = struct {
    fn tag(comptime Fn: type) *const anyopaque {
        return &struct {
            pub fn stub(_: *const volatile Fn) void {
                @panic("Tag function should never be invoked. Without this panic optimizer removes empty tag functions");
            }
        }.stub;
    }

    allocator: ?std.mem.Allocator,
    captures: *anyopaque,
    vtable: *const struct {
        can_blindly_invoke: bool,
        tag: *const anyopaque,
        func: *const anyopaque,
        destroyCaptures: *const raii.Destroy,
        dupeCaptures: duplication.DupePtr,
        eqlCaptures: equality.OpaqueEql,
    },

    pub fn dupe(self: @This(), allocator: std.mem.Allocator) !@This() {
        return .{
            .allocator = if (self.allocator != null) allocator else null,
            .captures = if (self.captures != void_address) self.vtable.dupeCaptures(allocator, self.captures) catch |err| switch (err) {
                duplication.Error.DupeIsNotSupported => self.captures,
                else => return err,
            } else @constCast(void_address),
            .vtable = self.vtable,
        };
    }

    pub fn deinit(self: @This()) void {
        if (self.captures != void_address and self.allocator != null) {
            self.vtable.destroyCaptures(self.allocator.?, self.captures);
        }
    }

    pub fn canBeBlindlyInvoked(self: @This()) bool {
        return self.vtable.can_blindly_invoke;
    }

    pub fn eql(self: @This(), other: @This()) bool {
        return self.vtable.func == other.vtable.func and self.vtable.eqlCaptures(self.captures, other.captures);
    }

    pub fn invoke(self: @This()) error{ClosureCannotBeBlindlyInvoked}!void {
        if (!self.canBeBlindlyInvoked()) {
            return error.ClosureCannotBeBlindlyInvoked;
        }

        @as(*const fn (*anyopaque) void, @alignCast(@ptrCast(self.vtable.func)))(self.captures);
    }

    pub fn toOpaque(self: @This(), comptime Fn: type) error{FunctionTagDoesNotMatch}!OpaqueClosure(Fn) {
        if (tag(Fn) != self.vtable.tag) {
            return error.FunctionTagDoesNotMatch;
        }

        return .{
            .closure = self,
        };
    }
};

pub fn OpaqueClosure(comptime Fn: type) type {
    return struct {
        pub const Function = Fn;
        pub const Return = @typeInfo(Fn).@"fn".return_type.?;
        pub const Error = error{AllocatorIsRequiredForInit};
        pub const Self = @This();

        pub fn init(
            allocator: ?std.mem.Allocator,
            comptime Captures: type,
            captures: Captures,
            comptime func: FnWithContext(Fn, Captures),
        ) !@This() {
            const is_captures_ptr: bool = switch (@typeInfo(Captures)) {
                .pointer => |v| v.size != .slice,
                else => false,
            };

            if (is_captures_ptr) {
                // Pointer optimization, no need to allocate anything if captures are single pointer
                return .{
                    .closure = .{
                        .allocator = null,
                        .captures = @constCast(@ptrCast(captures)),
                        .vtable = comptime &.{
                            .can_blindly_invoke = @typeInfo(Fn).@"fn".params.len == 0 and @typeInfo(Fn).@"fn".return_type.? == void,
                            .tag = AnyClosure.tag(Fn),
                            .func = anyContextFunc(Fn, Captures, func),
                            .destroyCaptures = raii.noDestroy,
                            .dupeCaptures = duplication.noDupePtr,
                            .eqlCaptures = equality.opaqueEqlFn(Captures),
                        },
                    },
                };
            }

            if (Captures == void) {
                // Void type optimization, no need to allocate anything
                return .{
                    .closure = .{
                        .allocator = null,
                        .captures = @constCast(void_address),
                        .vtable = comptime &.{
                            .can_blindly_invoke = @typeInfo(Fn).@"fn".params.len == 0 and @typeInfo(Fn).@"fn".return_type.? == void,
                            .tag = AnyClosure.tag(Fn),
                            .func = anyContextFunc(Fn, Captures, func),
                            .destroyCaptures = raii.noDestroy,
                            .dupeCaptures = duplication.noDupePtr,
                            .eqlCaptures = equality.opaqueAlwaysEql,
                        },
                    },
                };
            }

            if (allocator == null) {
                return Error.AllocatorIsRequiredForInit;
            }

            const captures_heap = try duplication.dupePtr(Captures, allocator.?, &captures);

            return .{
                .closure = .{
                    .allocator = allocator.?,
                    .captures = @ptrCast(captures_heap),
                    .vtable = comptime &.{
                        .can_blindly_invoke = @typeInfo(Fn).@"fn".params.len == 0 and @typeInfo(Fn).@"fn".return_type.? == void,
                        .tag = AnyClosure.tag(Fn),
                        .func = anyContextFunc(Fn, Captures, func),
                        .destroyCaptures = raii.destroyFn(Captures),
                        .dupeCaptures = duplication.dupePtrFn(Captures),
                        .eqlCaptures = equality.opaqueEqlFn(Captures),
                    },
                },
            };
        }

        pub fn fromFn(
            comptime function: anytype,
            captures: @typeInfo(@TypeOf(function)).@"fn".params[0].type.?,
        ) @TypeOf(closure(@TypeOf(function), function, captures).toOpaque()) {
            return closure(@TypeOf(function), function, captures).toOpaque();
        }

        closure: AnyClosure,

        pub fn eql(self: @This(), other: @This()) bool {
            return self.closure.eql(other.closure);
        }

        pub fn dupe(self: @This(), allocator: std.mem.Allocator) !@This() {
            return .{
                .closure = try self.closure.dupe(allocator),
            };
        }

        pub fn deinit(self: @This()) void {
            self.closure.deinit();
        }

        pub const invoke = switch (@typeInfo(Fn).@"fn".params.len) {
            0 => struct {
                pub fn invoke(
                    self: Self,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return @as(*const AnyContextFunc(Fn), @alignCast(@ptrCast(self.closure.vtable.func)))(self.closure.captures);
                }
            }.invoke,
            1 => struct {
                pub fn invoke(
                    self: Self,
                    arg1: @typeInfo(Function).@"fn".params[0].type.?,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return @as(*const AnyContextFunc(Fn), @alignCast(@ptrCast(self.closure.vtable.func)))(self.closure.captures, arg1);
                }
            }.invoke,
            2 => struct {
                pub fn invoke(
                    self: Self,
                    arg1: @typeInfo(Function).@"fn".params[0].type.?,
                    arg2: @typeInfo(Function).@"fn".params[1].type.?,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return @as(*const AnyContextFunc(Fn), @alignCast(@ptrCast(self.closure.vtable.func)))(self.closure.captures, arg1, arg2);
                }
            }.invoke,
            3 => struct {
                pub fn invoke(
                    self: Self,
                    arg1: @typeInfo(Function).@"fn".params[0].type.?,
                    arg2: @typeInfo(Function).@"fn".params[1].type.?,
                    arg3: @typeInfo(Function).@"fn".params[2].type.?,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return @as(*const AnyContextFunc(Fn), @alignCast(@ptrCast(self.closure.vtable.func)))(self.closure.captures, arg1, arg2, arg3);
                }
            }.invoke,
            4 => struct {
                pub fn invoke(
                    self: Self,
                    arg1: @typeInfo(Function).@"fn".params[0].type.?,
                    arg2: @typeInfo(Function).@"fn".params[1].type.?,
                    arg3: @typeInfo(Function).@"fn".params[2].type.?,
                    arg4: @typeInfo(Function).@"fn".params[3].type.?,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return @as(*const AnyContextFunc(Fn), @alignCast(@ptrCast(self.closure.vtable.func)))(self.closure.captures, arg1, arg2, arg3, arg4);
                }
            }.invoke,
            else => unreachable,
        };
    };
}

pub fn Closure(comptime Fn: type, comptime function: Fn, comptime Captures: type) type {
    return struct {
        const Self = @This();
        pub const func = function;
        pub const Function: type = FnWithoutContext(Fn);

        captures: Captures,

        pub fn any(self: @This(), allocator: std.mem.Allocator) !OpaqueClosure(Function) {
            return try .init(allocator, Captures, self.captures, function);
        }

        pub const toOpaque = blk: {
            // This needs to be in sync with OpaqueClosure.init
            const is_captures_ptr: bool = switch (@typeInfo(Captures)) {
                .pointer => |v| v.size != .slice,
                else => false,
            };

            if (is_captures_ptr or Captures == void) {
                break :blk struct {
                    pub fn toOpaque(self: Self) OpaqueClosure(Self.Function) {
                        return OpaqueClosure(Self.Function).init(
                            null,
                            Captures,
                            self.captures,
                            Self.func,
                        ) catch @panic("We should not have ever reached this point. OpaqueClosure should not need an allocator here");
                    }
                }.toOpaque;
            }

            break :blk struct {
                pub fn toOpaque(self: Self, allocator: std.mem.Allocator) !OpaqueClosure(Self.Function) {
                    return .init(allocator, Captures, self.captures, Self.func);
                }
            }.toOpaque;
        };

        pub const toAny = blk: {
            const is_captures_ptr: bool = switch (@typeInfo(Captures)) {
                .pointer => |v| v.size != .slice,
                else => false,
            };

            if (is_captures_ptr or Captures == void) {
                break :blk struct {
                    pub fn toAny(self: Self) AnyClosure {
                        return self.toOpaque().closure;
                    }
                }.toAny;
            }

            break :blk struct {
                pub fn toAny(self: Self, allocator: std.mem.Allocator) !AnyClosure {
                    return (try self.toOpaque(allocator)).closure;
                }
            }.toAny;
        };

        pub const invoke = switch (@typeInfo(Function).@"fn".params.len) {
            0 => struct {
                pub fn invoke(
                    self: Self,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return function(self.captures);
                }
            }.invoke,
            1 => struct {
                pub fn invoke(
                    self: Self,
                    arg1: @typeInfo(Function).@"fn".params[0].type.?,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return function(self.captures, arg1);
                }
            }.invoke,
            2 => struct {
                pub fn invoke(
                    self: Self,
                    arg1: @typeInfo(Function).@"fn".params[0].type.?,
                    arg2: @typeInfo(Function).@"fn".params[1].type.?,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return function(self.captures, arg1, arg2);
                }
            }.invoke,
            3 => struct {
                pub fn invoke(
                    self: Self,
                    arg1: @typeInfo(Function).@"fn".params[0].type.?,
                    arg2: @typeInfo(Function).@"fn".params[1].type.?,
                    arg3: @typeInfo(Function).@"fn".params[2].type.?,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return function(self.captures, arg1, arg2, arg3);
                }
            }.invoke,
            4 => struct {
                pub fn invoke(
                    self: Self,
                    arg1: @typeInfo(Function).@"fn".params[0].type.?,
                    arg2: @typeInfo(Function).@"fn".params[1].type.?,
                    arg3: @typeInfo(Function).@"fn".params[2].type.?,
                    arg4: @typeInfo(Function).@"fn".params[3].type.?,
                ) @typeInfo(Function).@"fn".return_type.? {
                    return function(self.captures, arg1, arg2, arg3, arg4);
                }
            }.invoke,
            else => @compileError("Closures currently support up to 4 arguments"),
        };
    };
}

pub fn closure(
    comptime Fn: type,
    comptime function: Fn,
    captures: @typeInfo(Fn).@"fn".params[0].type.?,
) Closure(Fn, function, @TypeOf(captures)) {
    return .{ .captures = captures };
}

pub fn closureFn(
    comptime function: anytype,
    captures: @typeInfo(@TypeOf(function)).@"fn".params[0].type.?,
) @TypeOf(closure(@TypeOf(function), function, captures)) {
    return closure(@TypeOf(function), function, captures);
}

inline fn firstDeclInStruct(comptime Struct: type) struct { type: type, name: [:0]const u8 } {
    const name = @typeInfo(Struct).@"struct".decls[0].name;
    return .{
        .type = @TypeOf(@field(Struct, name)),
        .name = name,
    };
}

pub fn closureStruct(
    comptime Struct: type,
    captures: @typeInfo(firstDeclInStruct(Struct).type).@"fn".params[0].type.?,
) @TypeOf(closureFn(
    @field(Struct, firstDeclInStruct(Struct).name),
    captures,
)) {
    return closureFn(@field(Struct, firstDeclInStruct(Struct).name), captures);
}

test "OpaqueClosure without captures and arguments created manually" {
    const Captures = struct {};

    const internal = struct {
        fn test1(_: Captures) void {}
    };

    const test1_closure = try OpaqueClosure(fn () void).init(std.testing.allocator, Captures, .{}, internal.test1);
    test1_closure.invoke();
}

test "OpaqueClosure without captures and with argument created manually" {
    const Captures = struct {};
    const Arg = struct {};

    const internal = struct {
        fn test1(_: Captures, _: Arg) void {}
    };

    const test1_closure = try OpaqueClosure(fn (Arg) void).init(std.testing.allocator, Captures, .{}, internal.test1);
    test1_closure.invoke(Arg{});
}

test "Closure with one capture" {
    const a: usize = 10;
    const closure_1 = closureFn(struct {
        fn x(captures: struct { usize }) !void {
            try std.testing.expectEqual(10, captures[0]);
        }
    }.x, .{a});

    try closure_1.invoke();
}

test "Closure with two captures" {
    const a: usize = 10;
    const b: usize = 20;

    const closure_1 = closureFn(struct {
        fn x(captures: struct { usize, usize }) anyerror!void {
            try std.testing.expectEqual(30, captures[0] + captures[1]);
        }
    }.x, .{ a, b });

    const any_closure = try closure_1.toOpaque(std.testing.allocator);
    defer any_closure.deinit();

    try any_closure.invoke();
}

test "Closure with two captures and an arguments" {
    const a: usize = 10;
    const b: usize = 20;
    const c: usize = 30;

    const closure_1 = closureFn(struct {
        fn x(captures: struct { usize, usize }, arg: usize) anyerror!void {
            const c_a, const c_b = captures;

            try std.testing.expectEqual(60, c_a + c_b + arg);
        }
    }.x, .{ a, b });

    const any_closure = try closure_1.toOpaque(std.testing.allocator);
    defer any_closure.deinit();

    try any_closure.invoke(c);
}

test "Closure in standard library function std.mem.sort" {
    var numbers: [8]i32 = .{ 13, 6, 4, 7, 9, 3, 2, 5 };
    const sort_ascending = closureFn(struct {
        fn sort(_: void, a: i32, b: i32) bool {
            return a < b;
        }
    }.sort, {});

    std.mem.sort(i32, &numbers, sort_ascending, @TypeOf(sort_ascending).invoke);

    try std.testing.expectEqualSlices(i32, &.{ 2, 3, 4, 5, 6, 7, 9, 13 }, &numbers);
}

test "OpaqueClosure in standard library function std.mem.sort" {
    var numbers: [8]i32 = .{ 13, 6, 4, 7, 9, 3, 2, 5 };
    const sort_ascending = closureFn(struct {
        fn sort(_: void, a: i32, b: i32) bool {
            return a < b;
        }
    }.sort, {}).toOpaque();

    std.mem.sort(i32, &numbers, sort_ascending, @TypeOf(sort_ascending).invoke);

    try std.testing.expectEqualSlices(i32, &.{ 2, 3, 4, 5, 6, 7, 9, 13 }, &numbers);
}

test "AnyClosure allow blindly invoke when closure has no arguments and returns void" {
    var result = false;
    const opaque_closure = closureFn(struct {
        fn run(r: *bool) void {
            r.* = true;
        }
    }.run, &result).toOpaque();

    const any_closure = opaque_closure.closure;
    defer any_closure.deinit();

    try std.testing.expect(any_closure.canBeBlindlyInvoked());

    try any_closure.invoke();

    try std.testing.expect(result);
}

test "Closure from struct" {
    const c = closureStruct(struct {
        pub fn run(_: void) void {}
    }, {});

    c.invoke();
}

test "AnyClosure converted to OpaqueClosure and tag equality" {
    try std.testing.expect(AnyClosure.tag(fn () void) == AnyClosure.tag(fn () void));
    try std.testing.expect(AnyClosure.tag(fn () void) != AnyClosure.tag(fn () i32));
    try std.testing.expect(AnyClosure.tag(fn () i32) == AnyClosure.tag(fn () i32));

    const opaque_closure = try closureStruct(struct {
        pub fn run(v: i32) i32 {
            return v;
        }
    }, @as(i32, 10)).toOpaque(std.testing.allocator);

    const any_closure = opaque_closure.closure;
    defer any_closure.deinit();

    try std.testing.expectError(
        error.FunctionTagDoesNotMatch,
        any_closure.toOpaque(fn (i32) void),
    );

    try std.testing.expectError(
        error.FunctionTagDoesNotMatch,
        any_closure.toOpaque(fn (i32) i32),
    );

    const opaque_from_any = try any_closure.toOpaque(fn () i32);

    try std.testing.expectEqual(10, opaque_from_any.invoke());
}

test "Void address is always the same" {
    try std.testing.expectEqual(&{}, &{});
}

test "Closure to AnyClosure conversion" {
    var result = false;
    const any_closure = closureFn(struct {
        fn run(r: *bool) void {
            r.* = true;
        }
    }.run, &result).toAny();

    defer any_closure.deinit();

    try std.testing.expect(any_closure.canBeBlindlyInvoked());

    try any_closure.invoke();

    try std.testing.expect(result);
}

test "Closure destroy tuple with pointer" {
    const x = try std.testing.allocator.create(u32);
    defer std.testing.allocator.destroy(x);

    const any_closure = try closureStruct(struct {
        pub fn run(_: @TypeOf(.{x})) void {}
    }, .{x}).toOpaque(std.testing.allocator);

    any_closure.deinit();
}

test "Eql closure with a pointer inside" {
    const Internal = struct {
        fn create(x: *u32) !OpaqueClosure(fn () void) {
            const any_closure = try closureStruct(struct {
                pub fn run(_: @TypeOf(.{x})) void {}
            }, .{x}).toOpaque(std.testing.allocator);
            return any_closure;
        }
    };

    const x = try std.testing.allocator.create(u32);
    defer std.testing.allocator.destroy(x);

    const any_closure = try Internal.create(x);
    const any_closure2 = try Internal.create(x);
    defer any_closure.deinit();
    defer any_closure2.deinit();

    try std.testing.expect(any_closure.eql(any_closure2));
}

// inline fn isComptime(v: anytype) bool {
//     return @typeInfo(@TypeOf(.{v})).struct.fields[0].is_comptime;
// }

// fn abc(x: anytype) void {
//     std.debug.print("{}\n", .{isComptime(x)});
// }

// test "Test" {
//     const x: []const u8 = "asd"; // try std.testing.allocator.alloc(u8, 10);
//     abc(.{x});
// }
