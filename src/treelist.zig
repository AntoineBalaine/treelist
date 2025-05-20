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

    return struct {
        const Self = @This();

        // Storage for each node type
        storage: Storage = undefined,
        // String pool for interning strings
        string_pool: StringPool = .empty,
        // Map from string refs to root nodes
        roots: std.AutoHashMapUnmanaged(StringPool.StringRef, Location(TableEnum)) = .{},
        traversal_stack: std.ArrayListUnmanaged(Location(TableEnum)) = .{},
        max_tree_height: usize = 0,

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

        // Get a pointer to a node from a location
        pub fn getNode(self: *Self, loc: Location(TableEnum)) ?*anyopaque {
            inline for (node_types) |T| {
                if (loc.table == @field(TableEnum, @typeName(T))) {
                    var list = &@field(self.storage, @typeName(T));
                    if (loc.idx >= list.items.len) return null;
                    return &list.items[loc.idx];
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
                const node_ptr = self.getNode(current).?;

                // If there's a child, go there next
                if (node_ptr.child) |child| {
                    // Save current location for later
                    try self.traversal_stack.append(allocator, current);
                    current = child;
                    current_depth += 1;
                }
                // Otherwise, try to go to sibling
                else if (node_ptr.sibling) |sibling| {
                    current = sibling;
                    // Depth stays the same for siblings
                }
                // No child or sibling, go back up
                else if (self.traversal_stack.items.len > 0) {
                    current = self.traversal_stack.pop();
                    current_depth -= 1;

                    // Try to go to sibling of this node
                    const parent_node = self.getNode(current).?;
                    if (parent_node.sibling) |sibling| {
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
                const node_ptr = self.getNode(current) orelse return error.InvalidNode;
                try visitor.visit(node_ptr);

                // If there's a child, go there next
                if (node_ptr.child) |child| {
                    // Save current location for later
                    try self.traversal_stack.append(allocator, current);
                    current = child;
                }
                // Otherwise, try to go to sibling
                else if (node_ptr.sibling) |sibling| {
                    current = sibling;
                }
                // No child or sibling, go back up to parent's sibling if possible
                else if (self.traversal_stack.items.len > 0) {
                    const parent = self.traversal_stack.pop();
                    const parent_node = self.getNode(parent) orelse return error.InvalidNode;

                    // If parent has a sibling, go there
                    if (parent_node.sibling) |sibling| {
                        current = sibling;
                    }
                    // Otherwise, keep going up
                    else {
                        // Continue popping until we find a node with a sibling
                        var found_next = false;
                        while (self.traversal_stack.items.len > 0) {
                            const ancestor = self.traversal_stack.pop();
                            const ancestor_node = self.getNode(ancestor) orelse return error.InvalidNode;

                            if (ancestor_node.sibling) |sibling| {
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
    };
}

const std = @import("std");
const StringPool = @import("../string_interning.zig");
