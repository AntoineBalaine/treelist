const std = @import("std");
const comptime_allocator = @import("comptimeAllocator.zig").comptime_allocator;

pub fn TypeRegistry(comptime TypeStruct: type) type {
    return struct {
        pub const Types = blk: {
            const fields = @typeInfo(TypeStruct).@"struct".fields;
            var types: [fields.len]type = undefined;

            for (fields, 0..) |field, i| {
                types[i] = field.type;
            }

            break :blk types;
        };

        // Generate type IDs at compile time
        pub const TypeId = blk: {
            const fields = @typeInfo(TypeStruct).@"struct".fields;
            var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;

            for (fields, 0..) |field, i| {
                enum_fields[i] = .{
                    .name = field.name,
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

        // Context for type lookups
        const TypeContext = struct {
            TypesList: [Types.len]type,

            pub fn hash(self: @This(), key: type) u32 {
                _ = self;
                return @truncate(std.hash_map.hashString(@typeName(key)));
            }

            pub fn eql(ctx: @This(), key: type, b_void: void, b_map_index: usize) bool {
                _ = b_void;
                return key == ctx.TypesList[b_map_index];
            }
        };

        const typeMap = blk: {
            var map: std.AutoArrayHashMapUnmanaged(void, void) = .{};

            map.ensureTotalCapacity(comptime_allocator, Types.len) catch unreachable;

            for (Types) |T| {
                const ctx = TypeContext{ .TypesList = Types };
                _ = map.getOrPutAssumeCapacityAdapted(T, ctx);
            }

            break :blk map;
        };

        /// Get the TypeId for a given type
        pub fn idFromType(T: type) TypeId {
            // Use the type context to find the index
            const ctx = TypeContext{ .TypesList = Types };
            const index = typeMap.getIndexAdapted(T, ctx).?;

            return @as(TypeId, @enumFromInt(index));
        }

        /// Get the type from a TypeId
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
