pub const std = @import("std");
pub const diag = @import("diag.zig");
pub const sp = @import("interner.zig");
pub const ast = @import("ast.zig");
pub const backends = @import("backends.zig");
pub const types = @import("types.zig");
pub const state = @import("state.zig");

pub const Lexer = @import("Lexer.zig");
pub const Parser = @import("Parser.zig");
pub const Sema = @import("Sema.zig");


pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

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

    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    state.source_files = .empty;
    defer state.source_files.deinit(alloc);
    const source_id = try state.add_source_file(alloc, try state.Source.init(alloc, cfg.ifile, bytes));

    state.diagnostics = .init(alloc);

    var the_lexer: Lexer = .init(alloc);
    const tokens = the_lexer.tokenize(source_id) catch |err| switch (err) {
        error.Diagnostic => undefined,
        else => return err,
    };

    state.diagnostics.print_all();
    if (state.diagnostics.errors > 0) die(
        "Could not compile program due to {d} errors",
        .{state.diagnostics.errors},
    );

    // Uncomment this to print all tokens
    // for (tokens) |tok| {
    //     ezio.println("{f}", .{tok});
    // }

    var string_pool: sp.StringPool = .init(alloc);
    var the_parser = Parser.init(alloc, &string_pool);
    const program = the_parser.parse_program(tokens) catch |err| switch (err) {
        error.Fatal => undefined,
        else => return err,
    };

    state.diagnostics.print_all();
    if (state.diagnostics.errors > 0) die(
        "Could not compile program due to {d} errors",
        .{state.diagnostics.errors},
    );

    var the_sema = try Sema.init(alloc, &string_pool);
    the_sema.sema_program(program) catch |err| switch (err) {
        error.Fatal => {},
        else => return err,
    };

    state.diagnostics.print_all();
    if (state.diagnostics.errors > 0) die(
        "Could not compile program due to {d} errors",
        .{state.diagnostics.errors},
    );

    // if (true) die("TODO: Codegen", .{});
    var codegen = try backends.llvm.Codegen.init(alloc, the_sema.symbol_table, &the_sema.tsys, cfg.ifile);
    const llvm_module_ir = try codegen.gen_program(program);
    // const llvm_module_ir = "TODO";

    switch (cfg.ofile) {
        .stdout => {
            try stdout.print("{s}", .{llvm_module_ir});
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
            if (result.term.exited == 0) {
                // try cwd.deleteFile(init.io, "tmp.ll");
            } else {
                std.log.err("Error calling `clang`:\n{s}\n", .{result.stderr});
            }
        },
    }

    if (state.diagnostics.warnings > 0) {
        std.log.warn("Generated {d} warnings\n", .{state.diagnostics.warnings});
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
