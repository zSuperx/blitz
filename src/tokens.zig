const std = @import("std");
const diag = @import("diag.zig");

pub const TokenKind = union(enum) {
    // zig fmt: off
    string_literal: std.ArrayList(u8),  // does not include surrounding quotes
    number: std.ArrayList(u8),          // does not include underscores
    ident,                              // raw contains payload

    // Keywords
    fn_,                                // fn
    return_,                            // return
    const_,                             // const
    mut,                                // mut
    if_,                                // if
    else_,                              // else
    while_,                             // while

    // Punctuation
    percent,                            // %
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
    bang,                               // !
    amp,                                // &
    pipe,                               // |
    eq,                                 // =
    gt,                                 // >
    lt,                                 // <
    eq2,                                // ==
    bangeq,                             // !=
    gteq,                               // >=
    lteq,                               // <=
    amp2,                               // &&
    pipe2,                              // ||

    eof,
    // zig fmt: on

};

pub const TokenMapping = struct { text: []const u8, kind: TokenKind };
pub const keywords: [7]TokenMapping = [_]TokenMapping{
    .{ .text = "const", .kind = .const_ },
    .{ .text = "mut", .kind = .mut },
    .{ .text = "fn", .kind = .fn_ },
    .{ .text = "if", .kind = .if_ },
    .{ .text = "else", .kind = .else_ },
    .{ .text = "return", .kind = .return_ },
    .{ .text = "while", .kind = .while_ },
};

pub const Punctuator = struct { name: []const u8, kind: TokenKind };
pub const MAX_PUNCT_LEN = 2;
pub const punctuators: [24]TokenMapping = [_]TokenMapping{
    .{ .text = "==", .kind = .eq2 },
    .{ .text = "!=", .kind = .bangeq },
    .{ .text = ">=", .kind = .gteq },
    .{ .text = "<=", .kind = .lteq },
    .{ .text = "&&", .kind = .amp2 },
    .{ .text = "||", .kind = .pipe2 },
    .{ .text = "%", .kind = .percent },
    .{ .text = ";", .kind = .semicolon },
    .{ .text = ":", .kind = .colon },
    .{ .text = "(", .kind = .lparen },
    .{ .text = ")", .kind = .rparen },
    .{ .text = "{", .kind = .lcurly },
    .{ .text = "}", .kind = .rcurly },
    .{ .text = ",", .kind = .comma },
    .{ .text = "+", .kind = .plus },
    .{ .text = "-", .kind = .minus },
    .{ .text = "*", .kind = .star },
    .{ .text = "/", .kind = .fslash },
    .{ .text = "!", .kind = .bang },
    .{ .text = "&", .kind = .amp },
    .{ .text = "|", .kind = .pipe },
    .{ .text = "=", .kind = .eq },
    .{ .text = ">", .kind = .gt },
    .{ .text = "<", .kind = .lt },
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
