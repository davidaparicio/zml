const std = @import("std");
const testing = std.testing;

const stdx = @import("stdx");
const FnParam = stdx.meta.FnParam;
const asSlice = stdx.meta.asSlice;

test {
    std.testing.refAllDecls(@This());
}

/// Visit a given type `T` and replace all fields containing `From` by fields containing `To`.
pub fn MapType(From: type, To: type) type {
    return struct {
        pub fn map(T: type) type {
            switch (T) {
                To => return To,
                ?To => return ?To,
                From => return To,
                *From => return *To,
                ?From => return ?To,
                else => {},
            }

            return switch (@typeInfo(T)) {
                .@"struct" => |struct_infos| {
                    const fields = struct_infos.fields;
                    var same: bool = true;
                    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
                    for (struct_fields[0..], fields) |*struct_field, field| {
                        if (!field.is_comptime) {
                            const R = map(field.type);
                            if (R == field.type) {
                                struct_field.* = field;
                            } else {
                                struct_field.* = .{
                                    .name = field.name,
                                    .type = R,
                                    .default_value_ptr = null,
                                    .is_comptime = field.is_comptime,
                                    .alignment = @alignOf(R),
                                };
                                same = false;
                                // Handle the case `field: ?Tensor = null`
                                // Generic handling of default value is complicated,
                                // it would require to call the callback at comptime.
                                if (R == ?To) {
                                    struct_field.default_value_ptr = &@as(R, null);
                                }
                            }
                        } else {
                            struct_field.* = field;
                        }
                    }
                    if (same) return T;
                    return @Type(.{ .@"struct" = .{
                        .layout = .auto,
                        .fields = struct_fields[0..],
                        .decls = &.{},
                        .is_tuple = struct_infos.is_tuple,
                    } });
                },
                .@"union" => |union_info| {
                    const fields = union_info.fields;
                    var same: bool = true;
                    var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
                    for (union_fields[0..], fields) |*union_field, field| {
                        const R = map(field.type);
                        if (R == field.type) {
                            union_field.* = field;
                        } else {
                            union_field.* = .{
                                .name = field.name,
                                .type = R,
                                .alignment = @alignOf(R),
                            };
                            same = false;
                        }
                    }
                    if (same) return T;
                    return @Type(.{ .@"union" = .{
                        .layout = .auto,
                        .tag_type = union_info.tag_type,
                        .fields = union_fields[0..],
                        .decls = &.{},
                    } });
                },
                .array => |arr_info| [arr_info.len]map(arr_info.child),
                .pointer => |ptr_info| switch (ptr_info.size) {
                    .slice => if (ptr_info.is_const)
                        []const map(ptr_info.child)
                    else
                        []map(ptr_info.child),
                    .one => if (ptr_info.is_const)
                        *const map(ptr_info.child)
                    else
                        *map(ptr_info.child),
                    else => T,
                },
                .optional => |opt_info| ?map(opt_info.child),
                else => T,
            };
        }
    };
}

test MapType {
    const A = struct { a: u32 };
    const B = struct { b: u32 };

    const A2B = MapType(A, B);

    const StructA = struct { some: []const A, one: A, maybe: ?A, other: u32 };
    const struct_b = A2B.map(StructA){
        .some = &[2]B{ .{ .b = 0 }, .{ .b = 1 } },
        .maybe = null,
        .one = .{ .b = 2 },
        .other = 43,
    };
    _ = struct_b;

    const UnionA = union { some: []const A, one: A, maybe: ?A, other: u32 };
    const union_b = [_]A2B.map(UnionA){
        .{ .some = &[2]B{ .{ .b = 0 }, .{ .b = 1 } } },
        .{ .one = .{ .b = 2 } },
        .{ .maybe = null },
        .{ .other = 43 },
    };
    _ = union_b;
}

