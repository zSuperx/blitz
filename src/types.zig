const std = @import("std");
const ast = @import("ast.zig");
const sema = @import("sema.zig");
const diag = @import("diag.zig");
const state = @import("state.zig");

// ====================================================
// Types

/// Builtin types that are implicitly defined in Blitz
pub const builtins = struct {
    pub var type_: Type = undefined;

    pub var u8_: Type = undefined;
    pub var u16_: Type = undefined;
    pub var u32_: Type = undefined;
    pub var u64_: Type = undefined;
    pub var usize_: Type = undefined;

    pub var i8_: Type = undefined;
    pub var i16_: Type = undefined;
    pub var i32_: Type = undefined;
    pub var i64_: Type = undefined;
    pub var isize_: Type = undefined;

    pub var bool_: Type = undefined;
    pub var void_: Type = undefined;

    const Spec = struct {
        text: []const u8,
        concrete: CTy,
        handle: *Type,
    };

    pub fn init(s: *sema.Sema) !void {
        // Register this first if other builtin types need it.
        type_ = try s.tsys.add_concrete(.type);

        const specs = [_]Spec{
            .{ .concrete = .bool, .text = "bool", .handle = &bool_ },
            .{ .concrete = .void, .text = "void", .handle = &void_ },

            .{ .text = "u8", .handle = &u8_, .concrete = .{
                .int = .{
                    .bits = 8,
                    .signed = false,
                },
            } },
            .{ .text = "u16", .handle = &u16_, .concrete = .{
                .int = .{
                    .bits = 16,
                    .signed = false,
                },
            } },
            .{ .text = "u32", .handle = &u32_, .concrete = .{
                .int = .{
                    .bits = 32,
                    .signed = false,
                },
            } },
            .{ .text = "u64", .handle = &u64_, .concrete = .{
                .int = .{
                    .bits = 64,
                    .signed = false,
                },
            } },
            .{ .text = "usize", .handle = &usize_, .concrete = .{
                .int = .{
                    .bits = 64,
                    .signed = false,
                    .system = true,
                },
            } },

            .{ .text = "i8", .handle = &i8_, .concrete = .{
                .int = .{
                    .bits = 8,
                    .signed = true,
                },
            } },
            .{ .text = "i16", .handle = &i16_, .concrete = .{
                .int = .{
                    .bits = 16,
                    .signed = true,
                },
            } },
            .{ .text = "i32", .handle = &i32_, .concrete = .{
                .int = .{
                    .bits = 32,
                    .signed = true,
                },
            } },
            .{ .text = "i64", .handle = &i64_, .concrete = .{
                .int = .{
                    .bits = 64,
                    .signed = true,
                },
            } },
            .{ .text = "isize", .handle = &isize_, .concrete = .{
                .int = .{
                    .bits = 64,
                    .signed = true,
                    .system = true,
                },
            } },
        };

        for (specs) |spec| {
            spec.handle.* = try s.add_type_binding(
                try s.string_pool.add(spec.text),
                spec.concrete,
            );
        }
    }
};

/// A concrete type
pub const CTy = union(enum) {
    void,
    type,
    bool,
    function: Function,
    pointer: Pointer,
    int: Integer,

    const Function = struct {
        args: []const Type,
        returns: Type,
    };

    const Integer = struct {
        signed: bool,
        system: bool = false,
        bits: u16,

        fn bytes(self: Integer) usize {
            return self.bits / 8;
        }
    };

    const Pointer = struct {
        points_to: Type,
    };
};

/// The ID of a type
pub const Type = enum(usize) {
    _,

    fn as_index(self: Type) usize {
        return @intFromEnum(self);
    }

    fn from_index(i: usize) Type {
        return @enumFromInt(i);
    }
};

pub const Constraint = union(enum) {
    equal: []const Type,
    numeric: Type,
    pointer: Type,
    binary: BinOpConstraint,

    pub const BinOpConstraint = struct {
        op: ast.BinOp,
        lhs: Type,
        rhs: Type,
        out: Type,
    };
};

/// An unknown type
pub const UTy = struct {
    parent: Type,
    properties: Properties,

    pub const Properties = std.EnumSet(Property);

    pub const Property = enum(u8) {
        numeric,
        pointer,
    };
};

/// DSU information for a type
pub const TypeEntry = struct {
    id: Type,
    kind: union(enum) {
        concrete: CTy,
        unknown: UTy,
    },
    size: usize = 1,
};

