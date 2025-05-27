const std = @import("std");

/// A type registry that maps struct fields to enum values for direct indexing
pub fn TypeRegistry(comptime TypeStruct: type) type {
    return struct {
        // Generate type IDs at compile time
        pub const TypeId = blk: {
            const fields = @typeInfo(TypeStruct).@"struct".fields;

            // Create enum fields - without _count
            var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;

            // Add a field for each type
            for (fields, 0..) |field, i| {
                enum_fields[i] = .{
                    .name = field.name,
                    .value = i,
                };
            }

            // Create the enum type
            break :blk @Type(.{
                .@"enum" = .{
                    .tag_type = u32,
                    .fields = &enum_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            });
        };

        /// Get the TypeId for a given type
        pub fn idFromType(comptime T: type) TypeId {
            inline for (@typeInfo(TypeId).@"enum".fields, 0..) |_, i| {
                if (Types[i] == T) {
                    return @as(TypeId, @enumFromInt(i));
                }
            }
            @compileError("Type not found in registry");
        }

        pub const Types = blk: {
            const fields = @typeInfo(TypeStruct).@"struct".fields;
            var types: [fields.len]type = undefined;

            for (fields, 0..) |field, i| {
                types[i] = field.defaultValue().?;
            }

            break :blk types;
        };

        pub fn typeFromId(id: TypeId) type {
            const idx = @intFromEnum(id);
            std.debug.assert(idx < Types.len);
            return Types[idx];
        }
    };
}

test "TypeRegistry with two fields" {
    // Define a struct with two fields
    const TestTypes = struct {
        field1: type = u8,
        field2: type = u16,
    };

    // Create a TypeRegistry
    const Registry = TypeRegistry(TestTypes);

    // Check that we can access fields using enum literals
    const id1 = Registry.TypeId.field1;
    const id2 = Registry.TypeId.field2;

    // Check the length of the enum fields
    const enum_fields = @typeInfo(Registry.TypeId).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 2), enum_fields.len); // field1, field2

    // Check that the enum values match the expected indices
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(id1));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(id2));

    try std.testing.expectEqual(@as(usize, 2), Registry.Types.len);

    // Check that we can retrieve the correct types
    try std.testing.expectEqual(u8, Registry.typeFromId(.field1));
    try std.testing.expectEqual(u16, Registry.typeFromId(.field2));
    try std.testing.expectEqual(u8, Registry.typeFromId(.field1));

    // Check that idFromType works correctly
    try std.testing.expectEqual(id1, Registry.idFromType(u8));
    try std.testing.expectEqual(id2, Registry.idFromType(u16));
}

