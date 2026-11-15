const std = @import("std");
const native_build = @import("native");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.dependency("native", .{
        .target = target,
        .optimize = optimize,
    });
    // The `publr` command's core (sites, servers, releases, sign-on), and the command itself,
    // which Studio carries beside its executable: the helper and sync run it.
    const cli = b.dependency("publr_cli", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "publr-studio-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "native",
                    .module = native.module("native"),
                },
                .{
                    .name = "ui",
                    .module = native.module("ui"),
                },
                .{
                    // The same engine `ui` draws with (taken through native, so the build
                    // sees one copy).
                    .name = "publr_engine",
                    .module = native.builder.dependency("publr_engine", .{
                        .target = target,
                        .optimize = optimize,
                    }).module("publr_engine"),
                },
                .{
                    .name = "publr_icons",
                    .module = b.dependency("publr_icons", .{}).module("publr_icons"),
                },
                .{
                    .name = "publr_cli",
                    .module = cli.module("publr_cli"),
                },
            },
        }),
    });
    b.installArtifact(exe);
    // Beside Studio in zig-out/bin too, so `zig build run` finds it as the app does.
    b.installArtifact(cli.artifact("publr"));
    const app = native_build.addAppBundle(b, exe, "Publr Studio", "app.publr.studio", .{
        .icon = b.path("assets/AppIcon.icns"),
    });
    const bundled = b.addInstallArtifact(cli.artifact("publr"), .{
        .dest_dir = .{
            .override = .{
                .custom = "Publr Studio.app/Contents/MacOS",
            },
        },
    });
    app.dependOn(&bundled.step);

    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const test_step = b.step("test", "Unit tests and tidy");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Publr's tidy, with only the options rule: optional parameters are one trailing
    // `options: Options` whose fields all have defaults.
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../publr/scripts/tidy.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const run_tidy = b.addRunArtifact(tidy);
    run_tidy.addArgs(&.{ "--only=options", "build.zig", "src" });
    run_tidy.setCwd(b.path("."));
    run_tidy.has_side_effects = true;
    b.step("tidy", "Check the options rule").dependOn(&run_tidy.step);
    test_step.dependOn(&run_tidy.step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Open Publr Studio").dependOn(&run.step);
}
