const std = @import("std");
const EnumIndexer = std.enums.EnumIndexer;

/// A type that stores multiple ArrayLists, one for each field in the given tagged union type.
/// Provides type-safe access to the elements using the union's tag type.
pub fn ArrayOfArrayLists(comptime UnionType: type) type {
    comptime {
        // Ensure we're working with a tagged union
        const info = @typeInfo(UnionType);
        if (info != .@"union" or info.@"union".tag_type == null) {
            @compileError("ArrayOfArrayLists requires a tagged union type");
        }
    }

    // Extract the tag type from the union
    const TagType = std.meta.Tag(UnionType);

    // Create a tuple of ArrayLists, one for each union field
    const union_info = @typeInfo(UnionType).@"union";
    const fields = union_info.fields;

    const ArrayListTypes = blk: {
        var types: [fields.len]type = undefined;
        inline for (fields, 0..) |field, i| {
            types[i] = std.ArrayListUnmanaged(field.type);
        }
        break :blk types;
    };

    const ArrayListsTuple = std.meta.Tuple(&ArrayListTypes);

    return struct {
        const Self = @This();
        pub const Tag = TagType;

        // Create an EnumIndexer to map from tag to array index efficiently
        const tag_indexer = EnumIndexer(Tag);

        // Tuple of properly typed ArrayLists
        lists: ArrayListsTuple = undefined,

        pub fn init() Self {
            var result: Self = undefined;
            inline for (0..fields.len) |i| {
                result.lists[i] = .{};
            }
            return result;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            inline for (0..fields.len) |i| {
                self.lists[i].deinit(allocator);
            }
        }

        // Get a typed pointer to an item
        pub fn getItemPtr(self: *Self, tag: Tag, idx: usize) anyerror!*@field(UnionType, @tagName(tag)) {
            // Use EnumIndexer to get the list index
            const list_idx = tag_indexer.indexOf(tag);

            // Safety check
            if (idx >= self.lists[list_idx].items.len) {
                return error.IndexOutOfBounds;
            }

            return &self.lists[list_idx].items[idx];
        }

        // Append an item
        pub fn append(self: *Self, value: UnionType, allocator: std.mem.Allocator) !struct { tag: Tag, idx: usize } {
            const tag = std.meta.activeTag(value);
            const list_idx = tag_indexer.indexOf(tag);
            const item_idx = self.lists[list_idx].items.len;
            // Extract the payload from the union
            inline for (fields, 0..) |field, i| {
                if (i == list_idx) {
                    const payload = @field(value, field.name);
                    try self.lists[list_idx].append(allocator, payload);
                    break;
                }
            }

            return .{ .tag = tag, .idx = item_idx };
        }

        // Swap remove an item
        pub fn swapRemove(self: *Self, tag: Tag, idx: usize) ?struct { tag: Tag, idx: usize } {
            const list_idx = tag_indexer.indexOf(tag);
            const list = &self.lists[list_idx];

            if (idx >= list.items.len) return null;

            if (idx == list.items.len - 1) {
                _ = list.pop();
                return null;
            }

            list.swapRemove(idx);
            return .{ .tag = tag, .idx = idx };
        }

        // Get the length of a specific list
        pub fn len(self: *Self, tag: Tag) usize {
            const list_idx = tag_indexer.indexOf(tag);
            return self.lists[list_idx].items.len;
        }
    };
}

test "ArrayOfArrayLists using tagged union" {
    // Define our node types with a tagged union
    const NodeType = union(enum) {
        NodeA: struct {
            value: i32,
            name: []const u8,
        },
        NodeB: struct {
            flag: bool,
            count: usize,
        },
    };

    // Create an ArrayOfArrayLists with our union type
    var array_lists = ArrayOfArrayLists(NodeType).init();
    defer array_lists.deinit(std.testing.allocator);

    // Insert elements
    const a1 = try array_lists.append(.{ .NodeA = .{ .value = 42, .name = "test1" } }, std.testing.allocator);
    const a2 = try array_lists.append(.{ .NodeA = .{ .value = 100, .name = "test2" } }, std.testing.allocator);
    _ = a2;
    const b1 = try array_lists.append(.{ .NodeB = .{ .flag = true, .count = 5 } }, std.testing.allocator);

    // Verify lengths
    try std.testing.expectEqual(@as(usize, 2), array_lists.len(.NodeA));
    try std.testing.expectEqual(@as(usize, 1), array_lists.len(.NodeB));

    // Get and mutate elements
    {
        const node_a1 = try array_lists.getItemPtr(a1.tag, a1.idx);
        try std.testing.expectEqual(@as(i32, 42), node_a1.value);
        try std.testing.expectEqualStrings("test1", node_a1.name);
        // Mutate the node
        node_a1.value = 99;

        const node_b1 = try array_lists.getItemPtr(b1.tag, b1.idx);
        try std.testing.expect(node_b1.flag);
        try std.testing.expectEqual(@as(usize, 5), node_b1.count);
        // Mutate the node
        node_b1.count = 10;
    }

    // Verify mutations
    {
        const node_a1 = try array_lists.getItemPtr(a1.tag, a1.idx);
        try std.testing.expectEqual(@as(i32, 99), node_a1.value); // Changed from 42 to 99

        const node_b1 = try array_lists.getItemPtr(b1.tag, b1.idx);
        try std.testing.expectEqual(@as(usize, 10), node_b1.count); // Changed from 5 to 10
    }

    // Delete elements
    _ = array_lists.swapRemove(a1.tag, a1.idx);

    // Verify the deletion (a2 should now be at index 0)
    try std.testing.expectEqual(@as(usize, 1), array_lists.len(.NodeA));

    const node_a0 = try array_lists.getItemPtr(.NodeA, 0);
    try std.testing.expectEqual(@as(i32, 100), node_a0.value); // This was a2
    try std.testing.expectEqualStrings("test2", node_a0.name);
}
