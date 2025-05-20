Here’s a project in which I want to implement a tree data structure.

I need to describe some pre-made component audio FX layouts using the tree. Each FX has a pre-made layout, which allows for quick recall to display in an fx-rack horizontal layout.

# n-ary trees

So at the root of each fx window, there is a list of nodes, and each of those nodes might contain a list of children nodes, each of which might also contain children node, etc.
Mentally, this maps easily to an N-ary tree, with the main disadvantage of an N-ary; which is that each node would potentially have to store a list of its children - or locations of its children, if we were storing the children into arrays, and only storing the locations/indexes into the nodes themselves.

No matter what the memory-backing strategy is going to be, this implies that the tree must be intrusive: location metadata must be stored inside the nodes themselves.
Also, the tree is going to be heterogeneous: different types of child nodes are allowed, depending on the gui widgets that will represent them.

# Locations and heterogeneous nodes

As a result, backing a heterogeneous memory layout is going to require storing each node type into an arrayList. So, we know that the initial call to the api of the data structure is going to be something akin to:
```zig
const ComponentDb = TreeList(NodeType1, NodeType2, NodeType3);
```
where each `NodeType` is going to be assigned an underlying arrayList. Each arrayList is going to be identified using an enum (`variantNodeType1`, `variantNodeType2`, etc.).

From there, we can assume that the `Location` type is going to be an aggregate of the table enum, and the index into the table:
```zig
const Location(TableEnum: type) type{
// I assume this struct to be packed
    return packed struct { 
       .table: TableEnum,
       .idx: u32,
    }
}
```
Since we can assume the TableEnum to be a u32 as well, we can optionally represent a location as a `u64` for portability, and cast it as a `Location(TableEnum)` whenever we need to run a lookup.

# how to retrieve an fx layout?
We want to be able to retrieve the root of a tree using hashtable lookups:
```zig
const fx_root_node = componentDb.get(fx_name);
```
 and then proceed to traversing:
```zig
for (fx_list)|fx_name|{
    const fx_root = componentDb.get(fx_name);
    gui.traverse(fx_root);
}
```
Since I potentially will have thousands of fx layouts, we want to minimize string repetitions, and could use an interning strategy. More on this later.

# traversing using labeled switches on the gui

The goal is to pass the tree datastructure into the GUI loop (which runs using imgui), where the gui dispatches which draw functions needs to be called depending on the node type:
```zig
switch(@typeOf(node)){
    .type1 => drawType1(node),
    .type2 => drawType2(node),
}
```
or something similar… We could even use zig’s 0.14 labeled switches as a way to treat the tree traversal as a statemachine.

# efficient serialization

The advantage of storing a collection of layouts as this kind of database, is that it makes it possible to serialize the byte sequences for storage on disk of the memory layout - as is, without need for specific data serialization formats which would require a parsing step upon recall, like json.

# b-tree instead of n-ary

Now, going back to the actual layout of the tree, there’s ways to simplify the design: instead of using an N-ary tree, we can use a binary tree: for each node, we keep a link to the first child (left) and a link to the next sibling node (right). The links are each represented as a `Location`.

# b-tree means you get a linked list ?
In my understanding this dramatic simplification sets up a string of sibling nodes as an intrusive heterogeneous linked list. This implies that adding/removing  into the list is relatively easy:

for a removal, get the node to remove and its parent, and update the next sibling location of the parent to point to the node’s next sibling.

# Writes versus reads

There is however one issue: removing links into the tree list doesn’t remove the actual nodes from their underlying arrays.
When it comes to this, other implementations I have seen didn’t implement removals: they just marked the locations in the underlying arrays using tombstones. This isn’t ideal, because as the db grows, you find yourself potentially with more and more dead space. The advantage, however, is that you can defer the dead space removal to a batch compaction operation - or something similar.  This does come with its own set of challenges, though.

Perhaps it’d be easier to store the Location of the parent in each node: this would make it possible to do a swap remove from the backing array, and update the parent locations of the swapped-in element. However, the writes into this DB promise to be extremely rare occurence, compared to the reads.

