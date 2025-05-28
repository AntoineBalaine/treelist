const std = @import("std");
const TreeList = @import("treelist.zig").TreeList;
const MultiArrayTreeList = @import("multiarray_treelist.zig").MultiArrayTreeList;
const StringPool = @import("string_interning.zig");

// Define node types with different sizes for TreeList
const TL_SmallNode = struct {
    value: i32,
    child: ?u64 = null,
    sibling: ?u64 = null,
    parent: ?u64 = null,
};

const TL_MediumNode = struct {
    value: i32,
    extra_data: [10]i32 = [_]i32{0} ** 10, // Make it larger
    child: ?u64 = null,
    sibling: ?u64 = null,
    parent: ?u64 = null,
};

const TL_LargeNode = struct {
    value: i32,
    extra_data: [100]i32 = [_]i32{0} ** 100, // 10x larger than medium
    child: ?u64 = null,
    sibling: ?u64 = null,
    parent: ?u64 = null,
};

// Define node types with different sizes for MultiArrayTreeList
const MA_SmallNode = struct {
    value: i32,
    child: ?u32 = null,
    sibling: ?u32 = null,
    parent: ?u32 = null,
};

const MA_MediumNode = struct {
    value: i32,
    extra_data: [10]i32 = [_]i32{0} ** 10, // Make it larger
    child: ?u32 = null,
    sibling: ?u32 = null,
    parent: ?u32 = null,
};

const MA_LargeNode = struct {
    value: i32,
    extra_data: [100]i32 = [_]i32{0} ** 100, // 10x larger than medium
    child: ?u32 = null,
    sibling: ?u32 = null,
    parent: ?u32 = null,
};

// For TreeList
const NodeTypes = struct {
    SmallNode: type = TL_SmallNode,
    MediumNode: type = TL_MediumNode,
    LargeNode: type = TL_LargeNode,
};

// For MultiArrayTreeList
const NodeUnion = union(enum(u32)) {
    SmallNode: MA_SmallNode,
    MediumNode: MA_MediumNode,
    LargeNode: MA_LargeNode,
};

// Benchmark configuration
const BenchmarkConfig = struct {
    num_trees: usize = 100,
    nodes_per_tree: usize = 1000,
    max_depth: usize = 10,
    max_siblings: usize = 5,
    small_node_weight: usize = 60,
    medium_node_weight: usize = 30,
    large_node_weight: usize = 10,
    seed: u64 = 42,
};

// TreeList benchmark implementation
fn benchmark(allocator: std.mem.Allocator, op: []const u8, config: BenchmarkConfig, BackingType: type, tree_list: anytype) !void {
    if (std.mem.eql(u8, op, "create")) {
        try createForest(allocator, BackingType, tree_list, config);
    } else if (std.mem.eql(u8, op, "traverse")) {
        try createForest(allocator, BackingType, tree_list, config);
        try traverseForest(tree_list);
    } else if (std.mem.eql(u8, op, "memory")) {
        try createForest(allocator, BackingType, tree_list, config);
        // Just create and exit - memory will be measured externally
    }
}

// Implementation of forest creation for TreeList
fn createForest(allocator: std.mem.Allocator, BackingType: type, tree_list: anytype, config: BenchmarkConfig) !void {
    var prng = std.Random.DefaultPrng.init(config.seed); // Fixed seed for reproducibility
    const random = prng.random();

    for (0..config.num_trees) |tree_idx| {
        const root_name = try std.fmt.allocPrint(allocator, "tree_{d}", .{tree_idx});
        var node_count: usize = 0;
        if (BackingType == NodeTypes) {
            const root_loc = try createTreeNodeTreeList(tree_list, allocator, random, config, 0, &node_count);
            try tree_list.addRoot(root_name, root_loc, allocator);
        } else if (BackingType == NodeUnion) {
            const root_loc = try createTreeNodeMultiArray(tree_list, allocator, random, config, 0, &node_count);
            try tree_list.addRoot(root_name, root_loc, allocator);
        } else {
            @compileError("Unsupported backing type, expected NodeTypes or NodeUnion, found " ++ @typeName(BackingType));
        }
    }
}

// Create a tree node for TreeList
fn createTreeNodeTreeList(
    tree_list: anytype,
    allocator: std.mem.Allocator,
    random: std.Random,
    config: BenchmarkConfig,
    depth: usize,
    node_count: *usize,
) anyerror!@TypeOf(tree_list.*).Loc {
    if (node_count.* >= config.nodes_per_tree or depth >= config.max_depth) {
        return error.TreeFull;
    }

    const weights = [_]usize{
        config.small_node_weight,
        config.medium_node_weight,
        config.large_node_weight,
    };
    const node_type = random.weightedIndex(usize, &weights);

    const node_loc = switch (node_type) {
        0 => try tree_list.appendUnion(.{ .SmallNode = .{ .value = @intCast(node_count.*) } }, allocator),
        1 => try tree_list.appendUnion(.{ .MediumNode = .{ .value = @intCast(node_count.*) } }, allocator),
        2 => try tree_list.appendUnion(.{ .LargeNode = .{ .value = @intCast(node_count.*) } }, allocator),
        else => unreachable,
    };

    node_count.* += 1;

    // Add children with some randomness
    const num_children = random.intRangeAtMost(usize, 0, config.max_siblings);

    child_loop: for (0..num_children) |_| {
        if (node_count.* >= config.nodes_per_tree) break;

        const child_loc = createTreeNodeTreeList(tree_list, allocator, random, config, depth + 1, node_count) catch |err| {
            switch (err) {
                error.TreeFull => break :child_loop,
                else => return err,
            }
        };
        tree_list.addChild(node_loc, child_loc);
    }

    return node_loc;
}

