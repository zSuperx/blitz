const std = @import("std");
const root = @import("root");
const llvm = @import("llvm");
const core = llvm.core;

const ast = root.ast;
const Sema = root.Sema;
const types = root.types;

const Symbol = Sema.Symbol;
const SymbolInfo = Sema.SymbolInfo;

const TypeSystem = types.TypeSystem;
const Type = types.Type;

const LLVMValueRef = llvm.types.LLVMValueRef;
const LLVMBasicBlockRef = llvm.types.LLVMBasicBlockRef;
const LLVMTypeRef = llvm.types.LLVMTypeRef;
const LLVMContextRef = llvm.types.LLVMContextRef;
const LLVMModuleRef = llvm.types.LLVMModuleRef;
const LLVMBuilderRef = llvm.types.LLVMBuilderRef;

const LLVMSymbolInfo = struct {
    value: LLVMValueRef = null,
    ty: LLVMTypeRef = null,
};

fn toLLVMType(gpa: std.mem.Allocator, ts: *TypeSystem, ty: Type) CodegenError!LLVMTypeRef {
    const ct = ts.getConcreteType(ty) orelse return error.UnknownType;
    switch (ct) {
        .function => |function| {
            const return_type = try toLLVMType(gpa, ts, function.returns);

            var arg_types = std.ArrayList(LLVMTypeRef).empty;
            defer arg_types.deinit(gpa);
            for (function.args) |arg| {
                const llvm_arg_type = try toLLVMType(gpa, ts, arg);
                try arg_types.append(gpa, llvm_arg_type);
            }

            const llvm_type = core.LLVMFunctionType(return_type, @ptrCast(arg_types.items.ptr), @intCast(arg_types.items.len), 0);
            return llvm_type;
        },
        .int => |int| {
            return core.LLVMIntType(@intCast(int.bits));
        },
        .pointer => |ptr| {
            const llvm_ptee = try toLLVMType(gpa, ts, ptr.points_to);
            const llvm_ptr = core.LLVMPointerType(llvm_ptee, 0);
            return llvm_ptr;
        },
        .bool => return core.LLVMInt1Type(),
        .void => return core.LLVMVoidType(),
        .type => return error.InvalidLLVMType,
    }
}

