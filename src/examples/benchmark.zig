const std = @import("std");
const rknpu2 = @import("zig-rknpu2");
const Rknn = rknpu2.Rknn;
const c = rknpu2.c;
const zstbi = @import("zstbi");

/// 获取当前时间（微秒）
fn getCurrentTimeUs() i64 {
    const now = std.time.microTimestamp();
    return now;
}

/// 获取Top N结果
fn getTopN(prob: []f32, max_prob: []f32, max_class: []u32, output_count: u32, top_num: u32) void {
    const top_count = if (output_count > top_num) top_num else output_count;

    // 初始化
    for (0..top_num) |i| {
        max_prob[i] = -std.math.floatMax(f32);
        max_class[i] = std.math.maxInt(u32);
    }

    // 查找top N
    for (0..top_count) |j| {
        for (0..output_count) |i| {
            // 检查是否已经在top N中
            var skip = false;
            for (0..5) |k| {
                if (i == max_class[k]) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;

            if (prob[i] > max_prob[j]) {
                max_prob[j] = prob[i];
                max_class[j] = @intCast(i);
            }
        }
    }
}

/// 打印张量属性
fn dumpTensorAttr(attr: *c.rknn_tensor_attr) void {
    var shape_str = std.ArrayList(u8).init(std.heap.page_allocator);
    defer shape_str.deinit();

    if (attr.n_dims >= 1) {
        shape_str.writer().print("{d}", .{attr.dims[0]}) catch {};
        for (1..attr.n_dims) |i| {
            shape_str.writer().print(", {d}", .{attr.dims[i]}) catch {};
        }
    }

    std.debug.print("  index={d}, name={s}, n_dims={d}, dims=[{s}], n_elems={d}, size={d}, w_stride={d}, size_with_stride={d}, fmt={s}, type={s}, qnt_type={s}, zp={d}, scale={d}\n", .{ attr.index, if (attr.name[0] != 0) attr.name[0 .. std.mem.indexOfScalar(u8, &attr.name, 0) orelse 64] else "", attr.n_dims, shape_str.items, attr.n_elems, attr.size, attr.w_stride, attr.size_with_stride, getFmtString(attr.fmt), getTypeString(attr.type), getQntTypeString(attr.qnt_type), attr.zp, attr.scale });
}

/// 获取格式字符串
fn getFmtString(fmt: c_uint) []const u8 {
    return switch (fmt) {
        c.RKNN_TENSOR_NCHW => "NCHW",
        c.RKNN_TENSOR_NHWC => "NHWC",
        c.RKNN_TENSOR_NC1HWC2 => "NC1HWC2",
        c.RKNN_TENSOR_UNDEFINED => "UNDEFINED",
        else => "UNKNOWN",
    };
}

/// 获取类型字符串
fn getTypeString(type_val: c_uint) []const u8 {
    return switch (type_val) {
        c.RKNN_TENSOR_FLOAT32 => "FP32", // c.RKNN_TENSOR_FLOAT32
        c.RKNN_TENSOR_FLOAT16 => "FP16", // c.RKNN_TENSOR_FLOAT16
        c.RKNN_TENSOR_INT8 => "INT8", // c.RKNN_TENSOR_INT8
        c.RKNN_TENSOR_UINT8 => "UINT8", // c.RKNN_TENSOR_UINT8
        c.RKNN_TENSOR_INT16 => "INT16", // c.RKNN_TENSOR_INT16
        c.RKNN_TENSOR_UINT16 => "UINT16", // c.RKNN_TENSOR_UINT16
        c.RKNN_TENSOR_INT32 => "INT32", // c.RKNN_TENSOR_INT32
        c.RKNN_TENSOR_UINT32 => "UINT32", // c.RKNN_TENSOR_UINT32
        else => "UNKNOWN",
    };
}

/// 获取量化类型字符串
fn getQntTypeString(qnt_type: c_uint) []const u8 {
    return switch (qnt_type) {
        c.RKNN_TENSOR_QNT_NONE => "NONE",
        c.RKNN_TENSOR_QNT_DFP => "DFP",
        c.RKNN_TENSOR_QNT_AFFINE_ASYMMETRIC => "AFFINE",
        else => "UNKNOWN",
    };
}

/// 加载图像
fn loadImage(allocator: std.mem.Allocator, image_path: []const u8, input_attr: *c.rknn_tensor_attr) ?[]u8 {
    var req_height: u32 = 0;
    var req_width: u32 = 0;
    var req_channel: u32 = 0;

    switch (input_attr.fmt) {
        c.RKNN_TENSOR_NHWC => {
            req_height = input_attr.dims[1];
            req_width = input_attr.dims[2];
            req_channel = input_attr.dims[3];
        },
        c.RKNN_TENSOR_NCHW => {
            req_height = input_attr.dims[2];
            req_width = input_attr.dims[3];
            req_channel = input_attr.dims[1];
        },
        else => {
            std.debug.print("不支持的布局格式\n", .{});
            return null;
        },
    }

    // 初始化zstbi
    zstbi.init(allocator);
    defer zstbi.deinit();

    // 加载图像
    std.debug.print("加载图像: {s}\n", .{image_path});
    // 将image_path转换为以0结尾的字符串
    const image_path_z = allocator.dupeZ(u8, image_path) catch {
        std.debug.print("复制图像路径失败\n", .{});
        return null;
    };
    defer allocator.free(image_path_z);

    var image = zstbi.Image.loadFromFile(image_path_z, req_channel) catch |err| {
        std.debug.print("加载图像失败: {s}\n", .{@errorName(err)});
        return null;
    };
    defer image.deinit();

    // 调整图像大小
    var resized_image = if (image.width != req_width or image.height != req_height) blk: {
        std.debug.print("调整图像大小: {d}x{d} -> {d}x{d}\n", .{ image.width, image.height, req_width, req_height });
        const resized = image.resize(req_width, req_height);
        break :blk resized;
    } else image;
    defer if (image.width != req_width or image.height != req_height) resized_image.deinit();

    // 创建输出缓冲区
    const image_size = req_width * req_height * req_channel;
    const image_data = allocator.alloc(u8, image_size) catch {
        std.debug.print("分配图像内存失败\n", .{});
        return null;
    };

    // 复制图像数据
    @memcpy(image_data, resized_image.data);

    return image_data;
}

/// 分割字符串
fn split(allocator: std.mem.Allocator, str: []const u8, delimiter: u8) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).init(allocator);

    var start: usize = 0;
    for (str, 0..) |char, i| {
        if (char == delimiter) {
            if (i > start) {
                try result.append(str[start..i]);
            }
            start = i + 1;
        }
    }

    if (start < str.len) {
        try result.append(str[start..]);
    }

    return result;
}