# traversing using a state machine?
For traversing, you can use a state-machine-based approach, which keeps track of the current position into the tree by maintaining a stack of the previous nodes:
```
prevList[]
switch (prev_node){
    parent => goto left node,
    left => goto right node,
    right => go to parent
}
```
The problem is the order in which the elements need to be rendered: when it comes to imgui, since it uses a draw stack, we want the background elements printed first, and the foreground elements printed last.
I tend to represent myself the draw process using breadth-first, since it maps to the way my n-ary tree was representing the hierarchy: root contains a list of children which are really the background elements (colors, subpanels or subwindows), ecah of which might contain more interactive nodes (buttons, sliders, etc.).
```
// n-ary breadth-first drawing
      A
   /  |  \
  b   c   d
 /|\  |  /|
e f g h i j
```
Following this structure for the drawing requirements means that either we do breadth first approach, or that we must invert the hierarchy tree so as to be able to use a depth-first approach for drawing.
If I use a state machine approach, we could go breadth-first by changing the order of tree traversal:
```
switch(prev)
    parent -> goto right node
    right -> goto left node
    left -> go to parent
```
This is nice:
```
left-child, right-sibling
     A
   /
  b----->c -->d
 /       |   /
e->f->g  h  i->j
```
**the advantage to this** is that since we’re traversing from the right-most point of the tree, the `prevList` stack already contains the whole context needed in case of removal: the prev stack contains the parent locations which would have to be linked to other right-child locations when removing nodes in-between them.

One could ultimately build the tree as `left-sibling, right-child` - dunno if it’s worth it, though. I’m under the hunch that either approach could be hacked to implement a threaded tree, in an inverted manner:
- in `left-child, right-sibling`, whatever rightmost node can point back to the previous sibling of its parent. The pointer could even be represented as a tagged-union: variant 1 is a regular location, variant2 is a previous sibling location.
```
left-child, right-sibling
     A
   /
  b----->c -->d
 /       |   /
e->f->g  h  i->j
```
Here, `j` points to `c`, `h` points to `b`. You’re having to visit some nodes twice, but it gives you the `prevList` context for removals.

- in `left-sibling, right-child`. It’s a little more difficult to reason about:
```
// left-sibling, right-child
        A
      /
      b -> e
    /      |
   c->h    f
  /        |
 d->i      g
    |
    j
```
Here, `g` points to `c`, `h` points to `d`. For removals, you can reconstitute the parent context using a stack - though that’s not necessary for traversal.
For traversals, each next parent sibling can be stored as tagged-unions in each leaf node, and you only have to visit each node once. This is however only possible because you’re traversing depth first.
The logic can be represented as:
```
switch(prev)
    parent -> goto right node
    right -> goto left node
    left -> go to next parent sibling
```
That’s the Morris traversal, ultimately. The child nodes’ left and right pointers (in our case, Locations…) are being used to reference the predecessor node and successor node.
If I try to rewrite this using a better-worded approach:
```
switch(prev)
  parent -> goto child
  child -> goto sibling
  sibling -> goto parent’s sibling
```

Upon trying to implement this thing, I found some problems.
1. the variants of prev (`parent`, `child`, and `sibling`) don’t actually account for all cases: what are we supposed to do when returning from a sibling? How’s the sibling supposed to know to return to its previous sibling?
2. this means that you have to maintain a stack, _and_ now you have two implementations instead of one on the arms. 

Classic case of _the better is the enemy of the good_.


# the Enum identifying tables:
Here’s an example piece from Groovebasin’s implementation. It uses string interning in the string_bytes, and it uses the Index enum internally for each of the ArrayHashMaps in its database. 
```zig
files: std.ArrayHashMapUnmanaged(File, void, File.Hasher, false),
// other lists after this

pub const File = extern struct {
    directory: Path.Index,
    basename: String,

    pub const Index = enum(u32) {
        _, // non-exhaustive enum
    };
};
```

We know that the inital call to the TreeList is going to be done by passing a list of types to the function. This can either be done with a slice, or an anonymous struct:
```zig
const DbType = TreeList(.{ NodeType1, NodeType2, NodeType3 });
const impl: DbType = .empty;
```
We know that `TreeList()` must return a struct that contains all the details we need: 
- a backing enum for Locations
- the struct must contain an arrayList per provided type
- a decl literal or some way of instantiating an empty version, with all backing lists created.

