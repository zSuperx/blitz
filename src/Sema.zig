const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const interner = @import("interner.zig");
const types = @import("types.zig");
const state = @import("state.zig");

const String = interner.String;
const StringPool = interner.StringPool;
const Type = types.Type;
const builtins = types.builtins;

const CTy = types.CTy;
const UTy = types.UTy;
const Constraint = types.Constraint;

pub const Symbol = enum(usize) {
    _,

    // TODO: my idea for this is so sema can continue analyzing even if there
    // are references to undefined variables
    pub const invalid: Symbol = .from_index(0);

    pub fn format(
        self: Symbol,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.is_invalid()) {
            try writer.writeAll("INVALID");
        } else {
            try writer.print("{d}", .{self.as_index()});
        }
    }

    pub fn is_invalid(self: Symbol) bool {
        return self.as_index() == 0;
    }

    pub fn from_index(index: usize) Symbol {
        return @enumFromInt(index);
    }

    pub fn as_index(self: Symbol) usize {
        return @intFromEnum(self);
    }
};

pub const TypeInfo = struct {
    resolves_to: Type,
};

pub const VariableInfo = struct {
    decl_span: diag.Span,
    mutable: bool,
    // Variables are initialized to untouched & unint. This changes
    // upon assignment
    mutated: bool = false,
    initialized: bool = false,
};

pub const FunctionInfo = struct {
    span: diag.Span,
};

pub const SymbolInfo = struct {
    name: String,
    /// The type of this symbol. A type's type is type. The type a type resolves to is in `SymbolInfo.kind.type.resolves_to`
    ty: Type,
    kind: union(enum) {
        variable: VariableInfo,
        function: FunctionInfo,
        type: TypeInfo,
    },
};

pub const SemaError = error{
    OutOfMemory,
    DuplicateSymbol,
    Fatal,
    ConstraintFail,
};

// These are carried out through the whole compiler
allocator: std.mem.Allocator,
string_pool: *StringPool,
tsys: types.TypeSystem,
// TODO: inherit this from init, use through whole program
symbol_table: std.AutoHashMap(Symbol, SymbolInfo),

symbol_count: usize = 0,
current_function: Symbol = undefined,
scopes: std.ArrayList(std.AutoHashMap(String, Symbol)),

pub fn init(allocator: std.mem.Allocator, string_pool: *StringPool) !@This() {
    var sema = @This(){
        .allocator = allocator,
        .string_pool = string_pool,
        .scopes = .empty,
        .tsys = .init(allocator),
        .symbol_table = .init(allocator),
    };
    try sema.scopes.append(allocator, .init(allocator));

    try builtins.init(&sema);

    return sema;
}

//
// Helper functions
//

fn create_pointer_to(self: *@This(), pointee: Type) !Type {
    return try self.tsys.createConcreteType(.{ .pointer = .{ .points_to = pointee } });
}

fn next_id(self: *@This()) Symbol {
    self.symbol_count += 1;
    return .from_index(self.symbol_count);
}

fn get_current_function_type(self: *@This()) @FieldType(types.CTy, "function") {
    const ftype = self.symbol_table.getPtr(self.current_function).?.ty;
    return self.tsys.getConcreteType(ftype).?.function;
}

fn get_binding_info(self: *@This(), name: String) ?*SymbolInfo {
    if (self.get_binding(name)) |symbol| {
        return self.symbol_table.getPtr(symbol);
    } else return null;
}

pub fn add_type_binding(
    self: *@This(),
    name: String,
    ct: CTy,
) !Type {
    const resolved = try self.tsys.createConcreteType(ct);

    const symbol = self.next_id();
    try self.symbol_table.put(
        symbol,
        .{
            .ty = builtins.type_,
            .name = name,
            .kind = .{
                .type = .{ .resolves_to = resolved },
            },
        },
    );

    var scope = &self.scopes.items[0];
    const res = try scope.getOrPut(name);
    if (res.found_existing) {
        state.diagnostics.emitError(
            "Type `{f}` already exists.",
            .{name},
        );
        return error.Fatal;
    }

    res.value_ptr.* = symbol;
    return resolved;
}

