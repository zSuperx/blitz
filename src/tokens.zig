const std = @import("std");
const diag = @import("diag.zig");

pub const TokenKind = union(enum) {
    // zig fmt: off
    string_literal: std.ArrayList(u8),  // does not include surrounding quotes
    number: std.ArrayList(u8),          // does not include underscores
    ident,                              // raw contains payload

    // Keywords
    fn_,
    return_,
    const_,
    mut,
    if_,
    else_,
    while_,

    // Punctuation
    percent,
    semicolon,
    colon,
    lparen,
    rparen,
    lcurly,
    rcurly,
    comma,
    plus,
    minus,
    star,
    fslash,
    bang,
    amp,
    pipe,
    eq,
    gt,
    lt,
    eq2,
    bang_eq,
    gt_eq,
    lt_eq,
    amp2,
    pipe2,
    plus2,
    minus2,
    plus_eq,
    minus_eq,
    star_eq,
    fslash_eq,
    percent_eq,

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
pub const punctuators: [32]TokenMapping = [_]TokenMapping{
    .{ .text = "+=", .kind = .plus_eq },
    .{ .text = "-=", .kind = .minus_eq },
    .{ .text = "*=", .kind = .star_eq },
    .{ .text = "/=", .kind = .fslash_eq },
    .{ .text = "/=", .kind = .fslash_eq },
    .{ .text = "%=", .kind = .percent_eq },
    .{ .text = "++", .kind = .plus2 },
    .{ .text = "--", .kind = .minus2 },
    .{ .text = "==", .kind = .eq2 },
    .{ .text = "!=", .kind = .bang_eq },
    .{ .text = ">=", .kind = .gt_eq },
    .{ .text = "<=", .kind = .lt_eq },
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
