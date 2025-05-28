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

        pub const Types = blk: {
            const fields = @typeInfo(TypeStruct).@"struct".fields;
            var types: [fields.len]type = undefined;

            for (fields, 0..) |field, i| {
                types[i] = field.defaultValue().?;
            }

            break :blk types;
        };

        pub fn idFromType(comptime T: type) TypeId {
            inline for (@typeInfo(TypeId).@"enum".fields, 0..) |_, i| {
                if (Types[i] == T) {
                    return @as(TypeId, @enumFromInt(i));
                }
            }
            @compileError("mismatched enum type");
        }

        pub fn typeFromId(id: TypeId) type {
            const idx = @intFromEnum(id);
            std.debug.assert(idx < Types.len);
            return Types[idx];
        }
    };
}

/// trims prefixed namespaces from a string
fn trimNamespace(name: []const u8) []const u8 {
    const lastDot = if (std.mem.lastIndexOf(u8, name, ".")) |val| val + 1 else 0;
    return name[lastDot..];
}

fn interface(T: type) void {
    // Check for child field with the right type
    if (!@hasField(T, "child")) {
        @compileError("Node type '" ++ @typeName(T) ++ "' is missing required 'child' field");
    }
    const ChildType = @TypeOf(@field(@as(T, undefined), "child"));
    if (ChildType != ?u64) {
        @compileError("Node type '" ++ @typeName(T) ++ "' has 'child' field of invalid type. Expected ?u64, got " ++ @typeName(ChildType));
    }

    if (!@hasField(T, "sibling")) {
        @compileError("Node type '" ++ @typeName(T) ++ "' is missing required 'sibling' field");
    }
    const SiblingType = @TypeOf(@field(@as(T, undefined), "sibling"));
    if (SiblingType != ?u64) {
        @compileError("Node type '" ++ @typeName(T) ++ "' has 'sibling' field of invalid type. Expected ?u64, got " ++ @typeName(SiblingType));
    }

    if (!@hasField(T, "parent")) {
        @compileError("Node type '" ++ @typeName(T) ++ "' is missing required 'parent' field");
    }
    const ParentType = @TypeOf(@field(@as(T, undefined), "parent"));
    if (ParentType != ?u64) {
        @compileError("Node type '" ++ @typeName(T) ++ "' has 'parent' field of invalid type. Expected ?u64, got " ++ @typeName(ParentType));
    }
}

pub fn Location(comptime TableEnum: type) type {
    return packed struct {
        table: TableEnum,
        idx: u32,

        pub fn toU64(self: @This()) u64 {
            return @as(u64, @bitCast(self));
        }

        pub fn fromU64(value: u64) @This() {
            return @as(@This(), @bitCast(value));
        }
    };
}

pub fn NodeInterface(comptime TableEnum: type) type {
    const Loc = Location(TableEnum);

    return struct {
        // These fields must be in every node type
        child: ?Loc = null,
        sibling: ?Loc = null,
        parent: ?Loc = null, // New parent pointer
    };
}