/// A storage container that allows direct indexing into arrays of different types
pub fn DirectStorage(comptime Types: type) type {
    return struct {
        const Self = @This();
        const Registry = TypeRegistry(Types);
        pub const TypeId = Registry.TypeId;

        // Storage arrays - directly accessible by TypeId
        arrays: [Registry.Types.len]ArrayData = undefined,

        const ArrayData = struct {
            data: [*]u8 = undefined,
            len: usize = 0,
            capacity: usize = 0,
            elem_size: usize,

            fn init(comptime T: type) ArrayData {
                return .{
                    .elem_size = @sizeOf(T),
                };
            }

            fn deinit(self: *ArrayData, allocator: std.mem.Allocator) void {
                if (self.capacity > 0) {
                    allocator.free(self.data[0 .. self.capacity * self.elem_size]);
                }
            }

            fn ensureCapacity(self: *ArrayData, allocator: std.mem.Allocator, new_capacity: usize) !void {
                if (self.capacity >= new_capacity) return;

                const new_data = try allocator.alloc(u8, new_capacity * self.elem_size);
                if (self.len > 0) {
                    @memcpy(new_data[0 .. self.len * self.elem_size], self.data[0 .. self.len * self.elem_size]);
                }

                if (self.capacity > 0) {
                    allocator.free(self.data[0 .. self.capacity * self.elem_size]);
                }

                self.data = new_data.ptr;
                self.capacity = new_capacity;
            }

            fn append(self: *ArrayData, allocator: std.mem.Allocator, value: anytype) !usize {
                if (self.len >= self.capacity) {
                    try self.ensureCapacity(allocator, if (self.capacity == 0) 4 else self.capacity * 2);
                }

                const idx = self.len;
                const ptr = self.data + (idx * self.elem_size);
                @memcpy(ptr[0..self.elem_size], std.mem.asBytes(&value));
                self.len += 1;
                return idx;
            }

            fn getPtr(self: *ArrayData, comptime T: type, idx: usize) ?*T {
                if (idx >= self.len) return null;
                const ptr = self.data + (idx * self.elem_size);
                return @ptrCast(@alignCast(ptr));
            }

            fn getSlice(self: *ArrayData, comptime T: type) []T {
                const typed_ptr: [*]T = @ptrCast(@alignCast(self.data));
                return typed_ptr[0..self.len];
            }
        };

        pub fn init() Self {
            var self: Self = undefined;
            inline for (@typeInfo(TypeId).@"enum".fields, 0..) |_, i| {
                const T = Registry.typeFromId(@as(TypeId, @enumFromInt(i)));
                self.arrays[i] = ArrayData.init(T);
            }
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            inline for (@typeInfo(TypeId).@"enum".fields, 0..) |_, i| {
                self.arrays[i].deinit(allocator);
            }
        }

        // Add an item of a specific type - returns the index
        pub fn append(self: *Self, comptime id: TypeId, value: Registry.typeFromId(id), allocator: std.mem.Allocator) !usize {
            return try self.arrays[@intFromEnum(id)].append(allocator, value);
        }

        // Get a typed pointer to an item - no branching, direct indexing
        pub fn getPtr(self: *Self, comptime id: TypeId, idx: usize) ?*Registry.typeFromId(id) {
            return self.arrays[@intFromEnum(id)].getPtr(Registry.typeFromId(id), idx);
        }

        // Get a slice of all items of a type - no branching
        pub fn items(self: *Self, comptime id: TypeId) []Registry.typeFromId(id) {
            return self.arrays[@intFromEnum(id)].getSlice(Registry.typeFromId(id));
        }

        // Count items of a specific type - no branching
        pub fn count(self: *Self, comptime id: TypeId) usize {
            return self.arrays[@intFromEnum(id)].len;
        }
    };
}

test "DirectStorage with struct types" {
    // Define our node types as a struct of types
    const NodeTypes = struct {
        SmallNode: type = struct { id: u32, value: u8 },
        MediumNode: type = struct { id: u32, name: []const u8 },
        LargeNode: type = struct { id: u32, data: [10]u8 },
    };

    // Create storage
    const Storage = DirectStorage(NodeTypes);
    var storage: Storage = .init();
    defer storage.deinit(std.testing.allocator);

    // Type IDs are generated as an enum
    const TypeId = Storage.TypeId;

    // Add items - direct indexing by type
    const small_idx = try storage.append(.SmallNode, .{ .id = 1, .value = 42 }, std.testing.allocator);
    const medium_idx = try storage.append(.MediumNode, .{ .id = 2, .name = "test" }, std.testing.allocator);
    _ = try storage.append(.LargeNode, .{ .id = 3, .data = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } }, std.testing.allocator);

    // Access items - direct indexing, no branching
    if (storage.getPtr(.SmallNode, small_idx)) |node| {
        try std.testing.expectEqual(@as(u32, 1), node.id);
        try std.testing.expectEqual(@as(u8, 42), node.value);

        // Mutate the node
        node.value = 99;
    } else {
        try std.testing.expect(false); // Should not happen
    }

    if (storage.getPtr(TypeId.MediumNode, medium_idx)) |node| {
        try std.testing.expectEqual(@as(u32, 2), node.id);
        try std.testing.expectEqualStrings("test", node.name);
    } else {
        try std.testing.expect(false); // Should not happen
    }

    // Verify mutation
    if (storage.getPtr(TypeId.SmallNode, small_idx)) |node| {
        try std.testing.expectEqual(@as(u8, 99), node.value); // Changed from 42 to 99
    }

    // Get all items of a type - direct slice access
    const all_small_nodes = storage.items(.SmallNode);
    try std.testing.expectEqual(@as(usize, 1), all_small_nodes.len);
    try std.testing.expectEqual(@as(u32, 1), all_small_nodes[0].id);
    try std.testing.expectEqual(@as(u8, 99), all_small_nodes[0].value);

    // Count items
    try std.testing.expectEqual(@as(usize, 1), storage.count(.SmallNode));
    try std.testing.expectEqual(@as(usize, 1), storage.count(.MediumNode));
    try std.testing.expectEqual(@as(usize, 1), storage.count(.LargeNode));
}
