const std = @import("std");
const StringPool = @import("string_interning.zig");

fn hasTreeInterface(T: type) void {
    if (!@hasField(T, "child") or
        !@hasField(T, "sibling") or
        !@hasField(T, "parent"))
    {
        @compileError("Union field '" ++ @typeName(T) ++ "' is missing required interface fields");
    }

    const ChildType = @TypeOf(@field(@as(T, undefined), "child"));
    const SiblingType = @TypeOf(@field(@as(T, undefined), "sibling"));
    const ParentType = @TypeOf(@field(@as(T, undefined), "parent"));

    if (ChildType != ?u32 or SiblingType != ?u32 or ParentType != ?u32) {
        @compileError("Union field '" ++ @typeName(T) ++ "' has interface fields of invalid type");
    }
}

fn unionInterface(T: type) type {
    // Verify T is a union
    if (@typeInfo(T) != .@"union") {
        @compileError("T must be a union type");
    }

    // Extract the tag type
    if (@typeInfo(T).@"union".tag_type == null) {
        @compileError("T must be a tagged union");
    }

    // Verify each union field has the required interface
    inline for (@typeInfo(T).@"union".fields) |field| {
        hasTreeInterface(field.type);
    }
}

/// MultiArrayList-based TreeList implementation
pub fn MultiArrayTreeList(comptime NodeUnion: type) type {
    return struct {
        const Self = @This();
        pub const Node = NodeUnion;

        // Storage using MultiArrayList
        nodes: std.MultiArrayList(NodeUnion) = .{},

        // String pool for interning strings
        string_pool: StringPool = .empty,

        // Map from string refs to root nodes
        roots: std.AutoHashMapUnmanaged(StringPool.StringRef, u32) = .{},

        /// Iterator for traversing the tree without allocations
        pub const Iterator = struct {
            tree_list: *Self,
            current: ?u32,
            start_root: u32, // Keep track of the starting root to know when we're done

            /// Create a new iterator starting at a given root
            pub fn init(tree_list: *Self, root: u32) Iterator {
                return .{
                    .tree_list = tree_list,
                    .current = root,
                    .start_root = root,
                };
            }

            /// Get the next node in depth-first traversal (child first, then sibling)
            pub fn nextDepth(self: *Iterator) ?NodeUnion {
                const current = self.current orelse return null;

                // Get the current node
                const node = self.tree_list.getNode(current) orelse return null;

                // If this node has a child, go there next
                const child_opt = switch (node) {
                    inline else => |node_val| node_val.child,
                };

                if (child_opt) |child_idx| {
                    self.current = child_idx;
                } else if (switch (node) {
                    inline else => |node_val| node_val.sibling,
                }) |sibling_idx| {
                    // If this node has a sibling, go there next
                    self.current = sibling_idx;
                } else {
                    // Otherwise, go up to parent and look for next sibling
                    self.ascendToSibling(current, node);
                }

                return node;
            }

            /// Move up to parent and find next sibling - no stack needed!
            fn ascendToSibling(self: *Iterator, current_idx: u32, current_node: NodeUnion) void {
                // Get parent location
                const parent_idx = switch (current_node) {
                    inline else => |node_val| node_val.parent,
                } orelse {
                    self.current = null;
                    return;
                };

                if (parent_idx == self.start_root) {
                    self.current = null;
                    return;
                }

                const parent = self.tree_list.getNode(parent_idx).?;

                if (switch (parent) {
                    inline else => |node_val| node_val.child,
                }) |child| {
                    if (child == current_idx) {
                        if (switch (parent) {
                            inline else => |node_val| node_val.sibling,
                        }) |sib| {
                            self.current = sib;
                            return;
                        }
                    }
                }

                // Current node is not the direct child of parent, or parent has no sibling
                // Continue up the chain
                self.ascendToSibling(parent_idx, parent);
            }
        };

        pub const empty: @This() = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.nodes.deinit(allocator);
            self.string_pool.deinit(allocator);
            self.roots.deinit(allocator);
        }

        /// Append a node to the tree list
        pub fn append(
            self: *Self,
            value: NodeUnion,
            allocator: std.mem.Allocator,
        ) !u32 {
            const idx = self.nodes.len;
            try self.nodes.append(allocator, value);
            return @intCast(idx);
        }

        /// Get a node by index
        pub fn getNode(self: *Self, idx: u32) ?NodeUnion {
            if (idx >= self.nodes.len) return null;
            return self.nodes.get(idx);
        }

        /// Update a node at the given index
        pub fn updateNode(self: *Self, idx: u32, new_value: NodeUnion) void {
            if (idx >= self.nodes.len) return;
            self.nodes.set(idx, new_value);
        }

        /// Add a root node with a name
        pub fn addRoot(self: *Self, name: []const u8, idx: u32, allocator: std.mem.Allocator) !void {
            const name_ref = try self.string_pool.add(allocator, name);
            try self.roots.put(allocator, name_ref, idx);
        }

        /// Get a root node by name
        pub fn getRoot(self: *Self, name: []const u8) ?u32 {
            if (self.string_pool.getStringRef(name)) |name_ref| {
                return self.roots.get(name_ref);
            }
            return null;
        }

        /// Add a child to a parent node.
        ///
        /// If parent already has a child,
        /// the new child will be appended last to the list of child’s siblings.
        pub fn addChild(
            self: *Self,
            parent_idx: u32,
            child_idx: u32,
        ) void {
            // Get parent node
            var parent = self.getNode(parent_idx).?;
            var child = self.getNode(child_idx).?;

            // Get parent's child field
            const parent_child_opt = switch (parent) {
                inline else => |parent_node| parent_node.child,
            };

            if (parent_child_opt) |cur_child_idx| {
                self.addSibling(cur_child_idx, child_idx);
            } else {
                // Set parent's child to the new child
                switch (parent) {
                    inline else => |*node| node.child = child_idx,
                }
                self.updateNode(parent_idx, parent);

                switch (child) {
                    inline else => |*node| {
                        node.parent = parent_idx;
                    },
                }
                self.updateNode(child_idx, child);
            }
        }

        /// Append a sibling to a node’s siblings list
        pub fn addSibling(
            self: *Self,
            older_sibling_idx: u32,
            sibling_idx: u32,
        ) void {
            var sibling = self.getNode(sibling_idx).?;
            var current_idx = older_sibling_idx;

            loop: while (true) {
                var current = self.getNode(current_idx).?;

                // Check if current node has a sibling
                const next_sibling_opt = switch (current) {
                    inline else => |cur_node| cur_node.sibling,
                };

                if (next_sibling_opt) |next_sibling_idx| {
                    // Move to the next sibling
                    current_idx = next_sibling_idx;
                } else {
                    // Found the last sibling, append the new sibling here
                    switch (current) {
                        inline else => |*node| {
                            node.sibling = sibling_idx;
                        },
                    }
                    // Mark the last sibling in the chain to be
                    // to the child's parent
                    switch (sibling) {
                        inline else => |*sibling_node| {
                            sibling_node.parent = current_idx;
                        },
                    }
                    self.updateNode(current_idx, current);
                    self.updateNode(sibling_idx, sibling);
                    break :loop;
                }
            }
        }

        /// Create an iterator for traversing the tree
        pub fn iterator(self: *Self, root: u32) Iterator {
            return Iterator.init(self, root);
        }

        /// Create an iterator from a named root
        pub fn iteratorFromRoot(self: *Self, name: []const u8) ?Iterator {
            const root_idx = self.getRoot(name) orelse return null;
            return Iterator.init(self, root_idx);
        }

        /// Remove a node and all its children from the tree
        pub fn swapRemove(self: *Self, idx: u32) void {
            const node = self.getNode(idx) orelse return;

            // Handle parent-child relationship
            const child_opt = switch (node) {
                inline else => |node_val| node_val.child,
            };

            if (child_opt) |child_idx| {
                self.swapRemove(child_idx);
            }

            const parent_opt = switch (node) {
                inline else => |node_val| node_val.parent,
            };

            if (parent_opt) |parent_idx| {
                var parent = self.getNode(parent_idx) orelse return;

                // Check if this node is the parent's child or sibling
                const parent_child_opt = switch (parent) {
                    inline else => |parent_node| parent_node.child,
                };

                if (parent_child_opt) |child| {
                    if (child == idx) {
                        // Update parent's child to this node's sibling
                        const node_sibling = switch (node) {
                            inline else => |node_val| node_val.sibling,
                        };

                        switch (parent) {
                            inline else => |*parent_node| parent_node.child = node_sibling,
                        }
                        self.updateNode(parent_idx, parent);
                    }
                }

                // Check siblings
                const parent_sibling_opt = switch (parent) {
                    inline else => |parent_node| parent_node.sibling,
                };

                if (parent_sibling_opt) |sibling| {
                    if (sibling == idx) {
                        // Update parent's sibling to this node's sibling
                        const node_sibling = switch (node) {
                            inline else => |node_val| node_val.sibling,
                        };

                        switch (parent) {
                            inline else => |*parent_node| parent_node.sibling = node_sibling,
                        }
                        self.updateNode(parent_idx, parent);
                    }
                }
            }

            // Now perform the actual swap remove
            const last_idx = self.nodes.len - 1;
            if (idx != last_idx) {
                // We're swapping with another node
                const last_node = self.nodes.get(last_idx);
                self.nodes.set(idx, last_node);

                // Update references to the moved node
                self.updateReferences(@intCast(last_idx), idx);
            }

            // Remove the last element
            _ = self.nodes.pop();
        }

        /// Update all references to a node that was moved
        fn updateReferences(self: *Self, old_idx: u32, new_idx: u32) void {
            const moved_node = self.getNode(new_idx) orelse return;

            // If the swapped node had a parent, update the parent's references
            const parent_opt = switch (moved_node) {
                inline else => |node_val| node_val.parent,
            };

            if (parent_opt) |parent_idx| {
                var parent = self.getNode(parent_idx) orelse return;

                // Check parent's child reference
                const parent_child_opt = switch (parent) {
                    inline else => |parent_node| parent_node.child,
                };

                if (parent_child_opt) |child| {
                    if (child == old_idx) {
                        switch (parent) {
                            inline else => |*parent_node| parent_node.child = new_idx,
                        }
                        self.updateNode(parent_idx, parent);
                    }
                }

                // Check parent's sibling reference
                const parent_sibling_opt = switch (parent) {
                    inline else => |parent_node| parent_node.sibling,
                };

                if (parent_sibling_opt) |sibling| {
                    if (sibling == old_idx) {
                        switch (parent) {
                            inline else => |*parent_node| parent_node.sibling = new_idx,
                        }
                        self.updateNode(parent_idx, parent);
                    }
                }
            }
        }

        /// Get all nodes as a slice
        pub fn items(self: *Self) []NodeUnion {
            return self.nodes.slice().items(.data);
        }

        /// Count total number of nodes
        pub fn count(self: *Self) usize {
            return self.nodes.len;
        }
    };
}
