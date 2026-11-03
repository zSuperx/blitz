const std = @import("std");
const lexer = @import("lexer.zig");
const token = @import("tokens.zig");
const ezio = @import("ezio.zig");
const diag = @import("diag.zig");
const sp = @import("string-pool.zig");

const ast = @import("ast.zig");

const Token = token.Token;
const TokenKind = token.TokenKind;

pub const ParseError = error{
    OutOfMemory,
    Overflow,
    InvalidCharacter,
    Diagnostic,
    WriteFailed,
};

pub const Parser = struct {
    string_pool: *sp.StringPool,
    tokens: []const Token = undefined,
    diagnostics: diag.DiagnosticList = undefined,
    cursor: usize = 0,
    allocator: std.mem.Allocator,
    last_span: diag.Span = .zeroed,

    pub fn init(allocator: std.mem.Allocator, string_pool: *sp.StringPool) @This() {
        return .{
            .string_pool = string_pool,
            .allocator = allocator,
        };
    }

    //
    // Helper functions
    //

    // Emits an unexpected EOF diagnostic error
    fn report_unexpected_eof(self: *Parser) ParseError {
        try self.diagnostics.emit_error(self.last_span, "Unexpected end of file", .{});
        return ParseError.Diagnostic;
    }

    // TODO: much of these operator powers are inherited from my old compiler,
    // and I forgot how I derived them. perhaps revisit and formalize this at
    // some point?
    fn get_op_power(op: Token) ?struct { prefix: usize = 0, left: usize, right: usize } {
        return switch (op.kind) {
            // zig fmt: off
            .eq               => .{ .left = 1, .right = 0 },
            .amp2, .pipe2     => .{ .left = 3, .right = 2 },
            .eq2, .bangeq     => .{ .left = 4, .right = 5 },
            .lt, .lteq,
            .gt, .gteq        => .{ .left = 6, .right = 7 },
            .plus, .minus     => .{ .left = 8, .right = 9 },
            .fslash, .percent => .{ .left = 10, .right = 11 },
            .star             => .{ .left = 10, .right = 11, .prefix = 12 },
            .lparen           => .{ .left = 13, .right = 14 },
            // zig fmt: on

            else => null,
        };
    }

    /// Returns next token without consuming it.
    fn peek_tok(self: *const Parser) ?Token {
        if (self.cursor < self.tokens.len) {
            return self.tokens[self.cursor];
        }
        return null;
    }

    /// Returns whether next token matches `kind`.
    fn peek_tok_is(self: *const @This(), kind: std.meta.Tag(TokenKind)) bool {
        const peek = self.peek_tok() orelse return false;
        return std.meta.activeTag(peek.kind) == kind;
    }

    /// If the next token matches `kind`, returns it, else `null`.
    fn peek_tok_if(self: *const @This(), kind: std.meta.Tag(TokenKind)) ?Token {
        const peek = self.peek_tok() orelse return null;
        if (std.meta.activeTag(peek.kind) == kind) {
            return peek;
        } else {
            return null;
        }
    }

    /// Returns next token and consumes it.
    fn next_tok(self: *@This()) ?Token {
        const tok = self.peek_tok();
        if (tok) |t| self.last_span = t.span;
        self.cursor += 1;
        return tok;
    }

    /// Returns and consumes next token if it matches one of `kinds`, else errors.
    fn expect_one_of(self: *Parser, kinds: []const std.meta.Tag(TokenKind)) !Token {
        const next = self.next_tok() orelse return self.report_unexpected_eof();
        for (kinds) |kind| {
            if (std.meta.activeTag(next.kind) == kind) {
                return next;
            }
        }
        var kinds_str: std.Io.Writer.Allocating = .init(self.allocator);
        defer kinds_str.deinit();
        for (kinds, 1..) |kind, i| {
            try kinds_str.writer.print("{s}", .{@tagName(kind)});
            if (i < kinds.len) try kinds_str.writer.writeAll(", ");
            if (i == kinds.len - 1 and i > 1) try kinds_str.writer.writeAll("or ");
        }
        try self.diagnostics.emit_error(next.span, "Expected {s} but found `{s}`", .{ kinds_str.written(), next.raw });
        return error.Diagnostic;
    }

    /// Returns and consumes next token if it matches `kind`, else errors.
    fn expect_tok(self: *@This(), kind: std.meta.Tag(TokenKind)) !Token {
        const next = self.next_tok() orelse return self.report_unexpected_eof();
        if (std.meta.activeTag(next.kind) != kind) {
            try self.diagnostics.emit_error(next.span, "Expected `{s}` but found `{s}`", .{ @tagName(kind), next.raw });
            return error.Diagnostic;
        }
        return next;
    }

    //
    // Expression parsers
    //

    fn parse_expr(self: *@This()) ParseError!*ast.Expr {
        return try self.parse_expr_1(0);
    }

    fn parse_if_else_expr(self: *Parser) !ast.IfElseExpr {
        const start = try self.expect_tok(.if_);

        _ = try self.expect_tok(.lparen);
        const cond = try self.parse_expr();
        _ = try self.expect_tok(.rparen);

        const then = try self.parse_expr();

        _ = self.expect_tok(.else_) catch |err| switch (err) {
            error.Diagnostic => {
                try self.diagnostics.emit_error(
                    start.span,
                    "This `if-else` statement is an expression, so it must have two branches with the same type",
                    .{},
                );
                return err;
            },
            else => return err,
        };
        const else_ = try self.parse_expr();

        return .{
            .cond = cond,
            .then = then,
            .else_ = else_,
        };
    }

    fn parse_prefix_expr(self: *@This()) !*ast.Expr {
        const tok = self.peek_tok() orelse return self.report_unexpected_eof();
        const p = try self.allocator.create(ast.Expr);
        switch (tok.kind) {
            .number => |digits| {
                _ = self.next_tok();
                p.kind = .{
                    .number = try std.fmt.parseInt(u128, digits.items, 10),
                };
            },
            .if_ => {
                p.kind = .{
                    .ifelse = try self.parse_if_else_expr(),
                };
            },
            .ident => {
                _ = self.next_tok();
                p.kind = .{
                    .variable = .{
                        .ident = try self.string_pool.insert(tok.raw),
                    },
                };
            },
            .lparen => {
                _ = self.next_tok();
                self.allocator.destroy(p);
                const inner = try self.parse_expr();
                _ = try self.expect_tok(.rparen);
                return inner;
            },
            .lcurly => {
                p.kind = .{
                    .block = try self.parse_block_expr(),
                };
            },
            .minus => {
                _ = self.next_tok();
                p.kind = .{
                    .unary = .{
                        .op = .negate,
                        .inner = try self.parse_expr(),
                    },
                };
            },
            .bang => {
                _ = self.next_tok();
                p.kind = .{
                    .unary = .{
                        .op = .not,
                        .inner = try self.parse_expr(),
                    },
                };
            },
            .star => {
                _ = self.next_tok();
                @panic("TODO: implement dereference");
            },
            else => {
                try self.diagnostics.emit_error(tok.span, "Expected start of expression but found `{s}`", .{tok.raw});
                return error.Diagnostic;
            },
        }
        p.span = tok.span.merge(self.last_span);
        return p;
    }

    fn parse_infix_expr(self: *@This(), lhs: *ast.Expr, op: Token, op_power: usize) ParseError!*ast.Expr {
        const p = try self.allocator.create(ast.Expr);
        switch (op.kind) {
            .plus, .minus, .star, .fslash, .percent => {
                const binop: ast.BinOp = switch (op.kind) {
                    .plus => .add,
                    .minus => .sub,
                    .star => .mul,
                    .fslash => .div,
                    .percent => .mod,
                    else => unreachable,
                };

                p.kind = .{
                    .binary = .{
                        .op = binop,
                        .left = lhs,
                        .right = try self.parse_expr_1(op_power),
                    },
                };
            },
            .eq2, .bangeq => {
                const logicop: ast.LogicOp = switch (op.kind) {
                    .eq2 => .eq,
                    .bangeq => .ne,
                    else => unreachable,
                };

                p.kind = .{
                    .logic = .{
                        .op = logicop,
                        .left = lhs,
                        .right = try self.parse_expr_1(op_power),
                    },
                };
            },
            .lt, .lteq, .gt, .gteq => {
                const cmpop: ast.CmpOp = switch (op.kind) {
                    .lt => .lt,
                    .lteq => .le,
                    .gt => .gt,
                    .gteq => .ge,
                    else => unreachable,
                };

                p.kind = .{
                    .cmp = .{
                        .op = cmpop,
                        .left = lhs,
                        .right = try self.parse_expr_1(op_power),
                    },
                };
            },
            .eq,
            => {
                p.kind = .{
                    .assign = .{
                        .left = lhs,
                        .right = try self.parse_expr_1(op_power),
                    },
                };
            },
            .lparen => {
                var args = std.ArrayList(*ast.Expr).empty;
                while (self.peek_tok()) |peek| {
                    if (peek.kind == .rparen) break;
                    if (args.items.len > 0) _ = try self.expect_tok(.comma);
                    const arg = try self.parse_expr();
                    try args.append(self.allocator, arg);
                }
                _ = try self.expect_tok(.rparen);
                p.kind = .{
                    .call = .{
                        .callee = lhs,
                        .args = args.items,
                    },
                };
            },
            else => {
                try self.diagnostics.emit_error(op.span, "Expected infix operator but got `{s}`", .{op.raw});
                return error.Diagnostic;
            },
        }
        p.span = lhs.span.merge(self.last_span);
        return p;
    }

    fn parse_expr_1(self: *@This(), min_power: usize) !*ast.Expr {
        var lhs = try self.parse_prefix_expr();

        while (true) {
            const op = self.peek_tok() orelse return self.report_unexpected_eof();
            const power = get_op_power(op) orelse break;
            if (power.left < min_power) break;

            _ = self.next_tok() orelse return self.report_unexpected_eof();

            lhs = try self.parse_infix_expr(lhs, op, power.right);
        }

        return lhs;
    }

    //
    // Statement parsers
    //

    fn parse_stmt(self: *@This()) ParseError!*ast.Stmt {
        const peek = self.peek_tok() orelse return self.report_unexpected_eof();
        const p = try self.allocator.create(ast.Stmt);
        switch (peek.kind) {
            .const_, .mut => {
                p.kind = .{ .decl = try self.parse_decl_stmt() };
            },
            .return_ => {
                p.kind = .{ .return_ = try self.parse_return_stmt() };
            },
            .if_ => {
                p.kind = .{ .if_ = try self.parse_if_stmt() };
            },
            else => {
                p.kind = .{ .expr = try self.parse_expr_stmt() };
            },
        }
        p.span = peek.span.merge(self.last_span);
        return p;
    }

    fn parse_if_stmt(self: *Parser) !ast.IfStmt {
        _ = try self.expect_tok(.if_);

        _ = try self.expect_tok(.lparen);
        const cond = try self.parse_expr();
        _ = try self.expect_tok(.rparen);

        const is_braced_then = self.peek_tok_is(.lcurly);
        const then = try self.parse_expr();
        if (!is_braced_then) _ = try self.expect_tok(.semicolon);

        var else_: ?*ast.Expr = null;

        if (self.peek_tok_is(.else_)) {
            _ = try self.expect_tok(.else_);
            const is_braced_else = self.peek_tok_is(.lcurly);
            else_ = try self.parse_expr();
            if (!is_braced_else) _ = try self.expect_tok(.semicolon);
        }

        return .{
            .cond = cond,
            .then = then,
            .else_ = else_,
        };
    }

    fn parse_expr_stmt(self: *@This()) !ast.ExprStmt {
        const expr = try self.parse_expr();
        return .{ .expr = expr };
    }

    fn parse_decl_stmt(self: *@This()) !ast.DeclStmt {
        const declarator = try self.expect_one_of(&.{ .const_, .mut });

        const ident = try self.expect_tok(.ident);
        const variable = ident.raw;

        var expr: ?*ast.Expr = null;
        if (self.peek_tok_is(.eq)) {
            _ = try self.expect_tok(.eq);

            expr = try self.parse_expr();
        }

        return .{
            .variable = ast.Variable{
                .ident = try self.string_pool.insert(variable),
            },
            .init = expr,
            .mutable = std.meta.activeTag(declarator.kind) == .mut,
        };
    }

    fn foo() void {}

    fn parse_block_expr(self: *@This()) !ast.BlockExpr {
        _ = try self.expect_tok(.lcurly);
        var stmts = std.ArrayList(*ast.Stmt).empty;

        // early return if empty block
        if (self.peek_tok_is(.rcurly)) {
            _ = try self.expect_tok(.rcurly);

            return .{
                .stmts = stmts.items,
                .tail = null,
            };
        }

        const tail = while (true) {
            // Try and parse a statement. It can be an expression too in which
            // case stmt.kind.expr will be active.
            const stmt = try self.parse_stmt();

            if (self.peek_tok_is(.rcurly)) {
                // This branch means stmt is a tail stmt.
                if (stmt.as_expr()) |expr| {
                    // If the stmt is an expression, set the block's tail
                    break expr;
                } else {
                    // Otherwise just append it to the block's stmts; the block
                    // has no tail expr
                    try stmts.append(self.allocator, stmt);
                    break null;
                }
            } else {
                // If we parse a statement and the next token is NOT an rcurly,
                // it must be a semicolon.
                _ = try self.expect_tok(.semicolon);
                try stmts.append(self.allocator, stmt);

                // In the case that this was the last statement in the block, check for rcurly
                if (self.peek_tok_is(.rcurly)) {
                    break null;
                }
            }
        };
        _ = try self.expect_tok(.rcurly);

        return .{
            .stmts = stmts.items,
            .tail = tail,
        };
    }

    fn parse_return_stmt(self: *Parser) !ast.ReturnStmt {
        _ = try self.expect_tok(.return_);
        const value = try self.parse_expr();
        return .{ .value = value };
    }

    //
    // Top level parsers
    //

    fn parse_function(self: *@This()) !*ast.Function {
        const fn_ = try self.expect_tok(.fn_);

        const fn_name = try self.expect_tok(.ident);
        const fn_id = try self.string_pool.insert(fn_name.raw);

        var arguments = std.ArrayList(ast.Variable).empty;
        // parse argument names
        _ = try self.expect_tok(.lparen);
        while (!self.peek_tok_is(.rparen)) {
            const arg_name = try self.expect_tok(.ident);
            const arg_id = try self.string_pool.insert(arg_name.raw);
            try arguments.append(self.allocator, .{ .ident = arg_id });
            if (!self.peek_tok_is(.rparen)) _ = try self.expect_tok(.comma);
        }
        const rparen = try self.expect_tok(.rparen);

        const body = try self.parse_block_expr();
        const expr = try self.allocator.create(ast.Expr);
        expr.* = .{
            .kind = .{ .block = body },
            .span = fn_.span.merge(rparen.span),
        };

        const p = try self.allocator.create(ast.Function);
        p.* = .{
            .name = .{ .ident = fn_id },
            .arguments = arguments.items,
            .body = expr,
            .span = fn_.span.merge(expr.span),
        };
        return p;
    }

    pub fn parse_program(self: *@This(), tokens: []const Token, source: *const diag.Source) !*ast.Program {
        self.diagnostics = .init(self.allocator, source);
        self.tokens = tokens;
        self.cursor = 0;

        var functions = std.ArrayList(*ast.Function).empty;

        while (self.cursor < tokens.len) {
            const function = try self.parse_function();
            try functions.append(self.allocator, function);
        }

        if (self.diagnostics.list.items.len > 0) return error.Diagnostic;

        const p = try self.allocator.create(ast.Program);
        p.* = .{
            .functions = functions.items,
        };
        return p;
    }
};
