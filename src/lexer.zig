const std = @import("std");
const diag = @import("diag.zig");
const token = @import("tokens.zig");
const Token = token.Token;
const TokenKind = token.TokenKind;

const Keyword = struct { name: []const u8, kind: TokenKind };
const keywords: [3]Keyword = [_]Keyword{
    Keyword{ .name = "let", .kind = .let },
    Keyword{ .name = "fn", .kind = .fn_ },
    Keyword{ .name = "return", .kind = .return_ },
};

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

        // Return null if EOF or if we are not at a punct character.
        const peek = self.peek_byte() orelse return null;
        if (!std.ascii.isPunctuation(peek)) return null;

        const punct = self.next_byte().?;

        const kind: TokenKind = switch (punct) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .fslash,
            '=' => .equals,
            ':' => .colon,
            ';' => .semicolon,
            ',' => .comma,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lcurly,
            '}' => .rcurly,
            else => {
                try self.diagnostics.emit_error(start, "Invalid token `{c}`", .{punct});
                return error.Diagnostic;
            }
        };

        const span = self.merge_span(start);
        return Token{
            .kind = kind,
            .raw = self.src.bytes[span.lo..span.hi],
            .span = span,
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
        for (keywords) |entry| {
            if (std.mem.eql(u8, self.src.bytes[span.lo..span.hi], entry.name)) {
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

    //
    // Driver code
    //

    fn next_token(self: *@This()) !Token {
        self.read_whitespace();

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
