const std = @import("std");

/// A type registry that maps struct fields to enum values for direct indexing
pub fn TypeRegistry(comptime Types: type) type {
    return struct {
        // Generate type IDs at compile time
        pub const TypeId = blk: {
            const fields = @typeInfo(Types).@"struct".fields;

            // Create enum fields
            var enum_fields: [fields.len + 1]std.builtin.Type.EnumField = undefined;

            // Add a field for each type
            for (fields, 0..) |field, i| {
                enum_fields[i] = .{
                    .name = field.name,
                    .value = i,
                };
            }

            // Add _count field
            enum_fields[fields.len] = .{
                .name = "_count",
                .value = fields.len,
            };

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

        // Get the actual type for a TypeId
        pub fn TypeFromId(comptime id: TypeId) type {
            const fields = @typeInfo(Types).@"struct".fields;
            const tag_name = @tagName(id);

            // Skip _count which isn't a real field
            if (comptime std.mem.eql(u8, tag_name, "_count")) {
                @compileError("Cannot get type for _count");
            }

            // Find the field with matching name and return its type
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, tag_name)) {
                    return field.defaultValue().?;
                }
            }

            @compileError("No field named " ++ tag_name);
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
    try std.testing.expectEqual(@as(usize, 3), enum_fields.len); // field1, field2, _count

    // Check that the enum values match the expected indices
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(id1));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(id2));

    // Check that _count is correct
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Registry.TypeId._count));

    // Check that we can retrieve the correct types
    try std.testing.expectEqual(u8, Registry.TypeFromId(.field1));
    try std.testing.expectEqual(u16, Registry.TypeFromId(.field2));
}

/// A storage container that allows direct indexing into arrays of different types
pub fn DirectStorage(comptime Types: type) type {
    return struct {
        const Self = @This();
        const Registry = TypeRegistry(Types);
        pub const TypeId = Registry.TypeId;

        // Storage arrays - directly accessible by TypeId
        arrays: [@intFromEnum(TypeId._count)]ArrayData = undefined,

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
            inline for (@typeInfo(TypeId).@"enum".fields, 0..) |field, i| {
                if (field.name[0] != '_') { // Skip _count
                    const T = Registry.TypeFromId(@as(TypeId, @enumFromInt(i)));
                    self.arrays[i] = ArrayData.init(T);
                }
            }
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            inline for (@typeInfo(TypeId).@"enum".fields, 0..) |field, i| {
                if (field.name[0] != '_') {
                    self.arrays[i].deinit(allocator);
                }
            }
        }

        // Add an item of a specific type - returns the index
        pub fn append(self: *Self, comptime id: TypeId, value: Registry.TypeFromId(id), allocator: std.mem.Allocator) !usize {
            return try self.arrays[@intFromEnum(id)].append(allocator, value);
        }

        // Get a typed pointer to an item - no branching, direct indexing
        pub fn getPtr(self: *Self, comptime id: TypeId, idx: usize) ?*Registry.TypeFromId(id) {
            return self.arrays[@intFromEnum(id)].getPtr(Registry.TypeFromId(id), idx);
        }

        // Get a slice of all items of a type - no branching
        pub fn items(self: *Self, comptime id: TypeId) []Registry.TypeFromId(id) {
            return self.arrays[@intFromEnum(id)].getSlice(Registry.TypeFromId(id));
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
