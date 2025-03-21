const std = @import("std");
const rknpu2 = @import("zig-rknpu2");
const Rknn = rknpu2.Rknn;
const c = rknpu2.c;

/// 获取当前时间（微秒）
fn getCurrentTimeUs() i64 {
    var tv: std.posix.timeval = undefined;
    _ = std.posix.gettimeofday(&tv, null);
    return tv.sec * 1000000 + tv.usec;
}

/// 获取前N个最大值
fn getTopN(allocator: std.mem.Allocator, prob: []f32, outputCount: u32, topNum: u32) !struct { max_probs: []f32, max_classes: []u32 } {
    const top_count = @min(topNum, outputCount);

    var max_probs = try allocator.alloc(f32, top_count);
    var max_classes = try allocator.alloc(u32, top_count);

    // 初始化
    for (0..top_count) |i| {
        max_probs[i] = -std.math.floatMax(f32);
        max_classes[i] = 0;
    }

    // 查找最大值
    for (0..top_count) |j| {
        for (0..outputCount) |i| {
            // 检查当前索引是否已经在最大值列表中
            var is_max = true;
            for (0..j) |k| {
                if (i == max_classes[k]) {
                    is_max = false;
                    break;
                }
            }

            if (is_max and prob[i] > max_probs[j]) {
                max_probs[j] = prob[i];
                max_classes[j] = @intCast(i);
            }
        }
    }

    return .{ .max_probs = max_probs, .max_classes = max_classes };
}

/// 加载并处理图像
fn loadImage(allocator: std.mem.Allocator, image_path: []const u8, input_attr: *c.rknn_tensor_attr) ![]u8 {
    var req_height: u32 = 0;
    var req_width: u32 = 0;
    var req_channel: u32 = 0;

    // 根据输入格式获取所需尺寸
    switch (input_attr.fmt) {
        c.RKNN_TENSOR_NHWC => {
            req_height = @intCast(input_attr.dims[1]);
            req_width = @intCast(input_attr.dims[2]);
            req_channel = @intCast(input_attr.dims[3]);
        },
        c.RKNN_TENSOR_NCHW => {
            req_height = @intCast(input_attr.dims[2]);
            req_width = @intCast(input_attr.dims[3]);
            req_channel = @intCast(input_attr.dims[1]);
        },
        else => {
            std.debug.print("不支持的布局格式\n", .{});
            return error.UnsupportedLayout;
        },
    }

    // 这里应该使用图像加载库（如stb_image）
    // 为了简化示例，我们创建一个模拟图像数据
    std.debug.print("模拟加载图像：{s}，尺寸：{d}x{d}x{d}\n", .{ image_path, req_width, req_height, req_channel });

    const image_size = req_width * req_height * req_channel;
    const image_data = try allocator.alloc(u8, image_size);

    // 填充随机数据作为图像数据
    for (0..image_size) |i| {
        image_data[i] = @intCast(i % 256);
    }

    return image_data;
}