/// 查询自定义字符串
fn queryCustomString(ctx: c.rknn_context) !c.rknn_custom_string {
    var custom_string: c.rknn_custom_string = undefined;
    const ret = c.rknn_query(ctx, c.RKNN_QUERY_CUSTOM_STRING, &custom_string, @sizeOf(c.rknn_custom_string));
    try rknpu2.mapRknnError(ret);
    return custom_string;
}

/// 主函数
pub fn main() !void {
    // 创建内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 解析命令行参数
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("用法: {s} 模型路径 [输入路径] [循环次数] [核心掩码]\n", .{args[0]});
        return error.InvalidArguments;
    }

    const model_path = args[1];
    var input_paths_split = std.ArrayList([]const u8).init(allocator);
    defer input_paths_split.deinit();

    var loop_count: i32 = 10;
    var core_mask: u32 = c.RKNN_NPU_CORE_AUTO;
    var total_time: f64 = 0;
    const top_num: u32 = 5;

    if (args.len > 2) {
        const input_paths = args[2];
        input_paths_split = try split(allocator, input_paths, '#');
    }

    if (args.len > 3) {
        loop_count = try std.fmt.parseInt(i32, args[3], 10);
    }

    if (args.len > 4) {
        core_mask = try std.fmt.parseInt(u32, args[4], 10);
    }

    // 初始化RKNN
    std.debug.print("正在加载模型: {s}\n", .{model_path});
    var rknn = Rknn.initFromFile(allocator, model_path, .{
        .ignore_platform_mismatch = true,
    }) catch |err| {
        std.debug.print("初始化RKNN失败: {s}\n", .{rknpu2.getErrorDescription(err)});
        return err;
    };
    defer rknn.deinit() catch |err| {
        std.debug.print("销毁RKNN失败: {s}\n", .{rknpu2.getErrorDescription(err)});
    };

    // 查询SDK版本
    const sdk_ver = try rknn.querySdkVersion();
    std.debug.print("rknn_api/rknnrt 版本: {s}, 驱动版本: {s}\n", .{ Rknn.getCString(&sdk_ver.api_version), Rknn.getCString(&sdk_ver.drv_version) });

    // 查询内存大小
    const mem_size = try rknn.queryMemSize();
    std.debug.print("总权重大小: {d}, 总内部大小: {d}\n", .{ mem_size.total_weight_size, mem_size.total_internal_size });
    std.debug.print("总DMA使用大小: {d}\n", .{mem_size.total_dma_allocated_size});

    // 查询输入输出数量
    const io_num = try rknn.queryInOutNum();
    std.debug.print("模型输入数量: {d}, 输出数量: {d}\n", .{ io_num.n_input, io_num.n_output });

    // 查询输入属性
    std.debug.print("输入张量:\n", .{});
    var input_attrs = try allocator.alloc(c.rknn_tensor_attr, io_num.n_input);
    defer allocator.free(input_attrs);

    for (0..io_num.n_input) |i| {
        input_attrs[i] = try rknn.queryInputAttr(@intCast(i));
        dumpTensorAttr(&input_attrs[i]);
    }

    // 查询输出属性
    std.debug.print("输出张量:\n", .{});
    var output_attrs = try allocator.alloc(c.rknn_tensor_attr, io_num.n_output);
    defer allocator.free(output_attrs);

    for (0..io_num.n_output) |i| {
        output_attrs[i] = try rknn.queryOutputAttr(@intCast(i));
        dumpTensorAttr(&output_attrs[i]);
    }

    // 查询自定义字符串
    const custom_string = try queryCustomString(rknn.ctx);
    std.debug.print("自定义字符串: {s}\n", .{Rknn.getCString(&custom_string.string)});

    // 准备输入数据
    var input_data = try allocator.alloc(?[]u8, io_num.n_input);
    defer {
        for (input_data) |data| {
            if (data) |d| {
                allocator.free(d);
            }
        }
        allocator.free(input_data);
    }

    var input_type = try allocator.alloc(c_uint, io_num.n_input);
    defer allocator.free(input_type);

    var input_size = try allocator.alloc(usize, io_num.n_input);
    defer allocator.free(input_size);

    var input_layout = try allocator.alloc(c_uint, io_num.n_input);
    defer allocator.free(input_layout);

    // 初始化输入
    for (0..io_num.n_input) |i| {
        input_data[i] = null;
        input_type[i] = c.RKNN_TENSOR_UINT8; // RKNN_TENSOR_UINT8
        input_layout[i] = c.RKNN_TENSOR_NHWC;
        input_size[i] = input_attrs[i].n_elems * @sizeOf(u8);
    }

    // 加载输入数据
    if (input_paths_split.items.len > 0) {
        if (io_num.n_input != input_paths_split.items.len) {
            std.debug.print("输入缺失! 需要输入数量: {d}, 只获取到 {d} 个输入\n", .{ io_num.n_input, input_paths_split.items.len });
            return error.InputMissing;
        }

        for (0..io_num.n_input) |i| {
            const path = input_paths_split.items[i];

            // 检查是否为npy文件
            if (std.mem.endsWith(u8, path, ".npy")) {
                std.debug.print("警告：NPY加载功能尚未实现\n", .{});
                // 这里需要实现NPY加载功能
                // input_data[i] = loadNpy(allocator, path, &input_attrs[i], &input_type[i], &input_size[i]);

                // 临时创建随机数据
                const size = input_attrs[i].n_elems * @sizeOf(u8);
                var data = try allocator.alloc(u8, size);
                for (0..size) |j| {
                    data[j] = @intCast(j % 255);
                }
                input_data[i] = data;
            } else {
                // 加载图像
                input_data[i] = loadImage(allocator, path, &input_attrs[i]);
            }

            if (input_data[i] == null) {
                std.debug.print("加载输入 {d} 失败\n", .{i});
                return error.LoadInputFailed;
            }
        }
    } else {
        // 创建空数据
        for (0..io_num.n_input) |i| {
            const data = try allocator.alloc(u8, input_size[i]);
            @memset(data, 0);
            input_data[i] = data;
        }
    }

    // 设置输入
    var inputs = try allocator.alloc(c.rknn_input, io_num.n_input);
    defer allocator.free(inputs);

    // 初始化inputs
    for (0..io_num.n_input) |i| {
        inputs[i] = c.rknn_input{
            .index = @intCast(i),
            .buf = @ptrCast(@constCast(input_data[i].?.ptr)),
            .size = @intCast(input_data[i].?.len),
            .pass_through = 0,
            .type = c.RKNN_TENSOR_UINT8, // RKNN_TENSOR_UINT8
            .fmt = c.RKNN_TENSOR_NHWC, // RKNN_TENSOR_NHWC
        };
    }

    try rknn.setInputs(inputs);

    // 设置核心掩码
    if (core_mask <= c.RKNN_NPU_CORE_ALL) {
        std.debug.print("设置核心掩码: 0x{x}\n", .{core_mask});
        try rknn.setCoreMask(core_mask);
    } else {
        std.debug.print("跳过设置核心掩码，使用默认值\n", .{});
    }

    // 预热
    std.debug.print("预热中...\n", .{});
    for (0..5) |i| {
        const start_us = getCurrentTimeUs();
        try rknn.run(null);
        const elapse_us = getCurrentTimeUs() - start_us;
        std.debug.print("{d:4}: 耗时 = {d:.2}ms, FPS = {d:.2}\n", .{ i, @as(f32, @floatFromInt(elapse_us)) / 1000.0, 1000.0 * 1000.0 / @as(f32, @floatFromInt(elapse_us)) });
    }

    // 运行
    std.debug.print("开始性能测试...\n", .{});
    for (0..@intCast(loop_count)) |i| {
        const start_us = getCurrentTimeUs();
        try rknn.run(null);
        const elapse_us = getCurrentTimeUs() - start_us;
        const elapse_ms = @as(f32, @floatFromInt(elapse_us)) / 1000.0;
        total_time += elapse_ms;
        std.debug.print("{d:4}: 耗时 = {d:.2}ms, FPS = {d:.2}\n", .{ i, elapse_ms, 1000.0 * 1000.0 / @as(f32, @floatFromInt(elapse_us)) });
    }
    std.debug.print("\n平均耗时 {d:.2}ms, 平均FPS = {d:.3}\n\n", .{ total_time / @as(f64, @floatFromInt(loop_count)), @as(f64, @floatFromInt(loop_count)) * 1000.0 / total_time });

    // 获取输出
    var outputs = try allocator.alloc(c.rknn_output, io_num.n_output);
    defer allocator.free(outputs);

    // 初始化outputs
    for (0..io_num.n_output) |i| {
        outputs[i] = .{
            .want_float = @intFromBool(true), // 使用1代替true
            .is_prealloc = @intFromBool(false), // 使用0代替false
            .index = @intCast(i),
            .buf = null,
            .size = 0,
        };
    }

    try rknn.getOutputs(outputs, null);
    defer _ = rknn.releaseOutputs(outputs) catch {};

    // 保存输出
    for (0..io_num.n_output) |i| {
        var output_path: [std.fs.max_path_bytes]u8 = undefined;
        @memset(&output_path, 0);
        _ = try std.fmt.bufPrint(&output_path, "rt_output{d}.npy", .{i});
        std.debug.print("保存输出到 {s}\n", .{output_path[0 .. std.mem.indexOfScalar(u8, &output_path, 0) orelse 0]});

        // 这里需要实现NPY保存功能
        std.debug.print("警告：NPY保存功能尚未实现\n", .{});
    }

    // 获取Top 5
    for (0..io_num.n_output) |i| {
        const max_class = try allocator.alloc(u32, top_num);
        defer allocator.free(max_class);

        const max_prob = try allocator.alloc(f32, top_num);
        defer allocator.free(max_prob);

        const buffer = @as([*]f32, @alignCast(@ptrCast(outputs[i].buf)));
        const sz = outputs[i].size / @sizeOf(f32);
        const top_count = if (sz > top_num) top_num else sz;

        getTopN(buffer[0..sz], max_prob, max_class, @intCast(sz), top_num);

        std.debug.print("---- Top{d} ----\n", .{top_count});
        for (0..top_count) |j| {
            std.debug.print("{d:8.6} - {d}\n", .{ max_prob[j], max_class[j] });
        }
    }
}