fn add_function_binding(
    self: *@This(),
    name: String,
    args: []Type,
    returns: Type,
    info: FunctionInfo,
) !Symbol {
    const symbol = self.next_id();
    try self.symbol_table.put(
        symbol,
        .{
            .ty = try self.tsys.createConcreteType(
                .{
                    .function = .{
                        .args = args,
                        .returns = returns,
                    },
                },
            ),

            .name = name,
            .kind = .{ .function = info },
        },
    );

    var scope = &self.scopes.items[self.scopes.items.len - 1];
    const res = try scope.getOrPut(name);
    if (res.found_existing) {
        state.diagnostics.emitError(
            "Function `{f}` already exists. {f}",
            .{ name, info.span },
        );
        return error.Fatal;
    }
    res.value_ptr.* = symbol;
    return symbol;
}

fn add_variable_binding(
    self: *@This(),
    name: String,
    ty: Type,
    info: VariableInfo,
) !Symbol {
    const symbol = self.next_id();
    try self.symbol_table.putNoClobber(
        symbol,
        .{
            .ty = ty,
            .name = name,
            .kind = .{ .variable = info },
        },
    );

    var scope = &self.scopes.items[self.scopes.items.len - 1];

    const res = try scope.getOrPut(name);
    if (res.found_existing) {
        state.diagnostics.emitError(
            "Variable `{f}` already exists. {f}",
            .{ name, info.decl_span },
        );
        return error.Fatal;
    }

    res.value_ptr.* = symbol;
    return symbol;
}

fn get_type_binding(self: *@This(), ident: String) ?Symbol {
    var i = self.scopes.items.len -| 1;
    while (i < self.scopes.items.len) : (i -%= 1) {
        const scope = self.scopes.items[i];
        if (scope.get(ident)) |id| {
            if (self.symbol_table.getPtr(id).?.kind != .type) continue;
            return id;
        }
    } else {
        return null;
    }
}

fn get_binding(self: *@This(), ident: String) ?Symbol {
    var i = self.scopes.items.len -| 1;
    while (i < self.scopes.items.len) : (i -%= 1) {
        const scope = self.scopes.items[i];
        if (scope.get(ident)) |id| {
            return id;
        }
    } else {
        return null;
    }
}

fn push_scope(self: *@This()) !void {
    try self.scopes.append(self.allocator, .init(self.allocator));
}

fn pop_scope(self: *@This()) void {
    _ = self.scopes.pop();
}

fn resolve_type_reference(self: *@This(), ty: *ast.TypeRef) !Type {
    switch (ty.kind) {
        .pointer => |inner| {
            const i = try self.resolve_type_reference(inner);
            return try self.tsys.createConcreteType(
                .{ .pointer = .{ .points_to = i } },
            );
        },
        .base => |*name| {
            if (self.get_type_binding(name.text)) |symbol| {
                const info = self.symbol_table.getPtr(symbol).?;
                if (info.kind != .type) {
                    state.diagnostics.emitError("Expected a type, but got a {s}. {f}", .{ @tagName(info.kind), ty.span });
                    return error.Fatal;
                }
                name.symbol = symbol;
                return info.kind.type.resolves_to;
            } else {
                state.diagnostics.emitError(
                    "Use of undefined type `{f}`. {f}",
                    .{
                        name.text,
                        ty.span,
                    },
                );
                return error.Fatal;
            }
        },
    }
}

//
// Semantic analysis on expressions
//

