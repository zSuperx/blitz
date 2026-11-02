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
    type_: QualType = .int64,
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

    fn add_binding(self: *Sema, ident: StringId) !Symbol {
        var inner_most_scope = &self.scopes.items[self.scopes.items.len - 1];
        const symbol = Symbol{ .id = self.symbol_table.count() + 1 };
        const info = SymbolInfo{
            .name = ident,
            .symbol = symbol,
        };

        const scope_entry = try inner_most_scope.getOrPut(ident);
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
            .variable => {
                try self.sema_variable_expr(expr);
            },
            .assign => {
                try self.sema_assign_expr(expr);
            },
            .binary => {
                try self.sema_binary_expr(expr);
            },
            .unary => {
                try self.sema_unary_expr(expr);
            },
            .call => {
                try self.sema_call_expr(expr);
            },
        }
    }

    fn sema_assign_expr(self: *Sema, expr: *ast.Expr) !void {
        const assign = &expr.kind.assign;

        if (!assign.left.is_lvalue()) {
            try self.diagnostics.emit_error(assign.left.span, "Cannot assign to this type of expression", .{});
        }

        try self.sema_expr(assign.left);
        try self.sema_expr(assign.right);
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
            .let => {
                try self.sema_let_stmt(stmt);
            },
            .block => {
                try self.sema_block_stmt(stmt);
            },
            .expr => {
                try self.sema_expr_stmt(stmt);
            },
            .return_ => {
                try self.sema_return_stmt(stmt);
            },
        }
    }

    fn sema_let_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const let = &stmt.kind.let;
        if (let.init) |init_expr| {
            try self.sema_expr(init_expr);
        }
        const symbol = self.add_binding(let.variable.ident) catch |err| switch (err) {
            error.DuplicateSymbol => {
                try self.diagnostics.emit_error(stmt.span, "Variable {f} already exists in this scope", .{let.variable});
                return error.Diagnostic;
            },
            else => return err,
        };
        let.variable.symbol = symbol;
    }

    fn sema_block_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const block = &stmt.kind.block;
        try self.push_scope();
        for (block.stmts) |inner_stmt| {
            try self.sema_stmt(inner_stmt);
        }
        self.pop_scope();
    }

    fn sema_expr_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const expr = stmt.kind.expr;
        try self.sema_expr(expr.expr);
    }

    fn sema_return_stmt(self: *Sema, stmt: *ast.Stmt) !void {
        const return_ = stmt.kind.return_;
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
            const symbol = self.add_binding(arg.ident) catch |err| switch (err) {
                error.DuplicateSymbol => {
                    try self.diagnostics.emit_error(function.span, "Argument `{f}` already exists", .{arg});
                    return error.Diagnostic;
                },
                else => return err,
            };
            arg.symbol = symbol;
        }

        try self.sema_block_stmt(function.body);

        self.pop_scope();
    }

    pub fn sema_program(self: *Sema, program: *ast.Program, source: *const diag.Source) SemaError!void {
        self.diagnostics = .init(self.allocator, source);

        try self.push_scope();

        for (program.functions) |function| {
            const symbol = self.add_binding(function.name.ident) catch |err| switch (err) {
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

        self.pop_scope();
        if (self.diagnostics.list.items.len > 0) return error.Diagnostic;
    }
};
