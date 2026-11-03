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
    body: *Expr,
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
        decl: DeclStmt,
        expr: ExprStmt,
        if_: IfStmt,
        return_: ReturnStmt,
    },
    span: diag.Span,

    pub fn as_expr(self: *Stmt) ?*Expr {
        switch (self.kind) {
            .expr => |*expr| return expr.expr,
            else => return null,
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.kind) {
            .decl => |stmt| try writer.print("{f}", .{stmt}),
            .block => |stmt| try writer.print("{f}", .{stmt}),
            .expr => |stmt| try writer.print("{f}", .{stmt}),
            .return_ => |stmt| try writer.print("{f}", .{stmt}),
        }
    }
};

pub const DeclStmt = struct {
    variable: Variable,
    init: ?*Expr,
    mutable: bool,

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

pub const IfStmt = struct {
    cond: *Expr,
    then: *Expr,
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
        cmp: CmpExpr,
        logic: LogicExpr,
        unary: UnExpr,
        assign: AssignExpr,
        call: CallExpr,
        block: BlockExpr,
        ifelse: IfElseExpr,
    },
    span: diag.Span,

    pub fn as_variable(self: *Expr) ?Symbol {
        switch (self.kind) {
            .variable => |variable| return variable.symbol,
            else => return null,
        }
    }

    pub fn is_lvalue(self: *Expr) bool {
        return switch (self.kind) {
            .variable => true,
            else => false,
        };
    }
};

pub const BlockExpr = struct {
    stmts: []const *Stmt,
    tail: ?*Expr,
};

pub const IfElseExpr = struct {
    cond: *Expr,
    then: *Expr,
    else_: *Expr,
};

pub const CmpExpr = struct {
    op: CmpOp,
    left: *Expr,
    right: *Expr,
};

pub const LogicExpr = struct {
    op: LogicOp,
    left: *Expr,
    right: *Expr,
};

pub const BinExpr = struct {
    op: BinOp,
    left: *Expr,
    right: *Expr,
};

pub const UnExpr = struct {
    op: UnOp,
    inner: *Expr,
};

pub const AssignExpr = struct {
    left: *Expr,
    right: *Expr,
};

pub const Variable = struct {
    ident: StringId,
    symbol: ?Symbol = null,

    pub fn format(
        self: Variable,
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
};

// ====================================================
// Operators

pub const LogicOp = enum {
    eq,
    ne,
};

pub const CmpOp = enum {
    lt,
    gt,
    le,
    ge,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
};

pub const UnOp = enum {
    negate,
    not,
};
