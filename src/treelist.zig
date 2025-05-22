/// trims prefixed namespaces from a string
fn trimNamespace(name: []const u8) []const u8 {
    const lastDot = if (std.mem.lastIndexOf(u8, name, ".")) |val| val + 1 else 0;
    return name[lastDot..];
}

fn interface(node_types: anytype) void {
    inline for (node_types) |T| {
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

        pub fn isNone(self: @This()) bool {
            return self.idx == std.math.maxInt(u32);
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

pub fn TreeList(comptime node_types: anytype) type {
    // Generate table enum from node types
    const TypeEnum = blk: {
        var enum_fields: [node_types.len]std.builtin.Type.EnumField = undefined;
        inline for (node_types, 0..) |T, i| {
            enum_fields[i] = .{
                .name = @typeName(T),
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

    interface(node_types);

    // Create the Storage struct type with an ArrayList field for each node type
    const Storage = blk: {
        var fields: [node_types.len]std.builtin.Type.StructField = undefined;

        inline for (node_types, 0..) |T, i| {
            const list_type = std.ArrayListUnmanaged(T);
            fields[i] = .{
                .name = @typeName(T),
                .type = list_type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(list_type),
            };
        }

        break :blk @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = false,
            },
        });
    };

    const TypeUnion = blk: {
        var union_fields: [node_types.len]std.builtin.Type.UnionField = undefined;
        inline for (node_types, 0..) |T, i| {
            union_fields[i] = .{
                .name = @typeName(T),
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
        var union_fields: [node_types.len]std.builtin.Type.UnionField = undefined;
        inline for (node_types, 0..) |T, i| {
            union_fields[i] = .{
                .name = @typeName(T),
                // .name = @typeName(T) ++ "Ptr",
                // .name = trimNamespace(@typeName(T)) ++ "Ptr",
                // trimNamespace
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
        const MAX_TREE_HEIGHT = 128;

        /// Storage for each node type
        storage: Storage = undefined,
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
                    return;
                }

                // If this node has a sibling, go there next
                if (switch (node_ptr) {
                    inline else => |ptr| ptr.sibling,
                }) |sibling_u64| {
                    const sibling = Loc.fromU64(sibling_u64);
                    self.current = sibling;
                    return;
                }

                // Otherwise, go up to parent and look for next sibling
                self.ascendToSibling(current, node_ptr);

                return node_ptr;
            }

            /// Move up to parent and find next sibling - no stack needed!
            fn ascendToSibling(self: *Iterator, current_loc: Loc, current_node: PtrUnion) void {
                var current = current_loc;

                // Go up the parent chain until we find a node with a sibling
                while (true) {
                    // Get parent location
                    const parent_opt = switch (current_node) {
                        inline else => |ptr| ptr.parent,
                    };

                    // If no parent, we're done
                    if (parent_opt == null) {
                        self.current = null;
                        return;
                    }

                    // If we've reached our starting root, we're done
                    if (parent_opt.? == self.start_root.toU64()) {
                        self.current = null;
                        return;
                    }

                    const parent_loc = Loc.fromU64(parent_opt.?);

                    const parent_ptr = self.tree_list.getNodePtr(parent_loc).?;

                    if (switch (parent_ptr) {
                        inline else => |ptr| ptr.sibling,
                    }) |sibling_u64| {
                        // Found a sibling of parent, move there
                        const sibling = Loc.fromU64(sibling_u64);
                        self.current = sibling;
                        return;
                    } else {
                        // No sibling for this parent, continue up the chain
                        current = parent_loc;
                    }
                }
            }
        };

        pub const empty: @This() = .{};

        pub fn init(self: *Self) !void {
            // Initialize each storage array
            inline for (node_types) |T| {
                @field(self.storage, @typeName(T)) = .empty;
            }
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // Free each storage array
            inline for (node_types) |T| {
                @field(self.storage, @typeName(T)).deinit(allocator);
            }

            // Free the string pool
            self.string_pool.deinit(allocator);

            // Free the roots map
            self.roots.deinit(allocator);
        }

        /// Append a node value to the tree list
        pub fn append(self: *Self, comptime T: type, value: T, allocator: std.mem.Allocator) !Location(TypeEnum) {
            // Find the enum value for this type
            const table_value = @field(TypeEnum, @typeName(T));

            // Get the array list for this type
            var list = &@field(self.storage, @typeName(T));

            // Add the node with the provided value
            const idx = list.items.len;
            try list.append(allocator, value);

            return Location(TypeEnum){
                .table = table_value,
                .idx = @intCast(idx),
            };
        }

        /// Get a node as a tagged union for type-safe access
        pub fn getNode(self: *Self, loc: Loc) ?NodeUnion {
            inline for (node_types) |T| {
                if (loc.table == @field(TypeEnum, @typeName(T))) {
                    const list = &@field(self.storage, @typeName(T));
                    if (loc.idx >= list.items.len) return null;

                    // Create and return the union directly
                    return @unionInit(NodeUnion, @typeName(T), list.items[loc.idx]);
                }
            }
            return null;
        }

        /// Get a typed pointer to a node
        pub fn getNodeAs(self: *Self, comptime T: type, loc: Location(TypeEnum)) ?*T {
            if (loc.table != @field(TypeEnum, @typeName(T))) return null;

            var list = &@field(self.storage, @typeName(T));
            if (loc.idx >= list.items.len) return null;

            return &list.items[loc.idx];
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
                    const child = self.getNodePtr(child_loc).?;
                    switch (child) {
                        inline else => |child_node| child_node.sibling = parent_node.child,
                    }
                    parent_node.child = child_loc.toU64();
                },
            }
        }

        /// Create an iterator for traversing the tree
        pub fn iterator(self: *Self, root: Loc) Iterator {
            return Iterator.init(self, root);
        }

        /// Get a typed pointer to a node as a union of pointers
        /// This provides direct access for modifying node properties with full type safety
        pub fn getNodePtr(self: *Self, loc: Loc) ?PtrUnion {
            inline for (node_types) |T| {
                if (loc.table == @field(TypeEnum, @typeName(T))) {
                    var list = &@field(self.storage, @typeName(T));
                    if (loc.idx >= list.items.len) return null;

                    // Create and return the pointer union
                    return @unionInit(PtrUnion, @typeName(T), &list.items[loc.idx]);
                }
            }
            return null;
        }

        /// Create an iterator from a named root
        pub fn iteratorFromRoot(self: *Self, name: []const u8) ?Iterator {
            const root_loc = self.getRoot(name) orelse return null;
            return Iterator.init(self, root_loc);
        }
    };
}

const std = @import("std");
const StringPool = @import("string_interning.zig");
