const d = @import("diag.zig");
const std = @import("std");

pub var diagnostics: d.DiagnosticList = undefined;
pub var source_files: std.ArrayList(Source) = undefined;

pub fn add_source_file(gpa: std.mem.Allocator, source: Source) !usize {
    const id = source_files.items.len;
    try source_files.append(gpa, source);
    return id;
}

pub const Source = struct {
    path: []const u8,
    bytes: []const u8,

    /// Mappings from each newline character to its offset in the file.
    /// Allows for Spans to print their source lines.
    newlines: std.AutoHashMap(usize, usize),

    pub fn init(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !Source {
        var newlines = std.AutoHashMap(usize, usize).init(allocator);
        try newlines.put(0, 0);

        for (bytes, 0..) |byte, offset| {
            if (byte == '\n') {
                try newlines.put(newlines.count(), offset);
            }
        }
        try newlines.put(newlines.count(), bytes.len);

        return .{
            .path = path,
            .bytes = bytes,
            .newlines = newlines,
        };
    }
};
