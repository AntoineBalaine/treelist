const std = @import("std");

/// A type that stores multiple ArrayLists, one for each type in node_types.
/// Provides type-safe access to the elements using an enum to identify the type.
pub fn ArrayOfArrayLists(comptime node_types: anytype) type {
    // Generate table enum from node types
    const TypeEnum = blk: {
        var enum_fields: [node_types.len]std.builtin.Type.EnumField = undefined;
        inline for (node_types, 0..) |T, i| {
            enum_fields[i] = .{
                // Use a simple name extraction instead of full @typeName
                .name = blk2: {
                    const full_name = @typeName(T);
                    // Extract just the type name without module path
                    // This is a simplified approach - you might need more sophisticated parsing
                    const last_dot = std.mem.lastIndexOf(u8, full_name, ".") orelse 0;
                    const simple_name = if (last_dot > 0) full_name[(last_dot + 1)..] else full_name;
                    break :blk2 simple_name;
                },
                .value = i,
            };
        }
        break :blk @Type(.{
            .@"enum" = .{
                .tag_type = u32,
                .fields = &enum_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    };

    // Create the union types for type-safe access
    const TypeUnion = blk: {
        var union_fields: [node_types.len]std.builtin.Type.UnionField = undefined;
        inline for (node_types, 0..) |T, i| {
            union_fields[i] = .{
                .name = blk2: {
                    const full_name = @typeName(T);
                    // Extract just the type name without module path
                    // This is a simplified approach - you might need more sophisticated parsing
                    const last_dot = std.mem.lastIndexOf(u8, full_name, ".") orelse 0;
                    const simple_name = if (last_dot > 0) full_name[(last_dot + 1)..] else full_name;
                    break :blk2 simple_name;
                },
                .type = T,
                .alignment = @alignOf(T),
            };
        }
        break :blk @Type(.{
            .@"union" = .{
                .layout = .auto,
                .tag_type = TypeEnum,
                .fields = &union_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
            },
        });
    };

    const NodePtrUnion = blk: {
        var union_fields: [node_types.len]std.builtin.Type.UnionField = undefined;
        inline for (node_types, 0..) |T, i| {
            union_fields[i] = .{
                .name = @typeName(T),
                .type = *T,
                .alignment = @alignOf(*T),
            };
        }
        break :blk @Type(.{
            .@"union" = .{
                .layout = .auto,
                .tag_type = TypeEnum,
                .fields = &union_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
            },
        });
    };

    // Create a tuple of ArrayLists using std.meta.Tuple
    const ArrayListTypes = blk: {
        var types: [node_types.len]type = undefined;
        inline for (node_types, 0..) |T, i| {
            types[i] = std.ArrayListUnmanaged(T);
        }
        break :blk types;
    };

    const ArrayListsTuple = std.meta.Tuple(&ArrayListTypes);

    return struct {
        const Self = @This();
        pub const TableEnum = TypeEnum;
        pub const NodeUnion = TypeUnion;
        pub const PtrUnion = NodePtrUnion;

        // Tuple of properly typed ArrayLists
        lists: ArrayListsTuple = undefined,

        pub fn init() Self {
            var result: Self = undefined;
            inline for (0..node_types.len) |i| {
                result.lists[i] = .{};
            }
            return result;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            inline for (0..node_types.len) |i| {
                self.lists[i].deinit(allocator);
            }
        }

        // Get a typed pointer to an item - direct one-liner implementation
        pub fn getItemPtr(self: *Self, tag: TypeEnum, idx: usize) PtrUnion {
            switch (tag) {
                inline else => |t| {
                    const field_name = @tagName(t);
                    const list_idx = @intFromEnum(t);
                    return @unionInit(PtrUnion, field_name, &self.lists[list_idx].items[idx]);
                },
            }
        }

        // Append an item
        pub fn append(self: *Self, comptime T: type, value: T, allocator: std.mem.Allocator) !struct { tag: TypeEnum, idx: usize } {
            const tag = @field(TypeEnum, @typeName(T));
            const tag_int = @intFromEnum(tag);

            const list = &self.lists[tag_int];
            const idx = list.items.len;
            try list.append(allocator, value);

            return .{ .tag = tag, .idx = idx };
        }

        // Swap remove an item
        pub fn swapRemove(self: *Self, tag: TypeEnum, idx: usize) ?struct { tag: TypeEnum, idx: usize } {
            const tag_int = @intFromEnum(tag);
            const list = &self.lists[tag_int];

            if (idx >= list.items.len) return null;

            if (idx == list.items.len - 1) {
                _ = list.pop();
                return null;
            }

            // Swap with the last item
            list.swapRemove(idx);
            return .{ .tag = tag, .idx = idx };
        }

        // Get the length of a specific list
        pub fn len(self: *Self, tag: TypeEnum) usize {
            switch (tag) {
                inline else => |t| {
                    const list_idx = @intFromEnum(t);
                    return self.lists[list_idx].items.len;
                },
            }
        }
    };
}

test "ArrayOfArrayLists basic operations" {
    const TestNodeA = struct {
        value: i32,
        name: []const u8,
    };

    const TestNodeB = struct {
        flag: bool,
        count: usize,
    };

    // Create an ArrayOfArrayLists with two node types
    var array_lists = ArrayOfArrayLists(.{ TestNodeA, TestNodeB }).init();
    defer array_lists.deinit(std.testing.allocator);

    // Insert elements
    const a1 = try array_lists.append(TestNodeA, .{ .value = 42, .name = "test1" }, std.testing.allocator);
    const a2 = try array_lists.append(TestNodeA, .{ .value = 100, .name = "test2" }, std.testing.allocator);
    _ = a2;
    const b1 = try array_lists.append(TestNodeB, .{ .flag = true, .count = 5 }, std.testing.allocator);

    // Verify lengths
    try std.testing.expectEqual(@as(usize, 2), array_lists.len(a1.tag));
    try std.testing.expectEqual(@as(usize, 1), array_lists.len(b1.tag));

    // Get and mutate elements
    {
        const ptr_a1 = array_lists.getItemPtr(a1.tag, a1.idx);
        switch (ptr_a1) {
            .TestNodeA => |node| {
                try std.testing.expectEqual(@as(i32, 42), node.value);
                try std.testing.expectEqualStrings("test1", node.name);
                // Mutate the node
                node.value = 99;
            },
            else => unreachable,
        }

        const ptr_b1 = array_lists.getItemPtr(b1.tag, b1.idx);
        switch (ptr_b1) {
            .TestNodeB => |node| {
                try std.testing.expect(node.flag);
                try std.testing.expectEqual(@as(usize, 5), node.count);
                // Mutate the node
                node.count = 10;
            },
            else => unreachable,
        }
    }

    // Verify mutations
    {
        const ptr_a1 = array_lists.getItemPtr(a1.tag, a1.idx);
        switch (ptr_a1) {
            .TestNodeA => |node| {
                try std.testing.expectEqual(@as(i32, 99), node.value); // Changed from 42 to 99
            },
            else => unreachable,
        }

        const ptr_b1 = array_lists.getItemPtr(b1.tag, b1.idx);
        switch (ptr_b1) {
            .TestNodeB => |node| {
                try std.testing.expectEqual(@as(usize, 10), node.count); // Changed from 5 to 10
            },
            else => unreachable,
        }
    }

    // Delete elements
    _ = array_lists.swapRemove(a1.tag, a1.idx);

    // Verify the deletion (a2 should now be at index 0)
    try std.testing.expectEqual(@as(usize, 1), array_lists.len(a1.tag));

    const ptr_a0 = array_lists.getItemPtr(a1.tag, 0);
    switch (ptr_a0) {
        .TestNodeA => |node| {
            try std.testing.expectEqual(@as(i32, 100), node.value); // This was a2
            try std.testing.expectEqualStrings("test2", node.name);
        },
        else => unreachable,
    }
}