const CodegenError = error{
    OutOfMemory,
    InvalidLValue,
    SymbolWithoutValue,
    LLVMVerifyFailed,
    InvalidLLVMType,
    UnknownType,
};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    tsys: *TypeSystem,
    symbol_table: std.AutoHashMap(Symbol, SymbolInfo),
    values: std.AutoHashMap(Symbol, LLVMSymbolInfo),

    // LLVM stuff
    context: LLVMContextRef,
    module: LLVMModuleRef,
    builder: LLVMBuilderRef,

    current_function: Symbol = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        symbol_table: std.AutoHashMap(Symbol, SymbolInfo),
        type_system: *TypeSystem,
        name: []const u8,
    ) !Codegen {
        return .{
            .allocator = allocator,
            .symbol_table = symbol_table,
            .values = .init(allocator),
            .tsys = type_system,
            .context = core.LLVMContextCreate().?,
            .module = core.LLVMModuleCreateWithName(@ptrCast(name)).?,
            .builder = core.LLVMCreateBuilder().?,
        };
    }

    fn get_current_function_type(self: *Codegen) *const @FieldType(types.CTy, "function") {
        const ftype = self.symbol_table.getPtr(self.current_function).?.ty;
        return &self.tsys.getConcreteType(ftype).?.function;
    }

    //
    // L-Value Expression code generation
    //

    fn gen_expr_lvalue(self: *Codegen, expr: *ast.Expr) CodegenError!LLVMValueRef {
        switch (expr.kind) {
            .variable => return self.gen_variable_expr_lvalue(expr),
            .deref => return self.gen_deref_expr_lvalue(expr),
            .index => return self.gen_index_expr_lvalue(expr),
            else => return error.InvalidLValue,
        }
    }

    /// Generating a variable as an Lvalue is akin to just producing the
    /// address it lives at. It does not necessarily generate any code.
    fn gen_variable_expr_lvalue(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const variable = &expr.kind.variable;
        const info = self.values.getPtr(variable.symbol).?;
        return info.value;
    }

    /// Generating *x should evaluate x and return it so it can be used as an
    /// address.
    fn gen_deref_expr_lvalue(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const deref = expr.kind.deref;
        return self.gen_expr_rvalue(deref.target);
    }

    fn gen_index_expr_lvalue(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const index = expr.kind.index;
        const b = try self.gen_expr_rvalue(index.base);
        const i = try self.gen_expr_rvalue(index.index);
        var indices = [_]LLVMValueRef{i};
        const ty = try toLLVMType(self.allocator, self.tsys, expr.ty.?);
        return core.LLVMBuildGEP2(self.builder, ty, b, @ptrCast(&indices), 1, "");
    }

    //
    // R-Value Expression code generation
    //

    fn gen_expr_rvalue(self: *Codegen, expr: *ast.Expr) CodegenError!LLVMValueRef {
        return switch (expr.kind) {
            .number => self.gen_number_expr(expr),
            .bool => self.gen_bool_expr(expr),
            .binary => self.gen_binary_expr(expr),
            .unary => self.gen_unary_expr(expr),
            .call => self.gen_call_expr(expr),
            .variable => self.gen_variable_expr_rvalue(expr),
            .block => self.gen_block_expr(expr),
            .ifelse => self.gen_if_else_expr(expr),
            .logic => self.gen_logic_expr(expr),
            .cmp => self.gen_cmp_expr(expr),
            .return_ => self.gen_return_expr(expr),
            .addr_of => self.gen_addr_of_expr(expr),
            .deref => self.gen_deref_expr_rvalue(expr),
            .index => self.gen_index_expr_rvalue(expr),
        };
    }

    fn gen_index_expr_rvalue(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const index = expr.kind.index;
        const b = try self.gen_expr_rvalue(index.base);
        const i = try self.gen_expr_rvalue(index.index);
        var indices = [_]LLVMValueRef{i};
        const ty = try toLLVMType(self.allocator, self.tsys, expr.ty.?);
        const element_ptr = core.LLVMBuildGEP2(self.builder, ty, b, @ptrCast(&indices), 1, "");
        return core.LLVMBuildLoad2(self.builder, ty, element_ptr, "");
    }

    fn gen_deref_expr_rvalue(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const deref = expr.kind.deref;
        const inner = try self.gen_expr_rvalue(deref.target);
        const pointed_to_ty = try toLLVMType(self.allocator, self.tsys, expr.ty.?);
        return core.LLVMBuildLoad2(self.builder, pointed_to_ty, inner, "");
    }

    fn gen_addr_of_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const addr_of = expr.kind.addr_of;
        const inner = try self.gen_expr_lvalue(addr_of.target);
        std.debug.assert(addr_of.target.is_lvalue());
        return inner;
    }

    fn gen_return_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const return_ = &expr.kind.return_;
        const value = try self.gen_expr_rvalue(return_.value);
        _ = core.LLVMBuildRet(self.builder, value);
        return value;
    }

    fn gen_if_else_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const if_else = &expr.kind.ifelse;

        const fn_value = self.values.get(self.current_function).?.value;

        const then_block = core.LLVMAppendBasicBlock(fn_value, "then").?;
        const else_block = core.LLVMAppendBasicBlock(fn_value, "else").?;
        const merge_block = core.LLVMAppendBasicBlock(fn_value, "merge").?;

        const merge_type = try toLLVMType(self.allocator, self.tsys, expr.ty.?);
        const void_value = core.LLVMConstInt(merge_type, 0, 0);

        // COND

        const cond_value = try self.gen_expr_rvalue(if_else.cond);
        _ = core.LLVMBuildCondBr(self.builder, cond_value, then_block, else_block);

        var incoming_values = std.ArrayList(LLVMValueRef).empty;
        var incoming_blocks = std.ArrayList(?@TypeOf(then_block)).empty;

        // THEN

        core.LLVMPositionBuilderAtEnd(self.builder, then_block);
        const then_value = try self.gen_expr_rvalue(if_else.then);
        const new_then_block = core.LLVMGetInsertBlock(self.builder);

        // If the then branch is not terminated, jump to merge and add Phi edge
        if (core.LLVMGetBasicBlockTerminator(new_then_block) == null) {
            _ = core.LLVMBuildBr(self.builder, merge_block);
            if (!expr.is_stmt)
                try incoming_values.append(self.allocator, then_value);
            try incoming_blocks.append(self.allocator, new_then_block);
        }

        // ELSE

        core.LLVMPositionBuilderAtEnd(self.builder, else_block);

        // If the else branch exists, compile it and use its value. Otherwise
        // just evalutate the else to 0
        const else_value = if (if_else.else_) |else_|
            try self.gen_expr_rvalue(else_)
        else
            core.LLVMConstInt(merge_type, 0, 0);

        const new_else_block = core.LLVMGetInsertBlock(self.builder);

        // If the else branch is not terminated, jump to merge and add Phi edge
        if (core.LLVMGetBasicBlockTerminator(new_else_block) == null) {
            _ = core.LLVMBuildBr(self.builder, merge_block);
            if (!expr.is_stmt)
                try incoming_values.append(self.allocator, else_value);
            try incoming_blocks.append(self.allocator, new_else_block);
        }

        const count = incoming_blocks.items.len;

        core.LLVMPositionBuilderAtEnd(self.builder, merge_block);
        if (count == 0) {
            // If both branches terminate and neither reach the merge, mark the merge as unreachable
            _ = core.LLVMBuildUnreachable(self.builder);
            return void_value;
        } else {
            // Otherwise add whatever branches DO reach the merge as incoming edges to the phi
            const phi = core.LLVMBuildPhi(self.builder, merge_type, "ifelse").?;
            core.LLVMAddIncoming(
                phi,
                @ptrCast(incoming_values.items),
                @ptrCast(incoming_blocks.items),
                @intCast(count),
            );
            return phi;
        }
    }

    fn gen_call_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const call = &expr.kind.call;

        const callee_value = try self.gen_expr_lvalue(call.callee);

        var arg_values = std.ArrayList(LLVMValueRef).empty;

        for (call.args) |arg_expr| {
            const arg_value = try self.gen_expr_rvalue(arg_expr);
            try arg_values.append(self.allocator, arg_value);
        }

        const function_type = try toLLVMType(self.allocator, self.tsys, call.callee.ty.?);

        return core.LLVMBuildCall2(
            self.builder,
            function_type,
            callee_value,
            @ptrCast(arg_values.items),
            @intCast(arg_values.items.len),
            "",
        ).?;
    }

    fn gen_block_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const block = &expr.kind.block;
        for (block.stmts) |inner_stmt| {
            _ = try self.gen_stmt(inner_stmt);
        }
        if (block.tail) |tail| {
            return try self.gen_expr_rvalue(tail);
        } else {
            return core.LLVMConstInt(try toLLVMType(self.allocator, self.tsys, expr.ty.?), 0, 0);
        }
    }

    fn gen_variable_expr_rvalue(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const variable = &expr.kind.variable;
        const info = self.values.getPtr(variable.symbol).?;
        return core.LLVMBuildLoad2(self.builder, info.ty, info.value, "").?;
    }

    fn gen_bool_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const bool_val = expr.kind.bool;
        const ty = try toLLVMType(self.allocator, self.tsys, expr.ty.?);
        return core.LLVMConstInt(ty, if (bool_val) 1 else 0, 0).?;
    }

    fn gen_number_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const number = expr.kind.number;
        const ty = try toLLVMType(self.allocator, self.tsys, expr.ty.?);
        return core.LLVMConstInt(ty, @truncate(number), 0).?;
    }

    fn gen_unary_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const unary = &expr.kind.unary;

        const inner_value = try self.gen_expr_rvalue(unary.inner);

        switch (unary.op) {
            .negate => return core.LLVMBuildNeg(self.builder, inner_value, "").?,
            .not => return core.LLVMBuildNot(self.builder, inner_value, "").?,
        }
    }

    fn gen_cmp_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const cmp = &expr.kind.cmp;

        const left_value = try self.gen_expr_rvalue(cmp.left);
        const right_value = try self.gen_expr_rvalue(cmp.right);

        switch (cmp.op) {
            .lt => return core.LLVMBuildICmp(self.builder, .LLVMIntSLT, left_value, right_value, "").?,
            .le => return core.LLVMBuildICmp(self.builder, .LLVMIntSLE, left_value, right_value, "").?,
            .gt => return core.LLVMBuildICmp(self.builder, .LLVMIntSGT, left_value, right_value, "").?,
            .ge => return core.LLVMBuildICmp(self.builder, .LLVMIntSGE, left_value, right_value, "").?,
        }
    }

    fn gen_logic_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const logic = &expr.kind.logic;

        const left_value = try self.gen_expr_rvalue(logic.left);
        const right_value = try self.gen_expr_rvalue(logic.right);

        switch (logic.op) {
            .eq => return core.LLVMBuildICmp(self.builder, .LLVMIntEQ, left_value, right_value, "").?,
            .ne => return core.LLVMBuildICmp(self.builder, .LLVMIntNE, left_value, right_value, "").?,
        }
    }

    fn gen_binary_expr(self: *Codegen, expr: *ast.Expr) !LLVMValueRef {
        const binary = &expr.kind.binary;

        const left_value = try self.gen_expr_rvalue(binary.left);
        const right_value = try self.gen_expr_rvalue(binary.right);

        switch (binary.op) {
            .add => return core.LLVMBuildAdd(self.builder, left_value, right_value, "").?,
            .sub => return core.LLVMBuildSub(self.builder, left_value, right_value, "").?,
            .mul => return core.LLVMBuildMul(self.builder, left_value, right_value, "").?,
            .div => return core.LLVMBuildSDiv(self.builder, left_value, right_value, "").?,
            .mod => return core.LLVMBuildSRem(self.builder, left_value, right_value, "").?,
        }
    }

    //
    // Statement code generation
    //

    fn gen_stmt(self: *Codegen, stmt: *ast.Stmt) CodegenError!void {
        switch (stmt.kind) {
            .decl => try self.gen_decl_stmt(stmt),
            .assign => return self.gen_assign_stmt(stmt),
            .expr => try self.gen_expr_stmt(stmt),
        }
    }

    fn gen_assign_stmt(self: *Codegen, stmt: *ast.Stmt) !void {
        const assign = &stmt.kind.assign;

        const left_ptr = try self.gen_expr_lvalue(assign.left);
        const left_ty = try toLLVMType(self.allocator, self.tsys, assign.left.ty.?);
        const right = try self.gen_expr_rvalue(assign.right);

        switch (assign.op) {
            .assign => _ = core.LLVMBuildStore(self.builder, right, left_ptr),
            else => {
                const old_left_val = core.LLVMBuildLoad2(self.builder, left_ty, left_ptr, "");
                const new_left_val = switch (assign.op) {
                    .assign_add => core.LLVMBuildAdd(self.builder, old_left_val, right, ""),
                    .assign_sub => core.LLVMBuildSub(self.builder, old_left_val, right, ""),
                    .assign_mul => core.LLVMBuildMul(self.builder, old_left_val, right, ""),
                    .assign_div => core.LLVMBuildSDiv(self.builder, old_left_val, right, ""),
                    .assign_mod => core.LLVMBuildSRem(self.builder, old_left_val, right, ""),
                    .assign => unreachable,
                };
                _ = core.LLVMBuildStore(self.builder, new_left_val, left_ptr);
            },
        }
    }

    fn gen_expr_stmt(self: *Codegen, stmt: *ast.Stmt) !void {
        const expr = stmt.kind.expr;
        _ = try self.gen_expr_rvalue(expr);
    }

    fn gen_decl_stmt(self: *Codegen, stmt: *ast.Stmt) !void {
        const decl = &stmt.kind.decl;

        const ptr = try self.gen_var_decl(decl.decl);

        if (decl.init) |init_expr| {
            const init_value = try self.gen_expr_rvalue(init_expr);
            _ = core.LLVMBuildStore(self.builder, init_value, ptr);
        }
    }

    //
    // Top level code generation
    //

    fn gen_var_decl(self: *Codegen, decl: ast.VarDecl) !LLVMValueRef {
        const name = try std.fmt.allocPrintSentinel(self.allocator, "{f}", .{decl.variable}, 0);
        const info = self.symbol_table.getPtr(decl.variable.symbol).?;

        const ty = try toLLVMType(self.allocator, self.tsys, info.ty);

        const ptr_value = core.LLVMBuildAlloca(self.builder, ty, name);

        try self.values.putNoClobber(decl.variable.symbol, .{ .ty = ty, .value = ptr_value });
        return ptr_value;
    }

    fn gen_function(self: *Codegen, function: *ast.Function) !void {
        self.current_function = function.name.symbol;
        const function_value = self.values.getPtr(function.name.symbol).?.value;

        // Create entrypoint and position builder at the end of it
        const entrypoint = core.LLVMAppendBasicBlock(function_value, "entrypoint").?;
        core.LLVMPositionBuilderAtEnd(self.builder, entrypoint);

        // Add value bindings for each argument
        for (function.arguments, 0..) |arg, i| {
            // Move each argument onto the stack and use the alloca pointer as the symbol'sLLVMValueRef.
            const arg_ptr = try self.gen_var_decl(arg);
            const arg_value = core.LLVMGetParam(function_value, @intCast(i)).?;
            _ = core.LLVMBuildStore(self.builder, arg_value, arg_ptr);
        }

        const tail = try self.gen_expr_rvalue(function.body);
        const bb = core.LLVMGetInsertBlock(self.builder);
        if (core.LLVMGetBasicBlockTerminator(bb) == null) {
            if (self.get_current_function_type().returns == types.builtins.void_) {
                _ = core.LLVMBuildRetVoid(self.builder);
            } else {
                _ = core.LLVMBuildRet(self.builder, tail);
            }
        }
    }

    pub fn gen_program(self: *Codegen, program: *ast.Program) ![:0]const u8 {
        for (program.functions) |function| {
            const function_info = self.symbol_table.getPtr(function.name.symbol).?;
            const function_type = try toLLVMType(self.allocator, self.tsys, function_info.ty);

            const function_name = if (std.mem.eql(u8, function.name.text.lookup(), "main"))
                "main"
            else
                try std.fmt.allocPrintSentinel(self.allocator, "{f}", .{function.name}, 0);

            // Create the function and update the LLVM symbol table
            const function_value = core.LLVMAddFunction(self.module, function_name, function_type);
            try self.values.put(function.name.symbol, .{ .value = function_value, .ty = function_type });
        }

        for (program.functions) |function| {
            try self.gen_function(function);
        }

        var message: [*c]u8 = null;

        const status = llvm.analysis.LLVMVerifyModule(self.module, .LLVMReturnStatusAction, &message);
        if (status != 0) std.log.err("LLVM ERROR: {s}", .{message});

        const module_string = core.LLVMPrintModuleToString(self.module);
        return std.mem.span(module_string);
    }
};