/// Given a callback: `fn(Ctx, From) To`, recursively visits the given `from` struct
/// and calls the callback when it finds a `From` element, and writes it to the `to` struct.
/// The `to` parameter must be passed with mutable pointer, and tensor data need to be mutable if callback needs it.
/// `mapAlloc` tries as much as possible to respect the conversions made by Zig itself.
/// For example it can convert from a comptime array to a runtime slice.
/// `mapAlloc` can allocate new slices to write the result if the result struct requires it.
/// The caller is owning said allocations, using an `ArenaAllocator` might help tracking them.
///
/// Note: to avoid infinite loop, mapAlloc doesn't look for `From` fields inside `To` struct.
/// Any `To` struct inside `from` will be copied over to the target.
pub fn mapAlloc(comptime cb: anytype, allocator: std.mem.Allocator, ctx: FnParam(cb, 0), from: anytype, to: anytype) !void {
    // TODO: handle tuple to slice conversion
    const From = FnParam(cb, 1);
    const To = stdx.meta.FnResult(cb);
    const FromStruct = @TypeOf(from);
    const type_info_to_ptr = @typeInfo(@TypeOf(to));
    if (type_info_to_ptr != .pointer) {
        stdx.debug.compileError("convertType is expecting a mutable `to` argument but received: {}", .{@TypeOf(to)});
    }
    const ToStruct = type_info_to_ptr.pointer.child;
    const type_info_to = @typeInfo(ToStruct);

    if (FromStruct == From) {
        // We have an issues with `Tensor` -> `Shape` -> `Tensor` conversion when compiling ZML functions where one argument is a Shape itself.
        // Normally we should call `cb` on all `Shape`.
        // But the "ShapeOf" struct will have more Shape than need on the output.
        // So here we take a hint from the receiving object.
        // If the target is indeed a Tensor, use the callback, but if the target is `Shape` just copy it over.
        if (ToStruct != To and FromStruct == ToStruct) {
            to.* = from;
        } else {
            to.* = @call(.auto, cb, .{ ctx, from });
        }
        return;
    }

    if (FromStruct == To) {
        to.* = from;
        return;
    }

    if (@sizeOf(ToStruct) == 0) return;

    switch (type_info_to) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (field.is_comptime or @sizeOf(field.type) == 0) continue;
            const field_type_info = @typeInfo(field.type);
            // If the field is already a pointer, we recurse with it directly, otherwise, we recurse with a pointer to the field.
            switch (field_type_info) {
                // .pointer => try convertType(From, To, allocator, @field(from, field.name), @field(to, field.name), Ctx, ctx, cb),
                .array, .optional, .@"union", .@"struct", .pointer => if (@hasField(FromStruct, field.name)) {
                    try mapAlloc(
                        cb,
                        allocator,
                        ctx,
                        @field(from, field.name),
                        &@field(to, field.name),
                    );
                } else if (field.default_value_ptr) |_| {
                    @field(to, field.name) = null;
                } else {
                    stdx.debug.compileError("Mapping {} -> {} inside {} failed. Missing field {s} in {}", .{ From, To, FromStruct, field.name, ToStruct });
                },
                else => @field(to, field.name) = @field(from, field.name),
            }
        },
        .@"union" => {
            switch (from) {
                inline else => |_, tag| {
                    to.* = @unionInit(ToStruct, @tagName(tag), undefined);
                    try mapAlloc(cb, allocator, ctx, @field(from, @tagName(tag)), &@field(to, @tagName(tag)));
                },
            }
        },
        .array => for (from, to) |f, *t| {
            try mapAlloc(cb, allocator, ctx, f, t);
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => switch (type_info_to_ptr.pointer.size) {
                // pointer to array -> slice promotion
                .slice => {
                    const items = try allocator.alloc(type_info_to_ptr.pointer.child, from.len);
                    for (from, items) |f, *t| {
                        try mapAlloc(cb, allocator, ctx, f, t);
                    }
                    to.* = items;
                },
                else => try mapAlloc(cb, allocator, ctx, from.*, to.*),
            },
            .slice => {
                const items = try allocator.alloc(@typeInfo(ToStruct).pointer.child, from.len);
                for (from, items) |f, *t| {
                    try mapAlloc(cb, allocator, ctx, f, t);
                }
                to.* = items;
            },
            else => stdx.debug.compileError("zml.meta.mapAlloc doesn't support: {}", .{FromStruct}),
        },
        .optional => if (from) |f| {
            to.* = @as(@typeInfo(type_info_to_ptr.pointer.child).optional.child, undefined);
            try mapAlloc(cb, allocator, ctx, f, &(to.*.?));
        } else {
            to.* = null;
        },
        .int, .float, .@"enum" => to.* = from,
        else => stdx.debug.compileError("zml.meta.mapAlloc doesn't support: {}", .{FromStruct}),
    }
}

