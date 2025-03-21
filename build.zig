const std = @import("std");

// 判断目标是否为Android
fn isAndroid(target: std.Target) bool {
    // 在Zig 0.14.0中检查Android平台
    // 通常Android目标的环境是.android
    return target.os.tag == .linux and target.abi == .android;
}

// 获取库文件路径
fn getLibPath(target: std.Target, root_dir: ?[]const u8) ![]const u8 {
    const base_dir = if (root_dir) |dir| dir else "runtime";
    // 判断操作系统
    if (target.os.tag == .linux) {
        if (isAndroid(target)) {
            // 判断 Android 的 CPU 架构
            switch (target.cpu.arch) {
                .aarch64 => {
                    return std.fmt.allocPrint(std.heap.page_allocator, "{s}/Android/librknn_api/arm64-v8a", .{base_dir}) catch "runtime/Android/librknn_api/arm64-v8a";
                },
                .arm, .thumb => {
                    return std.fmt.allocPrint(std.heap.page_allocator, "{s}/Android/librknn_api/armeabi-v7a", .{base_dir}) catch "runtime/Android/librknn_api/armeabi-v7a";
                },
                else => {
                    return error.UnsupportedArchitecture;
                },
            }
        } else {
            // 判断 Linux 的 CPU 架构
            switch (target.cpu.arch) {
                .aarch64 => {
                    return std.fmt.allocPrint(std.heap.page_allocator, "{s}/Linux/librknn_api/aarch64", .{base_dir}) catch "runtime/Linux/librknn_api/aarch64";
                },
                .arm, .thumb => {
                    return std.fmt.allocPrint(std.heap.page_allocator, "{s}/Linux/librknn_api/armhf", .{base_dir}) catch "runtime/Linux/librknn_api/armhf";
                },
                else => {
                    return error.UnsupportedArchitecture;
                },
            }
        }
    } else {
        return error.UnsupportedPlatform;
    }
}

// 获取头文件路径
fn getIncludePath(target: std.Target, root_dir: ?[]const u8) ![]const u8 {
    const base_dir = if (root_dir) |dir| dir else "runtime";
    // 判断操作系统
    if (target.os.tag == .linux) {
        if (isAndroid(target)) {
            return std.fmt.allocPrint(std.heap.page_allocator, "{s}/Android/librknn_api/include", .{base_dir}) catch "runtime/Android/librknn_api/include";
        } else {
            return std.fmt.allocPrint(std.heap.page_allocator, "{s}/Linux/librknn_api/include", .{base_dir}) catch "runtime/Linux/librknn_api/include";
        }
    } else {
        return error.UnsupportedPlatform;
    }
}

// 创建RKNPU2库模块
fn createRknpu2Module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_path: std.Build.LazyPath,
    include_path: std.Build.LazyPath,
) *std.Build.Module {
    // 创建库模块
    const rknpu2_module = b.addModule("zig-rknpu2", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    rknpu2_module.addLibraryPath(lib_path);
    rknpu2_module.addIncludePath(include_path);
    // 获取目标平台和架构信息
    const platform_str = if (isAndroid(target.result)) "Android" else "Linux";
    const arch_str = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64",
        .arm, .thumb => if (isAndroid(target.result)) "armeabi-v7a" else "armhf",
        else => "unknown",
    };

    // 添加平台和架构宏
    rknpu2_module.addCMacro("PLATFORM", platform_str);
    rknpu2_module.addCMacro("ARCH", arch_str);

    return rknpu2_module;
}

// 为可执行文件设置RKNPU2依赖
fn setupRknpu2ForExecutable(
    exe: *std.Build.Step.Compile,
    lib_path: std.Build.LazyPath,
    include_path: std.Build.LazyPath,
    rknpu2_module: *std.Build.Module,
) void {
    // 链接RKNPU2库
    exe.linkSystemLibrary("rknnrt");
    exe.addLibraryPath(lib_path);
    exe.addIncludePath(include_path);

    // 添加模块依赖
    exe.root_module.addImport("zig-rknpu2", rknpu2_module);
}

