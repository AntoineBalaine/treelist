const std = @import("std");
const StringPool = @import("string_interning.zig");
const tree_ls = @import("treelist.zig");
const TreeList = tree_ls.TreeList;
const Location = tree_ls.Location;
const NodeInterface = tree_ls.NodeInterface;

// Define test types
const IntNode = struct {
    value: i32,
    child: ?u64 = null,
    sibling: ?u64 = null,
    parent: ?u64 = null,
};

const FloatNode = struct {
    value: f64,
    child: ?u64 = null,
    sibling: ?u64 = null,
    parent: ?u64 = null,
};

const StrNode = struct {
    value: []const u8,
    child: ?u64 = null,
    sibling: ?u64 = null,
    parent: ?u64 = null,
};

// Define a struct of node types for TreeList
const NodeTypes = struct {
    IntNode: type = IntNode,
    FloatNode: type = FloatNode,
    StrNode: type = StrNode,
};

test "Insert and retrieve root node" {
    // Create TreeList instance
    const Tree = TreeList(NodeTypes);
    var tree: Tree = .empty;
    try tree.init();
    defer tree.deinit(std.testing.allocator);

    // Create and add a root node
    const int_loc = try tree.append(IntNode, .{ .value = 42 }, std.testing.allocator);
    try tree.addRoot("root", int_loc, std.testing.allocator);

    // Retrieve the root node
    const root_loc = tree.getRoot("root") orelse return std.testing.expect(false);
    const root_node = tree.getNodeAs(IntNode, root_loc).?;

    try std.testing.expectEqual(@as(i32, 42), root_node.value);
}

test "Insert and retrieve root and child nodes" {
    // Create TreeList instance
    const Tree = TreeList(NodeTypes);
    var tree: Tree = .empty;
    try tree.init();
    defer tree.deinit(std.testing.allocator);

    // Create and add a root node
    const int_loc = try tree.append(IntNode, .{ .value = 42 }, std.testing.allocator);
    try tree.addRoot("root", int_loc, std.testing.allocator);

    // Create and add a child node
    const float_loc = try tree.append(FloatNode, .{ .value = 3.14 }, std.testing.allocator);
    tree.addChild(int_loc, float_loc);

    // Retrieve the root node
    const root_loc = tree.getRoot("root") orelse return std.testing.expect(false);
    const root_node = tree.getNodeAs(IntNode, root_loc).?;
    try std.testing.expectEqual(@as(i32, 42), root_node.value);

    // Get the child node by traversing from root
    const child_u64 = root_node.child orelse return std.testing.expect(false);
    const child_loc = Tree.Loc.fromU64(child_u64);
    try std.testing.expectEqual(child_u64, float_loc.toU64());

    // Verify child is a float node with correct value
    const child_node = tree.getNodeAs(FloatNode, child_loc).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), child_node.value, 0.001);
}

test "Insert and retrieve root, child, and sibling nodes" {
    // Create TreeList instance
    const Tree = TreeList(NodeTypes);
    var tree: Tree = .empty;
    try tree.init();
    defer tree.deinit(std.testing.allocator);

    // Create and add a root node (Int)
    const int_loc = try tree.append(IntNode, .{ .value = 42 }, std.testing.allocator);
    try tree.addRoot("root", int_loc, std.testing.allocator);

    // Create and add first child node (Float)
    const float_loc = try tree.append(FloatNode, .{ .value = 3.14 }, std.testing.allocator);
    tree.addChild(int_loc, float_loc);

    // Create and add second child node (Str) - becomes sibling of first child
    const str_loc = try tree.append(StrNode, .{ .value = "hello" }, std.testing.allocator);
    tree.addChild(int_loc, str_loc);

    // Retrieve the root node
    const root_loc = tree.getRoot("root") orelse return std.testing.expect(false);
    const root_node = tree.getNodeAs(IntNode, root_loc).?;
    try std.testing.expectEqual(@as(i32, 42), root_node.value);

    // Get the first child (should be Str since it was added second)
    const first_child_u64 = root_node.child orelse return std.testing.expect(false);
    const first_child_loc = Location(Tree.TableEnum).fromU64(first_child_u64);
    const first_child = tree.getNodeAs(StrNode, first_child_loc).?;
    try std.testing.expectEqualStrings("hello", first_child.value);

    // Get the sibling (should be Float)
    const sibling_u64 = first_child.sibling orelse return std.testing.expect(false);
    const sibling_loc = Tree.Loc.fromU64(sibling_u64);
    const sibling = tree.getNodeAs(FloatNode, sibling_loc).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), sibling.value, 0.001);
}

