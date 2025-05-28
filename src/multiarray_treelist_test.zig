const std = @import("std");
const StringPool = @import("string_interning.zig");
const MultiArrayTreeList = @import("multiarray_treelist.zig").MultiArrayTreeList;

// Define test types
const IntNode = struct {
    value: i32,
    child: ?u32 = null,
    sibling: ?u32 = null,
    parent: ?u32 = null,
};

const FloatNode = struct {
    value: f64,
    child: ?u32 = null,
    sibling: ?u32 = null,
    parent: ?u32 = null,
};

const StrNode = struct {
    value: []const u8,
    child: ?u32 = null,
    sibling: ?u32 = null,
    parent: ?u32 = null,
};

// Define a union of node types for MultiArrayTreeList
const NodeUnion = union(enum(u32)) {
    IntNode: IntNode,
    FloatNode: FloatNode,
    StrNode: StrNode,
};

test "Insert and retrieve root node" {
    // Create MultiArrayTreeList instance
    const Tree = MultiArrayTreeList(NodeUnion);
    var tree: Tree = .empty;
    defer tree.deinit(std.testing.allocator);

    // Create and add a root node
    const int_loc = try tree.append(.{ .IntNode = .{ .value = 42 } }, std.testing.allocator);
    try tree.addRoot("root", int_loc, std.testing.allocator);

    // Retrieve the root node
    const root_loc = tree.getRoot("root") orelse return std.testing.expect(false);
    const root_node = tree.getNode(root_loc).?;

    try std.testing.expectEqual(@as(i32, 42), root_node.IntNode.value);
}

test "Insert and retrieve root and child nodes" {
    // Create MultiArrayTreeList instance
    const Tree = MultiArrayTreeList(NodeUnion);
    var tree: Tree = .empty;
    defer tree.deinit(std.testing.allocator);

    // Create and add a root node
    const int_loc = try tree.append(.{ .IntNode = .{ .value = 42 } }, std.testing.allocator);
    try tree.addRoot("root", int_loc, std.testing.allocator);

    // Create and add a child node
    const float_loc = try tree.append(.{ .FloatNode = .{ .value = 3.14 } }, std.testing.allocator);
    tree.addChild(int_loc, float_loc);

    // Retrieve the root node
    const root_loc = tree.getRoot("root") orelse return std.testing.expect(false);
    const root_node = tree.getNode(root_loc).?;
    try std.testing.expectEqual(@as(i32, 42), root_node.IntNode.value);

    // Get the child node by traversing from root
    const child_idx = switch (root_node) {
        .IntNode => |node| node.child,
        else => unreachable,
    } orelse return std.testing.expect(false);

    try std.testing.expectEqual(child_idx, float_loc);

    // Verify child is a float node with correct value
    const child_node = tree.getNode(child_idx).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), child_node.FloatNode.value, 0.001);
}

test "Insert and retrieve root, child, and sibling nodes" {
    // Create MultiArrayTreeList instance
    const Tree = MultiArrayTreeList(NodeUnion);
    var tree: Tree = .empty;
    defer tree.deinit(std.testing.allocator);

    // Create and add a root node (Int)
    const int_loc = try tree.append(.{ .IntNode = .{ .value = 42 } }, std.testing.allocator);
    try tree.addRoot("root", int_loc, std.testing.allocator);

    // Create and add first child node (Float)
    const float_loc = try tree.append(.{ .FloatNode = .{ .value = 3.14 } }, std.testing.allocator);
    tree.addChild(int_loc, float_loc);

    // Create and add second child node (Str) - becomes sibling of first child
    const str_loc = try tree.append(.{ .StrNode = .{ .value = "hello" } }, std.testing.allocator);
    tree.addChild(int_loc, str_loc);

    // Retrieve the root node
    const root_loc = tree.getRoot("root") orelse return std.testing.expect(false);
    const root_node = tree.getNode(root_loc).?;
    try std.testing.expectEqual(@as(i32, 42), root_node.IntNode.value);

    // Get the first child (should be Str since it was added second)
    const first_child_idx = switch (root_node) {
        .IntNode => |node| node.child,
        else => unreachable,
    } orelse return std.testing.expect(false);

    const first_child = tree.getNode(first_child_idx).?;
    try std.testing.expectEqualStrings("hello", first_child.StrNode.value);

    // Get the sibling (should be Float)
    const sibling_idx = switch (first_child) {
        .StrNode => |node| node.sibling,
        else => unreachable,
    } orelse return std.testing.expect(false);

    const sibling = tree.getNode(sibling_idx).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), sibling.FloatNode.value, 0.001);
}

