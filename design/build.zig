const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.dependency("platform", .{
        .target = target,
        .optimize = optimize,
    });
    // The engine as `platform` has it (its `ui` draws with it): one copy in the build.
    const engine = platform.builder.dependency("publr_engine", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "publr-design",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "publr_engine",
                    .module = engine.module("publr_engine"),
                },
                .{
                    .name = "platform",
                    .module = platform.module("platform"),
                },
                .{
                    .name = "ui",
                    .module = platform.module("ui"),
                },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Open the native viewer").dependOn(&run.step);

    // Publr's tidy, with only the options rule: optional parameters are one trailing
    // `options: Options` whose fields all have defaults.
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../../publr/scripts/tidy.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tidy = b.addRunArtifact(tidy);
    run_tidy.addArgs(&.{ "--only=options", "build.zig", "src" });
    run_tidy.setCwd(b.path("."));
    run_tidy.has_side_effects = true;
    b.step("tidy", "Check the options rule").dependOn(&run_tidy.step);
}
