pub const StringPool = struct {
    bytes: std.ArrayListUnmanaged(u8),
    table: std.HashMapUnmanaged(StringRef, void, TableContext, std.hash_map.default_max_load_percentage),

    pub const empty: @This() = .{ .bytes = .empty, .table = .empty };
    pub const StringRef = enum(u32) {
        _,
    };

    const TableContext = struct {
        bytes: []const u8,

        pub fn eql(_: @This(), a: StringRef, b: StringRef) bool {
            return a == b;
        }

        pub fn hash(ctx: @This(), key: StringRef) u64 {
            return std.hash_map.hashString(std.mem.sliceTo(ctx.bytes[@intFromEnum(key)..], 0));
        }
    };

    const TableIndexAdapter = struct {
        bytes: []const u8,

        pub fn eql(ctx: @This(), a: []const u8, b: StringRef) bool {
            return std.mem.eql(u8, a, std.mem.sliceTo(ctx.bytes[@intFromEnum(b)..], 0));
        }

        pub fn hash(_: @This(), adapted_key: []const u8) u64 {
            std.debug.assert(std.mem.indexOfScalar(u8, adapted_key, 0) == null);
            return std.hash_map.hashString(adapted_key);
        }
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.table.deinit(allocator);
    }

    pub fn add(self: *@This(), allocator: std.mem.Allocator, bytes: []const u8) !StringRef {
        const gop = try self.table.getOrPutContextAdapted(
            allocator,
            @as([]const u8, bytes),
            @as(TableIndexAdapter, .{ .bytes = self.bytes.items }),
            @as(TableContext, .{ .bytes = self.bytes.items }),
        );
        if (gop.found_existing) return gop.key_ptr.*;
        try self.bytes.ensureUnusedCapacity(allocator, bytes.len + 1);

        const new_off: StringRef = @enumFromInt(self.bytes.items.len);

        self.bytes.appendSliceAssumeCapacity(bytes);
        self.bytes.appendAssumeCapacity(0);

        gop.key_ptr.* = new_off;
        return new_off;
    }

    pub fn getString(self: @This(), name: StringRef) [:0]const u8 {
        const start_slice = self.bytes.items[@intFromEnum(name)..];
        return start_slice[0..std.mem.indexOfScalar(u8, start_slice, 0).? :0];
    }
};

test StringPool {

    // Initialize the buffer-backed string pool
    const allocator = std.testing.allocator;
    var pool: StringPool = .empty;
    defer pool.deinit(allocator);

    // Add some strings
    const hello_ref = try pool.add(allocator, "hello");
    const world_ref = try pool.add(allocator, "world");
    const zig_ref = try pool.add(allocator, "zig");

    try std.testing.expectEqualStrings("hello", pool.getString(hello_ref));
    try std.testing.expectEqualStrings("world", pool.getString(world_ref));
    try std.testing.expectEqualStrings("zig", pool.getString(zig_ref));
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const ArrayList = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
const HashMap = std.HashMapUnmanaged;
const AutoHashMap = std.AutoHashMapUnmanaged;
const max_load_percent = std.hash_map.default_max_load_percent;