// 构建示例
fn buildExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_path: std.Build.LazyPath,
    include_path: std.Build.LazyPath,
    rknpu2_module: *std.Build.Module,
) void {
    // 添加zstbi依赖
    const zstbi_dep = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });
    // 批量构建示例可执行文件
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "simple_example", .path = "src/examples/simple_example.zig" },
        .{ .name = "create_mem_example", .path = "src/examples/create_mem_example.zig" },
        .{ .name = "create_mem_with_rga_example", .path = "src/examples/create_mem_with_rga_example.zig" },
        .{ .name = "rknn_benchmark", .path = "src/examples/benchmark.zig" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = b.path(example.path),
            .target = target,
            .optimize = optimize,
        });
        exe.linkLibC();

        // 设置example的RKNPU2依赖
        setupRknpu2ForExecutable(exe, lib_path, include_path, rknpu2_module);
        // 添加依赖
        exe.root_module.addImport("zstbi", zstbi_dep.module("root"));

        // 安装example
        b.installArtifact(exe);

        // 添加运行example的步骤
        const run_example = b.addRunArtifact(exe);
        run_example.step.dependOn(b.getInstallStep());

        const example_step = b.step(example.name, "Build and run the simple example");
        example_step.dependOn(&run_example.step);

        // 添加只编译不运行的步骤
        const step_name = std.fmt.allocPrint(b.allocator, "build-{s}", .{example.name}) catch unreachable;
        const step_desc = std.fmt.allocPrint(b.allocator, "Build the {s} without running it", .{example.name}) catch unreachable;
        const build_example_step = b.step(step_name, step_desc);
        const install_example = b.addInstallArtifact(exe, .{});
        build_example_step.dependOn(&install_example.step);
    }
}

pub fn build(b: *std.Build) void {
    // 获取标准目标选项
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // 获取RKNPU2库路径选项
    const rknpu2_root_dir_opt = b.option([]const u8, "RKNPU2_LIB_ROOT_DIR", "Path to RKNPU2 library ROOT directory");

    // 获取RK_LIBRGA_ROOT_DIR环境变量
    const rknpu2_root_dir_env = std.process.getEnvVarOwned(std.heap.page_allocator, "RKNPU2_LIB_ROOT_DIR") catch null;

    // 确定根目录：优先使用命令行选项，其次使用环境变量
    const root_dir = if (rknpu2_root_dir_opt) |dir| dir else rknpu2_root_dir_env;

    // 检查目标平台和架构是否支持
    const lib_path = getLibPath(target.result, root_dir) catch |err| {
        std.debug.print("Error: {s}. Only Linux and Android platforms with ARM/ARM64 architectures are supported.\n", .{@errorName(err)});
        return;
    };

    const include_path = getIncludePath(target.result, root_dir) catch |err| {
        std.debug.print("Error: {s}. Only Linux and Android platforms are supported.\n", .{@errorName(err)});
        return;
    };

    // 如果指定了自定义库路径，则使用自定义路径
    const final_lib_path = lib_path;
    const final_include_path = include_path;

    // 创建库模块
    const rknpu2_module = createRknpu2Module(b, target, optimize, b.path(final_lib_path), b.path(final_include_path));

    // 创建静态库
    const lib = b.addStaticLibrary(.{
        .name = "zig-rknpu2",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // 添加C库链接
    lib.linkLibC();
    lib.linkSystemLibrary("rknnrt");
    lib.addLibraryPath(b.path(final_lib_path));
    lib.addIncludePath(b.path(final_include_path));

    // 获取目标平台和架构信息
    const platform_str = if (isAndroid(target.result)) "Android" else "Linux";
    const arch_str = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64",
        .arm, .thumb => if (isAndroid(target.result)) "armeabi-v7a" else "armhf",
        else => "unknown",
    };

    // 添加平台和架构宏
    lib.root_module.addCMacro("PLATFORM", platform_str);
    lib.root_module.addCMacro("ARCH", arch_str);

    // 安装库
    b.installArtifact(lib);

    // 创建测试
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 设置测试的库路径和头文件路径
    main_tests.linkLibC();
    main_tests.linkSystemLibrary("rknnrt");
    main_tests.addLibraryPath(b.path(final_lib_path));
    main_tests.addIncludePath(b.path(final_include_path));

    const run_main_tests = b.addRunArtifact(main_tests);

    // 添加测试步骤
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // 构建示例
    buildExamples(b, target, optimize, b.path(final_lib_path), b.path(final_include_path), rknpu2_module);
}
