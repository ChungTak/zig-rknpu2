const std = @import("std");
const rknpu2 = @import("zig-rknpu2");
const Rknn = rknpu2.Rknn;
const c = rknpu2.c;

pub fn main() !void {
    // 创建内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 解析命令行参数
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("用法: {s} 模型路径\n", .{args[0]});
        return error.InvalidArguments;
    }
    // 打印信息
    std.debug.print("RKNN示例程序\n", .{});

    // 从文件加载模型
    const model_path = args[1];
    std.debug.print("尝试加载模型: {s}\n", .{model_path});

    // 检查文件是否存在
    std.fs.cwd().access(model_path, .{}) catch |err| {
        std.debug.print("错误: 模型文件不存在或无法访问: {s}, 错误: {s}\n", .{ model_path, @errorName(err) });
        return err;
    };
    std.debug.print("模型文件存在，继续初始化...\n", .{});

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
    std.debug.print("正在查询SDK版本...\n", .{});
    const version = rknn.querySdkVersion() catch |err| {
        std.debug.print("查询SDK版本失败: {s}\n", .{rknpu2.getErrorDescription(err)});
        return err;
    };
    std.debug.print("RKNN SDK版本: {s}\n", .{Rknn.getCString(&version.api_version)});
    std.debug.print("RKNN 驱动版本: {s}\n", .{Rknn.getCString(&version.drv_version)});

    // 查询内存大小
    const mem_size = try rknn.queryMemSize();
    std.debug.print("总权重大小: {d}, 总内部大小: {d}\n", .{ mem_size.total_weight_size, mem_size.total_internal_size });
    std.debug.print("总DMA使用大小: {d}\n", .{mem_size.total_dma_allocated_size});

    // 查询输入输出数量
    std.debug.print("正在查询输入输出数量...\n", .{});
    const io_num = rknn.queryInOutNum() catch |err| {
        std.debug.print("查询输入输出数量失败: {s}\n", .{rknpu2.getErrorDescription(err)});
        return err;
    };
    std.debug.print("模型输入数量: {d}\n", .{io_num.n_input});
    std.debug.print("模型输出数量: {d}\n", .{io_num.n_output});

    // 检查输入输出数量是否合理
    if (io_num.n_input == 0 or io_num.n_output == 0) {
        std.debug.print("错误: 模型输入或输出数量为0，可能模型加载不正确\n", .{});
        return error.InvalidModel;
    }

    // 查询输入属性
    std.debug.print("正在查询输入属性...\n", .{});
    var input_attrs = allocator.alloc(c.rknn_tensor_attr, io_num.n_input) catch |err| {
        std.debug.print("分配输入属性内存失败: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(input_attrs);

    for (0..io_num.n_input) |i| {
        input_attrs[i].index = @intCast(i);
        input_attrs[i] = rknn.queryInputAttr(@intCast(i)) catch |err| {
            std.debug.print("查询输入属性失败，索引 {d}: {s}\n", .{ i, rknpu2.getErrorDescription(err) });
            return err;
        };

        std.debug.print("输入 {d} 信息:\n", .{i});
        std.debug.print("  名称: {s}\n", .{Rknn.getCString(&input_attrs[i].name)});
        std.debug.print("  维度: [", .{});
        for (0..input_attrs[i].n_dims) |j| {
            if (j > 0) std.debug.print(", ", .{});
            std.debug.print("{d}", .{input_attrs[i].dims[j]});
        }
        std.debug.print("]\n", .{});
        std.debug.print("  大小: {d} 字节\n", .{input_attrs[i].size});
        std.debug.print("  类型: {d}\n", .{input_attrs[i].type});
        std.debug.print("  格式: {d}\n", .{input_attrs[i].fmt});

        // 检查输入大小是否合理
        if (input_attrs[i].size == 0) {
            std.debug.print("错误: 输入 {d} 大小为0\n", .{i});
            return error.InvalidInputSize;
        }
    }

    // 查询输出属性
    std.debug.print("正在查询输出属性...\n", .{});
    var output_attrs = allocator.alloc(c.rknn_tensor_attr, io_num.n_output) catch |err| {
        std.debug.print("分配输出属性内存失败: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(output_attrs);

    for (0..io_num.n_output) |i| {
        output_attrs[i].index = @intCast(i);
        output_attrs[i] = rknn.queryOutputAttr(@intCast(i)) catch |err| {
            std.debug.print("查询输出属性失败，索引 {d}: {s}\n", .{ i, rknpu2.getErrorDescription(err) });
            return err;
        };

        std.debug.print("输出 {d} 信息:\n", .{i});
        std.debug.print("  名称: {s}\n", .{Rknn.getCString(&output_attrs[i].name)});
        std.debug.print("  维度: [", .{});
        for (0..output_attrs[i].n_dims) |j| {
            if (j > 0) std.debug.print(", ", .{});
            std.debug.print("{d}", .{output_attrs[i].dims[j]});
        }
        std.debug.print("]\n", .{});
        std.debug.print("  大小: {d} 字节\n", .{output_attrs[i].size});
        std.debug.print("  类型: {d}\n", .{output_attrs[i].type});
        std.debug.print("  格式: {d}\n", .{output_attrs[i].fmt});
    }

    // 创建输入数据（示例）
    std.debug.print("正在创建输入数据...\n", .{});
    var inputs = allocator.alloc(c.rknn_input, io_num.n_input) catch |err| {
        std.debug.print("分配输入内存失败: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(inputs);

    // 假设第一个输入是图像数据
    if (io_num.n_input > 0) {
        const input_size = input_attrs[0].size;
        std.debug.print("分配输入数据内存，大小: {d} 字节\n", .{input_size});

        var input_data = allocator.alloc(u8, input_size) catch |err| {
            std.debug.print("分配输入数据内存失败: {s}\n", .{@errorName(err)});
            return err;
        };
        defer allocator.free(input_data);

        // 这里应该填充实际的输入数据
        // 示例中只是填充随机数据
        std.debug.print("填充输入数据...\n", .{});
        for (0..input_size) |i| {
            input_data[i] = @intCast(i % 256);
        }

        // 设置输入 - 使用正确的调用方式
        std.debug.print("创建输入结构...\n", .{});
        inputs[0] = Rknn.createInput(0, input_data, input_attrs[0].type, input_attrs[0].fmt);
        std.debug.print("输入结构创建成功\n", .{});
    }

    // 创建输出
    std.debug.print("正在创建输出结构...\n", .{});
    var outputs = allocator.alloc(c.rknn_output, io_num.n_output) catch |err| {
        std.debug.print("分配输出内存失败: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(outputs);

    for (0..io_num.n_output) |i| {
        outputs[i] = Rknn.createNonPreallocOutput(@intCast(i), true);
    }
    std.debug.print("输出结构创建成功\n", .{});

    // 运行推理并获取结果
    std.debug.print("正在运行推理...\n", .{});
    rknn.runAndGetOutputs(inputs, outputs) catch |err| {
        std.debug.print("运行推理失败: {s}\n", .{rknpu2.getErrorDescription(err)});
        return err;
    };
    std.debug.print("推理完成\n", .{});

    defer rknn.releaseOutputs(outputs) catch |err| {
        std.debug.print("释放输出失败: {s}\n", .{rknpu2.getErrorDescription(err)});
    };

    // 处理输出结果
    std.debug.print("处理输出结果...\n", .{});
    for (0..io_num.n_output) |i| {
        std.debug.print("输出 {d} 数据:\n", .{i});

        // 假设输出是浮点数数组
        if (outputs[i].buf != null and outputs[i].size > 0) {
            std.debug.print("  输出缓冲区地址: {*}\n", .{outputs[i].buf});
            std.debug.print("  输出大小: {d} 字节\n", .{outputs[i].size});

            const float_data = @as([*]f32, @alignCast(@ptrCast(outputs[i].buf)))[0 .. outputs[i].size / @sizeOf(f32)];
            std.debug.print("  浮点数数组长度: {d}\n", .{float_data.len});

            // 打印前10个值（或更少）
            const print_count = @min(10, float_data.len);
            for (0..print_count) |j| {
                std.debug.print("  [{d}]: {d:.6}\n", .{ j, float_data[j] });
            }
        } else {
            std.debug.print("  输出缓冲区为空或大小为0\n", .{});
        }
    }

    std.debug.print("RKNN示例程序完成\n", .{});
}