test mapAlloc {
    const B = struct { b: u8 };
    const A = struct {
        a: u8,
        pub fn convert(_: void, a: @This()) B {
            return .{ .b = a.a };
        }
    };

    const Empty = struct {};

    const AA = struct {
        field: A,
        array: [2]A,
        slice: []const A,
        other: u8,
        // We want to allow conversion from comptime to runtime, because Zig type inference works like this.
        comptime static_val: u8 = 8,
        comptime static_slice: [2]A = .{ .{ .a = 11 }, .{ .a = 12 } },
        field_with_empty: struct { A, Empty },
    };
    const BB = struct {
        field: B,
        array: [2]B,
        slice: []const B,
        other: u8,
        static_val: u8,
        static_slice: []B,
        field_with_empty: struct { B, Empty },
    };

    const aa: AA = .{
        .field = .{ .a = 4 },
        .array = .{ .{ .a = 5 }, .{ .a = 6 } },
        .other = 7,
        .slice = &.{ .{ .a = 9 }, .{ .a = 10 } },
        .field_with_empty = .{ .{ .a = 9 }, .{} },
    };
    var bb: BB = undefined;

    try mapAlloc(A.convert, testing.allocator, {}, aa, &bb);
    defer testing.allocator.free(bb.slice);
    defer testing.allocator.free(bb.static_slice);

    try testing.expectEqual(4, bb.field.b);
    try testing.expectEqual(5, bb.array[0].b);
    try testing.expectEqual(6, bb.array[1].b);
    try testing.expectEqual(7, bb.other);
    try testing.expectEqual(8, bb.static_val);
    try testing.expectEqual(9, bb.slice[0].b);
    try testing.expectEqual(10, bb.slice[1].b);
    try testing.expectEqual(11, bb.static_slice[0].b);
    try testing.expectEqual(12, bb.static_slice[1].b);
}

/// Visit a given type `T` and:
/// * replace all fields containing `From` by fields containing `To`
/// * drop all fields not containing any `From`.
/// The returned type will contains only `To` making it easy for the compiler to produce compact layout.
/// Used by `zml.Bufferized` to strip compile time arguments from a model struct.
pub fn MapRestrict(From: type, To: type) type {
    return struct {
        pub fn map(T: type) type {
            switch (T) {
                From => return To,
                ?From => return ?To,
                *From => return *To,
                *const From => return *const To,
                []From => return []To,
                []const From => return []const To,
                else => {},
            }

            if (!Contains(T, From)) return void;

            return switch (@typeInfo(T)) {
                .@"struct" => |struct_infos| {
                    // We know that at least one of the struct field contains a From.
                    // We map each field individually. Fields without From and comptime fields are removed.
                    const fields = struct_infos.fields;
                    var num_fields: usize = 0;

                    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
                    for (fields) |field| {
                        if (!field.is_comptime and Contains(field.type, From)) {
                            const R = map(field.type);
                            if (R == field.type) {
                                struct_fields[num_fields] = field;
                            } else {
                                const name = if (struct_infos.is_tuple) struct_infos.fields[num_fields].name else field.name;
                                struct_fields[num_fields] = .{
                                    .name = name,
                                    .type = R,
                                    .default_value_ptr = null,
                                    .is_comptime = false,
                                    .alignment = @alignOf(R),
                                };
                                // Handle the case `field: ?Tensor = null`
                                // Generic handling of default value is not possible.
                                if (R == ?To) {
                                    struct_fields[num_fields].default_value_ptr = &@as(R, null);
                                }
                            }
                            num_fields += 1;
                        }
                    }
                    if (num_fields == 0) return void;
                    return @Type(.{ .@"struct" = .{
                        .layout = .auto,
                        .fields = struct_fields[0..num_fields],
                        .decls = &.{},
                        .is_tuple = struct_infos.is_tuple,
                    } });
                },
                .@"union" => |union_info| {
                    // We know that at least one of the union field contains a From.
                    // We map each field individually. Fields without From, are replaced by "void".
                    const fields = union_info.fields;
                    var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
                    for (0.., fields) |i, field| {
                        union_fields[i] = .{
                            .name = field.name,
                            .type = map(field.type),
                            .alignment = 0,
                        };
                    }
                    return @Type(.{ .@"union" = .{
                        .layout = .auto,
                        .tag_type = union_info.tag_type,
                        .fields = union_fields[0..],
                        .decls = &.{},
                    } });
                },
                .array => |arr_info| [arr_info.len]map(arr_info.child),
                .pointer => |ptr_info| switch (ptr_info.size) {
                    .slice => if (ptr_info.is_const)
                        []const map(ptr_info.child)
                    else
                        []map(ptr_info.child),
                    .one => if (ptr_info.is_const)
                        *const map(ptr_info.child)
                    else
                        *map(ptr_info.child),
                    .many => if (ptr_info.is_const)
                        [*]const map(ptr_info.child)
                    else
                        [*]map(ptr_info.child),
                    .c => if (ptr_info.is_const)
                        [*c]map(ptr_info.child)
                    else
                        [*c]map(ptr_info.child),
                },
                .optional => |opt_info| ?map(opt_info.child),
                else => T,
            };
        }
    };
}