fn sema_expr(self: *@This(), expr: *ast.Expr) SemaError!void {
    switch (expr.kind) {
        .number => try self.sema_number_expr(expr),
        .bool => try self.sema_bool_expr(expr),
        .variable => try self.sema_variable_expr(expr),
        .block => try self.sema_block_expr(expr),
        .binary => try self.sema_binary_expr(expr),
        .unary => try self.sema_unary_expr(expr),
        .call => try self.sema_call_expr(expr),
        .ifelse => try self.sema_if_else_expr(expr),
        .logic => try self.sema_logic_expr(expr),
        .equality => try self.sema_equality_expr(expr),
        .cmp => try self.sema_cmp_expr(expr),
        .return_ => try self.sema_return_expr(expr),
        .deref => try self.sema_deref_expr(expr),
        .addr_of => try self.sema_addr_of_expr(expr),
        .index => try self.sema_index_expr(expr),
    }
    std.debug.assert(expr.ty != null);
}

fn sema_index_expr(self: *@This(), expr: *ast.Expr) !void {
    const index = expr.kind.index;
    try self.sema_expr(index.base);
    try self.sema_expr(index.index);
    self.tsys.createConstraint(.{
        .equal = &.{
            index.index.ty.?,
            builtins.usize_,
        },
    }) catch {
        state.diagnostics.emitError("Indexing expects type `usize`, but got `{f}` {f}", .{
            self.tsys.fmtType(index.index.ty.?),
            index.index.span,
        });
        return error.Fatal;
    };

    expr.ty = try self.tsys.createUnknownType(.empty);

    self.tsys.createConstraint(.{
        .pointer = .{
            .pointer = index.base.ty.?,
            .points_to = expr.ty.?,
        },
    }) catch {
        state.diagnostics.emitError("Cannot index into non-pointer type `{f}` {f}", .{
            self.tsys.fmtType(index.base.ty.?),
            index.index.span,
        });
        return error.Fatal;
    };
}

fn sema_deref_expr(self: *@This(), expr: *ast.Expr) !void {
    const deref = expr.kind.deref;
    try self.sema_expr(deref.target);
    expr.ty = try self.tsys.createUnknownType(.empty);
    self.tsys.createConstraint(.{
        .pointer = .{
            .pointer = deref.target.ty.?,
            .points_to = expr.ty.?,
        },
    }) catch {
        state.diagnostics.emitError("Cannot dereference non-pointer type `{f}` {f}", .{
            self.tsys.fmtType(deref.target.ty.?),
            deref.target.span,
        });
        return error.Fatal;
    };
}

fn sema_addr_of_expr(self: *@This(), expr: *ast.Expr) !void {
    const addr_of = expr.kind.addr_of;
    try self.sema_expr(addr_of.target);
    if (!addr_of.target.is_lvalue()) {
        state.diagnostics.emitError(
            "Cannot take the address of this expression. The `&` operator can only be used on named locations. {f}",
            .{addr_of.target.span},
        );
        return error.Fatal;
    }
    expr.ty = try self.create_pointer_to(addr_of.target.ty.?);
    self.tsys.createConstraint(.{
        .pointer = .{
            .pointer = expr.ty.?,
            .points_to = addr_of.target.ty.?,
        },
    }) catch {
        state.diagnostics.emitError(
            "Mismatched types. {f}",
            .{
                addr_of.target.span,
            },
        );
        return error.Fatal;
    };
}

fn sema_bool_expr(self: *@This(), expr: *ast.Expr) !void {
    _ = self;
    expr.ty = builtins.bool_;
}

fn sema_number_expr(self: *@This(), expr: *ast.Expr) !void {
    expr.ty = try self.tsys.createUnknownType(.initOne(.numeric));
    self.tsys.createConstraint(.{ .numeric = expr.ty.? }) catch {
        state.diagnostics.emitError("Not a number. {f}", .{expr.span});
        return error.Fatal;
    };
}

