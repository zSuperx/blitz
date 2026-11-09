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
    /// The type of this symbol. A type's type is type. The type a type resolves to is in `kind.type`
    ty: Type,
    kind: union(enum) {
        variable: VariableInfo,
        function: FunctionInfo,
        type: Type,
    },
};

pub const SemaError = error{
    OutOfMemory,
    DuplicateSymbol,
    Fatal,
    ConstraintFail,
};

pub const Sema = struct {
    // These are carried out through the whole compiler
    allocator: std.mem.Allocator,
    string_pool: *StringPool,
    tsys: types.TypeSystem,
    // TODO: inherit this from init, use through whole program
    symbol_table: std.AutoHashMap(Symbol, SymbolInfo),

    symbol_count: usize = 0,
    current_function: Symbol = undefined,
    scopes: std.ArrayList(std.AutoHashMap(String, Symbol)),

    pub fn init(allocator: std.mem.Allocator, string_pool: *StringPool) !Sema {
        var sema = Sema{
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

    fn create_pointer_to(self: *Sema, pointee: Type, span: ?diag.Span) !Type {
        return try self.tsys.add_concrete(.{ .pointer = pointee }, span);
    }

    fn next_id(self: *Sema) Symbol {
        self.symbol_count += 1;
        return .from_index(self.symbol_count);
    }

    fn get_current_function_type(self: *Sema) *@FieldType(types.CTy, "function") {
        const ftype = self.symbol_table.getPtr(self.current_function).?.ty;
        return &self.tsys.get_entry(ftype).kind.concrete.function;
    }

    fn get_binding_info(self: *Sema, name: String) ?*SymbolInfo {
        if (self.get_binding(name)) |symbol| {
            return self.symbol_table.getPtr(symbol);
        } else return null;
    }

    pub fn add_type_binding(
        self: *Sema,
        name: String,
        ct: CTy,
    ) !Type {
        const resolved = try self.tsys.add_concrete(ct);

        const symbol = self.next_id();
        try self.symbol_table.put(
            symbol,
            .{
                .ty = builtins.type_,
                .name = name,
                .kind = .{
                    .type = resolved,
                },
            },
        );

        var scope = &self.scopes.items[0];
        const res = try scope.getOrPut(name);
        if (res.found_existing) {
            state.diagnostics.emit_error(
                "Type `{f}` already exists.",
                .{name},
            );
        }

        res.value_ptr.* = symbol;
        return resolved;
    }

    fn add_function_binding(
        self: *Sema,
        name: String,
        args: []Type,
        returns: Type,
        info: FunctionInfo,
    ) !Symbol {
        const symbol = self.next_id();
        try self.symbol_table.put(
            symbol,
            .{
                .ty = try self.tsys.add_concrete(
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
            state.diagnostics.emit_error(
                "Function `{f}` already exists. {f}",
                .{ name, info.span },
            );
        }
        res.value_ptr.* = symbol;
        return symbol;
    }

    fn add_variable_binding(
        self: *Sema,
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
            state.diagnostics.emit_error(
                "Variable `{f}` already exists. {f}",
                .{ name, info.decl_span },
            );
        }

        res.value_ptr.* = symbol;
        return symbol;
    }

    fn get_binding(self: *Sema, ident: String) ?Symbol {
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

    fn push_scope(self: *Sema) !void {
        try self.scopes.append(self.allocator, .init(self.allocator));
    }

    fn pop_scope(self: *Sema) void {
        _ = self.scopes.pop();
    }

    fn sema_var_decl(self: *Sema, decl: *ast.VarDecl) !void {
        const t = if (decl.ty) |ty|
            try self.resolve_type_reference(ty)
        else
            try self.tsys.add_unknown(.empty);

        const symbol = try self.add_variable_binding(decl.variable.text, t, .{
            .decl_span = decl.span,
            .mutable = decl.mutable,
        });

        decl.variable.symbol = symbol;
    }

    fn resolve_type_reference(self: *Sema, ty: *ast.TypeRef) !Type {
        switch (ty.kind) {
            .pointer => |inner| {
                const i = try self.resolve_type_reference(inner);
                return try self.tsys.add_concrete(
                    .{ .pointer = .{ .points_to = i } },
                );
            },
            .base => |*name| {
                if (self.get_binding(name.text)) |symbol| {
                    const info = self.symbol_table.getPtr(symbol).?;
                    if (info.kind != .type) {
                        state.diagnostics.emit_error("Expected a type, but got a {s}. {f}", .{ @tagName(info.kind), ty.span });
                        return error.Fatal;
                    }
                    name.symbol = symbol;
                    return info.kind.type;
                } else {
                    state.diagnostics.emit_error(
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

    fn sema_expr(self: *Sema, expr: *ast.Expr) SemaError!void {
        switch (expr.kind) {
            .number => try self.sema_number_expr(expr),
            .variable => try self.sema_variable_expr(expr),
            .block => try self.sema_block_expr(expr),
            .binary => try self.sema_binary_expr(expr),
            .unary => try self.sema_unary_expr(expr),
            .call => try self.sema_call_expr(expr),
            .ifelse => try self.sema_if_else_expr(expr),
            .logic => try self.sema_logic_expr(expr),
            .cmp => try self.sema_cmp_expr(expr),
            .return_ => try self.sema_return_expr(expr),
        }
        std.debug.assert(expr.ty != null);
    }

    fn sema_number_expr(self: *Sema, expr: *ast.Expr) !void {
        const number = expr.kind.number;
        _ = number;

        expr.ty = try self.tsys.add_unknown(.initOne(.numeric));
        _ = try self.tsys.constrain(.{ .numeric = expr.ty.? });
    }

    fn sema_if_else_expr(self: *Sema, expr: *ast.Expr) !void {
        const if_else = &expr.kind.ifelse;
        const then = if_else.then;
        const cond = if_else.cond;

        // TODO: type check cond to be bool
        try self.sema_expr(cond);
        self.tsys.constrain(.{ .equal = &.{ cond.ty.?, builtins.bool_ } }) catch {
            state.diagnostics.emit_error(
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
                self.tsys.constrain(.{
                    .equal = &.{
                        then.ty.?,
                        else_.ty.?,
                    },
                }) catch {
                    state.diagnostics.emit_error(
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
                state.diagnostics.emit_error(
                    "This `if` is being used as an expression, so it must have an else branch. {f}",
                    .{expr.span},
                );
                return error.Fatal;
            }
        }
    }

    fn sema_block_expr(self: *Sema, expr: *ast.Expr) !void {
        const block = &expr.kind.block;
        try self.push_scope();
        for (block.stmts) |inner_stmt| {
            try self.sema_stmt(inner_stmt);
        }

        if (block.tail) |tail| {
            tail.is_block_tail = true;
            try self.sema_expr(tail);
        }

        self.pop_scope();
    }

    fn sema_logic_expr(self: *Sema, expr: *ast.Expr) !void {
        const logic = &expr.kind.logic;
        try self.sema_expr(logic.left);
        try self.sema_expr(logic.right);
        self.tsys.constrain(.{
            .equal = &.{
                logic.left.ty.?,
                logic.right.ty.?,
            },
        }) catch {
            state.diagnostics.emit_error("`{f}` can only performed between same types. Got `{f}` and `{f}` {f}", .{
                logic.op,
                self.tsys.fmtType(logic.left.ty.?),
                self.tsys.fmtType(logic.right.ty.?),
                expr.span,
            });
            return error.Fatal;
        };
        expr.ty = builtins.bool_;
    }

    fn sema_cmp_expr(self: *Sema, expr: *ast.Expr) !void {
        const cmp = &expr.kind.cmp;
        try self.sema_expr(cmp.left);
        try self.sema_expr(cmp.right);
        self.tsys.constrain(.{
            .equal = &.{
                cmp.left.ty.?,
                cmp.right.ty.?,
            },
        }) catch {
            state.diagnostics.emit_error("`{f}` can only performed between same types. Got `{f}` and `{f}` {f}", .{
                cmp.op,
                self.tsys.fmtType(cmp.left.ty.?),
                self.tsys.fmtType(cmp.right.ty.?),
                expr.span,
            });
            return error.Fatal;
        };
        expr.ty = builtins.bool_;
    }

    fn sema_binary_expr(self: *Sema, expr: *ast.Expr) !void {
        const binary = &expr.kind.binary;
        const left = binary.left;
        const right = binary.right;

        try self.sema_expr(left);
        try self.sema_expr(right);

        const out_ty = try self.tsys.add_unknown(.initOne(.numeric));

        _ = try self.tsys.constrain(
            .{
                .binary = .{
                    .op = binary.op,
                    .lhs = left.ty.?,
                    .rhs = right.ty.?,
                    .out = out_ty,
                },
            },
        );

        expr.ty = out_ty;
    }

    fn sema_unary_expr(self: *Sema, expr: *ast.Expr) !void {
        const unary = &expr.kind.unary;
        try self.sema_expr(unary.inner);
    }

    fn sema_variable_expr(self: *Sema, expr: *ast.Expr) !void {
        const variable = &expr.kind.variable;
        if (self.get_binding(expr.kind.variable.text)) |symbol| {
            variable.symbol = symbol;
            const info = self.symbol_table.getPtr(symbol).?;
            expr.ty = info.ty;
            if (info.kind == .type) {
                state.diagnostics.emit_error("Expected expression, but found type. {f}", .{expr.span});
                return error.Fatal;
            }
        } else {
            state.diagnostics.emit_error("Use of undefined variable `{f}`. {f}", .{ variable.text, expr.span });
            return error.Fatal;
        }
    }

    fn sema_call_expr(self: *Sema, expr: *ast.Expr) !void {
        const call = &expr.kind.call;

        try self.sema_expr(call.callee);

        const callee_type = if (self.tsys.get_concrete(call.callee.ty.?)) |f| f else {
            state.diagnostics.emit_error("Cannot call non-function type. {f}", .{call.callee.span});
            return error.Fatal;
        };

        if (callee_type != .function) {
            state.diagnostics.emit_error("Cannot call non-function type. {f}", .{call.callee.span});
            return error.Fatal;
        }

        if (call.callee.kind != .variable) {
            state.diagnostics.emit_error("Indirect calls not supported (yet). {f}", .{call.callee.span});
            return error.Fatal;
        }

        try self.sema_variable_expr(call.callee);
        for (call.args, callee_type.function.args) |arg, expected| {
            try self.sema_expr(arg);
            self.tsys.constrain(.{
                .equal = &.{
                    arg.ty.?,
                    expected,
                },
            }) catch {
                state.diagnostics.emit_error("Incorrect argument type passed to function. {f}", .{arg.span});
            };
        }
        expr.ty = callee_type.function.returns;
    }

    //
    // Semantic analysis on statments
    //

    fn sema_stmt(self: *Sema, stmt: *ast.Stmt) SemaError!void {
        switch (stmt.kind) {
            .assign => try self.sema_assign_stmt(stmt),
            .decl => try self.sema_var_decl_stmt(stmt),
            .expr => try self.sema_expr_stmt(stmt),
        }
    }

    fn sema_assign_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const assign = &stmt.kind.assign;

        const left = assign.left;
        const right = assign.right;

        try self.sema_expr(left);
        try self.sema_expr(right);

        if (!left.is_lvalue()) {
            state.diagnostics.emit_error("Cannot assign to this type of expression \n {f}", .{left.span});
        }

        _ = self.tsys.unify(left.ty, right.ty) catch {
            state.diagnostics.emit_error("Mismatched types: {f} and {f}. {f} {f}", .{
                self.tsys.fmtType(left.ty.?),
                self.tsys.fmtType(right.ty.?),
                left.span,
                right.span,
            });
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

    fn sema_var_decl_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const decl = &stmt.kind.decl;

        try self.sema_var_decl(&decl.decl);

        if (decl.init) |expr| {
            try self.sema_expr(expr);
            const info = self.get_binding_info(decl.decl.variable.text).?;
            _ = self.tsys.unify(info.ty, expr.ty) catch {
                state.diagnostics.emit_error("Mismatched types: {f} and {f}. {f} {f}", .{
                    self.tsys.fmtType(info.ty),
                    self.tsys.fmtType(expr.ty.?),
                    decl.decl.variable.span,
                    expr.span,
                });
            };
        }
    }

    fn sema_expr_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const expr = stmt.kind.expr;
        expr.is_stmt = true;
        try self.sema_expr(expr);
    }

    fn sema_return_expr(self: *Sema, expr: *ast.Expr) !void {
        const return_ = expr.kind.return_;
        try self.sema_expr(return_.value);

        const function_type = self.get_current_function_type();
        _ = self.tsys.unify(function_type.returns, return_.value.ty) catch {
            state.diagnostics.emit_error("Function returns type {f}, but this expression is of type {f} {f}", .{
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

    fn sema_function(self: *Sema, function: *ast.Function) SemaError!void {
        // Set the current function
        self.current_function = function.name.symbol;

        try self.push_scope();

        for (function.arguments) |*arg| {
            try self.sema_var_decl(arg);
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
                state.diagnostics.emit_warning(
                    "Unnecessary `return` at the tail of a function. {f}  Consider using the expression without a trailing semicolon.",
                    .{tail.span},
                );
            }

            _ = self.tsys.unify(tail.ty, function_type.returns) catch {
                state.diagnostics.emit_error("Function returns type {f}, but this expression is of type {f} {f}", .{
                    self.tsys.fmtType(function_type.returns),
                    self.tsys.fmtType(tail.ty.?),
                    tail.span,
                });
                return error.Fatal;
            };
        }

        self.pop_scope();
    }

    pub fn sema_program(self: *Sema, program: *ast.Program) SemaError!void {
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

        // try self.tsys.solve_constraints();
        self.tsys.print();

        var iter = self.symbol_table.iterator();
        std.debug.print(
            \\---------
            \\Symbol : Type
            \\---------
            \\
        , .{});
        while (iter.next()) |entry| {
            const symbol = entry.key_ptr.*;
            const info = entry.value_ptr;
            std.debug.print("{f}.{d} : {f}\n", .{
                info.name,
                symbol,
                self.tsys.fmtType(info.ty),
            });

            if (info.kind == .variable) {
                const variable = &info.kind.variable;
                if (variable.mutable and !variable.mutated) {
                    state.diagnostics.emit_warning(
                        "Variable `{f}` does not need to be mutable. Consider changing it to be `const`. {f}",
                        .{ info.name, variable.decl_span },
                    );
                }
                if (!variable.mutable and variable.mutated) {
                    state.diagnostics.emit_error(
                        "Cannot assign to const variable `{f}`. Consider changing it to be `mut`. {f}",
                        .{ info.name, variable.decl_span },
                    );
                }
            }
        }

        self.pop_scope();
    }
};