test MapRestrict {
    const A = struct { a: u32 };
    const B = struct { b: u32 };

    const A2B = MapRestrict(A, B);

    const StructA = struct { some: []const A, one: A, maybe: ?A, other: u32 };
    const struct_b = A2B.map(StructA){
        .some = &[2]B{ .{ .b = 0 }, .{ .b = 1 } },
        .maybe = null,
        .one = .{ .b = 2 },
        // Note how struct_b doesn't even have a .other field now.
    };
    _ = struct_b;

    const UnionA = union { some: []const A, one: A, maybe: ?A, other: u32 };
    const union_b = [_]A2B.map(UnionA){
        .{ .some = &[2]B{ .{ .b = 0 }, .{ .b = 1 } } },
        .{ .one = .{ .b = 2 } },
        .{ .maybe = null },
        // Note how union_b.other is void now.
        .{ .other = {} },
    };
    _ = union_b;
}

/// Recursively visit the given struct and calls the callback for each K found.
/// The `v` parameter must me a pointer, and tensor data need to be mutable if callbacks needs it.
pub fn visit(comptime cb: anytype, ctx: FnParam(cb, 0), v: anytype) void {
    const Callback = @TypeOf(cb);
    const Ptr = @TypeOf(v);
    const type_info_v = @typeInfo(Ptr);
    if (type_info_v != .pointer) {
        stdx.debug.compileError("zml.meta.visit({}) is expecting a pointer/slice input, but received: {}", .{ Callback, Ptr });
    }
    const ptr_info = type_info_v.pointer;
    const Child = ptr_info.child;

    const K, const mutating_cb = switch (@typeInfo(FnParam(cb, 1))) {
        .pointer => |info| .{ info.child, !info.is_const },
        else => stdx.debug.compileError("zml.meta.visit is expecting a callback with a pointer as second argument but found {}", .{FnParam(cb, 1)}),
    };
    // Abort if v doesnt' contain any K.
    if (comptime !Contains(Ptr, K)) return;

    // Handle simple cases.
    switch (Ptr) {
        *const K, *K => return cb(ctx, v),
        *const ?K, *?K => return if (v.*) |*val| cb(ctx, val) else {},
        []const K, []K => {
            for (v) |*v_elem| cb(ctx, v_elem);
            return;
        },
        else => {},
    }

    // Handle std.BoundedArray that contains uninitalized data.
    if (@typeInfo(Child) == .@"struct" and @hasDecl(Child, "constSlice") and @hasDecl(Child, "slice")) {
        return visit(cb, ctx, if (mutating_cb) v.slice() else v.constSlice());
    }

    // Recursively visit fields of v.
    switch (ptr_info.size) {
        .one => switch (@typeInfo(Child)) {
            .@"struct" => |s| inline for (s.fields) |field| {
                if (field.is_comptime or comptime !Contains(field.type, K)) continue;
                const field_type_info = @typeInfo(field.type);
                // If the field is already a pointer, we recurse with it directly, otherwise, we recurse with a pointer to the field.
                switch (field_type_info) {
                    .pointer => visit(cb, ctx, @field(v, field.name)),
                    .array, .optional, .@"union", .@"struct" => visit(cb, ctx, &@field(v, field.name)),
                    else => {},
                }
            },
            .array => |_| for (v) |*elem| visit(cb, ctx, elem),
            .optional => if (v.* != null) visit(cb, ctx, &v.*.?),
            .@"union" => switch (v.*) {
                inline else => |*v_field| visit(cb, ctx, v_field),
            },
            else => stdx.debug.compileError("zml.meta.visit({}) doesn't support fields of type: {}", .{ Callback, Child }),
        },
        .slice => {
            for (v) |*v_elem| {
                switch (@typeInfo(Child)) {
                    .@"struct" => |s| inline for (s.fields) |field| {
                        if (field.is_comptime or comptime !Contains(field.type, K)) continue;
                        const field_type_info = @typeInfo(field.type);
                        // If the field is already a pointer, we recurse with it directly, otherwise, we recurse with a pointer to the field.
                        if (field_type_info == .pointer) {
                            visit(cb, ctx, @field(v_elem, field.name));
                        } else {
                            visit(cb, ctx, &@field(v_elem, field.name));
                        }
                    },
                    .array => |_| for (v) |*elem| visit(cb, ctx, elem),
                    .optional => if (v.* != null) visit(cb, ctx, &v.*.?),
                    .@"union" => switch (v_elem.*) {
                        inline else => |*v_field| visit(cb, ctx, v_field),
                    },
                    else => stdx.debug.compileError("zml.meta.visit({}) doesn't support fields of type: {}", .{ Callback, Child }),
                }
            }
        },
        .many, .c => stdx.debug.compileError("zml.meta.visit({}) doesn't support [*] style pointers, got: {}", .{ Callback, Ptr }),
    }
}