test "Add and retrieve siblings directly" {
    // Create TreeList instance
    const Tree = TreeList(NodeTypes);
    var tree: Tree = .empty;
    try tree.init();
    defer tree.deinit(std.testing.allocator);

    // Create nodes
    const node1 = try tree.append(IntNode, .{ .value = 10 }, std.testing.allocator);
    const node2 = try tree.append(IntNode, .{ .value = 20 }, std.testing.allocator);
    const node3 = try tree.append(IntNode, .{ .value = 30 }, std.testing.allocator);

    // Add node2 as sibling of node1
    tree.addSibling(node1, node2);

    // Add node3 as sibling of node2
    tree.addSibling(node2, node3);

    // Verify the sibling chain: node1 -> node2 -> node3
    const node1_ptr = tree.getNodeAs(IntNode, node1).?;
    try std.testing.expectEqual(node2.toU64(), node1_ptr.sibling.?);

    const node2_ptr = tree.getNodeAs(IntNode, node2).?;
    try std.testing.expectEqual(node3.toU64(), node2_ptr.sibling.?);

    const node3_ptr = tree.getNodeAs(IntNode, node3).?;
    try std.testing.expectEqual(@as(?u64, null), node3_ptr.sibling);
}

test "Complex tree traversal" {
    // Create a more complex tree to test traversal
    //       A
    //      /
    //     B---C---D
    //    /    |   \
    //   E-F-G H    I-J

    // Define a struct with just StrNode for this test
    const SimpleNodeTypes = struct {
        StrNode: type = StrNode,
    };
    const Tree = TreeList(SimpleNodeTypes);
    var tree: Tree = .empty;
    try tree.init();
    defer tree.deinit(std.testing.allocator);

    // Create nodes
    const nodeA = try tree.append(StrNode, .{ .value = "A" }, std.testing.allocator);
    const nodeB = try tree.append(StrNode, .{ .value = "B" }, std.testing.allocator);
    const nodeC = try tree.append(StrNode, .{ .value = "C" }, std.testing.allocator);
    const nodeD = try tree.append(StrNode, .{ .value = "D" }, std.testing.allocator);
    const nodeE = try tree.append(StrNode, .{ .value = "E" }, std.testing.allocator);
    const nodeF = try tree.append(StrNode, .{ .value = "F" }, std.testing.allocator);
    const nodeG = try tree.append(StrNode, .{ .value = "G" }, std.testing.allocator);
    const nodeH = try tree.append(StrNode, .{ .value = "H" }, std.testing.allocator);
    const nodeI = try tree.append(StrNode, .{ .value = "I" }, std.testing.allocator);
    const nodeJ = try tree.append(StrNode, .{ .value = "J" }, std.testing.allocator);

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
    tree.addChild(nodeD, nodeJ);
    tree.addSibling(nodeI, nodeJ);

    // Perform depth-first traversal
    var iter = tree.iterator(nodeA);
    _ = &iter;

    const vals = [_][]const u8{ "A", "B", "E", "F", "G", "C", "H", "D", "I", "J" };
    var i: usize = 0;
    while (iter.nextDepth()) |node_ptr| : (i += 1) {
        const node_value = switch (node_ptr) {
            inline else => |ptr| ptr.value,
        };
        try std.testing.expectEqualStrings(vals[i], node_value);
    }
}

