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
