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

    // Create a NodeUnion type for type-safe node access

    // Create the NodeUnion type for returning to users
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
    return struct {
        const Self = @This();
        pub const Loc = Location(TableEnum);
        pub const NodeUnion = TypeUnion;
        const MAX_TREE_HEIGHT = 64; // Maximum tree height for fixed-size stack

        // Storage for each node type
        storage: Storage = undefined,
        // String pool for interning strings
        string_pool: StringPool = .empty,
        // Map from string refs to root nodes
        roots: std.AutoHashMapUnmanaged(StringPool.StringRef, Location(TableEnum)) = .{},
        traversal_stack: std.ArrayListUnmanaged(Location(TableEnum)) = .{},
        max_tree_height: usize = 0,

        // Iterator for traversing the tree without allocations
        pub const Iterator = struct {
            tree_list: *Self,
            current: ?Loc,
            // Fixed-size stack to avoid allocations
            stack: [MAX_TREE_HEIGHT]Loc = undefined,
            stack_len: usize = 0,

            // Create a new iterator starting at a given root
            pub fn init(tree_list: *Self, root: Loc) Iterator {
                return .{
                    .tree_list = tree_list,
                    .current = root,
                    .stack_len = 0,
                };
            }

            // Get the next node in the traversal
            pub fn next(self: *Iterator) ?NodeUnion {
                const current = self.current orelse return null;

                // Get the current node
                const node = self.tree_list.getNode(current) orelse return null;

                // Prepare to move to the next node
                self.moveToNext(current, node);

                return node;
            }

            // Helper to move to the next node in traversal order
            fn moveToNext(self: *Iterator, current_loc: Loc, current_node: NodeUnion) void {

                // If this node has a child, go there next
                if (switch (current_node) {
                    inline else => |*data| data.child,
                }) |child| {
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
                    inline else => |*data| data.sibling,
                }) |sibling| {
                    self.current = sibling;
                    return;
                }

                // Otherwise, backtrack and look for a sibling of an ancestor
                self.backtrackToNextBranch();
            }

            // Backtrack up the tree until we find a node with an unused sibling
            fn backtrackToNextBranch(self: *Iterator) void {
                while (self.stack_len > 0) {
                    self.stack_len -= 1;
                    const parent_loc = self.stack[self.stack_len];

                    // Get the parent node
                    if (self.tree_list.getNode(parent_loc)) |parent| {
                        // Get parent's sibling
                        const parent_sibling_opt = switch (parent) {
                            inline else => |*data| data.sibling,
                        };

                        if (parent_sibling_opt) |parent_sibling| {
                            self.current = parent_sibling;
                            return;
                        }
                    }
                    // Continue backtracking if this parent has no sibling
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

        // Create a new node of a specific type
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

        // Get a node as a tagged union for type-safe access
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

        // Get a typed pointer to a node
        pub fn getNodeAs(self: *Self, comptime T: type, loc: Location(TableEnum)) ?*T {
            if (loc.table != @field(TableEnum, @typeName(T))) return null;

            var list = &@field(self.storage, @typeName(T));
            if (loc.idx >= list.items.len) return null;

            return &list.items[loc.idx];
        }

        // Add a root node with a name
        pub fn addRoot(self: *Self, name: []const u8, loc: Location(TableEnum), allocator: std.mem.Allocator) !void {
            const name_ref = try self.string_pool.add(allocator, name);
            try self.roots.put(allocator, name_ref, loc);
        }

        // Get a root node by name
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
        /// Allocator is only passed for measuring the max_height_tree in the treelist:
        /// if the max height changes, the traversal stack needs to be expanded
        pub fn addChild(
            self: *Self,
            parent_loc: Location(TableEnum),
            child_loc: Location(TableEnum),
            root_loc: Location(TableEnum),
            allocator: std.mem.Allocator,
        ) !void {
            // Get parent node
            const parent = self.getNode(parent_loc) orelse return error.InvalidParent;
            _ = parent;

            // Set the child's sibling to the parent's current first child
            inline for (node_types) |ChildT| {
                if (child_loc.table == @field(TableEnum, @typeName(ChildT))) {
                    var child_list = &@field(self.storage, @typeName(ChildT));
                    var child = &child_list.items[child_loc.idx];

                    // Set the child's sibling to the parent's current first child
                    inline for (node_types) |ParentT| {
                        if (parent_loc.table == @field(TableEnum, @typeName(ParentT))) {
                            var parent_list = &@field(self.storage, @typeName(ParentT));
                            var parent_node = &parent_list.items[parent_loc.idx];

                            // Link the child into the parent's child list
                            child.sibling = parent_node.child;
                            parent_node.child = child_loc;
                            break;
                        }
                    }
                    break;
                }
            }

            // Simple height check - measure this tree's height
            const height = try self.getTreeHeight(root_loc, allocator);

            // Update max height if needed
            if (height > self.max_tree_height) {
                self.max_tree_height = height;
                try self.traversal_stack.ensureTotalCapacity(allocator, self.max_tree_height + 1);
            }
        }

        fn getTreeHeight(self: *Self, root: Location(TableEnum), allocator: std.mem.Allocator) !usize {
            // Clear the stack without deallocating
            self.traversal_stack.clearRetainingCapacity();

            var max_depth: usize = 0;
            var current_depth: usize = 0;
            var current = root;

            while (true) {
                // Update max depth
                if (current_depth > max_depth) {
                    max_depth = current_depth;
                }

                // Get current node
                const node = self.getNode(current).?;

                // Get child and sibling locations from the union

                // If there's a child, go there next
                if (switch (node) {
                    inline else => |*data| data.child,
                }) |child_loc| {
                    // Save current location for later
                    try self.traversal_stack.append(allocator, current);
                    current = child_loc;
                    current_depth += 1;
                }
                // Otherwise, try to go to sibling
                else if (switch (node) {
                    inline else => |*data| data.sibling,
                }) |sibling_loc| {
                    current = sibling_loc;
                    // Depth stays the same for siblings
                }
                // No child or sibling, go back up
                else if (self.traversal_stack.items.len > 0) {
                    current = self.traversal_stack.pop();
                    current_depth -= 1;

                    // Try to go to sibling of this node
                    const parent_node = self.getNode(current).?;
                    const parent_sibling = switch (parent_node) {
                        inline else => |*data| data.sibling,
                    };

                    if (parent_sibling) |sibling| {
                        current = sibling;
                    }
                }
                // No more nodes to visit
                else {
                    break;
                }
            }

            return max_depth;
        }

        pub fn traverse(self: *Self, root: Location(TableEnum), visitor: anytype, allocator: std.mem.Allocator) !void {
            // Clear the stack without deallocating
            self.traversal_stack.clearRetainingCapacity();

            var current = root;

            while (true) {
                // Visit current node
                const node = self.getNode(current) orelse return error.InvalidNode;
                try visitor.visit(node);

                // Get child and sibling locations from the union
                const child = switch (node) {
                    inline else => |*data| data.child,
                };

                // If there's a child, go there next
                if (child) |child_loc| {
                    // Save current location for later
                    try self.traversal_stack.append(allocator, current);
                    current = child_loc;
                }
                // Otherwise, try to go to sibling
                else if (switch (node) {
                    inline else => |*data| data.sibling,
                }) |sibling_loc| {
                    current = sibling_loc;
                }
                // No child or sibling, go back up to parent's sibling if possible
                else if (self.traversal_stack.items.len > 0) {
                    const parent = self.traversal_stack.pop();
                    const parent_node = self.getNode(parent) orelse return error.InvalidNode;

                    // Get the parent's sibling from the union
                    const parent_sibling = switch (parent_node) {
                        inline else => |*data| data.sibling,
                    };

                    // If parent has a sibling, go there
                    if (parent_sibling) |sibling| {
                        current = sibling;
                    }
                    // Otherwise, keep going up
                    else {
                        // Continue popping until we find a node with a sibling
                        var found_next = false;
                        while (self.traversal_stack.items.len > 0) {
                            const ancestor = self.traversal_stack.pop();
                            const ancestor_node = self.getNode(ancestor) orelse return error.InvalidNode;

                            // Get the ancestor's sibling from the union
                            const ancestor_sibling = switch (ancestor_node) {
                                inline else => |*data| data.sibling,
                            };

                            if (ancestor_sibling) |sibling| {
                                current = sibling;
                                found_next = true;
                                break;
                            }
                        }

                        // If we've exhausted the stack and found no more siblings, we're done
                        if (!found_next) {
                            break;
                        }
                    }
                }
                // No more nodes to visit
                else {
                    break;
                }
            }
        }

        // Create an iterator for traversing the tree
        pub fn iterator(self: *Self, root: Loc) Iterator {
            return Iterator.init(self, root);
        }

        // Create an iterator from a named root
        pub fn iteratorFromRoot(self: *Self, name: []const u8) ?Iterator {
            const root_loc = self.getRoot(name) orelse return null;
            return Iterator.init(self, root_loc);
        }
    };
}

const std = @import("std");
const StringPool = @import("../string_interning.zig");
