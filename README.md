Here’s the init for a zig repo in which I want to implement a tree data structure.

I need to describe some pre-made component audio FX layouts using the tree. Each FX has a pre-made layout, which allows for quick recall to display in an fx-rack horizontal layout.

# n-ary trees

So at the root of each fx window, there is a list of nodes, and each of those nodes might contain a list of children nodes, each of which might also contain children node, etc.
Mentally, this maps easily to an N-ary tree, with the main disadvantage of an N-ary which is that each node would potentially have to store a list of its children - or locations of its children, if we were storing the children into arrays, and only storing the locations/indexes into the nodes themselves.

no matter what the memory-backing strategy is going to be, this implies that the tree must be intrusive: location metadata must be stored inside the nodes themselves.
Also, the tree is going to be heterogeneous: different types of child nodes are allowed, depending on the gui widgets that will represent them.

# Locations and heterogeneous nodes

As a result, backing a heterogeneous memory layout is going to require storing each node type into an arrayList. So, we know that the initial call to the api of the data structure is going to be something akin to:
```zig
const componentDb = TreeList(nodeType1, nodeType2, nodeType3);
```
where each nodeType is going to be assigned an underlying arrayList. Each arrayList is going to be identified using an enum (`variantNodeType1`, `variantNodeType2`, etc.).

From there, we can assume that the `Location` type is going to be an aggregate of the table enum, and the index into the table:
```zig
const Location(TableEnum: type) type{
    return packed struct { // I assume this struct to be packed
       .table: TableEnum,
       .idx: u32,
    }
}
```
Since we can assume the TableEnum to be a u32 as well, we can optionally represent a location as a `u64` for portability, and cast it as a `Location(TableEnum)` whenever we need to run an access.

# how to retrieve an fx layout?
we want to be able to retrieve the root of a tree using hashtable lookups:
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

The advantage of storing a collection of layouts as this kind of database, is that it makes it possible to serialize the byte sequences for storage on disk of the memory layout - as is, without need for specific data serialization formats which require a parsing step upon recall like json.

# b-tree instead of n-ary

Now, going back to the actual layout of the tree, there’s ways to simplify the design: instead of using an N-ary tree, we can use a binary tree: for each node, we keep a link to the first child (left) and a link to the next sibling node (right). The links are each represented as a `Location`.

# b-tree means you get a linked list ?
In my understanding this dramatic simplification sets up a string of sibling nodes as an intrusive heterogeneous linked list. This implies that adding/removing  into the list is relatively easy:

for a removal, get the node to remove and its parent, and update the next sibling location of the parent to point to the node’s next sibling.

# Writes versus reads

There is however one issue: removing links into the tree list doesn’t remove the actual nodes from their underlying arrays.
When it comes to this, other implementations that I have seen of similar approaches didn’t implement removals: they just marked the locations in the underlying arrays using tombstones. This isn’t ideal, because as the db grows, you find yourself potentially with more and more dead space. The advantage, however, is that you can defer the dead space removal to a batch compaction operation - or something similar.  This does come with its own set of challenges, though.

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
// here, j points to c, h points to b. You’re having to visit some nodes twice, but it gives you the `prevList` context for removals.
```
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
Here, g points to c, h points to d. For removals, you can reconstitute the parent context using a stack - though that’s not necessary for traversal.
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