fn sema_if_else_expr(self: *@This(), expr: *ast.Expr) !void {
    const if_else = &expr.kind.ifelse;
    const then = if_else.then;
    const cond = if_else.cond;

    // TODO: type check cond to be bool
    try self.sema_expr(cond);
    self.tsys.createConstraint(.{ .equal = &.{
        cond.ty.?,
        builtins.bool_,
    } }) catch {
        state.diagnostics.emitError(
            "Conditional expressions must be `bool`, but this is of type `{f}`. {f}",
            .{
                self.tsys.fmtType(cond.ty.?),
                cond.span,
            },
        );
        return error.Fatal;
    };

    // TODO: type check to make sure both branches are same type
    try self.sema_expr(then);

    if (expr.is_stmt) {
        if (if_else.else_) |else_| try self.sema_expr(else_);
        expr.ty = builtins.void_;
    } else {
        if (if_else.else_) |else_| {
            try self.sema_expr(else_);
            self.tsys.createConstraint(.{
                .equal = &.{
                    then.ty.?,
                    else_.ty.?,
                },
            }) catch {
                state.diagnostics.emitError(
                    \\Branches of `if else` expressions must have the same type.
                    \\The `then` branch has type `{f}` {f}
                    \\the `else` branch has type `{f}` {f}
                ,
                    .{
                        self.tsys.fmtType(then.ty.?),
                        then.span,
                        self.tsys.fmtType(else_.ty.?),
                        else_.span,
                    },
                );
                return error.Fatal;
            };
            expr.ty = then.ty;
        } else {
            state.diagnostics.emitError(
                "This `if` is being used as an expression, so it must have an else branch. {f}",
                .{expr.span},
            );
            return error.Fatal;
        }
    }
}

fn sema_block_expr(self: *@This(), expr: *ast.Expr) !void {
    const block = &expr.kind.block;
    try self.push_scope();
    for (block.stmts) |inner_stmt| {
        try self.sema_stmt(inner_stmt);
    }
    expr.ty = builtins.void_;

    if (block.tail) |tail| {
        tail.is_block_tail = true;
        try self.sema_expr(tail);
        expr.ty = tail.ty;
    }

    self.pop_scope();
}

fn sema_equality_expr(self: *@This(), expr: *ast.Expr) !void {
    const equality = &expr.kind.equality;
    try self.sema_expr(equality.left);
    try self.sema_expr(equality.right);
    self.tsys.createConstraint(.{
        .equal = &.{
            equality.left.ty.?,
            equality.right.ty.?,
        },
    }) catch {
        state.diagnostics.emitError("`{f}` can only performed between same types. Got `{f}` and `{f}` {f}", .{
            equality.op,
            self.tsys.fmtType(equality.left.ty.?),
            self.tsys.fmtType(equality.right.ty.?),
            expr.span,
        });
        return error.Fatal;
    };
    expr.ty = builtins.bool_;
}

fn sema_logic_expr(self: *@This(), expr: *ast.Expr) !void {
    const logic = &expr.kind.logic;
    try self.sema_expr(logic.left);
    try self.sema_expr(logic.right);
    self.tsys.createConstraint(.{
        .equal = &.{
            logic.left.ty.?,
            logic.right.ty.?,
            builtins.bool_,
        },
    }) catch {
        state.diagnostics.emitError("`{f}` can only performed between booleans. Got `{f}` and `{f}` {f}", .{
            logic.op,
            self.tsys.fmtType(logic.left.ty.?),
            self.tsys.fmtType(logic.right.ty.?),
            expr.span,
        });
        return error.Fatal;
    };
    expr.ty = builtins.bool_;
}

fn sema_cmp_expr(self: *@This(), expr: *ast.Expr) !void {
    const cmp = &expr.kind.cmp;
    try self.sema_expr(cmp.left);
    try self.sema_expr(cmp.right);
    self.tsys.createConstraint(.{
        .equal = &.{
            cmp.left.ty.?,
            cmp.right.ty.?,
        },
    }) catch {
        state.diagnostics.emitError("`{f}` can only performed between same types. Got `{f}` and `{f}` {f}", .{
            cmp.op,
            self.tsys.fmtType(cmp.left.ty.?),
            self.tsys.fmtType(cmp.right.ty.?),
            expr.span,
        });
        return error.Fatal;
    };
    expr.ty = builtins.bool_;
}

