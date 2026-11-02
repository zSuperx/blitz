const std = @import("std");
const diag = @import("diag.zig");

pub const TokenKind = union(enum) {
    // zig fmt: off
    string_literal: std.ArrayList(u8),  // does not include surrounding quotes
    number: std.ArrayList(u8),          // does not include underscores
    ident,                              // raw contains payload

    // Keywords
    let,                                // let
    fn_,                                // fn
    return_,                            // return

    // Punctuation
    semicolon,                          // ;
    colon,                              // :
    lparen,                             // (
    rparen,                             // )
    lcurly,                             // {
    rcurly,                             // }
    comma,                              // ,
    plus,                               // +
    minus,                              // -
    star,                               // *
    fslash,                             // /
    equals,                             // =
    bang,                               // !
    amp,                                // &
    pipe,                               // |

    eof,
    // zig fmt: on

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const s = switch (self) {
            .string_literal => "string literal",
            .number => "numeric literal",
            .ident => "identifier",

            .let => "let",
            .fn_ => "fn",
            .return_ => "return",

            .semicolon => ";",
            .colon => ":",
            .lparen => "(",
            .rparen => ")",
            .lcurly => "{",
            .rcurly => "}",
            .comma => ",",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .fslash => "/",
            .equals => "=",
            .bang => "!",
            .amp => "&",
            .pipe => "|",
            .eof => "EOF",
        };

        try writer.writeAll(s);
    }
};

pub const Token = struct {
    kind: TokenKind,
    span: diag.Span,
    raw: []const u8,

    pub fn format(self: Token, writer: *std.Io.Writer) !void {
        try writer.print("{any}", .{self.kind});
        try writer.print(", {any}", .{self.span});
    }
};