pub fn TreeList(comptime Types: type) type {
    // Verify Types is a struct with type fields
    if (@typeInfo(Types) != .@"struct") {
        @compileError("Types must be a struct");
    }

    const Registry = TypeRegistry(Types);
    const TypeEnum = Registry.TypeId;

    inline for (Registry.Types) |T| {
        interface(T);
    }

    // Create union type for node values
    const TypeUnion = blk: {
        var union_fields: [Registry.Types.len]std.builtin.Type.UnionField = undefined;

        inline for (@typeInfo(TypeEnum).@"enum".fields, 0..) |field, i| {
            const T = Registry.typeFromId(@as(TypeEnum, @enumFromInt(i)));
            union_fields[i] = .{
                .name = field.name,
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

    // Create union type for node pointers
    const NodePtrUnion = blk: {
        var union_fields: [Registry.Types.len]std.builtin.Type.UnionField = undefined;

        inline for (@typeInfo(TypeEnum).@"enum".fields, 0..) |field, i| {
            const T = Registry.typeFromId(@as(TypeEnum, @enumFromInt(i)));
            union_fields[i] = .{
                .name = field.name,
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

    return struct {
        const Self = @This();
        pub const Loc = Location(TypeEnum);
        pub const TableEnum = TypeEnum;
        pub const NodeUnion = TypeUnion;
        pub const PtrUnion = NodePtrUnion;
        pub const Reg = Registry;
        const MAX_TREE_HEIGHT = 128;

        // Storage arrays - specialized for each type with proper alignment
        arrays: [Registry.Types.len]anyopaque = undefined,

        /// String pool for interning strings
        string_pool: StringPool = .empty,
        /// Map from string refs to root nodes
        roots: std.AutoHashMapUnmanaged(StringPool.StringRef, Location(TypeEnum)) = .{},

        /// Iterator for traversing the tree without allocations
        pub const Iterator = struct {
            tree_list: *Self,
            current: ?Loc,
            start_root: Loc, // Keep track of the starting root to know when we're done

            /// Create a new iterator starting at a given root
            pub fn init(tree_list: *Self, root: Loc) Iterator {
                return .{
                    .tree_list = tree_list,
                    .current = root,
                    .start_root = root,
                };
            }

            /// Get the next node in depth-first traversal (child first, then sibling)
            pub fn nextDepth(self: *Iterator) ?PtrUnion {
                const current = self.current orelse return null;

                // Get the current node pointer
                const node_ptr = self.tree_list.getNodePtr(current) orelse return null;

                // If this node has a child, go there next
                if (switch (node_ptr) {
                    inline else => |ptr| ptr.child,
                }) |child_u64| {
                    const child = Loc.fromU64(child_u64);
                    self.current = child;
                } else if (switch (node_ptr) {
                    inline else => |ptr| ptr.sibling,
                }) |sibling_u64| {
                    // If this node has a sibling, go there next
                    const sibling = Loc.fromU64(sibling_u64);
                    self.current = sibling;
                } else {
                    // Otherwise, go up to parent and look for next sibling
                    self.ascendToSibling(current, node_ptr);
                }

                return node_ptr;
            }

            /// Move up to parent and find next sibling - no stack needed!
            fn ascendToSibling(self: *Iterator, current_loc: Loc, current_node: PtrUnion) void {
                // Get parent location
                const parent_u64 = switch (current_node) {
                    inline else => |ptr| ptr.parent,
                } orelse {
                    self.current = null;
                    return;
                };

                if (parent_u64 == self.start_root.toU64()) {
                    self.current = null;
                    return;
                }

                const parent_loc = Loc.fromU64(parent_u64);

                const parent = self.tree_list.getNodePtr(parent_loc).?;
                const child_opt = switch (parent) {
                    inline else => |prnt| prnt.child,
                };

                if (child_opt) |child| {
                    if (child == current_loc.toU64()) {
                        if (switch (parent) {
                            inline else => |prnt| prnt.sibling,
                        }) |sib| {
                            self.current = Loc.fromU64(sib);
                            return;
                        }
                    }
                }

                // Current node is not the direct child of parent, or parent has no sibling
                // Continue up the chain
                self.ascendToSibling(parent_loc, parent);
            }
        };

        pub const empty: @This() = .{};

        pub fn init(self: *Self) void {
            // Initialize each array with proper alignment
            inline for (@typeInfo(TypeEnum).@"enum".fields, 0..) |_, i| {
                const T = Registry.typeFromId(@as(TypeEnum, @enumFromInt(i)));
                const ArrayT = ArrayData(T);
                const array_ptr: *ArrayT = @ptrCast(&self.arrays[i]);
                array_ptr.* = ArrayT.init();
            }
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // Free each array with proper alignment
            inline for (@typeInfo(TypeEnum).@"enum".fields, 0..) |_, i| {
                const T = Registry.typeFromId(@as(TypeEnum, @enumFromInt(i)));
                const ArrayT = ArrayData(T);
                const array_ptr: *ArrayT = @ptrCast(&self.arrays[i]);
                array_ptr.deinit(allocator);
            }

            // Free the string pool
            self.string_pool.deinit(allocator);

            // Free the roots map
            self.roots.deinit(allocator);
        }

        /// Append a node value to the tree list
        pub fn append(
            self: *Self,
            comptime id: TypeEnum,
            value: Registry.typeFromId(id),
            allocator: std.mem.Allocator,
        ) !Location(TypeEnum) {
            const T = Registry.typeFromId(id);
            const ArrayT = ArrayData(T);
            const array: *ArrayT = @ptrCast(&self.arrays[@intFromEnum(id)]);
            const idx = try array.append(allocator, value);

            return Location(TypeEnum){
                .table = id,
                .idx = @intCast(idx),
            };
        }

        pub fn appendUnion(
            self: *Self,
            value: NodeUnion,
            allocator: std.mem.Allocator,
        ) !Location(TypeEnum) {
            // Extract the tag and value from the union
            return switch (value) {
                inline else => |typed_value, tag| {
                    const T = @TypeOf(typed_value);
                    const ArrayT = ArrayData(T);
                    const array: *ArrayT = @ptrCast(&self.arrays[@intFromEnum(tag)]);
                    const idx = try array.append(allocator, typed_value);
                    return Location(TypeEnum){
                        .table = tag,
                        .idx = @intCast(idx),
                    };
                },
            };
        }

        /// Get a node as a tagged union for type-safe access
        pub fn getNode(self: *Self, loc: Loc) ?NodeUnion {
            const table_idx = @intFromEnum(loc.table);
            if (table_idx >= Registry.Types.len) return null;

            // Get properly aligned array for this type
            return switch (loc.table) {
                inline else => |tag| blk: {
                    const T = Registry.typeFromId(tag);
                    const ArrayT = ArrayData(T);
                    const array: *ArrayT = @ptrCast(&self.arrays[table_idx]);

                    if (loc.idx >= array.len) break :blk null;

                    const item_ptr: ?*T = array.getPtr(T, loc.idx);
                    const item = item_ptr orelse break :blk null;
                    break :blk @unionInit(NodeUnion, @tagName(tag), item.*);
                },
            };
        }

        /// Get a typed pointer to a node
        pub fn getNodeAs(self: *Self, comptime T: type, loc: Location(TypeEnum)) ?*T {
            const table_idx = @intFromEnum(loc.table);
            if (table_idx >= Registry.Types.len) return null;

            return self.arrays[table_idx].getPtr(T, loc.idx);
        }

        /// Add a root node with a name
        pub fn addRoot(self: *Self, name: []const u8, loc: Location(TypeEnum), allocator: std.mem.Allocator) !void {
            const name_ref = try self.string_pool.add(allocator, name);
            try self.roots.put(allocator, name_ref, loc);
        }

        /// Get a root node by name
        pub fn getRoot(self: *Self, name: []const u8) ?Location(TypeEnum) {
            if (self.string_pool.getStringRef(name)) |name_ref| {
                return self.roots.get(name_ref);
            }

            return null;
        }

        /// Add a child to a parent node
        pub fn addChild(
            self: *Self,
            parent_loc: Location(TypeEnum),
            child_loc: Location(TypeEnum),
        ) void {
            // Get parent node
            const parent = self.getNodePtr(parent_loc).?;
            switch (parent) {
                inline else => |parent_node| {
                    const parent_child_opt = parent_node.child;
                    if (parent_child_opt) |cur_child_loc| {
                        self.addSibling(Loc.fromU64(cur_child_loc), child_loc);
                    } else {
                        const child = self.getNodePtr(child_loc).?;
                        switch (child) {
                            inline else => |child_node| child_node.sibling = parent_node.child,
                        }
                        parent_node.child = child_loc.toU64();
                    }
                },
            }
        }

        pub fn addSibling(
            self: *Self,
            parent_loc: Location(TypeEnum),
            sibling_loc: Location(TypeEnum),
        ) void {
            // Get parent node
            const sibling = self.getNodePtr(sibling_loc).?;
            var current_loc = parent_loc;
            loop: while (true) {
                const current = self.getNodePtr(current_loc).?;

                //check if current node has a sibling
                const next_sibling_opt = switch (current) {
                    inline else => |cur_node| cur_node.sibling,
                };
                if (next_sibling_opt) |next_sibling_loc| {
                    current_loc = Loc.fromU64(next_sibling_loc);
                } else {
                    switch (current) {
                        inline else => |cur_node| {
                            cur_node.sibling = sibling_loc.toU64();
                        },
                    }
                    switch (sibling) {
                        inline else => |sibling_node| {
                            sibling_node.parent = current_loc.toU64();
                        },
                    }
                    break :loop;
                }
            }
        }

        /// Create an iterator for traversing the tree
        pub fn iterator(self: *Self, root: Loc) Iterator {
            return Iterator.init(self, root);
        }

        /// Get a typed pointer to a node as a union of pointers
        pub fn getNodePtr(self: *Self, loc: Loc) ?PtrUnion {
            const table_idx = @intFromEnum(loc.table);
            if (table_idx >= Registry.Types.len) return null;

            // Get properly aligned array for this type
            return switch (loc.table) {
                inline else => |tag| blk: {
                    const T = Registry.typeFromId(tag);
                    const ArrayT = ArrayData(T);
                    const array: *ArrayT = @ptrCast(&self.arrays[table_idx]);

                    if (loc.idx >= array.len) break :blk null;

                    const ptr = array.getPtr(T, loc.idx) orelse break :blk null;
                    break :blk @unionInit(PtrUnion, @tagName(tag), ptr);
                },
            };
        }

        /// Create an iterator from a named root
        pub fn iteratorFromRoot(self: *Self, name: []const u8) ?Iterator {
            const root_loc = self.getRoot(name) orelse return null;
            return Iterator.init(self, root_loc);
        }

        /// Remove a node and all its children from the tree
        /// Uses swap remove to maintain array density
        pub fn swapRemove(self: *Self, location: Loc) void {
            const node_ptr = self.getNodePtr(location).?;

            // Handle parent-child relationship
            switch (node_ptr) {
                inline else => |node| {
                    if (node.child) |child_u64| {
                        self.swapRemove(Loc.fromU64(child_u64));
                    }
                    if (node.parent) |parent_u64| {
                        const node_u64 = location.toU64();
                        const parent_ptr = self.getNodePtr(Loc.fromU64(parent_u64)).?;

                        // Check if this node is the parent's child or sibling
                        switch (parent_ptr) {
                            inline else => |parent| blk: {
                                if (parent.child) |child| {
                                    if (child == node_u64) {
                                        parent.child = node.sibling;
                                        break :blk;
                                    }
                                }

                                if (parent.sibling) |sibling| {
                                    if (sibling == node_u64) {
                                        parent.sibling = node.sibling;
                                    }
                                }
                            },
                        }
                    }
                },
            }

            // Now perform the actual swap remove in the appropriate array
            const table_idx = @intFromEnum(location.table);

            // Get properly aligned array for this type
            const T = Registry.typeFromId(location.table);
            const ArrayT = ArrayData(T);
            const array: *ArrayT = @ptrCast(&self.arrays[table_idx]);

            const last_location = array.swapRemove(location.idx);

            // If we swapped with another node (not the one we just removed)
            if (last_location) |last_idx| {
                self.updateReferences(
                    Loc{ .table = location.table, .idx = @intCast(last_idx) },
                    location,
                );
            }
        }

        /// Update all references to a node that was moved
        fn updateReferences(self: *Self, old_loc: Loc, new_loc: Loc) void {
            const moved_node = self.getNodePtr(new_loc).?;

            // If the swapped node had a parent, update the parent's references
            if (switch (moved_node) {
                inline else => |ptr| ptr.parent,
            }) |parent_u64| {
                const parent = self.getNodePtr(Loc.fromU64(parent_u64)).?;

                const old_u64 = old_loc.toU64();
                const new_u64 = new_loc.toU64();

                switch (parent) {
                    inline else => |parent_node| {
                        if (parent_node.child) |child| {
                            if (child == old_u64) {
                                parent_node.child = new_u64;
                            }
                        }

                        if (parent_node.sibling) |sibling| {
                            if (sibling == old_u64) {
                                parent_node.sibling = new_u64;
                            }
                        }
                    },
                }
            }
        }

        // Get a slice of all items of a type
        pub fn items(self: *Self, comptime id: TypeEnum) []Registry.typeFromId(id) {
            const T = Registry.typeFromId(id);
            const ArrayT = ArrayData(T);
            const array: *ArrayT = @ptrCast(&self.arrays[@intFromEnum(id)]);
            return array.getSlice(T);
        }

        // Count items of a specific type
        pub fn count(self: *Self, comptime id: TypeEnum) usize {
            const T = Registry.typeFromId(id);
            const ArrayT = ArrayData(T);
            const array: *ArrayT = @ptrCast(&self.arrays[@intFromEnum(id)]);
            return array.len;
        }
    };
}

const std = @import("std");
const StringPool = @import("string_interning.zig");
const ArrayData = @import("ArrayData.zig");