For now: root nodes’ locations need to be retrieved based on some kind of string hashmap. I’m going to implement string interning for this, following Andrew Kelley’s example in `programming without pointers`.

# Traversal, re-visited with some more grief.

Then, there’s the question of: what to do with the Morris traversal? I can still use it with tagged unions:
```zig

pub const TreeList = struct {
    const Self = @This();

    // Link type with tags
    const Link = union(enum) {
        normal: usize, // Regular child or sibling link
        to_parent: usize, // Link back to parent
        to_parent_sibling: usize, // Link to parent's next sibling
    };

    // Node structure with tagged links
    const Node = struct {
        value: u32,
        child: ?Link = null,
        sibling: ?Link = null,
    };


```
Which leads to a reasonable traversal function:
```zig
pub fn traverse(self: *TreeList, root_idx: usize, visit: *const fn (*Node) void) !void {
    var current_idx = root_idx;

    while (true) {
        // Visit current node
        const node = &self.nodes.items[current_idx];
        visit(node);

        // Navigation logic using tagged links
        if (node.child) |child| {
            // Always go to child first if available
            switch (child) {
                .normal => |idx| current_idx = idx,
                else => unreachable, // Child should always be a normal link
            }
        } else if (node.sibling) |sibling| {
            // Then try sibling
            switch (sibling) {
                .normal => |idx| current_idx = idx,
                .to_parent => |idx| {
                    // Go back to parent
                    current_idx = idx;

                    // Skip visiting the parent again - we've already visited it
                    if (self.nodes.items[current_idx].sibling) |parent_sibling| {
                        switch (parent_sibling) {
                            .normal => |sibling_idx| current_idx = sibling_idx,
                            else => break, // End traversal if no normal sibling
                        }
                    } else {
                        break; // End traversal if no sibling
                    }
                },
                .to_parent_sibling => |idx| {
                    // Special sentinel value indicating end of traversal
                    if (idx == std.math.maxInt(usize)) {
                        break;
                    }
                    // Go to parent's sibling
                    current_idx = idx;
                },
            }
        } else {
            // No more navigation options
            break;
        }
    }
}
```
But that’s an in-place change, which means that I’m going to have to change all those non-normal links back to normal at _some_ point, if I want to be implementing undo functionality - which would have to be done using structural sharing. 

This is where my library looses in general-purposeness: I need the undo for my FX layouts. I want the user to be able to create his own fx layouts using a GUI. This means that if he makes a mistake, he has to be able to undo at some point. So the tree is going to need to be represented across undo versions, and that is done with structural sharing.

The problem with structural sharing, is that those non-normal links would all instantly be invalid. 

The Morris algo expects to be making these in-place changes only temporarily, but this feels redundant: if I make the changes temporarily, I’m going to have to need a stack-based traversal at some point anyway - which means two traversal implementations instead of one. 

Yet again, a good old case of _the better is the enemy of the good_.

# the stack…

This doesn’t have to be a stopgap, though: I can share the stack for the whole treelist, and store it top-level. 

```zig
pub fn TreeList(comptime node_types: anytype) type {
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
```
I can just empty its memory between tree traversals, and re-print into it whenever needed.
I care that traversals in the gui be confidently done without allocations mid-loop, so I’m adding some extra sugar on top: the treelist will measure the max height everytime a node is added to a tree:
```zig

pub fn addChild(
    self: *Self,
    parent_loc: Location(TableEnum),
    child_loc: Location(TableEnum),
    root_loc: Location(TableEnum),
    allocator: std.mem.Allocator,
) !void {
    const parent = self.getNode(parent_loc).?;

    child.sibling = parent_node.child;
    parent.child = child_loc;

    const height = try self.getTreeHeight(root_loc, allocator);

    // Update max height if needed
    if (height > self.max_tree_height) {
        self.max_tree_height = height;
        try self.traversal_stack.ensureTotalCapacity(allocator, self.max_tree_height + 1);
    }
}
```
This shouldn’t even be part of the `addChild()` function, though. This feels like overhead - and vanity on my part.
