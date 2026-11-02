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

    const bytes = try cwd.readFileAlloc(
        init.io,
        cfg.ifile,
        init.gpa,
        .unlimited,
    );
    defer init.gpa.free(bytes);

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const source = try diag.Source.init(alloc, cfg.ifile, bytes);

    var file_lexer = Lexer.init(alloc);
    const tokens = file_lexer.tokenize(&source) catch |err| switch (err) {
        error.Diagnostic => {
            try file_lexer.diagnostics.print_all();
            die("Could not parse file", .{});
        },
        else => return err,
    };

    // Uncomment this to print all tokens
    // for (tokens) |tok| {
    //     ezio.println("{f}", .{tok});
    // }

    var string_pool = sp.StringPool.init(alloc);
    var file_parser = Parser.init(alloc, &string_pool);
    const program = file_parser.parse_program(tokens, &source) catch |err| switch (err) {
        error.Diagnostic => {
            try file_parser.diagnostics.print_all();
            die("Could not parse file", .{});
        },
        else => return err,
    };

    var file_sema = try Sema.init(alloc);
    file_sema.sema_program(program, &source) catch |err| switch (err) {
        error.Diagnostic => {
            try file_sema.diagnostics.print_all();
            die("Could not compile program", .{});
        },
        else => return err,
    };

    var codegen = try backends.llvm.Codegen.init(alloc, file_sema.symbol_table, cfg.ifile);
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
            // if (result.stderr.len > 0) std.debug.print("{s}\n", .{result.stderr});
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
                ofile = .{ .file = iter.next() orelse die("-o expects a value", .{}) };
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
