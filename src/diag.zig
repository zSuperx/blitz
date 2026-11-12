const std = @import("std");
const ezio = @import("ezio.zig");
const state = @import("state.zig");

pub const Span = struct {
    lo: usize,
    hi: usize,
    row: usize,
    col: usize,
    source_id: usize,

    pub const zeroed: Span = .{ .col = 0, .row = 0, .lo = 0, .hi = 0, .source_id = 0 };

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (std.mem.allEqual(u8, std.mem.asBytes(&self), 0)) return;
        const source = &state.source_files.items[self.source_id];

        try writer.print("\n{s}:{d}:{d}:\n", .{ source.path, self.row + 1, self.col + 1 });

        // Calculate beginning & end of span's line
        var bol = source.newlines.get(self.row) orelse return;
        if (source.bytes[bol] == '\n') bol += 1;
        const eol = source.newlines.get(self.row + 1) orelse return;

        try writer.print("\t{s}\n\t", .{source.bytes[bol..eol]});
        for (0..self.col) |_| {
            try writer.print(" ", .{});
        }
        try writer.print("^", .{});

        const lo = self.lo;
        const hi = @min(eol, @max(self.lo, self.hi -| 1));
        for (lo..hi) |_| {
            try writer.print("~", .{});
        }
        try writer.print("\n", .{});
    }

    pub fn merge(self: Span, other: Span) Span {
        return .{
            .lo = @min(self.lo, other.lo),
            .hi = @max(self.hi, other.hi),
            .row = @min(self.row, other.row),
            .col = @min(self.col, other.col),
            .source_id = self.source_id,
        };
    }
};

pub const Diagnostic = struct {
    level: enum {
        warn,
        err,
    },
    msg: []const u8,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{self.msg});
    }
};

pub const DiagnosticList = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,
    errors: usize = 0,
    warnings: usize = 0,

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{
            .allocator = allocator,
        };
    }

    pub fn emitError(self: *DiagnosticList, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch @panic("");
        self.errors += 1;
        self.list.append(self.allocator, .{
            .level = .err,
            .msg = msg,
        }) catch @panic("");
    }

    pub fn emitWarning(self: *DiagnosticList, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch @panic("");
        self.warnings += 1;
        self.list.append(self.allocator, .{
            .level = .warn,
            .msg = msg,
        }) catch @panic("");
    }

    pub fn print_all(self: *const DiagnosticList) void {
        for (self.list.items) |*diag| {
            switch (diag.level) {
                .warn => std.log.warn("{f}\n", .{diag}),
                .err => std.log.err("{f}\n", .{diag}),
            }
        }
    }
};
