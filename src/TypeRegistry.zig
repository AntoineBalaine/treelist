const std = @import("std");
const comptime_allocator = @import("comptimeAllocator.zig").comptime_allocator;

pub fn TypeRegistry(comptime TypeStruct: type) type {
    return struct {
        pub const Types = blk: {
            const fields = @typeInfo(TypeStruct).@"struct".fields;
            var types: [fields.len]type = undefined;

            for (fields, 0..) |field, i| {
                types[i] = field.defaultValue().?;
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

        // Create the type map at comptime
        const typeMap = blk: {
            var kvs: [Types.len]struct { []const u8, u32 } = undefined;
            // Insert each type with its index
            for (Types, 0..) |T, i| {
                kvs[i] = .{ @typeName(T), i };
            }

            break :blk std.StaticStringMap(u32).initComptime(kvs);
        };

        /// Get the TypeId for a given type
        pub fn idFromType(comptime T: type) TypeId {
            const name = @typeName(T);
            const index = typeMap.get(name) orelse
                @compileError("Type not found in registry: " ++ name);

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

// pub const SymbolResolver = struct {
//     keys: std.ArrayListUnmanaged(Key) = .empty,
//     values: std.ArrayListUnmanaged(Ref) = .empty,
//     table: std.AutoArrayHashMapUnmanaged(void, void) = .empty,
//
//     const Result = struct {
//         found_existing: bool,
//         index: Index,
//         ref: *Ref,
//     };
//
//     pub fn deinit(resolver: *SymbolResolver, allocator: Allocator) void {
//         resolver.keys.deinit(allocator);
//         resolver.values.deinit(allocator);
//         resolver.table.deinit(allocator);
//     }
//
//     pub fn getOrPut(
//         resolver: *SymbolResolver,
//         allocator: Allocator,
//         ref: Ref,
//         macho_file: *MachO,
//     ) !Result {
//         const adapter = Adapter{ .keys = resolver.keys.items, .macho_file = macho_file };
//         const key = Key{ .index = ref.index, .file = ref.file };
//         const gop = try resolver.table.getOrPutAdapted(allocator, key, adapter);
//         if (!gop.found_existing) {
//             try resolver.keys.append(allocator, key);
//             _ = try resolver.values.addOne(allocator);
//         }
//         return .{
//             .found_existing = gop.found_existing,
//             .index = @intCast(gop.index + 1),
//             .ref = &resolver.values.items[gop.index],
//         };
//     }
//
//     pub fn get(resolver: SymbolResolver, index: Index) ?Ref {
//         if (index == 0) return null;
//         return resolver.values.items[index - 1];
//     }
//
//     pub fn reset(resolver: *SymbolResolver) void {
//         resolver.keys.clearRetainingCapacity();
//         resolver.values.clearRetainingCapacity();
//         resolver.table.clearRetainingCapacity();
//     }
//
//     const Key = struct {
//         index: Symbol.Index,
//         file: File.Index,
//
//         fn getName(key: Key, macho_file: *MachO) [:0]const u8 {
//             const ref = Ref{ .index = key.index, .file = key.file };
//             return ref.getSymbol(macho_file).?.getName(macho_file);
//         }
//
//         pub fn getFile(key: Key, macho_file: *MachO) ?File {
//             const ref = Ref{ .index = key.index, .file = key.file };
//             return ref.getFile(macho_file);
//         }
//
//         fn eql(key: Key, other: Key, macho_file: *MachO) bool {
//             const key_name = key.getName(macho_file);
//             const other_name = other.getName(macho_file);
//             return mem.eql(u8, key_name, other_name);
//         }
//
//         fn hash(key: Key, macho_file: *MachO) u32 {
//             const name = key.getName(macho_file);
//             return @truncate(Hash.hash(0, name));
//         }
//     };
//
//     const Adapter = struct {
//         keys: []const Key,
//         macho_file: *MachO,
//
//         pub fn eql(ctx: @This(), key: Key, b_void: void, b_map_index: usize) bool {
//             _ = b_void;
//             const other = ctx.keys[b_map_index];
//             return key.eql(other, ctx.macho_file);
//         }
//
//         pub fn hash(ctx: @This(), key: Key) u32 {
//             return key.hash(ctx.macho_file);
//         }
//     };
//
//     pub const Index = u32;
// };
