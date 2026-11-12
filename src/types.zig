const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const state = @import("state.zig");
const Sema = @import("Sema.zig");

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

    pub fn init(s: *Sema) !void {
        // Register this first if other builtin types need it.
        type_ = try s.tsys.createConcreteType(.type);

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

/// The ID of a type. This is small data and can be easily stored and copied
/// anywhere.
pub const Type = enum(usize) {
    _,

    /// Returns the backing integer.
    fn as_index(self: Type) usize {
        return @intFromEnum(self);
    }

    /// Creates a `Type` from a usize
    fn from_index(i: usize) Type {
        return @enumFromInt(i);
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

/// An unknown type
pub const UTy = struct {
    parent: Type,
    properties: Properties,

    pub const Properties = std.EnumSet(Property);

    pub const Property = enum(u8) {
        numeric,
        signed,
    };
};

pub const Constraint = union(enum) {
    equal: []const Type,
    numeric: Type,
    pointer: PointerConstraint,
    binary: BinaryConstraint,
    unary: UnaryConstraint,

    pub const PointerConstraint = struct {
        pointer: Type,
        points_to: Type,
    };

    pub const LogicalConstraint = struct {
        op: ast.LogicOp,
        lhs: Type,
        rhs: Type,
    };

    pub const UnaryConstraint = struct {
        op: ast.UnOp,
        in: Type,
        out: Type,
    };

    pub const BinaryConstraint = struct {
        op: ast.BinOp,
        lhs: Type,
        rhs: Type,
        out: Type,
    };
};

/// A `Type`'s entry in the Disjoint Set Union data structure.
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

    fn getTypeEntry(self: *TypeSystem, id: Type) *TypeEntry {
        return &self.types.items[id.as_index()];
    }

    /// Looks up `ty` in the type system and returns a `CTy` if the type
    /// resolves to a concrete type.
    pub fn getConcreteType(
        self: *TypeSystem,
        ty: Type,
    ) ?CTy {
        const entry = self.getTypeEntry(self.findParentType(ty));
        switch (entry.kind) {
            .unknown => return null,
            .concrete => |c| {
                return c;
            },
        }
    }

    /// Creates and potentially inserts a concrete type in the type system. If
    /// a type already exists, nothing is added. The `Type` index is returned,
    /// which can be used to retrieve the inserted `CTy`.
    pub fn createConcreteType(self: *TypeSystem, ct: CTy) !Type {
        const entry = self.concrete_map.getOrPut(ct) catch @panic("OOM");
        if (entry.found_existing) {
            return entry.value_ptr.*;
        }

        const id: Type = .from_index(self.types.items.len);
        self.types.append(self.allocator, .{
            .id = id,
            .kind = .{ .concrete = ct },
        }) catch @panic("OOM");

        entry.value_ptr.* = id;

        return id;
    }

    /// Creates a new unknown type with the given initial properties imposed
    /// upon it. As a `UTy` unifies with other unknown types, it collects
    /// properties.
    ///
    /// At the end of the type inference phase, the type checker will attempt
    /// to fit the `UTy` to any `CTy` it was unified with. If the `CTy` does
    /// not satisfy all properties, a type checking error is thrown.
    pub fn createUnknownType(self: *TypeSystem, properties: UTy.Properties) !Type {
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

    /// Returns whether a given `Type` satisfies the given property.
    fn satisfiesProperty(self: *TypeSystem, ty: Type, property: UTy.Property) bool {
        const parent = self.findParentType(ty);
        const entry = self.getTypeEntry(parent);
        switch (entry.kind) {
            .concrete => |c| {
                switch (property) {
                    .numeric => return c == .int,
                    .signed => return c == .int and c.int.signed,
                }
            },
            .unknown => |u| return u.properties.contains(property),
        }
    }

    /// Adds a property to a type. If the given type is a `CTy` that is known
    /// not to fit that property, an error is thrown. (e.g. `CTy.bool` with
    /// `UTy.Property.numeric` will result in an error)
    pub fn addProperty(self: *TypeSystem, ty: Type, property: UTy.Property) !void {
        const entry = self.getTypeEntry(ty);
        switch (entry.kind) {
            .concrete => {
                if (!self.satisfiesProperty(ty, property)) {
                    state.diagnostics.emitError("`{f}` does not satisfy the `{s}` property", .{
                        self.fmtType(ty),
                        @tagName(property),
                    });
                    return error.Fatal;
                }
            },
            .unknown => |*u| {
                u.properties.insert(property);
            },
        }
    }

    /// Create a constraint and add it to the type system. A constraint
    /// describes the relationships between types, and can result in type
    /// unifications.
    pub fn createConstraint(self: *TypeSystem, cst: Constraint) TypeError!void {
        switch (cst) {
            .equal => |c| {
                const t0 = c[0];
                for (c) |t| {
                    _ = try self.unify(t0, t);
                }
            },
            .numeric => |t| {
                try self.addProperty(t, .numeric);
            },
            .unary => |c| {
                switch (c.op) {
                    .negate => {
                        try self.addProperty(c.in, .numeric);
                        try self.addProperty(c.in, .signed);
                        try self.createConstraint(.{
                            .equal = &.{
                                c.in,
                                c.out,
                            },
                        });
                    },
                    .not => {
                        try self.createConstraint(.{
                            .equal = &.{
                                c.in,
                                c.out,
                                builtins.bool_,
                            },
                        });
                    },
                }
            },
            .binary => |c| {
                try self.addProperty(c.out, .numeric);

                try self.createConstraint(.{
                    .equal = &.{
                        c.lhs,
                        c.rhs,
                        c.out,
                    },
                });
            },
            .pointer => |c| {
                const ptr = try self.createConcreteType(.{
                    .pointer = .{ .points_to = c.points_to },
                });
                _ = try self.unify(ptr, c.pointer);
            },
        }
    }

    pub fn solveTypes(self: *TypeSystem) !void {
        for (0..self.types.items.len) |i| {
            const this = Type.from_index(i);
            const parent = self.findParentType(this);
            if (parent != this) {
                switch (self.getTypeEntry(parent).kind) {
                    .unknown => |u| {
                        if (u.properties.contains(.numeric)) {
                            if (u.properties.contains(.signed)) {
                                _ = try self.unify(parent, builtins.i32_);
                            } else {
                                _ = try self.unify(parent, builtins.u32_);
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Finds a type's parent in the DSU array. A type's parent is the type it
    /// resolves to. This function performs path compression.
    fn findParentType(self: *TypeSystem, ty: Type) Type {
        const entry = self.getTypeEntry(ty);
        switch (entry.kind) {
            .concrete => return ty,
            .unknown => |u| {
                if (u.parent == ty) return ty;
                const grandparent = self.findParentType(u.parent);

                entry.kind.unknown.parent = grandparent;
                return entry.kind.unknown.parent;
            },
        }
    }

    /// Attempts to unify two concrete types. To be unified, they must either
    /// be the same exact base type, or must unify all contained types.
    fn unifyConcreteTypes(self: *TypeSystem, a: CTy, b: CTy) TypeError!bool {
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

        const setA = self.findParentType(a.?);
        const setB = self.findParentType(b.?);

        if (setA == setB) return false;

        const entryA = self.getTypeEntry(setA);
        const entryB = self.getTypeEntry(setB);

        if (entryA.kind == .concrete and entryB.kind == .concrete) {
            // =================================
            // CASE 1: Concrete & Concrete

            return self.unifyConcreteTypes(entryA.kind.concrete, entryB.kind.concrete);
        } else if (entryA.kind == .unknown and entryB.kind == .unknown) {
            // =================================
            // CASE 2: Unknown & Unknown

            // canonicalize parent to be the larger set
            const parent = if (entryA.size > entryB.size) setA else setB;
            const other = if (entryA.size <= entryB.size) setA else setB;

            const parentEntry = self.getTypeEntry(parent);
            const otherEntry = self.getTypeEntry(other);

            otherEntry.kind.unknown.parent = parent;
            parentEntry.size += otherEntry.size;
            parentEntry.kind.unknown.properties.setUnion(otherEntry.kind.unknown.properties);
        } else {
            // =================================
            // CASE 3: Concrete & Unknown

            var concrete: Type = undefined;
            var unknown: Type = undefined;

            // canonicalize parent to be concrete
            if (entryA.kind == .concrete) {
                concrete = setA;
                unknown = setB;
            } else if (entryB.kind == .concrete) {
                concrete = setB;
                unknown = setA;
            }

            const concreteEntry = self.getTypeEntry(concrete);
            const unknownEntry = self.getTypeEntry(unknown);

            var properties = unknownEntry.kind.unknown.properties.iterator();
            while (properties.next()) |prop| {
                try self.addProperty(concrete, prop);
            }

            unknownEntry.kind.unknown.parent = concrete;
            concreteEntry.size += unknownEntry.size;
        }
        return true;
    }

    // ==============================
    // PRINTING HELPER FUNCTIONS

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

    const TyFmt = struct {
        ts: *TypeSystem,
        type: Type,

        pub fn format(
            self: TyFmt,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            const entry = self.ts.getTypeEntry(self.type);
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
                    const parent = self.ts.findParentType(entry.id);
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
                .pointer => |t| try writer.print("{f} must point to {f}", .{
                    self.ts.fmtType(t.pointer),
                    self.ts.fmtType(t.points_to),
                }),
                .unary => |un| {
                    try writer.print(
                        "{f} {f} = {f}",
                        .{
                            un.op,
                            self.ts.fmtType(un.in),
                            self.ts.fmtType(un.out),
                        },
                    );
                },
                .binary => |bin| {
                    try writer.print(
                        "{f} {f} {f} = {f}",
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
