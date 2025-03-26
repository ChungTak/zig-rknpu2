const std = @import("std");

// 获取库文件路径
fn getLibPath(target_str: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "runtime/lib/{s}", .{target_str});
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

        const example_step_desc = std.fmt.allocPrint(b.allocator, "Build and run the {s}", .{example.name}) catch unreachable;
        const example_step = b.step(example.name, example_step_desc);
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
    const target_str = std.fmt.allocPrint(b.allocator, "{s}-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) }) catch "aarch64-linux-gnu";
    const optimize = b.standardOptimizeOption(.{});

    // 获取RKNPU2库路径RKNPU2_LIBRARIES环境变量
    const rknpu2_lib = std.process.getEnvVarOwned(std.heap.page_allocator, "RKNPU2_LIBRARIES") catch null;

    // 本地链接库路径
    const lib_path = getLibPath(target_str) catch |err| {
        std.debug.print("Error: {s}. lib path not found.\n", .{@errorName(err)});
        return;
    };

    // 确定库路径：优先使用使用环境变量
    const final_lib_path = if (rknpu2_lib) |env_dir| env_dir else lib_path;
    const final_include_path = "runtime/include";

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
