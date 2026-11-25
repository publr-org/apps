const std = @import("std");
const platform_build = @import("platform");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.dependency("platform", .{
        .target = target,
        .optimize = optimize,
    });
    // The `publr` command's core (sites, servers, releases, sign-on), and the command itself,
    // which Desktop carries beside its executable: the helper and sync run it. The compiler
    // it carries takes minutes to build: a release passes the archive built before.
    const toolchain = b.option([]const u8, "toolchain-archive", "The archive of the compiler the publr command carries (cli's -Dtoolchain-archive)");
    const cli = if (toolchain) |archive| b.dependency("publr_cli", .{
        .target = target,
        .optimize = optimize,
        .@"toolchain-archive" = archive,
    }) else b.dependency("publr_cli", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "publr-desktop-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "platform",
                    .module = platform.module("platform"),
                },
                .{
                    .name = "ui",
                    .module = platform.module("ui"),
                },
                .{
                    // The same engine `ui` draws with (taken through native, so the build
                    // sees one copy).
                    .name = "publr_engine",
                    .module = platform.builder.dependency("publr_engine", .{
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
                .{
                    .name = "publr_api",
                    .module = cli.builder.dependency("publr_api", .{
                        .target = target,
                        .optimize = optimize,
                    }).module("publr_api"),
                },
            },
        }),
    });
    add_languages(b, exe.root_module, target, optimize);
    add_build_info(b, exe.root_module);
    b.installArtifact(exe);
    // Beside Desktop in zig-out/bin too, so `zig build run` finds it as the app does.
    b.installArtifact(cli.artifact("publr"));
    const app = platform_build.addAppBundle(b, exe, "Publr Desktop", "app.publr.desktop", .{
        .version = @import("build.zig.zon").version,
        .icon = b.path("assets/AppIcon.icns"),
    });
    const bundled = b.addInstallArtifact(cli.artifact("publr"), .{
        .dest_dir = .{
            .override = .{
                .custom = "Publr Desktop.app/Contents/MacOS",
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
            .root_source_file = b.path("../../publr/scripts/tidy.zig"),
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
    b.step("run", "Open Publr Desktop").dependOn(&run.step);

    add_web(b, optimize);
}

/// `build_info.version`: build.zig.zon's, the version Desktop says it is and updates from.
fn add_build_info(b: *std.Build, module: *std.Build.Module) void {
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    module.addOptions("build_info", options);
}

/// Desktop's words in other languages: Publr's own catalogue (PO files, plural rules), and
/// one PO file per language, `i18n/<language>.po`.
fn add_languages(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    module.addImport("publr_i18n", b.createModule(.{
        .root_source_file = b.path("../../publr/src/model/i18n/catalog.zig"),
        .target = target,
        .optimize = optimize,
    }));
    module.addAnonymousImport("desktop_pl", .{
        .root_source_file = b.path("i18n/pl.po"),
    });
}

/// `zig build web`: Desktop for a browser page (wasm32-wasi), `zig-out/web/publr-desktop.wasm`,
/// run by publr.app's guide (`.agents/specs/publr-desktop-web.md`).
fn add_web(b: *std.Build, optimize: std.builtin.Optimize) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const platform = b.dependency("platform", .{
        .target = target,
        .optimize = optimize,
    });
    const cli = b.dependency("publr_cli", .{
        .target = target,
        .optimize = optimize,
    });
    const wasm = b.addExecutable(.{
        .name = "publr-desktop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "platform",
                    .module = platform.module("platform"),
                },
                .{
                    .name = "ui",
                    .module = platform.module("ui"),
                },
                .{
                    .name = "publr_engine",
                    .module = platform.builder.dependency("publr_engine", .{
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
                .{
                    .name = "publr_api",
                    .module = cli.builder.dependency("publr_api", .{
                        .target = target,
                        .optimize = optimize,
                    }).module("publr_api"),
                },
            },
        }),
    });
    add_languages(b, wasm.root_module, target, optimize);
    add_build_info(b, wasm.root_module);
    // The page calls the backend's `desktop_*` functions.
    wasm.rdynamic = true;
    const install = b.addInstallArtifact(wasm, .{
        .dest_dir = .{
            .override = .{
                .custom = "web",
            },
        },
    });
    const web = b.step("web", "Publr Desktop for a browser page");
    web.dependOn(&install.step);
    // Beside it, what the page runs it with: the backend's page half and Publr's WASI files.
    web.dependOn(&b.addInstallFile(platform.path("src/web/desktop.js"), "web/desktop.js").step);
    web.dependOn(&b.addInstallFile(b.path("../../publr/browser/publr-files.js"), "web/publr-files.js").step);
}
