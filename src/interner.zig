const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

pub fn Interner(item_type: type) type {
    const maptype = if (item_type == []const u8)
        std.StringHashMap(usize)
    else
        std.HashMap(item_type, usize);

    return struct {
        allocator: std.mem.Allocator,
        map: maptype,
        ids: std.ArrayList(item_type),

        pub const Item = struct {
            id: usize,
            parent: *const Interner(item_type),

            pub fn lookup(self: *const @This()) item_type {
                return self.parent.get(self.id).?;
            }

            pub fn format(
                self: @This(),
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                if (item_type == []const u8) {
                    try writer.print("{s}", .{self.lookup()});
                } else {
                    try writer.print("{f}", .{self.lookup()});
                }
            }
        };

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .map = .init(allocator),
                .ids = .empty,
            };
        }

        pub fn add(self: *@This(), item: item_type) !Item {
            const entry = try self.map.getOrPut(item);
            if (!entry.found_existing) {
                entry.value_ptr.* = self.ids.items.len;
                try self.ids.append(self.allocator, entry.key_ptr.*);
            }

            return Item{
                .id = entry.value_ptr.*,
                .parent = self,
            };
        }

        pub fn get(self: *const @This(), id: usize) ?item_type {
            return self.ids.items[id];
        }
    };
}

pub const StringPool = Interner([]const u8);
pub const String = StringPool.Item;
