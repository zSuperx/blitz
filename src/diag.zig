const std = @import("std");
const ezio = @import("ezio.zig");

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

        return .{
            .path = path,
            .bytes = bytes,
            .newlines = newlines,
        };
    }
};

pub const Span = struct {
    lo: usize,
    hi: usize,
    row: usize,
    col: usize,

    pub fn merge(self: Span, other: Span) Span {
        return .{
            .lo = @min(self.lo, other.lo),
            .hi = @max(self.hi, other.hi),
            .row = @min(self.row, other.row),
            .col = @min(self.col, other.col),
        };
    }
};

pub const Diagnostic = struct {
    level: enum {
        warn,
        err,
    },
    msg: []const u8,
    span: Span,

    pub fn print(diag: *const Diagnostic, source: *const Source) void {
        switch (diag.level) {
            .err => std.log.err("\n{s}:{d}:{d}: {s}\n", .{ source.path, diag.span.row + 1, diag.span.col + 1, diag.msg }),
            .warn => std.log.warn("\n{s}:{d}:{d}: {s}\n", .{ source.path, diag.span.row + 1, diag.span.col + 1, diag.msg }),
        }
        var bol = source.newlines.get(diag.span.row).?;
        if (source.bytes[bol] == '\n') bol += 1;
        const eol = source.newlines.get(diag.span.row + 1).?;
        ezio.print("\t{s}\n\t", .{source.bytes[bol..eol]});
        for (0..diag.span.col) |_| {
            ezio.print(" ", .{});
        }
        ezio.print("^", .{});

        const lo = diag.span.lo;
        const hi = @max(diag.span.lo, diag.span.hi -| 1);
        for (lo..hi) |_| {
            ezio.print("~", .{});
        }
        ezio.println("\n", .{});
    }
};

pub const DiagnosticList = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,
    source: *const Source,
    errors: usize = 0,
    warnings: usize = 0,

    pub fn init(allocator: std.mem.Allocator, source: *const Source) DiagnosticList {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn emit_error(self: *DiagnosticList, span: Span, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        self.errors += 1;
        try self.list.append(self.allocator, .{
            .level = .err,
            .msg = msg,
            .span = span,
        });
    }

    pub fn emit_warning(self: *DiagnosticList, span: Span, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        self.warnings += 1;
        try self.list.append(self.allocator, .{
            .level = .warn,
            .msg = msg,
            .span = span,
        });
    }

    pub fn print_all(self: *const DiagnosticList) !void {
        for (self.list.items) |diag| {
            diag.print(self.source);
        }
    }
};
