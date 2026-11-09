const std = @import("std");
const lexer = @import("lexer.zig");
const token = @import("tokens.zig");
const ezio = @import("ezio.zig");
const diag = @import("diag.zig");
const interner = @import("interner.zig");
const state = @import("state.zig");

const ast = @import("ast.zig");

const Token = token.Token;
const TokenKind = token.TokenKind;

const String = interner.String;
const StringPool = interner.StringPool;

pub const ParseError = error{
    OutOfMemory,
    Overflow,
    InvalidCharacter,
    Fatal,
    WriteFailed,
};

pub const Parser = struct {
    string_pool: *StringPool,
    tokens: []const Token = undefined,
    cursor: usize = 0,
    allocator: std.mem.Allocator,
    last_span: diag.Span = .zeroed,
    last_token: ?Token = null,

    pub fn init(allocator: std.mem.Allocator, string_pool: *StringPool) Parser {
        return .{
            .string_pool = string_pool,
            .allocator = allocator,
        };
    }

    //
    // Helper functions
    //

    inline fn createInit(self: *Parser, comptime T: type, v: T) !*T {
        const p = try self.allocator.create(T);
        p.* = v;
        return p;
    }

    // Emits an unexpected EOF diagnostic error
    fn report_unexpected_eof(self: *Parser) ParseError {
        state.diagnostics.emit_error("Unexpected end of file {f}", .{self.last_span});
        return ParseError.Fatal;
    }

    // TODO: much of these operator powers are inherited from my old compiler,
    // and I forgot how I derived them. perhaps revisit and formalize this at
    // some point?
    fn get_op_power(op: TokenKind) ?struct { prefix: usize = 0, left: usize, right: usize } {
        return switch (op) {
            .eq, .plus_eq, .minus_eq, .star_eq, .fslash_eq, .percent_eq => .{ .left = 1, .right = 0 },
            .amp2, .pipe2 => .{ .left = 3, .right = 2 },
            .eq2, .bang_eq => .{ .left = 4, .right = 5 },
            .lt, .lt_eq, .gt, .gt_eq => .{ .left = 6, .right = 7 },
            .plus, .minus => .{ .left = 8, .right = 9 },
            .fslash, .percent => .{ .left = 10, .right = 11 },
            .star => .{ .left = 10, .right = 11, .prefix = 12 },
            .lparen => .{ .left = 13, .right = 14 },

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
    fn peek_tok_is(self: *const Parser, kind: std.meta.Tag(TokenKind)) bool {
        const peek = self.peek_tok() orelse return false;
        return std.meta.activeTag(peek.kind) == kind;
    }

    /// If the next token matches `kind`, returns it, else `null`.
    fn peek_tok_if(self: *const Parser, kind: std.meta.Tag(TokenKind)) ?Token {
        const peek = self.peek_tok() orelse return null;
        if (std.meta.activeTag(peek.kind) == kind) {
            return peek;
        } else {
            return null;
        }
    }

    /// Returns next token and consumes it.
    fn next_tok(self: *Parser) ?Token {
        const tok = self.peek_tok();
        if (tok) |t| {
            self.last_token = t;
            self.last_span = t.span;
        }
        self.cursor += 1;
        return tok;
    }

    /// Returns and consumes next token if it matches one of `kinds`, else errors.
    fn expect_one_of(self: *Parser, kinds: []const std.meta.Tag(TokenKind)) !Token {
        const span = self.last_span;
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
        state.diagnostics.emit_error(
            "Expected one of [{s}] after this, but found `{s}` {f}",
            .{ kinds_str.written(), next.raw, span },
        );
        return error.Fatal;
    }

    /// Returns and consumes next token if it matches `kind`, else errors.
    fn expect_tok(self: *Parser, kind: std.meta.Tag(TokenKind)) !Token {
        const span = self.last_span;
        const next = self.next_tok() orelse return self.report_unexpected_eof();
        if (std.meta.activeTag(next.kind) != kind) {
            state.diagnostics.emit_error(
                "Expected `{s}` after this, but found `{s}` {f}",
                .{
                    @tagName(kind),
                    next.raw,
                    span,
                },
            );
            return error.Fatal;
        }
        return next;
    }

    fn parse_var_decl(self: *Parser) !ast.VarDecl {
        const declarator = try self.expect_one_of(&.{ .const_, .mut });

        const variable = try self.parse_variable_reference();

        var ty: ?*ast.TypeRef = null;
        if (self.peek_tok_is(.colon)) {
            _ = self.next_tok();
            ty = try self.parse_type_reference();
        }

        return .{
            .mutable = declarator.kind == .mut,
            .variable = variable,
            .span = declarator.span.merge(self.last_span),
            .ty = ty,
        };
    }

    //
    // Expression parsers
    //

    fn parse_expr(self: *Parser) ParseError!*ast.Expr {
        return try self.parse_expr_1(0);
    }

    fn parse_if_else_expr(self: *Parser) !ast.IfElseExpr {
        _ = try self.expect_tok(.if_);

        _ = try self.expect_tok(.lparen);
        const cond = try self.parse_expr();
        _ = try self.expect_tok(.rparen);

        const then = try self.parse_expr();

        var else_: ?*ast.Expr = null;
        if (self.peek_tok_is(.else_)) {
            _ = self.next_tok();
            else_ = try self.parse_expr();
        }

        return .{
            .cond = cond,
            .then = then,
            .else_ = else_,
        };
    }

    // x++, ++x, x++6, ++6 x
    fn parse_prefix_expr(self: *Parser) !*ast.Expr {
        const tok = self.peek_tok() orelse return self.report_unexpected_eof();
        var kind: ast.ExprKind = undefined;
        switch (tok.kind) {
            .return_ => {
                kind = .{ .return_ = try self.parse_return_expr() };
            },
            .number => |digits| {
                _ = self.next_tok();
                kind = .{
                    .number = try std.fmt.parseInt(u128, digits.items, 10),
                };
            },
            .if_ => {
                kind = .{
                    .ifelse = try self.parse_if_else_expr(),
                };
            },
            .ident => {
                kind = .{
                    .variable = try self.parse_variable_reference(),
                };
            },
            .lparen => {
                _ = self.next_tok();
                const inner = try self.parse_expr();
                _ = try self.expect_tok(.rparen);
                return inner;
            },
            .lcurly => {
                kind = .{
                    .block = try self.parse_block_expr(),
                };
            },
            .minus => {
                _ = self.next_tok();
                kind = .{
                    .unary = .{
                        .op = .negate,
                        .inner = try self.parse_expr(),
                    },
                };
            },
            .bang => {
                _ = self.next_tok();
                kind = .{
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
                state.diagnostics.emit_error("Expected start of expression but found `{s}` {f}", .{ tok.raw, tok.span });
                return error.Fatal;
            },
        }
        const p = try self.createInit(ast.Expr, .{
            .kind = kind,
            .span = tok.span.merge(self.last_span),
            .ty = null,
        });
        return p;
    }

    fn parse_infix_expr(self: *Parser, lhs: *ast.Expr, op: Token, op_power: usize) ParseError!*ast.Expr {
        var kind: ast.ExprKind = undefined;
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

                kind = .{
                    .binary = .{
                        .op = binop,
                        .left = lhs,
                        .right = try self.parse_expr_1(op_power),
                    },
                };
            },
            .eq2, .bang_eq => {
                const logicop: ast.LogicOp = switch (op.kind) {
                    .eq2 => .eq,
                    .bang_eq => .ne,
                    else => unreachable,
                };

                kind = .{
                    .logic = .{
                        .op = logicop,
                        .left = lhs,
                        .right = try self.parse_expr_1(op_power),
                    },
                };
            },
            .lt, .lt_eq, .gt, .gt_eq => {
                const cmpop: ast.CmpOp = switch (op.kind) {
                    .lt => .lt,
                    .lt_eq => .le,
                    .gt => .gt,
                    .gt_eq => .ge,
                    else => unreachable,
                };

                kind = .{
                    .cmp = .{
                        .op = cmpop,
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
                kind = .{
                    .call = .{
                        .callee = lhs,
                        .args = args.items,
                    },
                };
            },
            else => {
                state.diagnostics.emit_error("Expected infix operator but got `{s}` {f}", .{ op.raw, op.span });
                return error.Fatal;
            },
        }
        return try self.createInit(ast.Expr, .{
            .kind = kind,
            .ty = null,
            .span = lhs.span.merge(self.last_span),
        });
    }

    fn parse_expr_1(self: *Parser, min_power: usize) !*ast.Expr {
        var lhs = try self.parse_prefix_expr();

        while (true) {
            const op = self.peek_tok() orelse return self.report_unexpected_eof();
            const power = get_op_power(op.kind) orelse break;
            if (power.left < min_power) break;

            _ = self.next_tok() orelse return self.report_unexpected_eof();

            lhs = try self.parse_infix_expr(lhs, op, power.right);
        }

        return lhs;
    }

    fn parse_block_expr(self: *Parser) !ast.BlockExpr {
        _ = try self.expect_tok(.lcurly);
        var stmts = std.ArrayList(*ast.Stmt).empty;
        var tail: ?*ast.Expr = null;

        while (!self.peek_tok_is(.rcurly)) {
            const stmt = try self.parse_stmt();
            if (self.peek_tok_is(.rcurly)) {
                if (stmt.as_expr()) |expr| {
                    tail = expr;
                } else {
                    try stmts.append(self.allocator, stmt);
                    if (self.last_token) |tok| {
                        if (tok.kind != .semicolon and tok.kind != .rcurly)
                            _ = try self.expect_tok(.semicolon);
                    }
                }
            } else {
                try stmts.append(self.allocator, stmt);
                if (self.last_token) |tok| {
                    if (tok.kind != .semicolon and tok.kind != .rcurly)
                        _ = try self.expect_tok(.semicolon);
                }
            }
        }

        _ = try self.expect_tok(.rcurly);

        return .{
            .stmts = stmts.items,
            .tail = tail,
        };
    }

    //
    // Statement parsers
    //

    fn parse_stmt(self: *Parser) ParseError!*ast.Stmt {
        const peek = self.peek_tok() orelse return self.report_unexpected_eof();
        var kind: @FieldType(ast.Stmt, "kind") = undefined;
        switch (peek.kind) {
            .const_, .mut => {
                kind = .{ .decl = try self.parse_decl_stmt() };
            },
            else => {
                const expr = try self.parse_expr_1(get_op_power(.eq).?.left + 1);

                const assign_op: ?ast.AssignOp = if (self.peek_tok()) |tok| switch (tok.kind) {
                    // zig fmt: off
                    .eq         => .assign,
                    .plus_eq    => .assign_add,
                    .minus_eq   => .assign_sub,
                    .star_eq    => .assign_mul,
                    .fslash_eq  => .assign_div,
                    .percent_eq => .assign_mod,
                    else        =>  null,
                    // zig fmt: on
                } else null;

                if (assign_op) |op| {
                    _ = self.next_tok();
                    const right = try self.parse_expr();
                    kind = .{
                        .assign = .{
                            .op = op,
                            .left = expr,
                            .right = right,
                        },
                    };
                } else {
                    kind = .{ .expr = expr };
                }
            },
        }

        return try self.createInit(ast.Stmt, .{
            .kind = kind,
            .span = peek.span.merge(self.last_span),
        });
    }

    fn parse_decl_stmt(self: *Parser) !ast.DeclStmt {
        const spec = try self.parse_var_decl();

        var expr: ?*ast.Expr = null;
        if (self.peek_tok_is(.eq)) {
            _ = self.next_tok();

            expr = try self.parse_expr();
        }

        return .{
            .decl = spec,
            .init = expr,
        };
    }

    fn parse_return_expr(self: *Parser) !ast.ReturnExpr {
        _ = try self.expect_tok(.return_);
        const value = try self.parse_expr();
        return .{ .value = value };
    }

    fn parse_variable_reference(self: *Parser) !ast.VarRef {
        const name = try self.expect_tok(.ident);
        return .{
            .text = try self.string_pool.add(name.raw),
            .span = name.span,
        };
    }

    //
    // Top level parsers
    //

    fn parse_type_reference(self: *Parser) !*ast.TypeRef {
        const start = self.peek_tok() orelse return self.report_unexpected_eof();
        var kind: @FieldType(ast.TypeRef, "kind") = undefined;
        var span: diag.Span = undefined;
        if (start.kind == .star) {
            _ = self.next_tok();
            const inner = try self.parse_type_reference();
            kind = .{ .pointer = inner };
            span = start.span.merge(inner.span);
        } else {
            const name = try self.parse_variable_reference();
            kind = .{ .base = name };
            span = start.span.merge(self.last_span);
        }
        return try self.createInit(ast.TypeRef, .{
            .kind = kind,
            .span = span,
        });
    }

    fn parse_argument(self: *Parser) !ast.VarDecl {
        if (self.peek_tok_is(.ident)) {
            const start = self.peek_tok().?.span;
            const variable = try self.parse_variable_reference();

            _ = self.expect_tok(.colon) catch {
                state.diagnostics.emit_error(
                    "Function arguments must have a known type {f}",
                    .{start},
                );
            };
            const ty = try self.parse_type_reference();

            return .{
                .ty = ty,
                .mutable = false,
                .variable = variable,
                .span = start.merge(self.last_span),
            };
        } else {
            const decl = try self.parse_var_decl();
            if (decl.ty == null) {
                state.diagnostics.emit_error(
                    "Function arguments must have a known type {f}",
                    .{decl.span},
                );
            }
            return decl;
        }
    }

    fn parse_function(self: *Parser) !*ast.Function {
        const start = try self.expect_tok(.fn_);

        const fn_name = try self.parse_variable_reference();

        // start parse args
        var arguments = std.ArrayList(ast.VarDecl).empty;
        _ = try self.expect_tok(.lparen);

        while (!self.peek_tok_is(.rparen)) {
            const arg = try self.parse_argument();
            try arguments.append(self.allocator, arg);
            if (!self.peek_tok_is(.rparen)) _ = try self.expect_tok(.comma);
        }

        const rparen = try self.expect_tok(.rparen);
        // end parse args

        // start parse return
        const return_type = if (self.peek_tok_is(.colon)) b: {
            _ = try self.expect_tok(.colon);
            break :b try self.parse_type_reference();
        } else null;
        // end parse return

        const body = try self.parse_block_expr();
        const expr = try self.createInit(ast.Expr, .{
            .kind = .{ .block = body },
            .span = start.span.merge(rparen.span),
            .ty = null,
        });

        return try self.createInit(ast.Function, .{
            .name = fn_name,
            .arguments = arguments.items,
            .return_type = return_type,
            .body = expr,
            .span = start.span.merge(expr.span),
        });
    }

    pub fn parse_program(self: *Parser, tokens: []const Token) !*ast.Program {
        state.diagnostics = .init(self.allocator);
        self.tokens = tokens;
        self.cursor = 0;

        var functions = std.ArrayList(*ast.Function).empty;

        while (self.cursor < tokens.len) {
            const function = try self.parse_function();
            try functions.append(self.allocator, function);
        }

        if (state.diagnostics.list.items.len > 0) return error.Fatal;

        return try self.createInit(ast.Program, .{
            .functions = functions.items,
        });
    }
};
