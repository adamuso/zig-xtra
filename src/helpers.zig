pub inline fn MakeConst(comptime Result: type) type {
    return switch (@typeInfo(Result)) {
        .pointer => |v| v.child,
        else => Result,
    };
}

pub inline fn AttachError(comptime Result: type) type {
    return switch (@typeInfo(Result)) {
        .error_union => |v| anyerror!v.payload,
        else => anyerror!Result,
    };
}

pub inline fn AttachErrorIf(comptime Result: type, comptime conidtion: bool) type {
    return if (conidtion) AttachError(Result) else Result;
}

pub inline fn DetachError(comptime Result: type) type {
    return switch (@typeInfo(Result)) {
        .error_union => |v| v.payload,
        else => Result,
    };
}

pub inline fn canHaveDecls(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .@"union" => true,
        .@"enum" => true,
        .@"opaque" => true,
        else => false,
    };
}

pub inline fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |v| v.size == .slice,
        else => false,
    };
}

pub inline fn isStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        else => false,
    };
}

pub inline fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |v| v.is_tuple,
        else => false,
    };
}

pub inline fn isPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        else => false,
    };
}

pub inline fn canBeDeinitializedWithoutAllocator(comptime T: type) bool {
    const DerefT = switch (@typeInfo(T)) {
        .pointer => |v| if (v.size != .slice) v.child else T,
        else => T,
    };

    if (canHaveDecls(DerefT) and @hasDecl(DerefT, "deinit") and @typeInfo(@TypeOf(DerefT.deinit)).@"fn".params.len == 1) {
        return true;
    }

    return false;
}

pub inline fn errorOrUnrechable(value: anytype) !switch (@typeInfo(@TypeOf(value))) {
    .error_union => anyerror,
    else => noreturn,
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .error_union => value,
        else => unreachable,
    };
}

pub inline fn derefIfNeeded(value: anytype) MakeConst(@TypeOf(value)) {
    return switch (@typeInfo(@TypeOf(value))) {
        .pointer => value.*,
        else => value,
    };
}
