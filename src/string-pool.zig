const std = @import("std");

pub const StringId = struct {
    id: usize,
    parent: *const StringPool,

    pub fn lookup(self: *const @This()) []const u8 {
        return self.parent.get(self.id).?;
    }
};

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(usize),
    ids: std.ArrayList([]const u8),

    pub fn insert(self: *@This(), string: []const u8) !StringId {
        const entry = try self.map.getOrPut(string);
        if (!entry.found_existing) {
            entry.value_ptr.* = self.ids.items.len;
            try self.ids.append(self.allocator, entry.key_ptr.*);
        }
        return StringId{
            .id = entry.value_ptr.*,
            .parent = self,
        };
    }

    pub fn get(self: *const @This(), id: usize) ?[]const u8 {
        return self.ids.items[id];
    }

    pub fn init(allocator: std.mem.Allocator) @This() {
        return StringPool{
            .allocator = allocator,
            .map = .init(allocator),
            .ids = .empty,
        };
    }
};
