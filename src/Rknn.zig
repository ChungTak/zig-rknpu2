const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const std_mem = std.mem;
const Allocator = std_mem.Allocator;

/// RKNN上下文
pub const Rknn = struct {
    /// C API上下文
    ctx: c.rknn_context,
    /// 内存分配器
    allocator: Allocator,
    /// 是否已初始化
    initialized: bool,

    /// 初始化选项
    pub const InitOptions = struct {
        /// 初始化标志
        flag: u32 = c.RKNN_FLAG_PRIOR_HIGH,
        /// 扩展选项
        extend: ?*c.rknn_init_extend = null,
        /// 是否忽略平台不匹配错误
        ignore_platform_mismatch: bool = false,
    };

    /// 创建RKNN上下文
    pub fn init(allocator: Allocator, model_data: []const u8, options: InitOptions) errors.RknnError!Rknn {
        var ctx: c.rknn_context = undefined;
        const flag = options.flag;

        const ret = c.rknn_init(&ctx, @constCast(model_data.ptr), @intCast(model_data.len), flag, options.extend);

        // 如果设置了忽略平台不匹配，并且错误是平台不匹配，则尝试使用不同的标志重新初始化
        if (options.ignore_platform_mismatch and ret == c.RKNN_ERR_TARGET_PLATFORM_UNMATCH) {
            std.debug.print("警告：目标平台不匹配，尝试使用不同的标志重新初始化...\n", .{});

            // 尝试使用不同的优先级标志
            const flags_to_try = [_]u32{
                c.RKNN_FLAG_PRIOR_MEDIUM,
                c.RKNN_FLAG_PRIOR_LOW,
                c.RKNN_FLAG_PRIOR_HIGH | c.RKNN_FLAG_COLLECT_PERF_MASK,
            };

            for (flags_to_try) |try_flag| {
                const retry_ret = c.rknn_init(&ctx, @constCast(model_data.ptr), @intCast(model_data.len), try_flag, options.extend);
                if (retry_ret == c.RKNN_SUCC) {
                    std.debug.print("成功使用标志 0x{x} 初始化模型\n", .{try_flag});
                    return Rknn{
                        .ctx = ctx,
                        .allocator = allocator,
                        .initialized = true,
                    };
                }
            }

            // 如果所有尝试都失败，返回原始错误
            try errors.mapRknnError(ret);
        } else {
            try errors.mapRknnError(ret);
        }

        return Rknn{
            .ctx = ctx,
            .allocator = allocator,
            .initialized = true,
        };
    }

    /// 从文件创建RKNN上下文
    pub fn initFromFile(allocator: Allocator, model_path: []const u8, options: InitOptions) errors.RknnError!Rknn {
        // 打开文件
        const file = std.fs.cwd().openFile(model_path, .{}) catch |err| {
            std.debug.print("无法打开模型文件: {s}\n", .{@errorName(err)});
            return errors.RknnError.ModelInvalid;
        };
        defer file.close();

        // 获取文件大小
        const file_size = file.getEndPos() catch |err| {
            std.debug.print("无法获取文件大小: {s}\n", .{@errorName(err)});
            return errors.RknnError.ModelInvalid;
        };

        // 分配内存
        const model_data = allocator.alloc(u8, file_size) catch |err| {
            std.debug.print("内存分配失败: {s}\n", .{@errorName(err)});
            return errors.RknnError.MallocFail;
        };
        defer allocator.free(model_data);

        // 读取文件内容
        _ = file.readAll(model_data) catch |err| {
            std.debug.print("读取文件失败: {s}\n", .{@errorName(err)});
            return errors.RknnError.ModelInvalid;
        };

        // 初始化RKNN
        return try init(allocator, model_data, options);
    }

    /// 复制RKNN上下文
    pub fn dup(self: *Rknn) errors.RknnError!Rknn {
        var new_ctx: c.rknn_context = undefined;
        const ret = c.rknn_dup_context(self.ctx, &new_ctx);
        try errors.mapRknnError(ret);

        return Rknn{
            .ctx = new_ctx,
            .allocator = self.allocator,
            .initialized = true,
        };
    }

    /// 销毁RKNN上下文
    pub fn deinit(self: *Rknn) errors.RknnError!void {
        if (self.initialized) {
            const ret = c.rknn_destroy(self.ctx);
            try errors.mapRknnError(ret);
            self.initialized = false;
        }
    }

    /// 查询输入输出数量
    pub fn queryInOutNum(self: *Rknn) errors.RknnError!c.rknn_input_output_num {
        var io_num: c.rknn_input_output_num = undefined;
        const ret = c.rknn_query(self.ctx, c.RKNN_QUERY_IN_OUT_NUM, &io_num, @sizeOf(c.rknn_input_output_num));
        try errors.mapRknnError(ret);
        return io_num;
    }

    /// 查询输入属性
    pub fn queryInputAttr(self: *Rknn, index: u32) errors.RknnError!c.rknn_tensor_attr {
        var attr: c.rknn_tensor_attr = undefined;
        attr.index = index;
        const ret = c.rknn_query(self.ctx, c.RKNN_QUERY_INPUT_ATTR, &attr, @sizeOf(c.rknn_tensor_attr));
        try errors.mapRknnError(ret);
        return attr;
    }

    /// 查询输出属性
    pub fn queryOutputAttr(self: *Rknn, index: u32) errors.RknnError!c.rknn_tensor_attr {
        var attr: c.rknn_tensor_attr = undefined;
        attr.index = index;
        const ret = c.rknn_query(self.ctx, c.RKNN_QUERY_OUTPUT_ATTR, &attr, @sizeOf(c.rknn_tensor_attr));
        try errors.mapRknnError(ret);
        return attr;
    }

    /// 查询SDK版本
    pub fn querySdkVersion(self: *Rknn) errors.RknnError!c.rknn_sdk_version {
        var version: c.rknn_sdk_version = undefined;
        const ret = c.rknn_query(self.ctx, c.RKNN_QUERY_SDK_VERSION, &version, @sizeOf(c.rknn_sdk_version));
        try errors.mapRknnError(ret);
        return version;
    }

    /// 查询内存大小
    pub fn queryMemSize(self: *Rknn) errors.RknnError!c.rknn_mem_size {
        var mem_size: c.rknn_mem_size = undefined;
        const ret = c.rknn_query(self.ctx, c.RKNN_QUERY_MEM_SIZE, &mem_size, @sizeOf(c.rknn_mem_size));
        try errors.mapRknnError(ret);
        return mem_size;
    }

    /// 设置输入
    pub fn setInputs(self: *Rknn, inputs: []c.rknn_input) errors.RknnError!void {
        const ret = c.rknn_inputs_set(self.ctx, @intCast(inputs.len), inputs.ptr);
        try errors.mapRknnError(ret);
    }

    /// 设置批处理核心数量
    pub fn setBatchCoreNum(self: *Rknn, core_num: i32) errors.RknnError!void {
        const ret = c.rknn_set_batch_core_num(self.ctx, core_num);
        try errors.mapRknnError(ret);
    }

    /// 设置核心掩码
    pub fn setCoreMask(self: *Rknn, core_mask: u32) errors.RknnError!void {
        // 检查是否为有效的核心掩码
        const valid_masks = [_]u32{
            c.RKNN_NPU_CORE_AUTO,
            c.RKNN_NPU_CORE_0,
            c.RKNN_NPU_CORE_1,
            c.RKNN_NPU_CORE_2,
            c.RKNN_NPU_CORE_0_1,
            c.RKNN_NPU_CORE_0_1_2,
            c.RKNN_NPU_CORE_ALL,
        };

        var is_valid = false;
        for (valid_masks) |mask| {
            if (mask == core_mask) {
                is_valid = true;
                break;
            }
        }

        if (!is_valid) {
            std.debug.print("警告：无效的核心掩码 0x{x}，使用默认值 AUTO\n", .{core_mask});
            const ret = c.rknn_set_core_mask(self.ctx, c.RKNN_NPU_CORE_AUTO);
            try errors.mapRknnError(ret);
            return;
        }

        const ret = c.rknn_set_core_mask(self.ctx, core_mask);
        try errors.mapRknnError(ret);
    }

    /// 运行推理
    pub fn run(self: *Rknn, extend: ?*c.rknn_run_extend) errors.RknnError!void {
        const ret = c.rknn_run(self.ctx, extend);
        try errors.mapRknnError(ret);
    }

    /// 等待推理完成
    pub fn wait(self: *Rknn, extend: ?*c.rknn_run_extend) errors.RknnError!void {
        const ret = c.rknn_wait(self.ctx, extend);
        try errors.mapRknnError(ret);
    }

    /// 获取输出
    pub fn getOutputs(self: *Rknn, outputs: []c.rknn_output, extend: ?*c.rknn_output_extend) errors.RknnError!void {
        const ret = c.rknn_outputs_get(self.ctx, @intCast(outputs.len), outputs.ptr, extend);
        try errors.mapRknnError(ret);
    }

    /// 释放输出
    pub fn releaseOutputs(self: *Rknn, outputs: []c.rknn_output) errors.RknnError!void {
        const ret = c.rknn_outputs_release(self.ctx, @intCast(outputs.len), outputs.ptr);
        try errors.mapRknnError(ret);
    }

    /// 创建内存
    pub fn createMem(self: *Rknn, size: u32) errors.RknnError!*c.rknn_tensor_mem {
        const tensor_mem = c.rknn_create_mem(self.ctx, size);
        if (tensor_mem == null) {
            return errors.RknnError.MallocFail;
        }
        return tensor_mem.?;
    }

    /// 创建内存（扩展版本）
    pub fn createMem2(self: *Rknn, size: u64, alloc_flags: u64) errors.RknnError!*c.rknn_tensor_mem {
        const tensor_mem = c.rknn_create_mem2(self.ctx, size, alloc_flags);
        if (tensor_mem == null) {
            return errors.RknnError.MallocFail;
        }
        return tensor_mem.?;
    }

    /// 销毁内存
    pub fn destroyMem(self: *Rknn, tensor_mem: *c.rknn_tensor_mem) errors.RknnError!void {
        const ret = c.rknn_destroy_mem(self.ctx, tensor_mem);
        try errors.mapRknnError(ret);
    }

    /// 设置权重内存
    pub fn setWeightMem(self: *Rknn, tensor_mem: *c.rknn_tensor_mem) errors.RknnError!void {
        const ret = c.rknn_set_weight_mem(self.ctx, tensor_mem);
        try errors.mapRknnError(ret);
    }

    /// 设置内部内存
    pub fn setInternalMem(self: *Rknn, tensor_mem: *c.rknn_tensor_mem) errors.RknnError!void {
        const ret = c.rknn_set_internal_mem(self.ctx, tensor_mem);
        try errors.mapRknnError(ret);
    }

    /// 设置IO内存
    pub fn setIoMem(self: *Rknn, tensor_mem: *c.rknn_tensor_mem, attr: *c.rknn_tensor_attr) errors.RknnError!void {
        const ret = c.rknn_set_io_mem(self.ctx, tensor_mem, attr);
        try errors.mapRknnError(ret);
    }

    /// 设置输入形状
    pub fn setInputShape(self: *Rknn, attr: *c.rknn_tensor_attr) errors.RknnError!void {
        const ret = c.rknn_set_input_shape(self.ctx, attr);
        try errors.mapRknnError(ret);
    }

    /// 设置多个输入形状
    pub fn setInputShapes(self: *Rknn, attrs: []c.rknn_tensor_attr) errors.RknnError!void {
        const ret = c.rknn_set_input_shapes(self.ctx, @intCast(attrs.len), attrs.ptr);
        try errors.mapRknnError(ret);
    }

    /// 同步内存
    pub fn memSync(self: *Rknn, tensor_mem: *c.rknn_tensor_mem, mode: c.rknn_mem_sync_mode) errors.RknnError!void {
        const ret = c.rknn_mem_sync(self.ctx, tensor_mem, mode);
        try errors.mapRknnError(ret);
    }

    /// 创建输入
    pub fn createInput(index: u32, data: []const u8, tensor_type: c_uint, fmt: c_uint) c.rknn_input {
        return c.rknn_input{
            .index = index,
            .buf = @constCast(data.ptr),
            .size = @intCast(data.len),
            .pass_through = 0,
            .type = tensor_type,
            .fmt = fmt,
        };
    }

    /// 创建输出
    pub fn createOutput(index: u32, want_float: bool, is_prealloc: bool, buf: ?*anyopaque, size: u32) c.rknn_output {
        return c.rknn_output{
            .index = index,
            .want_float = if (want_float) 1 else 0,
            .is_prealloc = if (is_prealloc) 1 else 0,
            .buf = buf,
            .size = size,
        };
    }

    /// 创建预分配输出
    pub fn createPreallocOutput(allocator: Allocator, index: u32, want_float: bool, size: u32) !c.rknn_output {
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);

        return c.rknn_output{
            .index = index,
            .want_float = if (want_float) 1 else 0,
            .is_prealloc = 1,
            .buf = buf.ptr,
            .size = @intCast(buf.len),
        };
    }

    /// 创建非预分配输出
    pub fn createNonPreallocOutput(index: u32, want_float: bool) c.rknn_output {
        return c.rknn_output{
            .index = index,
            .want_float = if (want_float) 1 else 0,
            .is_prealloc = 0,
            .buf = null,
            .size = 0,
        };
    }

    /// 运行推理并获取结果
    pub fn runAndGetOutputs(self: *Rknn, inputs: []c.rknn_input, outputs: []c.rknn_output) errors.RknnError!void {
        // 设置输入
        try self.setInputs(inputs);

        // 运行推理
        try self.run(null);

        // 获取输出
        try self.getOutputs(outputs, null);
    }

    /// 获取C字符串
    pub fn getCString(bytes: []const u8) []const u8 {
        const len = std_mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
        return bytes[0..len];
    }
};
