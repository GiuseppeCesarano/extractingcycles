const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const bench_step = b.step("benchmark", "Benchmark bmi, hybrid and simdzone");
    const test_step = b.step("test", "Test bmi, hybrid and simdzone");

    const cpu = target.result.cpu;
    if (cpu.arch != .x86_64 or !std.Target.x86.featureSetHasAll(cpu.features, .{ .bmi2, .sse4_1, .avx2 })) {
        const fail = b.addFail("needs an x86_64 target with BMI2, SSE4.1 and AVX2");
        bench_step.dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        return;
    }

    const benchmark = parsersModule(b, target, .ReleaseFast, "benchmark.zig");
    const exe = b.addExecutable(.{ .name = "benchmark", .root_module = benchmark });
    bench_step.dependOn(&b.addRunArtifact(exe).step);

    const tests = b.addTest(.{ .root_module = parsersModule(b, target, .ReleaseSafe, "test.zig") });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn parsersModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, root: []const u8) *std.Build.Module {
    const bmi = b.createModule(.{
        .root_source_file = b.path("bmiParseIPV4.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hybrid = b.createModule(.{
        .root_source_file = b.path("hybridParseIPV4.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "bmi", .module = bmi },
            .{ .name = "hybrid", .module = hybrid },
        },
    });
    // includes simdzoneIp4.c
    module.addCSourceFile(.{ .file = b.path("simdzoneRegs.c"), .flags = &.{"-O3"} });
    return module;
}