test "Add and retrieve siblings directly" {
    // Create MultiArrayTreeList instance
    const Tree = MultiArrayTreeList(NodeUnion);
    var tree: Tree = .empty;
    defer tree.deinit(std.testing.allocator);

    // Create nodes
    const node1 = try tree.append(.{ .IntNode = .{ .value = 10 } }, std.testing.allocator);
    const node2 = try tree.append(.{ .IntNode = .{ .value = 20 } }, std.testing.allocator);
    const node3 = try tree.append(.{ .IntNode = .{ .value = 30 } }, std.testing.allocator);

    // Add node2 as sibling of node1
    tree.addSibling(node1, node2);

    // Add node3 as sibling of node2
    tree.addSibling(node2, node3);

    // Verify the sibling chain: node1 -> node2 -> node3
    const node1_ptr = tree.getNode(node1).?;
    try std.testing.expectEqual(node2, switch (node1_ptr) {
        .IntNode => |node| node.sibling.?,
        else => unreachable,
    });

    const node2_ptr = tree.getNode(node2).?;
    try std.testing.expectEqual(node3, switch (node2_ptr) {
        .IntNode => |node| node.sibling.?,
        else => unreachable,
    });

    const node3_ptr = tree.getNode(node3).?;
    try std.testing.expectEqual(@as(?u32, null), switch (node3_ptr) {
        .IntNode => |node| node.sibling,
        else => unreachable,
    });
}

test "Complex tree traversal" {
    // Create a more complex tree to test traversal
    //       A
    //      /
    //     B---C---D
    //    /    |   \
    //   E-F-G H    I-J

    const Tree = MultiArrayTreeList(NodeUnion);
    var tree: Tree = .empty;
    defer tree.deinit(std.testing.allocator);

    // Create nodes
    const nodeA = try tree.append(.{ .StrNode = .{ .value = "A" } }, std.testing.allocator);
    const nodeB = try tree.append(.{ .StrNode = .{ .value = "B" } }, std.testing.allocator);
    const nodeC = try tree.append(.{ .StrNode = .{ .value = "C" } }, std.testing.allocator);
    const nodeD = try tree.append(.{ .StrNode = .{ .value = "D" } }, std.testing.allocator);
    const nodeE = try tree.append(.{ .StrNode = .{ .value = "E" } }, std.testing.allocator);
    const nodeF = try tree.append(.{ .StrNode = .{ .value = "F" } }, std.testing.allocator);
    const nodeG = try tree.append(.{ .StrNode = .{ .value = "G" } }, std.testing.allocator);
    const nodeH = try tree.append(.{ .StrNode = .{ .value = "H" } }, std.testing.allocator);
    const nodeI = try tree.append(.{ .StrNode = .{ .value = "I" } }, std.testing.allocator);
    const nodeJ = try tree.append(.{ .StrNode = .{ .value = "J" } }, std.testing.allocator);

    // Build tree structure
    // A is the root
    try tree.addRoot("complex_tree", nodeA, std.testing.allocator);

    // B, C, D are children of A
    tree.addChild(nodeA, nodeB);
    tree.addSibling(nodeB, nodeC);
    tree.addSibling(nodeC, nodeD);

    // E, F, G are children of B
    tree.addChild(nodeB, nodeE);
    tree.addSibling(nodeE, nodeF);
    tree.addSibling(nodeF, nodeG);

    // H is child of C
    tree.addChild(nodeC, nodeH);

    // I, J are children of D
    tree.addChild(nodeD, nodeI);
    tree.addSibling(nodeI, nodeJ);

    // Perform depth-first traversal
    var iter = tree.iterator(nodeA);

    const vals = [_][]const u8{ "A", "B", "E", "F", "G", "C", "H", "D", "I", "J" };
    var i: usize = 0;
    while (iter.nextDepth()) |node| : (i += 1) {
        const node_value = switch (node) {
            .StrNode => |node_| node_.value,
            else => unreachable,
        };
        try std.testing.expectEqualStrings(vals[i], node_value);
    }
}