fn sema_binary_expr(self: *@This(), expr: *ast.Expr) !void {
    const binary = &expr.kind.binary;
    const left = binary.left;
    const right = binary.right;

    try self.sema_expr(left);
    try self.sema_expr(right);

    const out_ty = try self.tsys.createUnknownType(.initOne(.numeric));

    self.tsys.createConstraint(
        .{
            .binary = .{
                .op = binary.op,
                .lhs = left.ty.?,
                .rhs = right.ty.?,
                .out = out_ty,
            },
        },
    ) catch {
        state.diagnostics.emitError("Operator `{f}` can only be used between same integral types. Got `{f}` and `{f}`. {f}", .{
            binary.op,
            self.tsys.fmtType(left.ty.?),
            self.tsys.fmtType(right.ty.?),
            expr.span,
        });
        return error.Fatal;
    };

    expr.ty = out_ty;
}

fn sema_unary_expr(self: *@This(), expr: *ast.Expr) !void {
    const unary = &expr.kind.unary;
    try self.sema_expr(unary.inner);

    expr.ty = switch (unary.op) {
        .negate => brk: {
            const ty = try self.tsys.createUnknownType(.empty);
            try self.tsys.addProperty(ty, .numeric);
            try self.tsys.addProperty(ty, .signed);
            break :brk ty;
        },
        .not => builtins.bool_,
    };

    self.tsys.createConstraint(.{
        .unary = .{
            .op = unary.op,
            .in = unary.inner.ty.?,
            .out = expr.ty.?,
        },
    }) catch {
        state.diagnostics.emitError("The `{f}` operator can't be used on expressions of type `{f}`. {f}", .{
            unary.op,
            self.tsys.fmtType(unary.inner.ty.?),
            expr.span,
        });
        return error.Fatal;
    };
}

fn sema_variable_expr(self: *@This(), expr: *ast.Expr) !void {
    const variable = &expr.kind.variable;
    if (self.get_binding(expr.kind.variable.text)) |symbol| {
        variable.symbol = symbol;
        const info = self.symbol_table.getPtr(symbol).?;
        expr.ty = info.ty;
        switch (info.kind) {
            .type => {
                state.diagnostics.emitError("Expected expression, but found type. {f}", .{expr.span});
                return error.Fatal;
            },
            else => {
                expr.ty = info.ty;
            },
        }
    } else {
        state.diagnostics.emitError("Use of undefined variable `{f}`. {f}", .{ variable.text, expr.span });
        return error.Fatal;
    }
}

fn sema_call_expr(self: *@This(), expr: *ast.Expr) !void {
    const call = &expr.kind.call;

    try self.sema_expr(call.callee);

    const callee_type = if (self.tsys.getConcreteType(call.callee.ty.?)) |f| f else {
        state.diagnostics.emitError(
            "Cannot call non-function type `{f}`. {f}",
            .{
                self.tsys.fmtType(call.callee.ty.?),
                call.callee.span,
            },
        );
        return error.Fatal;
    };

    const function_type = switch (callee_type) {
        .pointer => |p| brk: {
            const inner_ty = self.tsys.getConcreteType(p.points_to) orelse {
                state.diagnostics.emitError(
                    "Cannot call non-function type `{f}`. {f}",
                    .{
                        self.tsys.fmtType(call.callee.ty.?),
                        call.callee.span,
                    },
                );
                return error.Fatal;
            };
            break :brk inner_ty.function;
        },
        .function => |f| f,
        else => {
            state.diagnostics.emitError(
                "Cannot call non-function type `{f}`. {f}",
                .{
                    self.tsys.fmtType(call.callee.ty.?),
                    call.callee.span,
                },
            );
            return error.Fatal;
        },
    };

    // if (call.callee.kind != .variable) {
    //     state.diagnostics.emit_error("Indirect calls not supported (yet). {f}", .{call.callee.span});
    //     return error.Fatal;
    // }

    try self.sema_variable_expr(call.callee);
    for (call.args, function_type.args) |arg, expected| {
        try self.sema_expr(arg);
        self.tsys.createConstraint(.{
            .equal = &.{
                arg.ty.?,
                expected,
            },
        }) catch {
            state.diagnostics.emitError(
                "Incorrect argument type passed to function. Expected `{f}` but got `{f}` {f}",
                .{
                    self.tsys.fmtType(expected),
                    self.tsys.fmtType(arg.ty.?),
                    arg.span,
                },
            );
            return error.Fatal;
        };
    }

    expr.ty = function_type.returns;
}

