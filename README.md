# TreeList, a POC of a database of trees backed by a pool of arrays

I have some heterogeneously-typed trees. I’d like to store and traverse them. 

Where am I supposed to put them ? In some arrays!

In this implementation, we pass a struct of types to the TreeList, and it takes care of building a pool of arrays - one per type.
```zig
const NodeTypes = struct {
    SmallNode: type = TL_SmallNode,
    MediumNode: type = TL_MediumNode,
    LargeNode: type = TL_LargeNode,
};

const Tree = TreeList(NodeTypes);
var tree_list: Tree = .empty;
tree_list.init();
```


