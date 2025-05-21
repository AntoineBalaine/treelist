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
};

const FloatNode = struct {
    value: f64,
    child: ?u64 = null,
    sibling: ?u64 = null,
};

const StrNode = struct {
    value: []const u8,
    child: ?u64 = null,
    sibling: ?u64 = null,
};

test "Insert and retrieve root node" {
    // Create TreeList instance
    const Tree = TreeList(.{
        IntNode,
        FloatNode,
        StrNode,
    });
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
    // Define test types
    // Create TreeList instance
    const Tree = TreeList(.{
        IntNode,
        FloatNode,
        StrNode,
    });
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
    // Define test types
    // Create TreeList instance
    const Tree = TreeList(.{
        IntNode,
        FloatNode,
        StrNode,
    });
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
