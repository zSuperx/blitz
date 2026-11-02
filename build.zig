const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zb",
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const llvm_dep = b.dependency("llvm", .{ // <== as declared in build.zig.zon
        .target = target, // the same as passing `-Dtarget=<...>` to the library's build.zig script
        .optimize = optimize, // ditto for `-Doptimize=<...>`
    });

    const llvm_mod = llvm_dep.module("llvm"); // <== get llvm bindings module

    // your executable config
    exe.root_module.addImport("llvm", llvm_mod); // <== add llvm module
    // exe.root_module.addImport("clang", clang_mod); // <== add clang module

    b.installArtifact(exe);
}