test visit {
    const Attr = struct { data: usize };
    const OtherAttr = struct { other: []const u8 };
    const NestedAttr = struct { nested: Attr };
    const NestedAttrOptional = struct { nested: ?Attr };
    const SimpleStruct = struct { prop: Attr };
    const MultipleTypesStruct = struct { prop1: Attr, prop2: OtherAttr, prop3: ?Attr };
    const NestedTypesStruct = struct { prop1: Attr, prop2: OtherAttr, prop3: NestedAttr, prop4: NestedAttrOptional, prop5: std.BoundedArray(Attr, 8) };

    const LocalContext = struct { result: usize };

    {
        var context: LocalContext = .{ .result = 0 };
        const container: SimpleStruct = .{ .prop = .{ .data = 1 } };

        visit((struct {
            fn cb(ctx: *LocalContext, attr: *const Attr) void {
                ctx.result += attr.data;
            }
        }).cb, &context, &container);

        try std.testing.expectEqual(1, context.result);
    }
    {
        var context: LocalContext = .{ .result = 0 };
        var container: SimpleStruct = .{ .prop = .{ .data = 1 } };

        visit((struct {
            fn cb(ctx: *LocalContext, attr: *Attr) void {
                ctx.result += attr.data;
            }
        }).cb, &context, &container);

        try std.testing.expectEqual(1, context.result);
    }
    {
        var context: LocalContext = .{ .result = 0 };
        var container: MultipleTypesStruct = .{ .prop1 = .{ .data = 1 }, .prop2 = .{ .other = "hello" }, .prop3 = null };

        visit((struct {
            fn cb(ctx: *LocalContext, attr: *Attr) void {
                ctx.result += attr.data;
            }
        }).cb, &context, &container);

        try std.testing.expectEqual(1, context.result);
    }
    {
        var context: LocalContext = .{ .result = 0 };
        const container: MultipleTypesStruct = .{ .prop1 = .{ .data = 1 }, .prop2 = .{ .other = "hello" }, .prop3 = .{ .data = 2 } };

        visit((struct {
            fn cb(ctx: *LocalContext, attr: *const Attr) void {
                ctx.result += attr.data;
            }
        }).cb, &context, &container);

        try std.testing.expectEqual(3, context.result);
    }
    {
        var context: LocalContext = .{ .result = 0 };
        const prop5: std.BoundedArray(Attr, 8) = .{
            .buffer = @splat(.{ .data = 4 }),
            .len = 2,
        };
        const container: NestedTypesStruct = .{
            .prop1 = .{ .data = 1 },
            .prop2 = .{ .other = "hello" },
            .prop3 = .{ .nested = .{ .data = 2 } },
            .prop4 = .{ .nested = .{ .data = 3 } },
            .prop5 = prop5, // 4 will be counted twice.
        };

        visit((struct {
            fn cb(ctx: *LocalContext, attr: *const Attr) void {
                ctx.result += attr.data;
            }
        }).cb, &context, &container);

        try std.testing.expectEqual(14, context.result);
    }
}

