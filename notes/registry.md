…Long story short, let’s simplify further. Let’s have a registry, _and_ the treelist. At this pt I’m mixing up multiple projects: the console, and the rack. Let’s start with the console, since that’s what we’re deep in. Also, their design decisions are going to overlap:

# Console1

```zig
const FX = struct {
  selected_map: Location
  maps: []Location
};

const Registry = struct{
  list: []FX,
};
```
This doesn’t really tell us how the hierarchy works. When we validate a track, we retrieve the fx names one by one, and those are supposed to be associated to some maps. We’re far from the TreeList, but do have the string interning in place. 

```zig
const FX = struct {
  selected_map: Location
  maps: []Location
};

const Registry = struct {
  string_pool: StringPool,
  /// Map from string refs to root nodes
  fx_ls: std.AutoHashMapUnmanaged(StringPool.StringRef, FX) = .{},

}
```
and then it becomes possible to include the other tables, which makes this data-struct a full-fledged database:
```zig
const DB = struct {
  string_pool: StringPool,
  fx_ls: AutoHashMapUnmanaged(StringPool.StringRef, FX),
  Comp: ArrayListUnmanaged(Comp), 
  Eq: ArrayListUnmanaged(Eq), 
  Inpt: ArrayListUnmanaged(Inpt), 
  Outpt: ArrayListUnmanaged(Outpt), 
}
```
If I’m thinking of adding a multi-module mode, then I run into an issue: a single FX might be represented by multiple entries with different modes. Is this actually a problem, though?
```zig
const FX = struct {
  selected_map: Location // this can be multi-mode, or single mode.
  maps: []Location // this list can include a mix.
};
const DB = struct {
  string_pool: StringPool,
  fx_ls: AutoHashMapUnmanaged(StringPool.StringRef, FX),
  Multi: ArrayListUnmanaged(Multi), 
  Comp: ArrayListUnmanaged(Comp), 
  Eq: ArrayListUnmanaged(Eq), 
  Inpt: ArrayListUnmanaged(Inpt), 
  Outpt: ArrayListUnmanaged(Outpt), 
}
```
Then, how does this tie with the validation?

```reaper
Track Fxlist:
  fx1 (c1-i)
  fx2 (c1-e)
  fx3 (c1-c)
  fx4 (c1-g)
  fx5 (c1-o)
```
This is relatively straight-forward: 
- run through the list
- for each fx marked with the C1 prefix,
  find their matching entry:
    `const strRef = string_pool.get(fx_name);`
  resolve any conflicts (reorder, or remove any of them if necessary)
  fetch their respective maps
    `const map_location = Db.fx_ls.get(strRef)`, and then proceed to perform the join
    or `Db.get(fx_ls)` if we want to have an englobing API.

The advantage of the englobing API, is that you can use it for «import presets»:
```zig
fn save_mapping(db: DB, str_name, Module, map)void{
  db.append(str_name, Module, map)
}
const MappingModeAction = union(enum){
  save = save_mapping,
  set_as_default,
  ...
}

fn import_presets(path: [:0]const u8, db: DB)!void{
  const preset_db = load_preset_file(path);
  for (preset_db.iter())|fx|{
    save_mapping(db, fx.name, fx.module, fx.map)
  }
}
const SettingsAction = union(enum){
  import_presets = import_presets,
  ...
}
```
That’s relatively straight forward, and it covers most of the cases: 
- schemas can be incremented and migrated, since all you have to do is pass the new version’s type to the generic-DB data struct (in theory, we’ll see how it plays out in practice). APIs might change, but that’s still relatively straight-forward:
```zig
const Schema1 = struct { ... } ;
const Schema2 = struct { ... } ;
const DB1 = Db(Schema1);
const DB2 = Db(Schema2);
```
- you can maintain backwards compatibility using some mappers:
```zig
fn  load_db(path){
  const schema_version = try reader.readInt(u16, .little)

  return switch (@intFromEnum(Version, schema_version)) {
      .v1 => { 
        const db_v1 = try DB1.readDb(file);
        Db1ToDb2(db_v1);
      },
      .v2 => try DB2.readDb(file),
      else => return error.UnsupportedVersion,
  }
}
```
- fx are allowed to have multiple maps associated.
- you could add extra metadata in the maps: author, responsiveness slope, style, date created, etc.
- exporting presets can be done by serializing a filtered version of the user’s database:
```zig
  // This is probably going to be the trickiest part of this implementation, 
  // though the idea is deceptively simple.
fn filter(self: *Db, allocator: std.mem.Allocator, selections: []FxSelection) !Db {}
```
- you can cache the currently-used maps for fast access, and iteration on the GUI.


# Rack
Same problem, same causes, same solutions:
Upon reading a new track, get all the track fx names. Find the gui layouts of each fx in the db: `fx_list.get(fx_name).?.selected_map`, push them (or their `Location`s) into the cache, and use the cache to draw.

on load: pull from disk, reading the binary file layout into memory. If we set it up correctly, we should be able to make it backwards _and_ forwards compatible. No parsing, done with a single disk read.
on save: store the current mem layout to disk. Same story.

Big unblock. How do I implement this? Can it be done with meta programming? How much effort is it? When it comes to root nodes or indexing, how hard is it going to be ? Should the StripPool be its own data struct or should it be broken out into pieces into the main TreeList? Is it realistic to keep the TreeList as a general purpose datastructure or are my requirements too specific?


