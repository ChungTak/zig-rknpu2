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

/// 加载图像并返回原始大小的图像数据
fn loadImage(allocator: std.mem.Allocator, image_path: []const u8) !struct { width: u32, height: u32, channel: u32, data: []u8 } {
    // 这里应该使用真实的图像加载库，例如stb_image
    // 为了示例，我们创建模拟图像数据
    std.debug.print("模拟加载图像：{s}\n", .{image_path});

    // 模拟图像尺寸
    const width: u32 = 640;
    const height: u32 = 480;
    const channel: u32 = 3; // RGB

    const image_size = width * height * channel;
    var image_data = try allocator.alloc(u8, image_size);

    // 填充随机图像数据
    for (0..image_size) |i| {
        image_data[i] = @intCast(i % 256);
    }

    std.debug.print("已加载模拟图像，尺寸为：{d}x{d}x{d}\n", .{ width, height, channel });

    return .{
        .width = width,
        .height = height,
        .channel = channel,
        .data = image_data,
    };
}

/// 模拟RGA图像处理（调整大小和格式转换）
fn simulateRgaProcess(allocator: std.mem.Allocator, src_data: []u8, src_width: u32, src_height: u32, src_channel: u32, dst_width: u32, dst_height: u32) ![]u8 {
    std.debug.print("模拟RGA处理：将图像从 {d}x{d} 调整为 {d}x{d}\n", .{ src_width, src_height, dst_width, dst_height });

    // 在实际的RGA实现中，这里应该使用RGA库执行硬件加速的图像处理
    // 对于这个示例，我们只是分配调整大小后的缓冲区

    const dst_size = dst_width * dst_height * src_channel;
    var dst_data = try allocator.alloc(u8, dst_size);

    // 简单的模拟调整大小（实际上应该使用插值算法或RGA硬件）
    // 这里只是为了演示目的，我们只将源图像数据复制到目标缓冲区的前部分
    const min_width = @min(src_width, dst_width);
    const min_height = @min(src_height, dst_height);

    // 简单的像素复制（这不是正确的调整大小算法，只是示例）
    for (0..min_height) |y| {
        for (0..min_width) |x| {
            for (0..src_channel) |channel_index| {
                const src_idx = (y * src_width + x) * src_channel + channel_index;
                const dst_idx = (y * dst_width + x) * src_channel + channel_index;

                if (src_idx < src_data.len and dst_idx < dst_data.len) {
                    dst_data[dst_idx] = src_data[src_idx];
                }
            }
        }
    }

    std.debug.print("模拟RGA处理完成\n", .{});
    return dst_data;
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

    const align_size: u32 = 8; // 对齐大小

    // 初始化模拟RGA上下文
    std.debug.print("初始化模拟RGA上下文...\n", .{});

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

    // 加载图像（获取原始尺寸）
    const image_info = try loadImage(allocator, input_path);
    defer allocator.free(image_info.data);

    // 获取模型输入需要的尺寸
    var model_in_height: u32 = 0;
    var model_in_width: u32 = 0;
    var req_channel: u32 = 0;

    switch (input_attrs[0].fmt) {
        c.RKNN_TENSOR_NHWC => {
            model_in_height = @intCast(input_attrs[0].dims[1]);
            model_in_width = @intCast(input_attrs[0].dims[2]);
            req_channel = @intCast(input_attrs[0].dims[3]);
        },
        c.RKNN_TENSOR_NCHW => {
            model_in_height = @intCast(input_attrs[0].dims[2]);
            model_in_width = @intCast(input_attrs[0].dims[3]);
            req_channel = @intCast(input_attrs[0].dims[1]);
        },
        else => {
            std.debug.print("不支持的布局格式\n", .{});
            return error.UnsupportedLayout;
        },
    }

    // 设置输入属性
    const input_type = c.RKNN_TENSOR_UINT8; // RKNN_TENSOR_UINT8
    const input_layout = c.RKNN_TENSOR_NHWC; // RKNN_TENSOR_NHWC

    input_attrs[0].type = input_type;
    input_attrs[0].fmt = input_layout;

    // 创建输入内存
    std.debug.print("创建输入内存（使用RKNN内存）...\n", .{});
    const input_mem = try rknn.createMem(input_attrs[0].size_with_stride);
    defer rknn.destroyMem(input_mem) catch |err| {
        std.debug.print("销毁输入内存失败：{s}\n", .{rknpu2.getErrorDescription(err)});
    };

    // 计算对齐步长
    const wstride = model_in_width + (align_size - model_in_width % align_size) % align_size;
    const hstride = model_in_height;

    std.debug.print("使用RGA调整图像大小：从 {d}x{d} 到 {d}x{d}（步长：{d}x{d}）\n", .{
        image_info.width, image_info.height,
        model_in_width,   model_in_height,
        wstride,          hstride,
    });

    // 模拟使用RGA处理图像（实际实现需要使用RGA库）
    // 在实际实现中，这里应该使用input_mem的fd与RGA API进行调用
    // 对于示例，我们只是将处理后的数据复制到input_mem
    const processed_data = try simulateRgaProcess(allocator, image_info.data, image_info.width, image_info.height, image_info.channel, model_in_width, model_in_height);
    defer allocator.free(processed_data);

    // 复制处理后的数据到输入内存
    std.debug.print("复制处理后的数据到输入内存...\n", .{});
    @memcpy(@as([*]u8, @alignCast(@ptrCast(input_mem.virt_addr)))[0..processed_data.len], processed_data);

    // 创建输出张量内存
    std.debug.print("创建输出内存...\n", .{});
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
        const output_size = output_attrs[i].n_elems * @sizeOf(f32);
        output_attrs[i].type = 0; // RKNN_TENSOR_FLOAT32
        output_mems[i] = try rknn.createMem(@intCast(output_size));
    }

    // 设置输入张量内存
    try rknn.setIoMem(input_mem, &input_attrs[0]);

    // 设置输出张量内存
    for (0..io_num.n_output) |i| {
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
