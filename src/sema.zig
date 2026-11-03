const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");

const StringId = @import("string-pool.zig").StringId;

pub const Symbol = struct {
    id: ?usize,

    const invalid: Symbol = .{ .id = null };
};

pub const QualType = union(enum) {
    function: struct {
        num_params: usize,
    },
    int64,
};

pub const SymbolInfo = struct {
    name: StringId,
    symbol: Symbol,
    decl_span: diag.Span,
    is_param: bool,
    mutable: bool,
    type_: QualType = .int64,
    initialized: bool = false,
    mutated: bool = false,
};

pub const SemaError = error{
    OutOfMemory,
    DuplicateSymbol,
    Diagnostic,
};

pub const Sema = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(std.AutoHashMap(StringId, Symbol)),
    symbol_table: std.AutoHashMap(Symbol, SymbolInfo),
    diagnostics: diag.DiagnosticList = undefined,

    pub fn init(allocator: std.mem.Allocator) !Sema {
        var sema = Sema{
            .allocator = allocator,
            .scopes = .empty,
            .symbol_table = .init(allocator),
        };
        try sema.scopes.append(allocator, .init(allocator));

        return sema;
    }

    //
    // Helper functions
    //

    fn add_binding(self: *Sema, opts: struct {
        span: diag.Span,
        ident: StringId,
        mutable: bool = false,
        initialized: bool = false,
        is_param: bool = false,
    }) !Symbol {
        var inner_most_scope = &self.scopes.items[self.scopes.items.len - 1];
        const symbol = Symbol{ .id = self.symbol_table.count() + 1 };
        const info = SymbolInfo{
            .name = opts.ident,
            .decl_span = opts.span,
            .initialized = opts.initialized,
            .is_param = opts.is_param,
            .symbol = symbol,
            .mutable = opts.mutable,
        };

        const scope_entry = try inner_most_scope.getOrPut(opts.ident);
        if (scope_entry.found_existing) return error.DuplicateSymbol;
        scope_entry.value_ptr.* = symbol;

        const symbol_table_entry = try self.symbol_table.getOrPut(symbol);
        if (symbol_table_entry.found_existing) {
            @panic("Duplicate symbol");
        } else {
            symbol_table_entry.value_ptr.* = info;
        }
        return symbol;
    }

    fn get_binding(self: *Sema, ident: StringId) !?Symbol {
        for (self.scopes.items) |*scope| {
            if (scope.get(ident)) |symbol| return symbol;
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

    //
    // Semantic analysis on expressions
    //

    fn sema_expr(self: *Sema, expr: *ast.Expr) SemaError!void {
        switch (expr.kind) {
            .number => {},
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
    }

    fn sema_if_else_expr(self: *Sema, expr: *ast.Expr) !void {
        const if_else = &expr.kind.ifelse;

        // TODO: type check cond to be bool
        try self.sema_expr(if_else.cond);

        // TODO: type check to make sure both branches are same type
        try self.sema_expr(if_else.then);

        // If STATEMENTS can omit their else branch
        if (if_else.else_) |else_| {
            try self.sema_expr(else_);
        } else if (!expr.is_stmt) {
            // If EXPRESSIONS cannot
            try self.diagnostics.emit_error(
                expr.span,
                "This `if` is being used as an expression, so it must have an else branch",
                .{},
            );
        }
    }

    fn sema_block_expr(self: *Sema, expr: *ast.Expr) !void {
        const block = &expr.kind.block;
        try self.push_scope();
        for (block.stmts) |inner_stmt| {
            try self.sema_stmt(inner_stmt);
        }

        if (block.tail) |tail| {
            tail.is_tail = true;
            try self.sema_expr(tail);
        }

        self.pop_scope();
    }

    fn sema_logic_expr(self: *Sema, expr: *ast.Expr) !void {
        const logic = &expr.kind.logic;
        try self.sema_expr(logic.left);
        try self.sema_expr(logic.right);
    }

    fn sema_cmp_expr(self: *Sema, expr: *ast.Expr) !void {
        const cmp = &expr.kind.cmp;
        try self.sema_expr(cmp.left);
        try self.sema_expr(cmp.right);
    }

    fn sema_binary_expr(self: *Sema, expr: *ast.Expr) !void {
        const binary = &expr.kind.binary;
        try self.sema_expr(binary.left);
        try self.sema_expr(binary.right);
    }

    fn sema_unary_expr(self: *Sema, expr: *ast.Expr) !void {
        const unary = &expr.kind.unary;
        try self.sema_expr(unary.inner);
    }

    fn sema_variable_expr(self: *Sema, expr: *ast.Expr) !void {
        const variable = &expr.kind.variable;
        if (try self.get_binding(expr.kind.variable.ident)) |symbol| {
            variable.symbol = symbol;
        } else {
            try self.diagnostics.emit_error(expr.span, "Use of undefined variable `{s}`", .{variable.ident.lookup()});
        }
    }

    fn sema_call_expr(self: *Sema, expr: *ast.Expr) !void {
        const call = &expr.kind.call;
        try self.sema_expr(call.callee);
        for (call.args) |arg| {
            try self.sema_expr(arg);
        }
    }

    //
    // Semantic analysis on statments
    //

    fn sema_stmt(self: *Sema, stmt: *ast.Stmt) SemaError!void {
        switch (stmt.kind) {
            .assign => try self.sema_assign_stmt(stmt),
            .decl => try self.sema_decl_stmt(stmt),
            .expr => try self.sema_expr_stmt(stmt),
        }
    }

    fn sema_assign_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const assign = &stmt.kind.assign;

        try self.sema_expr(assign.left);
        try self.sema_expr(assign.right);

        if (!assign.left.is_lvalue()) {
            try self.diagnostics.emit_error(assign.left.span, "Cannot assign to this type of expression", .{});
        }

        if (assign.left.as_variable()) |symbol| {
            const info = self.symbol_table.getEntry(symbol).?.value_ptr;
            if (!info.initialized) {
                // if variable has not been initialized yet then mark it as init and move on
                info.initialized = true;
            } else {
                // happy path: mark mutable variable as mutated
                info.mutated = true;
            }
        }
    }

    fn sema_decl_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const decl = &stmt.kind.decl;
        var initialized = false;
        if (decl.init) |init_expr| {
            try self.sema_expr(init_expr);
            initialized = true;
        }

        const symbol = self.add_binding(.{
            .span = stmt.span,
            .ident = decl.variable.ident,
            .initialized = initialized,
            .mutable = decl.mutable,
        }) catch |err| switch (err) {
            error.DuplicateSymbol => {
                try self.diagnostics.emit_error(stmt.span, "Variable {f} already exists in this scope", .{decl.variable});
                return error.Diagnostic;
            },
            else => return err,
        };
        decl.variable.symbol = symbol;
    }

    fn sema_expr_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const expr = stmt.kind.expr;
        expr.is_stmt = true;
        try self.sema_expr(expr);
    }

    fn sema_return_expr(self: *Sema, expr: *ast.Expr) !void {
        const return_ = expr.kind.return_;
        try self.sema_expr(return_.value);
    }

    //
    // Semantic analysis on top level things
    //

    fn sema_function(self: *Sema, function: *ast.Function) SemaError!void {
        // Set the function type
        self.symbol_table.getEntry(function.name.symbol.?).?.value_ptr.type_ = .{
            .function = .{
                .num_params = function.arguments.len,
            },
        };

        try self.push_scope();

        for (function.arguments) |*arg| {
            const symbol = self.add_binding(.{
                .span = function.span,
                .ident = arg.ident,
                .is_param = true,
            }) catch |err| switch (err) {
                error.DuplicateSymbol => {
                    try self.diagnostics.emit_error(function.span, "Argument `{s}` already exists", .{arg.ident.lookup()});
                    return error.Diagnostic;
                },
                else => return err,
            };
            arg.symbol = symbol;
        }

        try self.sema_block_expr(function.body);

        const block = &function.body.kind.block;
        var unnecessary_return_span: ?diag.Span = null;
        if (block.tail) |tail| {
            if (tail.kind == .return_) unnecessary_return_span = tail.span;
        } else if (block.stmts.len > 0) {
            if (block.stmts[block.stmts.len - 1].as_expr()) |expr| {
                if (expr.kind == .return_)
                    unnecessary_return_span = expr.span;
            }
        }

        if (unnecessary_return_span) |span| try self.diagnostics.emit_warning(
            span,
            "Unnecessary `return` at tail of function.",
            .{},
        );

        self.pop_scope();
    }

    pub fn sema_program(self: *Sema, program: *ast.Program, source: *const diag.Source) SemaError!void {
        self.diagnostics = .init(self.allocator, source);

        try self.push_scope();

        for (program.functions) |function| {
            const symbol = self.add_binding(.{
                .span = function.span,
                .ident = function.name.ident,
            }) catch |err| switch (err) {
                error.DuplicateSymbol => brk: {
                    try self.diagnostics.emit_error(function.span, "Function `{s}` already exists", .{function.name.ident.lookup()});
                    break :brk Symbol.invalid;
                },
                else => return err,
            };
            function.name.symbol = symbol;
        }

        for (program.functions) |function| {
            try self.sema_function(function);
        }

        var iter = self.symbol_table.valueIterator();
        while (iter.next()) |info| {
            if (info.mutable and !info.mutated) {
                try self.diagnostics.emit_warning(
                    info.decl_span,
                    "Variable `{s}` does not need to be mutable. Consider changing it to be `const`.",
                    .{info.name.lookup()},
                );
            }
            if (!info.mutable and info.mutated) {
                try self.diagnostics.emit_error(
                    info.decl_span,
                    "Cannot assign to const variable `{s}`. Consider changing it to be `mut`.",
                    .{info.name.lookup()},
                );
            }
        }

        self.pop_scope();
        if (self.diagnostics.errors > 0) return error.Diagnostic;
    }
};
