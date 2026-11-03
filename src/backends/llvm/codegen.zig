const std = @import("std");
const root = @import("root");
const llvm = @import("llvm");
const core = llvm.core;

const ast = root.ast;
const sema = root.sema;

const Symbol = sema.Symbol;
const BaseSymbolInfo = sema.SymbolInfo;

const LLVMValue = llvm.types.LLVMOpaqueValue;
const LLVMSymbolInfo = struct {
    base: BaseSymbolInfo,
    value: ?*LLVMValue = null,
    type_: ?*llvm.types.LLVMOpaqueType = null,
};

var llvm_i64: *llvm.types.LLVMOpaqueType = undefined;
var llvm_zero: *llvm.types.LLVMOpaqueValue = undefined;

const CodegenError = error{
    OutOfMemory,
    InvalidLValue,
    SymbolWithoutValue,
    LLVMVerifyFailed,
};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    symbol_table: std.AutoHashMap(Symbol, LLVMSymbolInfo),

    // LLVM stuff
    context: *llvm.types.LLVMOpaqueContext,
    module: *llvm.types.LLVMOpaqueModule,
    builder: *llvm.types.LLVMOpaqueBuilder,

    current_function: Symbol = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        symbol_table: std.AutoHashMap(Symbol, BaseSymbolInfo),
        name: []const u8,
    ) !Codegen {
        // init global constants
        llvm_i64 = core.LLVMInt64Type().?;
        llvm_zero = core.LLVMConstInt(llvm_i64, 0, 0).?;

        // Build LLVM-specific symbol table
        var llvm_symbol_table = std.AutoHashMap(Symbol, LLVMSymbolInfo).init(allocator);
        var iterator = symbol_table.iterator();
        while (iterator.next()) |entry| {
            try llvm_symbol_table.put(entry.key_ptr.*, .{ .base = entry.value_ptr.* });
        }

        return .{
            .allocator = allocator,
            .symbol_table = llvm_symbol_table,
            .context = core.LLVMContextCreate().?,
            .module = core.LLVMModuleCreateWithName(@ptrCast(name)).?,
            .builder = core.LLVMCreateBuilder().?,
        };
    }

    //
    // L-Value Expression code generation
    //

    fn gen_variable_expr_lvalue(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        const variable = &expr.kind.variable;
        const info = self.symbol_table.getEntry(variable.symbol.?).?;
        if (info.value_ptr.value) |value| {
            return value;
        } else {
            return error.SymbolWithoutValue;
        }
    }

    fn gen_expr_lvalue(self: *Codegen, expr: *ast.Expr) CodegenError!*LLVMValue {
        switch (expr.kind) {
            .variable => return self.gen_variable_expr_lvalue(expr),
            else => return error.InvalidLValue,
        }
    }

    //
    // R-Value Expression code generation
    //

    fn gen_expr_rvalue(self: *Codegen, expr: *ast.Expr) CodegenError!*LLVMValue {
        switch (expr.kind) {
            .number => return self.gen_number_expr(expr),
            .binary => return self.gen_binary_expr(expr),
            .unary => return self.gen_unary_expr(expr),
            .assign => return self.gen_assign_expr(expr),
            .call => return self.gen_call_expr(expr),
            .variable => return self.gen_variable_expr_rvalue(expr),
            .block => return self.gen_block_expr(expr),
            .ifelse => return self.gen_if_else_expr(expr),
            .logic => return self.gen_logic_expr(expr),
            .cmp => return self.gen_cmp_expr(expr),
        }
    }

    fn gen_if_else_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        const if_else = &expr.kind.ifelse;

        const fn_info = self.symbol_table.getEntry(self.current_function).?.value_ptr;

        const then_block = core.LLVMAppendBasicBlock(fn_info.value, "then").?;
        const else_block = core.LLVMAppendBasicBlock(fn_info.value, "else").?;
        const merge_block = core.LLVMAppendBasicBlock(fn_info.value, "merge").?;

        // COND

        const cond_value = try self.gen_expr_rvalue(if_else.cond);
        const cmp_value = core.LLVMBuildIsNotNull(self.builder, cond_value, "cond");
        _ = core.LLVMBuildCondBr(self.builder, cmp_value, then_block, else_block);

        var incoming_values = std.ArrayList(*LLVMValue).empty;
        var incoming_blocks = std.ArrayList(?@TypeOf(then_block)).empty;

        // THEN

        core.LLVMPositionBuilderAtEnd(self.builder, then_block);
        const then_value = try self.gen_expr_rvalue(if_else.then);
        const new_then_block = core.LLVMGetInsertBlock(self.builder);

        // If the else branch is not terminated, jump to merge and add Phi edge
        if (core.LLVMGetBasicBlockTerminator(new_then_block) == null) {
            _ = core.LLVMBuildBr(self.builder, merge_block);
            try incoming_values.append(self.allocator, then_value);
            try incoming_blocks.append(self.allocator, new_then_block);
        }

        // ELSE

        core.LLVMPositionBuilderAtEnd(self.builder, else_block);
        const else_value = try self.gen_expr_rvalue(if_else.else_);
        const new_else_block = core.LLVMGetInsertBlock(self.builder);

        // If the else branch is not terminated, jump to merge and add Phi edge
        if (core.LLVMGetBasicBlockTerminator(new_else_block) == null) {
            _ = core.LLVMBuildBr(self.builder, merge_block);
            try incoming_values.append(self.allocator, else_value);
            try incoming_blocks.append(self.allocator, new_else_block);
        }

        const count = incoming_blocks.items.len;

        core.LLVMPositionBuilderAtEnd(self.builder, merge_block);
        if (count == 0) {
            // If both branches terminate and neither reach the merge, mark the merge as unreachable
            _ = core.LLVMBuildUnreachable(self.builder);
            return llvm_zero;
        } else {
            // Otherwise add whatever branches DO reach the merge as incoming edges to the phi
            const phi = core.LLVMBuildPhi(self.builder, llvm_i64, "ifelse").?;
            core.LLVMAddIncoming(
                phi,
                @ptrCast(incoming_values.items),
                @ptrCast(incoming_blocks.items),
                @intCast(count),
            );
            return phi;
        }
    }

    fn gen_call_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        const call = &expr.kind.call;

        const callee_value = try self.gen_expr_lvalue(call.callee);

        var arg_values = std.ArrayList(?*LLVMValue).empty;

        var arg_types = std.ArrayList(*llvm.types.LLVMOpaqueType).empty;

        for (call.args) |arg_expr| {
            try arg_types.append(self.allocator, llvm_i64);
            const arg_value = try self.gen_expr_rvalue(arg_expr);
            try arg_values.append(self.allocator, arg_value);
        }

        const function_type = core.LLVMFunctionType(llvm_i64, @ptrCast(arg_types.items), @intCast(arg_types.items.len), 0);

        return core.LLVMBuildCall2(self.builder, function_type, callee_value, @ptrCast(arg_values.items), @intCast(arg_values.items.len), "").?;
    }

    fn gen_block_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        const block = &expr.kind.block;
        for (block.stmts) |inner_stmt| {
            _ = try self.gen_stmt(inner_stmt);
        }
        if (block.tail) |tail| {
            return try self.gen_expr_rvalue(tail);
        } else {
            return llvm_zero;
        }
    }

    fn gen_assign_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        const assign = &expr.kind.assign;

        const left = try self.gen_expr_lvalue(assign.left);
        const right = try self.gen_expr_rvalue(assign.right);

        _ = core.LLVMBuildStore(self.builder, right, left).?;

        return llvm_zero;
    }

    fn gen_variable_expr_rvalue(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        const variable = &expr.kind.variable;
        const info = self.symbol_table.getEntry(variable.symbol.?).?;
        if (info.value_ptr.value) |value| {
            return core.LLVMBuildLoad2(self.builder, llvm_i64, value, "").?;
        } else {
            return error.SymbolWithoutValue;
        }
    }

    fn gen_number_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        _ = self;
        const number = expr.kind.number;
        return core.LLVMConstInt(llvm_i64, @truncate(number), 0).?;
    }

    fn gen_unary_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        const unary = &expr.kind.unary;

        const inner_value = try self.gen_expr_rvalue(unary.inner);

        switch (unary.op) {
            .negate => return core.LLVMBuildNeg(self.builder, inner_value, "").?,
            .not => return core.LLVMBuildNot(self.builder, inner_value, "").?,
        }
    }

    fn gen_cmp_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
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

    fn gen_logic_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
        const logic = &expr.kind.logic;

        const left_value = try self.gen_expr_rvalue(logic.left);
        const right_value = try self.gen_expr_rvalue(logic.right);

        switch (logic.op) {
            .eq => return core.LLVMBuildICmp(self.builder, .LLVMIntEQ, left_value, right_value, "").?,
            .ne => return core.LLVMBuildICmp(self.builder, .LLVMIntNE, left_value, right_value, "").?,
        }
    }

    fn gen_binary_expr(self: *Codegen, expr: *ast.Expr) !*LLVMValue {
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
            .if_ => try self.gen_if_stmt(stmt),
            .decl => try self.gen_decl_stmt(stmt),
            .expr => try self.gen_expr_stmt(stmt),
            .return_ => try self.gen_return_stmt(stmt),
        }
    }

    fn gen_if_stmt(self: *Codegen, stmt: *ast.Stmt) !void {
        const if_ = &stmt.kind.if_;

        const fn_info = self.symbol_table.getEntry(self.current_function).?.value_ptr;

        const then_block = core.LLVMAppendBasicBlock(fn_info.value, "then").?;
        const else_block = core.LLVMAppendBasicBlock(fn_info.value, "else").?;
        const merge_block = core.LLVMAppendBasicBlock(fn_info.value, "merge").?;

        // COND

        const cond_value = try self.gen_expr_rvalue(if_.cond);
        const cmp_value = core.LLVMBuildIsNotNull(self.builder, cond_value, "cond");

        const condbr_target = if (if_.else_) |_| else_block else merge_block;
        _ = core.LLVMBuildCondBr(self.builder, cmp_value, then_block, condbr_target);

        // THEN

        core.LLVMPositionBuilderAtEnd(self.builder, then_block);
        _ = try self.gen_expr_rvalue(if_.then);
        const new_then_block = core.LLVMGetInsertBlock(self.builder);

        // If the else branch is not terminated, jump to merge
        if (core.LLVMGetBasicBlockTerminator(new_then_block) == null) {
            _ = core.LLVMBuildBr(self.builder, merge_block);
        }

        // ELSE

        if (if_.else_) |else_| {
            core.LLVMPositionBuilderAtEnd(self.builder, else_block);
            _ = try self.gen_expr_rvalue(else_);
            const new_else_block = core.LLVMGetInsertBlock(self.builder);

            // If the else branch is not terminated, jump to merge and add Phi edge
            if (core.LLVMGetBasicBlockTerminator(new_else_block) == null) {
                _ = core.LLVMBuildBr(self.builder, merge_block);
            }
        }


        core.LLVMPositionBuilderAtEnd(self.builder, merge_block);
    }

    fn gen_return_stmt(self: *Codegen, stmt: *ast.Stmt) !void {
        const return_ = &stmt.kind.return_;
        const value = try self.gen_expr_rvalue(return_.value);
        _ = core.LLVMBuildRet(self.builder, value);
    }

    fn gen_expr_stmt(self: *Codegen, stmt: *ast.Stmt) !void {
        const expr = &stmt.kind.expr;
        _ = try self.gen_expr_rvalue(expr.expr);
    }

    fn gen_decl_stmt(self: *Codegen, stmt: *ast.Stmt) !void {
        const decl = &stmt.kind.decl;

        const name = try std.fmt.allocPrintSentinel(self.allocator, "{f}", .{decl.variable}, 0);
        const ptr_value = core.LLVMBuildAlloca(self.builder, llvm_i64, name);
        self.symbol_table.getEntry(decl.variable.symbol.?).?.value_ptr.value = ptr_value;

        if (decl.init) |init_expr| {
            const init_value = try self.gen_expr_rvalue(init_expr);
            _ = core.LLVMBuildStore(self.builder, init_value, ptr_value);
        }
    }

    //
    // Top level code generation
    //

    fn gen_function(self: *Codegen, function: *ast.Function) !void {
        self.current_function = function.name.symbol.?;
        const function_value = self.symbol_table.getEntry(function.name.symbol.?).?.value_ptr.value;

        // Create entrypoint and position builder at the end of it
        const entrypoint = core.LLVMAppendBasicBlock(function_value, "entrypoint").?;
        core.LLVMPositionBuilderAtEnd(self.builder, entrypoint);

        // Add value bindings for each argument
        for (function.arguments, 0..) |arg, i| {
            // Move each argument onto the stack and use the alloca pointer as the symbol's LLVMValue.
            const arg_name = try std.fmt.allocPrintSentinel(self.allocator, "{f}", .{arg}, 0);
            const arg_ptr = core.LLVMBuildAlloca(self.builder, llvm_i64, arg_name).?;
            const arg_value = core.LLVMGetParam(function_value, @intCast(i)).?;

            _ = core.LLVMBuildStore(self.builder, arg_value, arg_ptr);

            self.symbol_table.getEntry(arg.symbol.?).?.value_ptr.value = arg_ptr;
        }

        const tail = try self.gen_expr_rvalue(function.body);
        const bb = core.LLVMGetInsertBlock(self.builder);
        if (core.LLVMGetBasicBlockTerminator(bb) == null) {
            _ = core.LLVMBuildRet(self.builder, tail);
        }

        _ = llvm.analysis.LLVMVerifyFunction(function_value, .LLVMPrintMessageAction);
    }

    pub fn gen_program(self: *Codegen, program: *ast.Program) ![:0]const u8 {
        for (program.functions) |function| {
            var arg_types = std.ArrayList(*llvm.types.LLVMOpaqueType).empty;
            for (function.arguments) |_| {
                try arg_types.append(self.allocator, llvm_i64);
            }
            const function_type = core.LLVMFunctionType(llvm_i64, @ptrCast(arg_types.items), @intCast(arg_types.items.len), 0);

            const function_name = if (std.mem.eql(u8, function.name.ident.lookup(), "main"))
                "main"
            else
                try std.fmt.allocPrintSentinel(self.allocator, "{f}", .{function.name}, 0);

            // Create the function and update the LLVM symbol table
            const function_value = core.LLVMAddFunction(self.module, function_name, function_type);
            self.symbol_table.getEntry(function.name.symbol.?).?.value_ptr.value = function_value;
        }

        for (program.functions) |function| {
            try self.gen_function(function);
        }

        const module_string = core.LLVMPrintModuleToString(self.module);
        return std.mem.span(module_string);
    }
};
