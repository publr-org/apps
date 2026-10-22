const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // wgpu-native: the WebGPU C API, prebuilt (fetched by build.zig.zon), linked statically.
    const wgpu_pkg = b.lazyDependency("wgpu_macos_aarch64", .{}) orelse return;
    const wgpu_c = b.addTranslateC(.{
        .root_source_file = b.path("src/wgpu.h"),
        .target = target,
        .optimize = optimize,
    });
    wgpu_c.addIncludePath(wgpu_pkg.path("include"));
    const wgpu = wgpu_c.addModule("wgpu");
    wgpu.addObjectFile(wgpu_pkg.path("lib/libwgpu_native.a"));
    for ([_][]const u8{ "Metal", "QuartzCore", "Foundation", "CoreGraphics", "IOSurface" }) |f| wgpu.linkFramework(f, .{});

    // The platform layer: app, windows, input, menus, frame timing, GPU surface, web view.
    const native = b.addModule("native", .{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{
            .name = "wgpu",
            .module = wgpu,
        }},
    });
    for ([_][]const u8{ "AppKit", "WebKit", "QuartzCore", "CoreGraphics", "Security" }) |f| native.linkFramework(f, .{});

    // Our own-drawn UI, on PublrEngine: boxes, text, icons, and their frame on a GPU surface.
    const engine = b.dependency("publr_engine", .{
        .target = target,
        .optimize = optimize,
    });
    const ui = b.addModule("ui", .{
        .root_source_file = b.path("src/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "native",
                .module = native,
            },
            .{
                .name = "publr_engine",
                .module = engine.module("publr_engine"),
            },
        },
    });
    const ui_tests = b.addTest(.{
        .root_module = ui,
    });
    // The tests read every Publr icon.
    ui.addImport("publr_icons", b.dependency("publr_icons", .{}).module("publr_icons"));
    const test_step = b.step("test", "Unit tests and tidy");
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    // Publr's tidy, with only the options rule: optional parameters are one trailing
    // `options: Options` whose fields all have defaults.
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../publr/scripts/tidy.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tidy = b.addRunArtifact(tidy);
    run_tidy.addArgs(&.{ "--only=options", "build.zig", "src", "examples" });
    run_tidy.setCwd(b.path("."));
    run_tidy.has_side_effects = true;
    b.step("tidy", "Check the options rule").dependOn(&run_tidy.step);
    test_step.dependOn(&run_tidy.step);

    // `zig build uicheck`: the UI on the GPU against the CPU, and frame times.
    const uicheck = b.addExecutable(.{
        .name = "uicheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/uicheck.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "native",
                    .module = native,
                },
                .{
                    .name = "ui",
                    .module = ui,
                },
                .{
                    .name = "publr_engine",
                    .module = engine.module("publr_engine"),
                },
            },
        }),
    });
    b.step("uicheck", "The UI on the GPU against the CPU, and frame times").dependOn(&b.addRunArtifact(uicheck).step);

    // `zig build demo`: a window with a GPU clear and input printed, to check the layer.
    const demo = b.addExecutable(.{
        .name = "native-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "native",
                    .module = native,
                },
                .{
                    .name = "wgpu",
                    .module = wgpu,
                },
            },
        }),
    });
    b.installArtifact(demo);
    const run = b.addRunArtifact(demo);
    b.step("demo", "Run the demo window").dependOn(&run.step);
}

pub const BundleOptions = struct {
    version: []const u8 = "0.0.0",
    /// The oldest macOS it runs on (the display link needs 14).
    min_macos: []const u8 = "14.0",
};

/// A macOS `.app` around `exe`, installed to `zig-out/<name>.app`: Info.plist and the
/// executable. `name` is the name people see ("Publr Studio") and the bundle's folder name;
/// `id` is the reverse-DNS identifier ("app.publr.studio"). Signing and notarising come
/// later, with releases.
pub fn addAppBundle(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    name: []const u8,
    id: []const u8,
    options: BundleOptions,
) *std.Build.Step {
    const files = b.addWriteFiles();
    const plist = files.add("Info.plist", b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleName</key><string>{[name]s}</string>
        \\  <key>CFBundleDisplayName</key><string>{[name]s}</string>
        \\  <key>CFBundleIdentifier</key><string>{[id]s}</string>
        \\  <key>CFBundleExecutable</key><string>{[exe]s}</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>{[version]s}</string>
        \\  <key>CFBundleVersion</key><string>{[version]s}</string>
        \\  <key>LSMinimumSystemVersion</key><string>{[min]s}</string>
        \\  <key>NSPrincipalClass</key><string>NSApplication</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
        \\  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
        \\</dict>
        \\</plist>
        \\
    , .{
        .name = name,
        .id = id,
        .exe = exe.name,
        .version = options.version,
        .min = options.min_macos,
    }));
    const app_dir = b.fmt("{s}.app/Contents", .{name});
    const install_plist = b.addInstallFile(plist, b.fmt("{s}/Info.plist", .{app_dir}));
    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{
            .override = .{
                .custom = b.fmt("{s}/MacOS", .{app_dir}),
            },
        },
    });
    const step = b.step("app", b.fmt("Build {s}.app in zig-out", .{name}));
    step.dependOn(&install_plist.step);
    step.dependOn(&install_exe.step);
    return step;
}