const TypeError = error{
    Fatal,
};

/// Context used for hashing `CTy`s.
pub const TypeContext = struct {
    const Wyhash = std.hash.Wyhash;
    pub fn hash(ctx: @This(), key: CTy) u64 {
        _ = ctx;
        var hasher = Wyhash.init(0);
        switch (key) {
            .function => |function| {
                hasher.update(std.mem.asBytes(&function.returns));
                for (function.args) |arg| hasher.update(std.mem.asBytes(&arg));
            },
            else => {
                hasher.update(std.mem.asBytes(&key));
            },
        }
        return hasher.final();
    }

    pub fn eql(self: @This(), a: CTy, b: CTy) bool {
        _ = self;

        return std.meta.eql(a, b);
    }
};

pub const TypeSystem = struct {
    allocator: std.mem.Allocator,
    concrete_map: std.HashMap(CTy, Type, TypeContext, 80),
    constraints: std.ArrayList(Constraint),
    types: std.ArrayList(TypeEntry),

    pub fn init(allocator: std.mem.Allocator) TypeSystem {
        return .{
            .allocator = allocator,
            .concrete_map = .init(allocator),
            .constraints = .empty,
            .types = .empty,
        };
    }

    pub fn get_entry(self: *TypeSystem, id: Type) *TypeEntry {
        return &self.types.items[id.as_index()];
    }

    pub fn get_concrete(
        self: *TypeSystem,
        ty: Type,
    ) ?CTy {
        const entry = self.get_entry(self.find_parent(ty));
        switch (entry.kind) {
            .unknown => return null,
            .concrete => |c| {
                return c;
            },
        }
    }

    fn downcastCT(
        self: *TypeSystem,
        ty: Type,
        comptime tag: std.meta.Tag(CTy),
    ) ?@FieldType(CTy, @tagName(tag)) {
        const entry = self.get_entry(self.find_parent(ty));
        switch (entry.kind) {
            .unknown => return null,
            .concrete => |c| {
                if (c != tag) return null;
                return @field(c, @tagName(tag));
            },
        }
    }

    pub fn add_concrete(self: *TypeSystem, ct: CTy) !Type {
        const entry = try self.concrete_map.getOrPut(ct);
        if (entry.found_existing) {
            return entry.value_ptr.*;
        }

        const id: Type = .from_index(self.types.items.len);
        try self.types.append(self.allocator, .{
            .id = id,
            .kind = .{ .concrete = ct },
        });

        entry.value_ptr.* = id;

        return id;
    }

    pub fn create_constraint(self: *TypeSystem, cst: Constraint) !usize {
        const id = self.constraints.items.len;
        try self.constraints.append(self.allocator, cst);
        return id;
    }

    pub fn solve_constraints(self: *TypeSystem) !void {
        var changed = true;

        while (changed) {
            changed = false;
            for (self.types.items) |ty| {
                _ = self.find_parent(ty.id);
            }

            for (self.constraints.items) |cst| {
                changed |= try self.solve_constraint(cst);
            }
        }
    }

    fn satisfiesNumeric(self: *TypeSystem, ty: Type) enum { yes, no, idk } {
        switch (self.get_entry(ty).kind) {
            .unknown => |ut| {
                return if (ut.properties.contains(.numeric)) .yes else .idk;
            },
            .concrete => |ct| return if (ct == .int) .yes else .no,
        }
    }

    fn satisfiesPointer(self: *TypeSystem, ty: Type) enum { yes, no, idk } {
        switch (self.get_entry(ty).kind) {
            .unknown => return .idk,
            .concrete => |ct| return if (ct == .pointer) .yes else .no,
        }
    }

    fn solve_constraint(self: *TypeSystem, cst: Constraint) !bool {
        switch (cst.kind) {
            .binary => |b| {
                return self.solve_binary_constraint(b);
            },
            .numeric => {},
            .pointer => {},
        }
        return false;
    }

    fn solve_binary_constraint(self: *TypeSystem, cst: Constraint.BinOpConstraint) !bool {
        var changed = false;
        changed = changed;
        switch (cst.op) {
            .add => {
                if (self.satisfiesNumeric(cst.lhs) == .yes or
                    self.satisfiesNumeric(cst.rhs) == .yes or
                    self.satisfiesNumeric(cst.out) == .yes)
                {
                    changed |= try self.unify(cst.lhs, cst.rhs);
                    changed |= try self.unify(cst.lhs, cst.out);
                }
            },
            .sub => {}, // TODO
            .mul => {},
            .div => {},
            .mod => {},
        }
        return changed;
    }

    pub fn add_unknown(self: *TypeSystem, properties: UTy.Properties) !Type {
        const id: Type = .from_index(self.types.items.len);
        try self.types.append(self.allocator, .{
            .id = id,
            .kind = .{
                .unknown = .{
                    .parent = id,
                    .properties = properties,
                },
            },
        });

        // Set the new unknown type's parent to itself
        const u = &self.types.items[id.as_index()];
        u.id = id;
        u.kind.unknown.parent = id;

        return id;
    }

    pub fn find_parent(self: *TypeSystem, ty: Type) Type {
        const index = ty.as_index();

        switch (self.types.items[index].kind) {
            .concrete => return ty,
            .unknown => |*u| {
                if (u.parent == ty) return ty;
                const grandparent = self.find_parent(u.parent);
                // if (u.parent.index != grandparent.index)
                //     std.debug.print(
                //         "Compressing path {f} -> {f} -> {f} to {f} -> {f}\n",
                //         .{
                //             self.fmtType(ty),
                //             self.fmtType(u.parent),
                //             self.fmtType(grandparent),
                //             self.fmtType(ty),
                //             self.fmtType(grandparent),
                //         },
                //     );
                u.parent = grandparent;
                return u.parent;
            },
        }
    }

    fn unify_concrete_types(self: *TypeSystem, a: CTy, b: CTy) TypeError!bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
            return error.Fatal;
        }

        var changed = false;
        switch (a) {
            .pointer => {
                changed |= try self.unify(a.pointer.points_to, b.pointer.points_to);
            },
            .function => |af| {
                const bf = b.function;
                changed |= try self.unify(af.returns, bf.returns);
                if (af.args.len != bf.args.len) {
                    return error.Fatal;
                }

                for (af.args, bf.args) |aarg, barg| {
                    changed |= try self.unify(aarg, barg);
                }
            },
            .int,
            .void,
            .type,
            .bool,
            => {
                if (!std.meta.eql(a, b)) return error.Fatal;
            },
        }
        return changed;
    }

    pub fn constrain(self: *TypeSystem, cst: Constraint) TypeError!void {
        switch (cst) {
            .equal => |c| {
                const t0 = c[0];
                for (c) |t| {
                    _ = try self.unify(t0, t);
                }
            },
            .numeric => |t| {
                if (self.satisfiesNumeric(t) == .no) return error.Fatal;
                const entry = self.get_entry(t);
                if (entry.kind == .unknown) {
                    entry.kind.unknown.properties.insert(.numeric);
                }
            },
            .binary => |c| {
                if (self.satisfiesNumeric(c.lhs) == .no or
                    self.satisfiesNumeric(c.rhs) == .no or
                    self.satisfiesNumeric(c.out) == .no) return error.Fatal;

                try self.constrain(.{ .numeric = c.lhs });
                try self.constrain(.{ .numeric = c.rhs });
                try self.constrain(.{ .numeric = c.out });

                try self.constrain(.{ .equal = &.{
                    c.lhs,
                    c.rhs,
                    c.out,
                } });
            },
            else => {},
        }
    }

    /// Returns whether unification changed something
    pub fn unify(self: *TypeSystem, a: ?Type, b: ?Type) TypeError!bool {
        if (a == null or b == null) return false;

        // Rules for unification:
        // 1. Concrete types cannot unify if they are different
        // 2. Merge unknowns into concretes
        // 3. Merge smaller unknowns into larger unknowns (union-find by rank)
        //      - Constraints are absorbed into the larger unknown
        //
        // After walking the AST and unifying expression types, we will attempt
        // to solve all constraints.

        const setA = self.find_parent(a.?);
        const setB = self.find_parent(b.?);

        if (setA == setB) return false;

        const entryA = self.get_entry(setA);
        const entryB = self.get_entry(setB);

        // =================================
        // CASE 1: Concrete & Concrete

        if (entryA.kind == .concrete and entryB.kind == .concrete) {
            return self.unify_concrete_types(entryA.kind.concrete, entryB.kind.concrete);
        }

        // we will merge other into parent
        var parent: Type = undefined;
        var other: Type = undefined;

        // =================================
        // CASE 2: Unknown & Unknown

        if (entryA.kind == .unknown and entryB.kind == .unknown) {
            // canonicalize parent to be the larger set
            parent = if (entryA.size > entryB.size) setA else setB;
            other = if (entryA.size <= entryB.size) setA else setB;

            const parentEntry = self.get_entry(parent);
            const otherEntry = self.get_entry(other);

            otherEntry.kind.unknown.parent = parent;
            parentEntry.size += otherEntry.size;
        } else {
            // =================================
            // CASE 3: Concrete & Unknown

            // canonicalize parent to be concrete
            if (entryA.kind == .concrete) {
                parent = setA;
                other = setB;
            } else if (entryB.kind == .concrete) {
                parent = setB;
                other = setA;
            }

            // other is guaranteed to be unknown, parent can be either unknown or concrete
            const parentEntry = self.get_entry(parent);
            const otherEntry = self.get_entry(other);

            otherEntry.kind.unknown.parent = parent;
            parentEntry.size += otherEntry.size;
        }
        return true;
    }

    pub fn print(self: *TypeSystem) void {
        std.debug.print("TYPES:\n", .{});
        for (self.types.items, 0..) |ty, i| {
            std.debug.print("?{d} = {f}\n", .{ i, self.fmtType(ty.id) });
        }

        std.debug.print("CONSTRAINTS:\n", .{});
        for (self.constraints.items) |cst| {
            std.debug.print("{f}\n", .{self.fmtCst(cst)});
        }
    }

    // ==============================
    // PRINTING HELPER FUNCTIONS

    const TyFmt = struct {
        ts: *TypeSystem,
        type: Type,

        pub fn format(
            self: TyFmt,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            const entry = self.ts.get_entry(self.type);
            switch (entry.kind) {
                .concrete => |concrete| {
                    switch (concrete) {
                        .pointer => |ptr| {
                            try writer.print("*{f}", .{self.ts.fmtType(ptr.points_to)});
                        },
                        .function => |function| {
                            try writer.print("fn(", .{});
                            for (function.args, 0..) |arg, i| {
                                try writer.print("{f}", .{self.ts.fmtType(arg)});
                                if (i + 1 < function.args.len) {
                                    try writer.print(", ", .{});
                                }
                            }
                            try writer.print("){f}", .{self.ts.fmtType(function.returns)});
                        },
                        .int => |i| {
                            try writer.print("{s}", .{if (i.signed) "i" else "u"});
                            if (i.system) {
                                try writer.writeAll("size");
                            } else {
                                try writer.print("{d}", .{i.bits});
                            }
                        },
                        else => try writer.print("{s}", .{@tagName(concrete)}),
                    }
                },
                .unknown => {
                    const parent = self.ts.find_parent(entry.id);
                    if (parent != entry.id) {
                        try writer.print("(?{d} -> {f})", .{ entry.id.as_index(), self.ts.fmtType(parent) });
                    } else {
                        try writer.print("?{d}", .{entry.id.as_index()});
                    }
                },
            }
        }
    };

    pub fn fmtType(self: *TypeSystem, ty: Type) TyFmt {
        return .{ .ts = self, .type = ty };
    }

    const ConstraintFmt = struct {
        cst: Constraint,
        ts: *TypeSystem,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            switch (self.cst) {
                .numeric => |t| try writer.print("{f} must be numeric", .{self.ts.fmtType(t)}),
                .pointer => |t| try writer.print("{f} must be a pointer", .{self.ts.fmtType(t)}),
                .binary => |bin| {
                    try writer.print(
                        "binary: {f} {f} {f} = {f}",
                        .{
                            self.ts.fmtType(bin.lhs),
                            bin.op,
                            self.ts.fmtType(bin.rhs),
                            self.ts.fmtType(bin.out),
                        },
                    );
                },
                .equal => |ts| {
                    for (ts, 1..) |t, i| {
                        try writer.print(
                            "{f}",
                            .{self.ts.fmtType(t)},
                        );
                        if (i < ts.len) try writer.writeAll(" = ");
                    }
                },
            }
        }
    };

    pub fn fmtCst(self: *TypeSystem, cst: Constraint) ConstraintFmt {
        return .{ .cst = cst, .ts = self };
    }
};
