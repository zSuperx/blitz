const std = @import("std");
const diag = @import("diag.zig");
const interner = @import("interner.zig");
const types = @import("types.zig");

const Type = types.Type;
const Sema = @import("Sema.zig");

// Interned items
const String = interner.String;
const ConcreteTypeId = interner.ConcreteTypeId;

const Symbol = Sema.Symbol;

// ====================================================
// Top level AST nodes

pub const Program = struct {
    functions: []const *Function,
};

pub const Function = struct {
    name: VarRef,
    arguments: []VarDecl,
    return_type: ?*TypeRef,
    body: *Expr,
    span: diag.Span,
};

// ====================================================
// Meta

pub const TypeRef = struct {
    span: diag.Span,
    kind: union(enum) {
        pointer: *TypeRef,
        base: VarRef,
    },
};

pub const VarDecl = struct {
    span: diag.Span,
    variable: VarRef,
    mutable: bool,
    ty: ?*TypeRef,
};

pub const VarRef = struct {
    text: String,
    symbol: Symbol = .invalid,
    span: diag.Span,

    pub fn format(
        self: VarRef,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}.{f}", .{ self.text, self.symbol });
    }
};

// ====================================================
// Statements

pub const Stmt = struct {
    kind: union(enum) {
        decl: DeclStmt,
        assign: AssignStmt,
        expr: ExprStmt,
    },
    span: diag.Span,

    pub fn as_expr(self: *Stmt) ?*Expr {
        switch (self.kind) {
            .expr => |expr| return expr,
            else => return null,
        }
    }
};

pub const AssignStmt = struct {
    op: AssignOp,
    left: *Expr,
    right: *Expr,
};

pub const DeclStmt = struct {
    decl: VarDecl,
    init: ?*Expr,
};

pub const IfStmt = struct {
    cond: *Expr,
    then: *Expr,
    else_: ?*Expr = null,
};

pub const ExprStmt = *Expr;

// ====================================================
// Expressions

pub const Expr = struct {
    kind: ExprKind,
    span: diag.Span,
    ty: ?Type,
    is_stmt: bool = false,
    is_block_tail: bool = false,

    pub fn collect_tail_exprs(self: *const Expr, gpa: std.mem.Allocator, tails: *std.ArrayList(*const Expr)) !void {
        switch (self.kind) {
            // These expressions evaluate to their children
            .block => |expr| {
                if (expr.tail) |tail| {
                    try tail.collect_tail_exprs(gpa, tails);
                } else if (expr.fake_tail()) |tail| {
                    if (tail.kind == .return_)
                        try tail.collect_tail_exprs(gpa, tails);
                }
            },
            .ifelse => |expr| {
                try expr.then.collect_tail_exprs(gpa, tails);
                if (expr.else_) |else_|
                    try else_.collect_tail_exprs(gpa, tails);
            },

            // All other expressions produce a new value
            else => {
                try tails.append(gpa, self);
            },
        }
    }

    pub fn as(self: *Expr, comptime tag: std.meta.Tag(ExprKind)) ?*@FieldType(ExprKind, @tagName(tag)) {
        return if (self.kind == tag) &@field(self.kind, @tagName(tag)) else null;
    }

    pub fn is_lvalue(self: *Expr) bool {
        return switch (self.kind) {
            .variable, .deref, .index => true,
            else => false,
        };
    }
};

pub const ExprKind = union(enum) {
    number: u128,
    bool: bool,
    variable: VarRef,
    binary: BinExpr,
    cmp: CmpExpr,
    logic: LogicExpr,
    unary: UnExpr,
    call: CallExpr,
    return_: ReturnExpr,
    deref: DerefExpr,
    addr_of: AddrOfExpr,
    index: IndexExpr,

    // These expressions evaluate to their children
    block: BlockExpr,
    ifelse: IfElseExpr,
};

pub const IndexExpr = struct {
    base: *Expr,
    index: *Expr,
};

pub const AddrOfExpr = struct {
    target: *Expr,
};

pub const DerefExpr = struct {
    target: *Expr,
};

pub const ReturnExpr = struct {
    value: *Expr,
};

pub const BlockExpr = struct {
    stmts: []const *Stmt,
    tail: ?*Expr,

    pub fn fake_tail(self: *const BlockExpr) ?*Expr {
        if (self.tail) |_| return null;
        if (self.stmts.len == 0) return null;
        const last = self.stmts[self.stmts.len - 1];
        if (last.as_expr()) |expr| {
            if (expr.as(.return_)) |_| return expr;
            return null;
        } else {
            return null;
        }
    }
};

pub const IfElseExpr = struct {
    cond: *Expr,
    then: *Expr,
    else_: ?*Expr,
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

pub const CallExpr = struct {
    callee: *Expr,
    args: []*Expr,
};

// ====================================================
// Operators

pub const AssignOp = enum {
    assign,
    assign_add,
    assign_sub,
    assign_mul,
    assign_div,
    assign_mod,
};

pub const LogicOp = enum {
    eq,
    ne,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const s = switch (self) {
            .eq => "==",
            .ne => "!=",
        };
        try writer.writeAll(s);
    }
};

pub const CmpOp = enum {
    lt,
    gt,
    le,
    ge,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const s = switch (self) {
            .lt => "<=",
            .gt => ">=",
            .le => "<=",
            .ge => ">=",
        };
        try writer.writeAll(s);
    }
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const s = switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
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
