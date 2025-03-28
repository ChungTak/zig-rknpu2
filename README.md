# zig-rknpu2

zig-rknpu2是一个用Zig语言封装的RKNPU2库，用于在Rockchip NPU上运行神经网络模型。

## 特性

- 支持Linux(aarch64/armhf)和Android(arm64-v8a/armeabi-v7a)平台
- 提供安全的Zig API，包括错误处理、内存管理等
- 支持从系统环境变量中搜索库文件和头文件
- 完整封装RKNPU2的C API

## 要求

- Zig 0.14.0或更高版本
- RKNPU2运行时库

## 预编译库

项目已包含以下主流系统的预编译库:
- aarch64-linux-gnu
- aarch64-linux-android

需要更多平台的库文件，可以从官方下载：[https://github.com/airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2)下载。


## 编译

项目通过环境变量`RKNPU2_LIBRARIES`指定RKNPU2库路径的路径:

```bash
# 示例: 指定自定义库路径
export RKNPU2_LIBRARIES=/path/to/your/libraries 
zig build
```

如果未设置环境变量，将使用项目内置的库(根据目标平台自动选择)。


## 安装

### 方法一：克隆仓库

1. 克隆仓库：

```bash
git clone https://github.com/ChungTak/zig-rknpu2.git
cd zig-rknpu2
```

2. 构建库：

```bash
zig build
```

### 方法二：作为依赖使用（推荐）

在您的项目中使用以下命令添加依赖：

```bash
zig fetch --save git+https://github.com/ChungTak/zig-rknpu2.git
```

或者在你的`build.zig.zon`中手动添加依赖:

```zig
.dependencies = .{
    .zig_rknpu2 = .{
        .url = "git+https://github.com/ChungTak/zig-rknpu2.git",
        .hash = "...", // 使用zig fetch获取正确的hash
    },
},
```

## 使用方法

### 基本用法

```zig
const std = @import("std");
const rknpu2 = @import("zig-rknpu2");
const Rknn = rknpu2.Rknn;

pub fn main() !void {
    // 创建内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化RKNN上下文
    var rknn = try Rknn.initFromFile(allocator, "model.rknn", .{
        .ignore_platform_mismatch = true,
    });
    defer rknn.deinit() catch {};

    // 查询模型信息
    const io_num = try rknn.queryInOutNum();
    std.debug.print("模型输入数量: {d}\n", .{io_num.n_input});
    std.debug.print("模型输出数量: {d}\n", .{io_num.n_output});

    // 创建输入数据
    // ...

    // 运行推理
    // ...

    // 处理输出结果
    // ...
}
```

### 指定平台和架构

在构建时，可以指定目标平台和架构：

```bash
# Linux + aarch64 (默认)
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe

# Linux + armhf 32bit
zig build -Dtarget=arm-linux-gnueabihf

# Android + arm64-v8a
zig build -Dtarget=aarch64-linux-android

# Android + armeabi-v7a 32bit
zig build -Dtarget=arm-linux-androi
```

## API文档

### 初始化和销毁

```zig
// 从内存初始化
pub fn init(allocator: Allocator, model_data: []const u8, options: InitOptions) errors.RknnError!Rknn;

// 从文件初始化
pub fn initFromFile(allocator: Allocator, model_path: []const u8, options: InitOptions) errors.RknnError!Rknn;

// 复制上下文
pub fn dup(self: *Rknn) errors.RknnError!Rknn;

// 销毁上下文
pub fn deinit(self: *Rknn) errors.RknnError!void;
```

### 查询信息

```zig
// 查询输入输出数量
pub fn queryInOutNum(self: *Rknn) errors.RknnError!c.rknn_input_output_num;

// 查询输入属性
pub fn queryInputAttr(self: *Rknn, index: u32) errors.RknnError!c.rknn_tensor_attr;

// 查询输出属性
pub fn queryOutputAttr(self: *Rknn, index: u32) errors.RknnError!c.rknn_tensor_attr;

// 查询SDK版本
pub fn querySdkVersion(self: *Rknn) errors.RknnError!c.rknn_sdk_version;

// 查询内存大小
pub fn queryMemSize(self: *Rknn) errors.RknnError!c.rknn_mem_size;
```

### 设置输入和运行

```zig
// 设置输入
pub fn setInputs(self: *Rknn, inputs: []c.rknn_input) errors.RknnError!void;

// 运行推理
pub fn run(self: *Rknn, extend: ?*c.rknn_run_extend) errors.RknnError!void;

// 等待推理完成
pub fn wait(self: *Rknn, extend: ?*c.rknn_run_extend) errors.RknnError!void;

// 获取输出
pub fn getOutputs(self: *Rknn, outputs: []c.rknn_output, extend: ?*c.rknn_output_extend) errors.RknnError!void;

// 释放输出
pub fn releaseOutputs(self: *Rknn, outputs: []c.rknn_output) errors.RknnError!void;

// 运行推理并获取结果
pub fn runAndGetOutputs(self: *Rknn, inputs: []c.rknn_input, outputs: []c.rknn_output) errors.RknnError!void;
```

### 内存管理

```zig
// 创建内存
pub fn createMem(self: *Rknn, size: u32) errors.RknnError!*c.rknn_tensor_mem;

// 创建内存（扩展版本）
pub fn createMem2(self: *Rknn, size: u64, alloc_flags: u64) errors.RknnError!*c.rknn_tensor_mem;

// 销毁内存
pub fn destroyMem(self: *Rknn, mem: *c.rknn_tensor_mem) errors.RknnError!void;

// 同步内存
pub fn memSync(self: *Rknn, mem: *c.rknn_tensor_mem, mode: c.rknn_mem_sync_mode) errors.RknnError!void;
```

## 示例

查看 `src/examples` 目录获取完整示例：

- `simple_example.zig`：基本推理示例
- `create_mem_example.zig`：内存管理示例
- `create_mem_with_rga_example.zig`：使用RGA加速的内存管理示例
- `benchmark.zig`：性能基准测试示例

编译并运行示例:

```bash
# 编译benchmark示例
zig build -Dtarget=aarch64-linux-gnu

# 运行benchmark示例
LD_LIBRARY_PATH=runtime/lib/aarch64-linux-gnu ./zig-out/bin/benchmark
```

## 许可证

MIT 