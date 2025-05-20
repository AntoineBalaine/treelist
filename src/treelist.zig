pub fn Location(comptime TableEnum: type) type {
    return packed struct {
        table: TableEnum,
        idx: u32,

        pub fn toU64(self: @This()) u64 {
            return (@as(u64, @intFromEnum(self.table))) | self.idx;
        }

        pub fn fromU64(value: u64) @This() {
            return .{
                .table = @enumFromInt(value),
                .idx = @truncate(value),
            };
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
    };
}

pub fn TreeList(comptime node_types: anytype) type {
    // Generate table enum from node types
    const TableEnum = blk: {
        var enum_fields: [node_types.len]std.builtin.Type.EnumField = undefined;
        inline for (node_types, 0..) |T, i| {
            enum_fields[i] = .{
                .name = @typeName(T),
                .value = i,
            };
        }
        break :blk @Type(.{
            .Enum = .{
                .tag_type = u32,
                .fields = &enum_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    };

    // Validate that all node types have the required fields
    inline for (node_types) |T| {
        // Check for child field with the right type
        if (!@hasField(T, "child")) {
            @compileError("Node type '" ++ @typeName(T) ++ "' is missing required 'child' field");
        }

        // Check for sibling field with the right type
        if (!@hasField(T, "sibling")) {
            @compileError("Node type '" ++ @typeName(T) ++ "' is missing required 'sibling' field");
        }

        // Check field types - must be optional locations
        const ChildType = @TypeOf(@field(@as(T, undefined), "child"));
        const SiblingType = @TypeOf(@field(@as(T, undefined), "sibling"));

        if (ChildType != ?u64) {
            @compileError("Node type '" ++ @typeName(T) ++ "' has 'child' field of invalid type. Expected ?u64, got " ++ @typeName(ChildType));
        }

        if (SiblingType != ?u64) {
            @compileError("Node type '" ++ @typeName(T) ++ "' has 'sibling' field of invalid type. Expected ?u64, got " ++ @typeName(SiblingType));
        }
    }

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
            .Union = .{
                .layout = .auto,
                .tag_type = TableEnum,
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
                .name = @typeName(T) ++ "Ptr",
                .type = *T,
                .alignment = @alignOf(*T),
            };
        }
        break :blk @Type(.{
            .Union = .{
                .layout = .auto,
                .tag_type = TableEnum,
                .fields = &union_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
            },
        });
    };
    return struct {
        const Self = @This();
        pub const Loc = Location(TableEnum);
        pub const NodeUnion = TypeUnion;
        pub const PtrUnion = NodePtrUnion;
        const MAX_TREE_HEIGHT = 128;

        /// Storage for each node type
        storage: Storage = undefined,
        /// String pool for interning strings
        string_pool: StringPool = .empty,
        /// Map from string refs to root nodes
        roots: std.AutoHashMapUnmanaged(StringPool.StringRef, Location(TableEnum)) = .{},

        /// Iterator for traversing the tree without allocations
        pub const Iterator = struct {
            tree_list: *Self,
            current: ?Loc,
            // Fixed-size stack to avoid allocations
            stack: [MAX_TREE_HEIGHT]Loc = undefined,
            stack_len: usize = 0,

            /// Create a new iterator starting at a given root
            pub fn init(tree_list: *Self, root: Loc) Iterator {
                return .{
                    .tree_list = tree_list,
                    .current = root,
                    .stack_len = 0,
                };
            }

            /// Get the next node in depth-first traversal (child first, then sibling)
            pub fn next(self: *Iterator) ?PtrUnion {
                const current = self.current orelse return null;

                // Get the current node pointer
                const node_ptr = self.tree_list.getNodePtr(current) orelse return null;

                // Prepare to move to the next node
                self.moveToNext(current, node_ptr);

                return node_ptr;
            }

            /// Get the next node in sibling-first traversal (breadth-like)
            pub fn nextSiblingFirst(self: *Iterator) ?PtrUnion {
                const current = self.current orelse return null;

                // Get the current node pointer
                const node_ptr = self.tree_list.getNodePtr(current) orelse return null;

                // Prepare to move to the next node (sibling first)
                self.moveToNextSiblingFirst(current, node_ptr);

                return node_ptr;
            }

            /// Helper to move to the next node in depth-first order (child first)
            fn moveToNext(self: *Iterator, current_loc: Loc, current_node: PtrUnion) void {

                // If this node has a child, go there next
                if (switch (current_node) {
                    inline else => |ptr| ptr.child,
                }) |child_u64| {
                    const child = Loc.fromU64(child_u64);

                    // Save current location for backtracking
                    if (self.stack_len < self.stack.len) {
                        self.stack[self.stack_len] = current_loc;
                        self.stack_len += 1;
                    }
                    self.current = child;
                    return;
                }

                // If this node has a sibling, go there next
                if (switch (current_node) {
                    inline else => |ptr| ptr.sibling,
                }) |sibling_u64| {
                    const sibling = Loc.fromU64(sibling_u64);
                    self.current = sibling;
                    return;
                }

                // Otherwise, backtrack and look for a sibling of an ancestor
                self.backtrackToNextBranch();
            }

            /// Backtrack up the tree until we find a node with an unused sibling
            fn backtrackToNextBranch(self: *Iterator) void {
                while (self.stack_len > 0) {
                    self.stack_len -= 1;
                    const parent_loc = self.stack[self.stack_len];

                    // Get the parent node pointer
                    if (self.tree_list.getNodePtr(parent_loc)) |parent_ptr| {
                        // Get parent's sibling
                        const parent_sibling_opt = switch (parent_ptr) {
                            inline else => |ptr| ptr.sibling,
                        };

                        if (parent_sibling_opt) |parent_sibling_u64| {
                            const parent_sibling = Loc.fromU64(parent_sibling_u64);
                            self.current = parent_sibling;
                            return;
                        }
                    }
                    // Continue backtracking if this parent has no sibling
                }

                // If we've exhausted all nodes, mark as done
                self.current = null;
            }

            /// Helper to move to the next node in sibling-first order (breadth-like)
            fn moveToNextSiblingFirst(self: *Iterator, current_loc: Loc, current_node: PtrUnion) void {
                // If this node has a sibling, go there first
                if (switch (current_node) {
                    inline else => |ptr| ptr.sibling,
                }) |sibling_u64| {
                    const sibling = Loc.fromU64(sibling_u64);
                    self.current = sibling;
                    return;
                }

                // If no sibling but has a child, go to child
                if (switch (current_node) {
                    inline else => |ptr| ptr.child,
                }) |child_u64| {
                    const child = Loc.fromU64(child_u64);

                    // Save current location for backtracking
                    if (self.stack_len < self.stack.len) {
                        self.stack[self.stack_len] = current_loc;
                        self.stack_len += 1;
                    }
                    self.current = child;
                    return;
                }

                // Otherwise, backtrack and look for a child of an ancestor
                self.backtrackToNextChild();
            }

            /// Backtrack up the tree until we find a node with an unused child
            fn backtrackToNextChild(self: *Iterator) void {
                while (self.stack_len > 0) {
                    self.stack_len -= 1;
                    const parent_loc = self.stack[self.stack_len];

                    // Get the parent node pointer
                    if (self.tree_list.getNodePtr(parent_loc)) |parent_ptr| {
                        // Get parent's child
                        const parent_child_opt = switch (parent_ptr) {
                            inline else => |ptr| ptr.child,
                        };

                        if (parent_child_opt) |parent_child_u64| {
                            const parent_child = Loc.fromU64(parent_child_u64);
                            self.current = parent_child;
                            return;
                        }
                    }
                    // Continue backtracking if this parent has no child
                }

                // If we've exhausted all nodes, mark as done
                self.current = null;
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

        /// Create a new node of a specific type
        pub fn createNode(self: *Self, comptime T: type, allocator: std.mem.Allocator) !Location(TableEnum) {
            // Find the enum value for this type
            const table_value = @field(TableEnum, @typeName(T));

            // Get the array list for this type
            var list = &@field(self.storage, @typeName(T));

            // Add a new node
            const idx = list.items.len;
            try list.append(allocator, .{
                .child = null,
                .sibling = null,
            });

            return Location(TableEnum){
                .table = table_value,
                .idx = @intCast(idx),
            };
        }

        /// Get a node as a tagged union for type-safe access
        pub fn getNode(self: *Self, loc: Loc) ?NodeUnion {
            inline for (node_types) |T| {
                if (loc.table == @field(TableEnum, @typeName(T))) {
                    const list = &@field(self.storage, @typeName(T));
                    if (loc.idx >= list.items.len) return null;

                    // Create and return the union directly
                    return @unionInit(NodeUnion, @typeName(T), list.items[loc.idx]);
                }
            }
            return null;
        }

        /// Get a typed pointer to a node
        pub fn getNodeAs(self: *Self, comptime T: type, loc: Location(TableEnum)) ?*T {
            if (loc.table != @field(TableEnum, @typeName(T))) return null;

            var list = &@field(self.storage, @typeName(T));
            if (loc.idx >= list.items.len) return null;

            return &list.items[loc.idx];
        }

        /// Add a root node with a name
        pub fn addRoot(self: *Self, name: []const u8, loc: Location(TableEnum), allocator: std.mem.Allocator) !void {
            const name_ref = try self.string_pool.add(allocator, name);
            try self.roots.put(allocator, name_ref, loc);
        }

        /// Get a root node by name
        pub fn getRoot(self: *Self, name: []const u8) ?Location(TableEnum) {
            // Try to find the string in the pool without adding it
            const adapter = StringPool.TableIndexAdapter{ .bytes = self.string_pool.bytes.items };
            const context = StringPool.TableContext{ .bytes = self.string_pool.bytes.items };

            if (self.string_pool.table.getKeyAdapted(name, adapter, context)) |name_ref| {
                return self.roots.get(name_ref);
            }

            return null;
        }

        /// Add a child to a parent node
        pub fn addChild(
            self: *Self,
            parent_loc: Location(TableEnum),
            child_loc: Location(TableEnum),
        ) !void {
            // Get parent node
            const parent = self.getNode(parent_loc).?;
            switch (parent) {
                inline else => |*parent_node| {
                    const child = self.getNode(child_loc).?;
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
                if (loc.table == @field(TableEnum, @typeName(T))) {
                    var list = &@field(self.storage, @typeName(T));
                    if (loc.idx >= list.items.len) return null;

                    // Create and return the pointer union
                    return @unionInit(PtrUnion, @typeName(T) ++ "Ptr", &list.items[loc.idx]);
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
const StringPool = @import("../string_interning.zig");
