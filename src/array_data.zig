const std = @import("std");

/// ArrayData is a generic function that returns a struct to store type-erased 
/// arrays with proper alignment for the intended type T.
pub fn ArrayData(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Pointer to the underlying data with proper alignment for type T
        data: [*]align(@alignOf(T)) u8 = undefined,
        
        /// Number of elements currently in the array
        len: usize = 0,
        
        /// Allocated capacity of the array
        capacity: usize = 0,
        
        /// Size of each element in bytes
        elem_size: usize = @sizeOf(T),

        /// Initialize the array data
        pub fn init(self: *Self) void {
            self.* = .{};
        }

        /// Free the allocated memory
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.data != undefined and self.capacity > 0) {
                allocator.free(self.data[0..self.capacity * self.elem_size]);
                self.* = .{};
            }
        }

        /// Ensure the array has enough capacity for at least new_capacity elements
        pub fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, new_capacity: usize) !void {
            if (new_capacity <= self.capacity) return;

            // Calculate new capacity (double current or use requested, whichever is larger)
            const better_capacity = @max(new_capacity, self.capacity * 2);
            
            // Allocate new memory with proper alignment
            const new_data = try allocator.alignedAlloc(
                u8, 
                @alignOf(T), 
                better_capacity * self.elem_size
            );

            // Copy existing data if any
            if (self.capacity > 0) {
                @memcpy(new_data[0..self.len * self.elem_size], self.data[0..self.len * self.elem_size]);
                allocator.free(self.data[0..self.capacity * self.elem_size]);
            }

            self.data = new_data.ptr;
            self.capacity = better_capacity;
        }

        /// Append an element to the array
        pub fn append(self: *Self, value: T, allocator: std.mem.Allocator) !usize {
            try self.ensureCapacity(allocator, self.len + 1);
            
            const idx = self.len;
            // Use a properly aligned pointer for the destination
            const dest_ptr: *align(@alignOf(T)) T = @ptrCast(@alignCast(
                &self.data[idx * self.elem_size]
            ));
            dest_ptr.* = value;
            self.len += 1;

            return idx;
        }

        /// Get a pointer to an element at the given index
        pub fn getPtr(self: *Self, comptime PT: type, idx: usize) ?*PT {
            if (idx >= self.len) return null;
            
            // Calculate byte offset
            const offset = idx * self.elem_size;
            
            // Create properly aligned pointer
            const ptr = &self.data[offset];
            
            // Cast to the requested type with alignment check
            return @ptrCast(@alignCast(ptr));
        }

        /// Get a slice of elements
        pub fn getSlice(self: *Self, comptime PT: type) []PT {
            const ptr = @as([*]PT, @ptrCast(@alignCast(self.data)));
            return ptr[0..self.len];
        }

        /// Remove an element by swapping it with the last element
        pub fn swapRemove(self: *Self, idx: usize) void {
            if (idx >= self.len) return;
            if (idx == self.len - 1) {
                self.len -= 1;
                return;
            }

            // Calculate byte positions
            const remove_pos = idx * self.elem_size;
            const last_pos = (self.len - 1) * self.elem_size;
            
            // Copy last element over the one to be removed
            @memcpy(
                self.data[remove_pos..remove_pos + self.elem_size],
                self.data[last_pos..last_pos + self.elem_size],
            );
            
            self.len -= 1;
        }
    };
}