pub fn count(T: type, value: anytype) u32 {
    var counter: u32 = 0;
    visit(struct {
        pub fn cb(res: *u32, _: *const T) void {
            res.* += 1;
        }
    }.cb, &counter, value);
    return counter;
}

pub fn first(T: type, value: anytype) T {
    var res: ?T = null;
    visit(struct {
        pub fn cb(res_ptr: *?T, x: *const T) void {
            if (res_ptr.* == null) res_ptr.* = x.*;
        }
    }.cb, &res, &value);
    return res.?;
}

/// Given a `fn([]const T, Args) T` and a slice of values,
/// will combine all values in one value.
/// Only T elements of values will be looked at.
/// This only works for simple types, in particular `zip` doesn't follow pointers.
/// Which means that zip only allocate temp memory, and nothing need to be freed after the call.
pub fn zip(comptime func: anytype, allocator: std.mem.Allocator, values: anytype, args: anytype) error{OutOfMemory}!asSlice(@TypeOf(values)) {
    const sliceT = @typeInfo(FnParam(func, 0));
    const T = sliceT.pointer.child;
    const V = asSlice(@TypeOf(values));
    if (V == T) {
        return @call(.auto, func, .{values} ++ args);
    }
    // const fn_args

    return switch (@typeInfo(V)) {
        .pointer => stdx.debug.compileError("zip only accept by value arguments. Received: {}", .{V}),
        .@"struct" => |struct_info| {
            var out: V = values[0];
            inline for (struct_info.fields) |f| {
                if (f.is_comptime) continue;
                if (@typeInfo(f.type) == .pointer) {
                    stdx.debug.compileError("zip doesn't follow pointers and don't accept struct containing them. Received: {}", .{V});
                }
                var fields = try allocator.alloc(f.type, values.len);
                defer allocator.free(fields);
                for (values, 0..) |val, i| {
                    fields[i] = @field(val, f.name);
                }
                @field(out, f.name) = try zip(func, allocator, fields, args);
            }
            return out;
        },
        .array => |arr_info| {
            if (@typeInfo(arr_info.child) == .pointer) {
                stdx.debug.compileError("zip doesn't follow pointers and don't accept struct containing them. Received: {}", .{V});
            }
            var out: V = undefined;
            var slice = try allocator.alloc(arr_info.child, values.len);
            defer allocator.free(slice);
            for (&out, 0..) |*o, j| {
                for (values, 0..) |val, i| {
                    slice[i] = val[j];
                }
                o.* = try zip(func, allocator, slice, args);
            }
            return out;
        },
        .@"union", .optional => stdx.debug.compileError("zip doesn't yet support {}", .{V}),
        else => values[0],
    };
}

