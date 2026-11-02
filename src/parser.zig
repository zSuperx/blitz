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
};

pub const Parser = struct {
    string_pool: *sp.StringPool,
    tokens: []const Token = undefined,
    diagnostics: diag.DiagnosticList = undefined,
    cursor: usize = 0,
    allocator: std.mem.Allocator,
    last_token: ?Token = null,

    pub fn init(allocator: std.mem.Allocator, string_pool: *sp.StringPool) @This() {
        return .{
            .string_pool = string_pool,
            .allocator = allocator,
        };
    }

    //
    // Helper functions
    //

    fn report_unexpected_eof(self: *Parser) ParseError {
        try self.diagnostics.emit_error(self.last_token.?.span, "Unexpected end of file", .{});
        return ParseError.Diagnostic;
    }

    fn get_infix_power(op: Token) ?struct { prefix: usize = 0, left: usize, right: usize } {
        return switch (op.kind) {
            .equals => .{ .left = 1, .right = 0 },
            .plus, .minus => .{ .left = 2, .right = 3 },
            .fslash => .{ .left = 4, .right = 5 },
            .star => .{ .prefix = 9, .left = 4, .right = 5 },
            .lparen => .{ .left = 10, .right = 11 },

            else => null,
        };
    }

    fn peek_tok(self: *const @This()) ?Token {
        if (self.cursor < self.tokens.len) {
            return self.tokens[self.cursor];
        }
        return null;
    }

    fn peek_tok_is(self: *const @This(), kind: std.meta.Tag(TokenKind)) bool {
        const peek = self.peek_tok() orelse return false;
        return std.meta.activeTag(peek.kind) == kind;
    }

    fn next_tok(self: *@This()) ?Token {
        const tok = self.peek_tok();
        self.last_token = tok;
        self.cursor += 1;
        return tok;
    }

    fn expect_tok(self: *@This(), kind: std.meta.Tag(TokenKind)) !Token {
        const next = self.next_tok() orelse return self.report_unexpected_eof();
        if (std.meta.activeTag(next.kind) != kind) {
            try self.diagnostics.emit_error(next.span, "Expected `{s}` but found `{f}`", .{ @tagName(kind), next.kind });
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

    fn parse_prefix_expr(self: *@This()) !*ast.Expr {
        const tok = self.next_tok() orelse return self.report_unexpected_eof();
        const p = try self.allocator.create(ast.Expr);
        switch (tok.kind) {
            .number => |digits| {
                p.kind = .{
                    .number = try std.fmt.parseInt(u128, digits.items, 10),
                };
            },
            .ident => {
                p.kind = .{
                    .variable = .{
                        .ident = try self.string_pool.insert(tok.raw),
                    },
                };
            },
            .lparen => {
                self.allocator.destroy(p);
                const inner = try self.parse_expr();
                _ = try self.expect_tok(.rparen);
                return inner;
            },
            .minus => {
                p.kind = .{
                    .unary = .{
                        .op = .negate,
                        .inner = try self.parse_expr(),
                    },
                };
            },
            .bang => {
                p.kind = .{
                    .unary = .{
                        .op = .not,
                        .inner = try self.parse_expr(),
                    },
                };
            },
            .star => {
                @panic("TODO: implement dereference");
            },
            else => {
                try self.diagnostics.emit_error(tok.span, "Expected start of expression but found `{f}`", .{tok.kind});
                return error.Diagnostic;
            },
        }
        p.span = tok.span.merge(self.last_token.?.span);
        return p;
    }

    fn parse_infix_expr(self: *@This(), lhs: *ast.Expr, op: Token, op_power: usize) ParseError!*ast.Expr {
        const p = try self.allocator.create(ast.Expr);
        switch (op.kind) {
            .plus,
            .minus,
            .star,
            .fslash,
            => {
                const binop: ast.BinOp = switch (op.kind) {
                    .plus => .add,
                    .minus => .sub,
                    .star => .mul,
                    .fslash => .div,
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
            .equals => {
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
                try self.diagnostics.emit_error(op.span, "Expected infix operator but got `{f}`", .{op.kind});
                return error.Diagnostic;
            },
        }
        p.span = lhs.span.merge(self.last_token.?.span);
        return p;
    }

    fn parse_expr_1(self: *@This(), min_power: usize) !*ast.Expr {
        var lhs = try self.parse_prefix_expr();

        while (true) {
            const op = self.peek_tok() orelse return self.report_unexpected_eof();
            const power = get_infix_power(op) orelse break;
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
        var expect_semicolon = true;
        const p = try self.allocator.create(ast.Stmt);
        switch (std.meta.activeTag(peek.kind)) {
            .lcurly => {
                expect_semicolon = false;
                p.kind = .{ .block = try self.parse_block_stmt() };
            },
            .let => {
                p.kind = .{ .let = try self.parse_let_stmt() };
            },
            .return_ => {
                p.kind = .{ .return_ = try self.parse_return_stmt() };
            },
            else => {
                p.kind = .{ .expr = try self.parse_expr_stmt() };
            },
        }
        if (expect_semicolon) _ = try self.expect_tok(.semicolon);
        p.span = peek.span.merge(self.last_token.?.span);
        return p;
    }

    fn parse_expr_stmt(self: *@This()) !ast.ExprStmt {
        const expr = try self.parse_expr();
        return .{ .expr = expr };
    }

    fn parse_let_stmt(self: *@This()) !ast.LetStmt {
        _ = try self.expect_tok(.let);

        const ident = try self.expect_tok(.ident);
        const variable = ident.raw;

        _ = try self.expect_tok(.equals);

        const expr = try self.parse_expr();

        return .{
            .variable = ast.Variable{
                .ident = try self.string_pool.insert(variable),
            },
            .init = expr,
        };
    }

    fn parse_block_stmt(self: *@This()) !ast.BlockStmt {
        const lcurly = try self.expect_tok(.lcurly);
        var stmts = std.ArrayList(*ast.Stmt).empty;
        while (!self.peek_tok_is(.rcurly)) {
            const stmt = try self.parse_stmt();
            try stmts.append(self.allocator, stmt);
        }
        const rcurly = try self.expect_tok(.rcurly);

        _ = lcurly;
        _ = rcurly;

        return .{ .stmts = stmts.items };
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

        const body = try self.parse_block_stmt();
        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = .{
            .kind = .{ .block = body },
            .span = fn_.span.merge(rparen.span),
        };

        const p = try self.allocator.create(ast.Function);
        p.* = .{
            .name = .{ .ident = fn_id },
            .arguments = arguments.items,
            .body = stmt,
            .span = fn_.span.merge(stmt.span),
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