// Create a tree node for MultiArrayTreeList
fn createTreeNodeMultiArray(
    tree_list: anytype,
    allocator: std.mem.Allocator,
    random: std.Random,
    config: BenchmarkConfig,
    depth: usize,
    node_count: *usize,
) anyerror!u32 {
    if (node_count.* >= config.nodes_per_tree or depth >= config.max_depth) {
        return error.TreeFull;
    }

    const weights = [_]usize{
        config.small_node_weight,
        config.medium_node_weight,
        config.large_node_weight,
    };
    const node_type = random.weightedIndex(usize, &weights);

    const node_loc = switch (node_type) {
        0 => try tree_list.append(.{ .SmallNode = .{ .value = @intCast(node_count.*) } }, allocator),
        1 => try tree_list.append(.{ .MediumNode = .{ .value = @intCast(node_count.*) } }, allocator),
        2 => try tree_list.append(.{ .LargeNode = .{ .value = @intCast(node_count.*) } }, allocator),
        else => unreachable,
    };

    node_count.* += 1;

    // Add children with some randomness
    const num_children = random.intRangeAtMost(usize, 0, config.max_siblings);

    child_loop: for (0..num_children) |_| {
        if (node_count.* >= config.nodes_per_tree) break;

        const child_loc = createTreeNodeMultiArray(tree_list, allocator, random, config, depth + 1, node_count) catch |err| {
            switch (err) {
                error.TreeFull => break :child_loop,
                else => return err,
            }
        };
        tree_list.addChild(node_loc, child_loc);
    }

    return node_loc;
}

// Traverse all trees in TreeList
fn traverseForest(tree_list: anytype) !void {
    var sum: i32 = 0; // To prevent optimization

    // Iterate through all roots
    var root_it = tree_list.roots.iterator();
    while (root_it.next()) |entry| {
        const root_loc = entry.value_ptr.*;

        // Create iterator for this tree
        var iter = tree_list.iterator(root_loc);

        // Traverse all nodes
        while (iter.nextDepth()) |node| {
            switch (node) {
                .SmallNode => |ptr| sum += ptr.value,
                .MediumNode => |ptr| sum += ptr.value,
                .LargeNode => |ptr| sum += ptr.value,
            }
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);

    // Skip program name
    _ = args.next();

    var impl_type: []const u8 = "treelist";
    var op_type: []const u8 = "create";
    var num_trees: usize = 100;
    var nodes_per_tree: usize = 1000;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--impl=")) {
            impl_type = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--op=")) {
            op_type = arg[5..];
        } else if (std.mem.startsWith(u8, arg, "--trees=")) {
            num_trees = try std.fmt.parseInt(usize, arg[8..], 10);
        } else if (std.mem.startsWith(u8, arg, "--nodes=")) {
            nodes_per_tree = try std.fmt.parseInt(usize, arg[8..], 10);
        }
    }

    const config = BenchmarkConfig{
        .num_trees = num_trees,
        .nodes_per_tree = nodes_per_tree,
    };

    if (std.mem.eql(u8, impl_type, "treelist")) {
        const Tree = TreeList(NodeTypes);
        var tree_list: Tree = .empty;
        tree_list.init();
        try benchmark(allocator, op_type, config, NodeTypes, &tree_list);
    } else if (std.mem.eql(u8, impl_type, "multiarray")) {
        const Tree = MultiArrayTreeList(NodeUnion);
        var tree_list: Tree = .empty;
        try benchmark(allocator, op_type, config, NodeUnion, &tree_list);
    } else {
        return error.InvalidArgument;
    }
}

test "TreeList benchmark" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Tree = TreeList(NodeTypes);
    var tree_list: Tree = .empty;
    tree_list.init();

    const config = BenchmarkConfig{
        .num_trees = 10,
        .nodes_per_tree = 100,
    };

    try benchmark(allocator, "create", config, NodeTypes, &tree_list);
}

test "MultiArrayTreeList benchmark" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Tree = MultiArrayTreeList(NodeUnion);
    var tree_list: Tree = .empty;

    const config = BenchmarkConfig{
        .num_trees = 10,
        .nodes_per_tree = 100,
    };

    try benchmark(allocator, "create", config, NodeUnion, &tree_list);
}