test zip {
    const A = struct { a: u8, b: [2]u8 };
    const a0: A = .{ .a = 1, .b = .{ 2, 3 } };
    const a1: A = .{ .a = 4, .b = .{ 5, 6 } };

    const Sum = struct {
        pub fn call(x: []const u8) u8 {
            var res: u8 = 0;
            for (x) |xx| res += xx;
            return res;
        }
    };
    const a_sum: A = try zip(Sum.call, testing.allocator, &[_]A{ a0, a1 }, .{});
    try testing.expectEqual(A{ .a = 5, .b = .{ 7, 9 } }, a_sum);
}

/// Given a func(X) -> Y or a func(Ctx, X) -> Y,
/// finds all X in the given object, and write the result of func(X) into an arraylist.
pub fn collect(func: anytype, func_ctx: _CollectCtx(func), out: *std.ArrayList(stdx.meta.FnSignature(func, null).ReturnT), obj: anytype) error{OutOfMemory}!void {
    stdx.debug.assertComptime(@typeInfo(@TypeOf(func)).@"fn".params.len <= 2, "zml.meta.collect expects a func with two arguments, got: {}", .{@TypeOf(func)});
    const LocalContext = struct {
        func_ctx: _CollectCtx(func),
        out: *std.ArrayList(stdx.meta.FnSignature(func, null).ReturnT),
        oom: bool = false,
    };
    var context = LocalContext{ .func_ctx = func_ctx, .out = out };
    visit((struct {
        fn cb(ctx: *LocalContext, val: *const _CollectArg(func)) void {
            if (ctx.oom) return;
            const res = if (_CollectCtx(func) == void) func(val.*) else func(ctx.func_ctx, val.*);
            ctx.out.append(res) catch {
                ctx.oom = true;
            };
        }
    }).cb, &context, obj);
    if (context.oom) return error.OutOfMemory;
}

/// Given a func(X) -> Y or a func(Ctx, X) -> Y,
/// finds all X in the given object, and write the result of func(X) into an arraylist.
pub fn collectBuf(func: anytype, func_ctx: _CollectCtx(func), obj: anytype, out: []stdx.meta.FnResult(func)) void {
    stdx.debug.assertComptime(@typeInfo(@TypeOf(func)).@"fn".params.len <= 2, "zml.meta.collectBuf expects a func with one or two arguments, got: {}", .{@TypeOf(func)});
    const LocalContext = struct {
        func_ctx: _CollectCtx(func),
        out: @TypeOf(out),
        idx: usize = 0,
    };
    var context = LocalContext{ .func_ctx = func_ctx, .out = out };
    visit((struct {
        fn cb(ctx: *LocalContext, val: *const _CollectArg(func)) void {
            if (ctx.idx >= ctx.out.len) return;

            const res = if (_CollectCtx(func) == void) func(val.*) else func(ctx.func_ctx, val.*);
            ctx.out[ctx.idx] = res;
            ctx.idx += 1;
        }
    }).cb, &context, obj);
    std.debug.assert(context.idx == context.out.len);
}

fn _CollectCtx(func: anytype) type {
    const params = @typeInfo(@TypeOf(func)).@"fn".params;
    if (params.len == 1) return void;
    return params[0].type orelse @compileError("anytype not supported in collect");
}

fn _CollectArg(func: anytype) type {
    const params = @typeInfo(@TypeOf(func)).@"fn".params;
    return params[params.len - 1].type orelse @compileError("anytype not supported in collect");
}

pub fn Contains(Haystack: type, T: type) bool {
    switch (Haystack) {
        T, ?T => return true,
        *T, ?*T => return true,
        *const T, ?*const T => return true,
        []const T, ?[]const T => return true,
        anyopaque => return false,
        else => {},
    }

    return switch (@typeInfo(Haystack)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!field.is_comptime and Contains(field.type, T))
                    return true;
            }
            return false;
        },
        .@"union" => |info| {
            inline for (info.fields) |field| {
                if (Contains(field.type, T))
                    return true;
            }
            return false;
        },
        .array => |info| Contains(info.child, T),
        .pointer => |info| Contains(info.child, T),
        .optional => |info| Contains(info.child, T),
        .vector => |info| Contains(info.child, T),
        else => false,
    };
}
