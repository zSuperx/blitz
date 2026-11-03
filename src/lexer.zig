const std = @import("std");
const diag = @import("diag.zig");
const token = @import("tokens.zig");
const Token = token.Token;
const TokenKind = token.TokenKind;

const LexError = error{
    InvalidPunct,
    NotANumber,
    OutOfMemory,
    Diagnostic,
};

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    diagnostics: diag.DiagnosticList = undefined,
    src: *const diag.Source = undefined,
    cursor: usize = 0,
    row: usize = 0,
    col: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Lexer {
        return .{
            .allocator = allocator,
        };
    }

    //
    // Helper functions
    //

    fn current_span(self: *const Lexer) diag.Span {
        return .{
            .lo = self.cursor,
            .hi = self.cursor,
            .row = self.col,
            .col = self.row,
        };
    }

    fn merge_span(self: *const Lexer, span: diag.Span) diag.Span {
        return self.current_span().merge(span);
    }

    fn peek_byte(self: *const @This()) ?u8 {
        if (self.cursor >= self.src.bytes.len) {
            return null;
        } else {
            return self.src.bytes[self.cursor];
        }
    }

    fn peek_n_bytes(self: *const Lexer, n: usize) []const u8 {
        const hi = @min(self.src.bytes.len, self.cursor + n);
        return self.src.bytes[self.cursor..hi];
    }

    fn next_byte(self: *@This()) ?u8 {
        const byte = self.peek_byte();
        self.cursor += 1;
        if (byte == '\n') {
            self.col += 1;
            self.row = 0;
        } else {
            self.row += 1;
        }
        return byte;
    }

    //
    // Reader functions
    //

    fn read_number(self: *@This()) !?Token {
        const start = self.current_span();
        var buffer = std.ArrayList(u8).empty;

        // return null if EOF or not a number
        var peek = self.peek_byte() orelse return null;
        if (!std.ascii.isDigit(peek)) return null;

        while (true) {
            peek = self.peek_byte() orelse break;
            if ((!std.ascii.isDigit(peek) and
                peek != '_'))
            {
                break;
            }

            const digit = self.next_byte().?;
            if (digit != '_') try buffer.append(self.allocator, digit);
        }
        const span = self.merge_span(start);

        return Token{
            .kind = .{ .number = buffer },
            .raw = self.src.bytes[span.lo..span.hi],
            .span = span,
        };
    }

    fn read_punctuation(self: *@This()) !?Token {
        const start = self.current_span();

        const lookahead = self.peek_n_bytes(token.MAX_PUNCT_LEN);
        var token_length = lookahead.len;

        const kind: TokenKind = brk: while (token_length > 0) : (token_length -= 1) {
            for (token.punctuators) |p| {
                if (std.mem.eql(u8, lookahead[0..token_length], p.text)) {
                    break :brk p.kind;
                }
            }
        } else {
            return null;
        };

        for (0..token_length) |_| {
            _ = self.next_byte();
        }

        const span = start.merge(self.current_span());
        return .{
            .kind = kind,
            .span = span,
            .raw = self.src.bytes[span.lo..span.hi],
        };
    }

    fn read_word(self: *@This()) !?Token {
        const start = self.current_span();

        var peek = self.peek_byte() orelse return null;
        if (!std.ascii.isAlphabetic(peek) and peek != '_') return null;

        while (true) {
            peek = self.peek_byte() orelse break;
            if (!std.ascii.isAlphanumeric(peek) and peek != '_') break;

            _ = self.next_byte().?;
        }
        const span = self.merge_span(start);
        var kind: TokenKind = .ident;
        for (token.keywords) |entry| {
            if (std.mem.eql(u8, self.src.bytes[span.lo..span.hi], entry.text)) {
                kind = entry.kind;
            }
        }

        return Token{
            .kind = kind,
            .raw = self.src.bytes[span.lo..span.hi],
            .span = span,
        };
    }

    fn read_whitespace(self: *@This()) void {
        while (self.peek_byte()) |byte| {
            if (!std.ascii.isWhitespace(byte)) break;
            _ = self.next_byte();
        }
    }

    // Reads a comment, whether it be line or block. Returns whether a comment was read.
    fn read_comment(self: *Lexer) !bool {
        const lookahead = self.peek_n_bytes(2);

        if (std.mem.eql(u8, lookahead, "//")) {
            _ = self.next_byte();
            _ = self.next_byte();

            while (self.next_byte()) |byte| {
                if (byte == '\n') break;
            }
            return true;
        } else if (std.mem.eql(u8, lookahead, "/*")) {
            _ = self.next_byte();
            _ = self.next_byte();

            while (true) {
                const byte = self.next_byte() orelse {
                    try self.diagnostics.emit_error(
                        self.current_span(),
                        "Unterminated block comment. Terminate it with `*/`",
                        .{},
                    );
                    return error.Diagnostic;
                };

                if (byte == '*') {
                    if (self.peek_byte() == '/') {
                        _ = self.next_byte();
                        return true;
                    }
                }
            }
        }
        return false;
    }
    //
    // Driver code
    //

    fn next_token(self: *@This()) !Token {
        while (true) {
            self.read_whitespace();
            if (!try self.read_comment()) break;
        }

        if (try self.read_number()) |tok| return tok;
        if (try self.read_word()) |tok| return tok;
        if (try self.read_punctuation()) |tok| return tok;

        // EOF
        return Token{
            .kind = .eof,
            .raw = self.src.bytes[self.cursor..self.cursor],
            .span = self.current_span(),
        };
    }

    pub fn tokenize(self: *@This(), source: *const diag.Source) LexError![]const Token {
        self.diagnostics = .init(self.allocator, source);
        self.src = source;
        self.cursor = 0;
        self.row = 0;
        self.col = 0;

        var tokens = std.ArrayList(Token).empty;

        while (true) {
            const tok = try self.next_token();
            if (tok.kind == .eof) break;
            try tokens.append(self.allocator, tok);
        }

        return tokens.items;
    }
};