//
// Semantic analysis on statments
//

fn sema_stmt(self: *@This(), stmt: *ast.Stmt) SemaError!void {
    switch (stmt.kind) {
        .assign => try self.sema_assign_stmt(stmt),
        .decl => try self.sema_var_decl_stmt(stmt),
        .expr => try self.sema_expr_stmt(stmt),
    }
}

fn sema_assign_stmt(self: *@This(), stmt: *ast.Stmt) !void {
    const assign = &stmt.kind.assign;

    const left = assign.left;
    const right = assign.right;

    try self.sema_expr(left);
    try self.sema_expr(right);

    if (!left.is_lvalue()) {
        state.diagnostics.emitError("Cannot assign to this type of expression \n {f}", .{left.span});
        return error.Fatal;
    }

    _ = self.tsys.unify(left.ty, right.ty) catch {
        state.diagnostics.emitError("Mismatched types: {f} and {f}. {f} {f}", .{
            self.tsys.fmtType(left.ty.?),
            self.tsys.fmtType(right.ty.?),
            left.span,
            right.span,
        });
        return error.Fatal;
    };

    if (assign.left.as(.variable)) |variable| {
        const info = self.symbol_table.getPtr(variable.symbol).?;
        if (!info.kind.variable.initialized) {
            // if variable has not been initialized yet then mark it as init and move on
            info.kind.variable.initialized = true;
        } else {
            // happy path: mark mutable variable as mutated
            info.kind.variable.mutated = true;
        }
    }
}

fn sema_var_decl_stmt(self: *@This(), stmt: *ast.Stmt) !void {
    const decl = &stmt.kind.decl;

    try self.sema_var_decl(&decl.decl);

    if (decl.init) |expr| {
        try self.sema_expr(expr);
        const info = self.get_binding_info(decl.decl.variable.text).?;
        info.kind.variable.initialized = true;
        _ = self.tsys.unify(info.ty, expr.ty) catch {
            state.diagnostics.emitError("Mismatched types: {f} and {f}. {f} {f}", .{
                self.tsys.fmtType(info.ty),
                self.tsys.fmtType(expr.ty.?),
                decl.decl.variable.span,
                expr.span,
            });
            return error.Fatal;
        };
    }
}

fn sema_expr_stmt(self: *@This(), stmt: *ast.Stmt) !void {
    const expr = stmt.kind.expr;
    expr.is_stmt = true;
    try self.sema_expr(expr);
}

fn sema_return_expr(self: *@This(), expr: *ast.Expr) !void {
    const return_ = expr.kind.return_;
    try self.sema_expr(return_.value);

    const function_type = self.get_current_function_type();
    _ = self.tsys.unify(function_type.returns, return_.value.ty) catch {
        state.diagnostics.emitError("Function returns type {f}, but this expression is of type {f} {f}", .{
            self.tsys.fmtType(function_type.returns),
            self.tsys.fmtType(return_.value.ty.?),
            return_.value.span,
        });
        return error.Fatal;
    };
    expr.ty = return_.value.ty;
}