/// 加载模型
fn loadModel(allocator: std.mem.Allocator, model_path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(model_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const model_data = try allocator.alloc(u8, file_size);

    const bytes_read = try file.readAll(model_data);
    if (bytes_read != file_size) {
        return error.IncompleteRead;
    }

    return model_data;
}

pub fn main() !void {
    // 创建内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 解析命令行参数
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("用法：{s} 模型路径 输入图像路径 [循环次数]\n", .{args[0]});
        return error.InvalidArguments;
    }

    const model_path = args[1];
    const input_path = args[2];

    // 可选的循环次数参数
    var loop_count: u32 = 1;
    if (args.len > 3) {
        loop_count = try std.fmt.parseInt(u32, args[3], 10);
    }

    // 加载模型
    std.debug.print("加载模型：{s}\n", .{model_path});
    const model_data = try loadModel(allocator, model_path);
    defer allocator.free(model_data);

    // 初始化RKNN
    var rknn = try Rknn.init(allocator, model_data, .{});
    defer rknn.deinit() catch |err| {
        std.debug.print("销毁RKNN失败：{s}\n", .{rknpu2.getErrorDescription(err)});
    };

    // 查询SDK版本
    const sdk_ver = try rknn.querySdkVersion();
    std.debug.print("RKNN API/RKNN RT版本：{s}，驱动版本：{s}\n", .{
        Rknn.getCString(&sdk_ver.api_version),
        Rknn.getCString(&sdk_ver.drv_version),
    });

    // 查询输入输出数量
    const io_num = try rknn.queryInOutNum();
    std.debug.print("模型输入数量：{d}，输出数量：{d}\n", .{ io_num.n_input, io_num.n_output });

    // 查询输入属性
    std.debug.print("输入张量：\n", .{});
    var input_attrs = try allocator.alloc(c.rknn_tensor_attr, io_num.n_input);
    defer allocator.free(input_attrs);

    for (0..io_num.n_input) |i| {
        input_attrs[i] = try rknn.queryInputAttr(@intCast(i));
        std.debug.print("  索引={d}, 名称={s}, 维度数={d}, 维度=[{d}, {d}, {d}, {d}], 元素数={d}, 大小={d}, 格式={d}, 类型={d}\n", .{
            input_attrs[i].index,
            Rknn.getCString(&input_attrs[i].name),
            input_attrs[i].n_dims,
            input_attrs[i].dims[0],
            input_attrs[i].dims[1],
            input_attrs[i].dims[2],
            input_attrs[i].dims[3],
            input_attrs[i].n_elems,
            input_attrs[i].size,
            input_attrs[i].fmt,
            input_attrs[i].type,
        });
    }

    // 查询输出属性
    std.debug.print("输出张量：\n", .{});
    var output_attrs = try allocator.alloc(c.rknn_tensor_attr, io_num.n_output);
    defer allocator.free(output_attrs);

    for (0..io_num.n_output) |i| {
        output_attrs[i] = try rknn.queryOutputAttr(@intCast(i));
        std.debug.print("  索引={d}, 名称={s}, 维度数={d}, 维度=[{d}, {d}, {d}, {d}], 元素数={d}, 大小={d}, 格式={d}, 类型={d}\n", .{
            output_attrs[i].index,
            Rknn.getCString(&output_attrs[i].name),
            output_attrs[i].n_dims,
            output_attrs[i].dims[0],
            output_attrs[i].dims[1],
            output_attrs[i].dims[2],
            output_attrs[i].dims[3],
            output_attrs[i].n_elems,
            output_attrs[i].size,
            output_attrs[i].fmt,
            output_attrs[i].type,
        });
    }

    // 获取自定义字符串
    var custom_string: c.rknn_custom_string = undefined;
    _ = c.rknn_query(rknn.ctx, c.RKNN_QUERY_CUSTOM_STRING, &custom_string, @sizeOf(c.rknn_custom_string));
    std.debug.print("自定义字符串：{s}\n", .{Rknn.getCString(&custom_string.string)});

    // 加载图像
    const input_data = try loadImage(allocator, input_path, &input_attrs[0]);
    defer allocator.free(input_data);

    // 创建输入张量内存
    const input_type = 3; // RKNN_TENSOR_UINT8
    const input_layout = 1; // RKNN_TENSOR_NHWC

    input_attrs[0].type = input_type;
    input_attrs[0].fmt = input_layout;

    // 创建内存
    const input_mem = try rknn.createMem(input_attrs[0].size_with_stride);
    defer rknn.destroyMem(input_mem) catch |err| {
        std.debug.print("销毁输入内存失败：{s}\n", .{rknpu2.getErrorDescription(err)});
    };

    // 复制输入数据到输入张量内存
    const width = input_attrs[0].dims[2];
    const stride = input_attrs[0].w_stride;

    if (width == stride) {
        const total_size = width * input_attrs[0].dims[1] * input_attrs[0].dims[3];
        @memcpy(@as([*]u8, @alignCast(@ptrCast(input_mem.virt_addr)))[0..total_size], input_data[0..total_size]);
    } else {
        const height = input_attrs[0].dims[1];
        const channel = input_attrs[0].dims[3];
        // 复制数据（考虑步长）
        const src_wc_elems = width * channel;
        const dst_wc_elems = stride * channel;

        var h: usize = 0;
        while (h < height) : (h += 1) {
            const src_offset = h * src_wc_elems;
            const dst_offset = h * dst_wc_elems;
            @memcpy(
                @as([*]u8, @alignCast(@ptrCast(input_mem.virt_addr)))[dst_offset .. dst_offset + src_wc_elems],
                input_data[src_offset .. src_offset + src_wc_elems],
            );
        }
    }

    // 创建输出张量内存
    const output_mems = try allocator.alloc(*c.rknn_tensor_mem, io_num.n_output);
    defer allocator.free(output_mems);

    defer {
        for (0..io_num.n_output) |i| {
            rknn.destroyMem(output_mems[i]) catch |err| {
                std.debug.print("销毁输出内存失败：{s}\n", .{rknpu2.getErrorDescription(err)});
            };
        }
    }

    for (0..io_num.n_output) |i| {
        // 默认输出类型取决于模型，这里我们需要float32来计算top5
        const output_size = output_attrs[i].n_elems * @sizeOf(f32);
        output_mems[i] = try rknn.createMem(@intCast(output_size));
    }

    // 设置输入张量内存
    try rknn.setIoMem(input_mem, &input_attrs[0]);

    // 设置输出张量内存
    for (0..io_num.n_output) |i| {
        // 默认输出类型取决于模型，这里我们需要float32来计算top5
        output_attrs[i].type = c.RKNN_TENSOR_FLOAT32; // RKNN_TENSOR_FLOAT32
        try rknn.setIoMem(output_mems[i], &output_attrs[i]);
    }

    // 运行推理
    std.debug.print("开始性能测试...\n", .{});
    for (0..loop_count) |i| {
        const start_us = getCurrentTimeUs();
        try rknn.run(null);
        const elapse_us = getCurrentTimeUs() - start_us;
        std.debug.print("{d:4}: 耗时 = {d:.2}毫秒, FPS = {d:.2}\n", .{
            i,
            @as(f32, @floatFromInt(elapse_us)) / 1000.0,
            1000.0 * 1000.0 / @as(f32, @floatFromInt(elapse_us)),
        });
    }

    // 获取top 5结果
    const top_num: u32 = 5;
    for (0..io_num.n_output) |i| {
        const buffer = @as([*]f32, @alignCast(@ptrCast(output_mems[i].virt_addr)))[0..output_attrs[i].n_elems];
        const result = try getTopN(allocator, buffer, output_attrs[i].n_elems, top_num);
        defer allocator.free(result.max_probs);
        defer allocator.free(result.max_classes);

        const top_count = @min(top_num, output_attrs[i].n_elems);
        std.debug.print("---- Top{d} ----\n", .{top_count});
        for (0..top_count) |j| {
            std.debug.print("{d:8.6} - {d}\n", .{ result.max_probs[j], result.max_classes[j] });
        }
    }

    std.debug.print("示例运行完成\n", .{});
}
