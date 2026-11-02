const std = @import("std");
const diag = @import("diag.zig");
const StringId = @import("string-pool.zig").StringId;
const Symbol = @import("sema.zig").Symbol;

// ====================================================
// Top level AST nodes

pub const Program = struct {
    functions: []const *Function,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        for (self.functions) |function| {
            try writer.print("{f}\n", .{function});
        }
    }
};

pub const Function = struct {
    name: Variable,
    arguments: []Variable,
    body: *Stmt,
    span: diag.Span,

    pub fn format(self: Function, writer: *std.Io.Writer) !void {
        try writer.print("{s}(", .{self.name});
        for (self.arguments) |arg| {
            try writer.print("{f},", .{arg});
        }
        try writer.print("): {f}", .{self.body});
    }
};

// ====================================================
// Statements

pub const Stmt = struct {
    kind: union(enum) {
        let: LetStmt,
        block: BlockStmt,
        expr: ExprStmt,
        return_: ReturnStmt,
    },
    span: diag.Span,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.kind) {
            .let => |stmt| try writer.print("{f}", .{stmt}),
            .block => |stmt| try writer.print("{f}", .{stmt}),
            .expr => |stmt| try writer.print("{f}", .{stmt}),
            .return_ => |stmt| try writer.print("{f}", .{stmt}),
        }
    }
};

pub const LetStmt = struct {
    variable: Variable,
    init: ?*Expr,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("let {f} = ", .{self.variable});
        if (self.init) |init| {
            try writer.print("{f}", .{init});
        } else {
            try writer.print("?", .{});
        }
    }
};

pub const BlockStmt = struct {
    stmts: []const *Stmt,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{{\n", .{});
        for (self.stmts) |stmt| {
            try writer.print("{f}\n", .{stmt});
        }
        try writer.print("}}", .{});
    }
};

pub const ReturnStmt = struct {
    value: *Expr,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("return ({f})", .{self.value});
    }
};

pub const ExprStmt = struct {
    expr: *Expr,
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}", .{self.expr});
    }
};

// ====================================================
// Expressions

pub const Expr = struct {
    kind: union(enum) {
        number: u128,
        variable: Variable,
        binary: BinExpr,
        unary: UnExpr,
        assign: AssignExpr,
        call: CallExpr,
    },
    span: diag.Span,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.kind) {
            .number => |expr| try writer.print("{d}", .{expr}),
            .unary => |expr| try writer.print("{f}", .{expr}),
            .binary => |expr| try writer.print("{f}", .{expr}),
            .variable => |expr| try writer.print("{f}", .{expr}),
            .call => |expr| try writer.print("{f}", .{expr}),
        }
    }

    pub fn is_lvalue(self: *Expr) bool {
        return switch (self.kind) {
            .variable => true,
            else => false,
        };
    }
};

pub const BinExpr = struct {
    op: BinOp,
    left: *Expr,
    right: *Expr,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("({f}, {f}, {f})", .{ self.op, self.left, self.right });
    }
};

pub const UnExpr = struct {
    op: UnOp,
    inner: *Expr,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("({f}, {f})", .{ self.op, self.inner });
    }
};

pub const AssignExpr = struct {
    left: *Expr,
    right: *Expr,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("(= {f}, {f})", .{ self.left, self.right });
    }
};

pub const Variable = struct {
    ident: StringId,
    symbol: ?Symbol = null,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.symbol) |symbol| {
            try writer.print("{s}_{any}", .{ self.ident.lookup(), symbol.id });
        } else {
            try writer.print("{s}", .{self.ident.lookup()});
        }
    }
};

pub const CallExpr = struct {
    callee: *Expr,
    args: []*Expr,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("call {f}", .{self.callee});
        if (self.args.len > 0) {
            try writer.writeAll(" with (");
            for (self.args) |arg| {
                try writer.print("{f},", .{arg});
            }
            try writer.writeAll(")");
        }
    }
};

// ====================================================
// Operators

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const s = switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .assign => "=",
        };
        try writer.writeAll(s);
    }
};

pub const UnOp = enum {
    negate,
    not,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const s = switch (self) {
            .negate => "-",
            .not => "!",
        };
        try writer.writeAll(s);
    }
};
