# TreeList, an exploratory POC database of trees backed by a pool of arrays

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

Blog posts about the lib:

- [part1: the design](https://antoinebalaine.github.io/devlog/code/2025/05/29/treelist.html)
- [part2: how the array pool works](https://antoinebalaine.github.io/devlog/code/2025/05/30/memory.html)
- [part3: traversing trees in zig](https://antoinebalaine.github.io/devlog/code/2025/06/01/traversal.html)
- [part4: performance shoot-out with the multi-array list](https://antoinebalaine.github.io/devlog/code/2025/06/02/benchmarking.html)
