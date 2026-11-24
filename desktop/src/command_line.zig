//! Terminal's `publr`: Desktop carries the command and puts it on the PATH each time it
//! starts, the way its install script does (`cli/install.sh`): `~/.local/bin/publr` a link to
//! the one inside the app, and that folder added to the shell's profile once. Nothing to
//! press. A `publr` installed another way there (a file, not a link) is left as it is.

const std = @import("std");

const profile_bytes_max = 1 << 20;

pub fn ensure(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
    const home = env.get("HOME") orelse return;
    const dir = std.process.executableDirPathAlloc(io, gpa) catch return;
    defer gpa.free(dir);
    const bundled = std.fs.path.join(gpa, &.{ dir, "publr" }) catch return;
    defer gpa.free(bundled);
    // Run from a build with no command beside it: nothing to put on the PATH.
    std.Io.Dir.cwd().access(io, bundled, .{}) catch return;
    const bin = std.fs.path.join(gpa, &.{ home, ".local", "bin" }) catch return;
    defer gpa.free(bin);

    link(gpa, io, bundled, bin) catch |e| std.debug.print("desktop: linking publr: {t}\n", .{e});
    addToProfile(gpa, io, env, home, bin) catch |e| {
        std.debug.print("desktop: adding publr to the PATH: {t}\n", .{e});
    };
}

/// `bin/publr` a link to `bundled`: made, or moved there from an older Desktop.
fn link(gpa: std.mem.Allocator, io: std.Io, bundled: []const u8, bin: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const at = try std.fs.path.join(gpa, &.{ bin, "publr" });
    defer gpa.free(at);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    if (cwd.readLink(io, at, &buffer)) |length| {
        if (std.mem.eql(u8, buffer[0..length], bundled)) return;
        try cwd.deleteFile(io, at);
    } else |err| switch (err) {
        error.FileNotFound => {},
        // A `publr` put there another way, as the install script copies it: left as it is.
        error.NotLink => return,
        else => return err,
    }

    try cwd.createDirPath(io, bin);
    try cwd.symLink(io, bundled, at, .{});
}

/// The line the install script adds, added to the shell's profile once: zsh's `.zshrc` or
/// bash's `.bashrc`; one that already names `.local/bin` is left as it is.
fn addToProfile(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    home: []const u8,
    bin: []const u8,
) !void {
    const shell = env.get("SHELL") orelse return;
    const name = if (std.mem.endsWith(u8, shell, "/zsh"))
        ".zshrc"
    else if (std.mem.endsWith(u8, shell, "/bash"))
        ".bashrc"
    else
        return;
    const cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(gpa, &.{ home, name });
    defer gpa.free(path);
    const text = cwd.readFileAlloc(io, path, gpa, .limited(profile_bytes_max)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
    defer gpa.free(text);

    if (std.mem.indexOf(u8, text, ".local/bin") != null) return;

    const added = try std.fmt.allocPrint(gpa, "{s}\n# publr\nexport PATH=\"{s}:$PATH\"\n", .{
        text,
        bin,
    });
    defer gpa.free(added);

    try cwd.writeFile(io, .{
        .sub_path = path,
        .data = added,
    });
}
