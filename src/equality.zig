const std = @import("std");

pub const OpaqueEql = fn (value: *const anyopaque, other: *const anyopaque) bool;

pub fn Eql(comptime T: type) type {
    return fn (value: T, other: T) bool;
}

pub fn eql(comptime T: type, value: T, other: T) bool {
    return eqlFn(T)(value, other);
}

pub fn eqlFn(comptime T: type) Eql(T) {
    return struct {
        fn eqlImpl(a: T, b: T) bool {
            switch (@typeInfo(T)) {
                .@"struct" => |info| {
                    if (@hasDecl(T, "eql")) {
                        return a.eql(b);
                    }

                    inline for (info.fields) |field_info| {
                        if (!eql(field_info.type, @field(a, field_info.name), @field(b, field_info.name))) return false;
                    }
                    return true;
                },
                .error_union => {
                    if (a) |a_p| {
                        if (b) |b_p| return eql(a_p, b_p) else |_| return false;
                    } else |a_e| {
                        if (b) |_| return false else |b_e| return a_e == b_e;
                    }
                },
                .@"union" => |info| {
                    if (@hasDecl(T, "eql")) {
                        return a.eql(b);
                    }

                    if (info.tag_type) |UnionTag| {
                        const tag_a = std.meta.activeTag(a);
                        const tag_b = std.meta.activeTag(b);
                        if (tag_a != tag_b) return false;

                        inline for (info.fields) |field_info| {
                            if (@field(UnionTag, field_info.name) == tag_a) {
                                return eql(@field(a, field_info.name), @field(b, field_info.name));
                            }
                        }
                        return false;
                    }

                    @compileError("cannot compare untagged union type " ++ @typeName(T));
                },
                .array => {
                    if (a.len != b.len) return false;
                    for (a, 0..) |e, i|
                        if (!eql(e, b[i])) return false;
                    return true;
                },
                .vector => |info| {
                    var i: usize = 0;
                    while (i < info.len) : (i += 1) {
                        if (!eql(a[i], b[i])) return false;
                    }
                    return true;
                },
                .optional => {
                    if (a == null and b == null) return true;
                    if (a == null or b == null) return false;
                    return eql(a.?, b.?);
                },
                else => return std.meta.eql(a, b),
            }
        }
    }.eqlImpl;
}

pub fn neverEql(comptime T: type) Eql(T) {
    return &struct {
        fn eqlImpl(_: std.mem.Allocator, _: T) bool {
            return false;
        }
    }.eqlImpl;
}

pub fn alwaysEql(comptime T: type) Eql(T) {
    return &struct {
        fn eqlImpl(_: std.mem.Allocator, _: T) bool {
            return true;
        }
    }.eqlImpl;
}

pub fn opaqueEqlFn(comptime T: type) OpaqueEql {
    return struct {
        fn eqlImpl(a: *const anyopaque, b: *const anyopaque) bool {
            return eql(T, @as(*const T, @alignCast(@ptrCast(a))).*, @as(*const T, @alignCast(@ptrCast(b))).*);
        }
    }.eqlImpl;
}

pub fn opaqueNeverEql(_: *const anyopaque, _: *const anyopaque) bool {
    return false;
}

pub fn opaqueAlwaysEql(_: *const anyopaque, _: *const anyopaque) bool {
    return true;
}