//
// Semantic analysis on top level things
//

fn sema_var_decl(self: *@This(), decl: *ast.VarDecl) !void {
    if (self.get_type_binding(decl.variable.text) != null) {
        state.diagnostics.emitError(
            "Variable names cannot shadow type names. Why must we spread misinformation and lies? {f}",
            .{
                decl.variable.span,
            },
        );
        return error.Fatal;
    }

    const t = if (decl.ty) |ty|
        try self.resolve_type_reference(ty)
    else
        try self.tsys.createUnknownType(.empty);

    const symbol = try self.add_variable_binding(decl.variable.text, t, .{
        .decl_span = decl.span,
        .mutable = decl.mutable,
    });

    decl.variable.symbol = symbol;
}

fn sema_function(self: *@This(), function: *ast.Function) SemaError!void {
    // Set the current function
    self.current_function = function.name.symbol;

    try self.push_scope();

    for (function.arguments) |*arg| {
        try self.sema_var_decl(arg);
        const info = self.symbol_table.getPtr(arg.variable.symbol).?;
        info.kind.variable.initialized = true;
    }

    try self.sema_block_expr(function.body);

    const block = &function.body.kind.block;

    var alloc = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer alloc.deinit();

    var tails: std.ArrayList(*const ast.Expr) = .empty;
    if (block.tail) |tail| {
        try tail.collect_tail_exprs(alloc.allocator(), &tails);
    } else if (block.fake_tail()) |tail| {
        if (tail.kind == .return_)
            try tail.collect_tail_exprs(alloc.allocator(), &tails);
    }

    const function_type = self.get_current_function_type();

    for (tails.items) |tail| {
        if (tail.kind == .return_) {
            state.diagnostics.emitWarning(
                "Unnecessary `return` at the tail of a function. {f}  Consider using the expression without a trailing semicolon.",
                .{tail.span},
            );
        }

        _ = self.tsys.unify(tail.ty, function_type.returns) catch {
            state.diagnostics.emitError("Function returns type {f}, but this expression is of type {f} {f}", .{
                self.tsys.fmtType(function_type.returns),
                self.tsys.fmtType(tail.ty.?),
                tail.span,
            });
            return error.Fatal;
        };
    }

    self.pop_scope();
}

pub fn sema_program(self: *@This(), program: *ast.Program) SemaError!void {
    try self.push_scope();

    for (program.functions) |function| {
        var args: std.ArrayList(Type) = .empty;
        for (function.arguments) |*decl| {
            const t = try self.resolve_type_reference(decl.ty.?);
            try args.append(self.allocator, t);
        }

        const returns: Type =
            if (function.return_type) |r|
                try self.resolve_type_reference(r)
            else
                builtins.void_;

        const symbol = try self.add_function_binding(
            function.name.text,
            args.items,
            returns,
            .{
                .span = function.span,
            },
        );

        function.name.symbol = symbol;
    }

    for (program.functions) |function| {
        try self.sema_function(function);
    }

    try self.tsys.solveTypes();

    var iter = self.symbol_table.iterator();
    while (iter.next()) |entry| {
        const info = entry.value_ptr;

        if (info.kind == .variable) {
            const variable = &info.kind.variable;
            if (variable.mutable and !variable.mutated) {
                state.diagnostics.emitWarning(
                    "Variable `{f}` does not need to be mutable. Consider changing it to be `const`. {f}",
                    .{ info.name, variable.decl_span },
                );
            }
            if (!variable.mutable and variable.mutated) {
                state.diagnostics.emitError(
                    "Cannot assign to const variable `{f}`. Consider changing it to be `mut`. {f}",
                    .{ info.name, variable.decl_span },
                );
            }
        }
    }

    self.pop_scope();
}
