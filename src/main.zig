pub const std = @import("std");
pub const diag = @import("diag.zig");
pub const sp = @import("string-pool.zig");
pub const ezio = @import("ezio.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const sema = @import("sema.zig");
pub const backends = @import("backends.zig");
pub const llvm_bindings = @import("llvm");

const Lexer = lexer.Lexer;
const Parser = parser.Parser;
const Sema = sema.Sema;

pub fn main(init: std.process.Init) !void {
    ezio.initWriters(init.io);

    const cfg = try parse_args(init.minimal.args);

    const cwd = std.Io.Dir.cwd();

    const bytes = cwd.readFileAlloc(
        init.io,
        cfg.ifile,
        init.gpa,
        .unlimited,
    ) catch |err| {
        switch (err) {
            error.FileNotFound => die("File `{s}` not found", .{cfg.ifile}),
            else => return err,
        }
    };

    defer init.gpa.free(bytes);

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const source = try diag.Source.init(alloc, cfg.ifile, bytes);

    var the_lexer = Lexer.init(alloc);
    const tokens = the_lexer.tokenize(&source) catch |err| switch (err) {
        error.Diagnostic => undefined,
        else => return err,
    };

    try the_lexer.diagnostics.print_all();
    if (the_lexer.diagnostics.errors > 0) die("Could not compile program", .{});

    // Uncomment this to print all tokens
    // for (tokens) |tok| {
    //     ezio.println("{f}", .{tok});
    // }

    var string_pool = sp.StringPool.init(alloc);
    var the_parser = Parser.init(alloc, &string_pool);
    const program = the_parser.parse_program(tokens, &source) catch |err| switch (err) {
        error.Diagnostic => undefined,
        else => return err,
    };

    try the_parser.diagnostics.print_all();
    if (the_parser.diagnostics.errors > 0) die("Could not compile program", .{});

    var the_sema = try Sema.init(alloc);
    the_sema.sema_program(program, &source) catch |err| switch (err) {
        error.Diagnostic => {},
        else => return err,
    };

    try the_sema.diagnostics.print_all();
    if (the_sema.diagnostics.errors > 0) die("Could not compile program", .{});

    var codegen = try backends.llvm.Codegen.init(alloc, the_sema.symbol_table, cfg.ifile);
    const llvm_module_ir = try codegen.gen_program(program);

    switch (cfg.ofile) {
        .stdout => {
            ezio.println("{s}", .{llvm_module_ir});
            return;
        },
        .file => |file| {
            try cwd.writeFile(init.io, .{
                .sub_path = "tmp.ll",
                .data = llvm_module_ir,
            });
            const result = try std.process.run(alloc, init.io, .{
                .argv = &.{ "clang", "tmp.ll", "-O3", "-o", file },
            });
            _ = result;

            // try cwd.deleteFile(init.io, "tmp.ll");
        },
    }
}

const Config = struct {
    ifile: [:0]const u8,
    ofile: Output,

    const Output = union(enum) {
        stdout,
        file: [:0]const u8,
    };
};

fn parse_args(args: std.process.Args) !Config {
    var ifile: ?[:0]const u8 = null;
    var ofile: ?Config.Output = null;

    var iter = args.iterate();

    _ = iter.next();

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            if (ofile) |_| {
                die("More than one output file provided", .{});
            } else {
                const next = iter.next() orelse die("-o expects a value", .{});
                ofile = if (std.mem.eql(u8, next, "-"))
                    .stdout
                else
                    .{ .file = next };
            }
        } else {
            if (ifile) |_| {
                die("More than one input file provided", .{});
            } else {
                ifile = arg;
            }
        }
    }

    return Config{
        .ifile = ifile orelse die("No input file given", .{}),
        .ofile = ofile orelse .{
            .file = "a.out",
        },
    };
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
