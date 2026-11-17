//! An app of a project on this Mac changed as the dashboard changes one on Cloud: its name
//! and path written into its `app.zon`, or its folder moved to `.removed-apps`, kept whole.
//! The project's server is told with `publr apps load` by the caller.

const std = @import("std");

pub const Problem = error{
    /// No name, or a path that is not one an app may have.
    Invalid,
    /// Another app has that path.
    Conflict,
    NotFound,
    Unavailable,
};

/// Paths Publr answers itself: no app is mounted there.
const reserved = [_][]const u8{ "/admin", "/api", "/auth", "/media", "/oauth", "/mcp", "/_publr", "/.well-known" };

/// A path an app may have: `/`, or `/` and lowercase words of letters, digits, `-` and `_`,
/// joined by single slashes, none of Publr's own.
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 128 or path[0] != '/') return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/' or std.mem.indexOf(u8, path, "//") != null) return false;
    for (path[1..]) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '_', '/' => {},
        else => return false,
    };
    for (reserved) |r| {
        if (std.mem.eql(u8, path, r) or (std.mem.startsWith(u8, path, r) and path[r.len] == '/')) return false;
    }
    return true;
}

/// `name` and `path` for the app in `apps/<app>` of `folder`.
pub fn update(io: std.Io, gpa: std.mem.Allocator, folder: []const u8, app: []const u8, name: []const u8, path: []const u8) Problem!void {
    const label = std.mem.trim(u8, name, " \t");
    if (label.len == 0 or label.len > 64 or std.mem.indexOfAny(u8, label, "\"\\\n") != null) return error.Invalid;
    if (!validPath(path)) return error.Invalid;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    try noOtherAt(io, a, folder, app, path);
    const file = std.fs.path.join(a, &.{ folder, "apps", app, "app.zon" }) catch return error.Unavailable;
    const text = cwd.readFileAlloc(io, file, a, .limited(64 << 10)) catch return error.NotFound;
    const named = setString(a, text, ".label", label, ".name") catch return error.Unavailable;
    const moved = setPath(a, named, path) catch |e| return switch (e) {
        error.Invalid => error.Invalid,
        else => error.Unavailable,
    };
    const temporary = std.fs.path.join(a, &.{ folder, "apps", app, ".app.zon.tmp" }) catch return error.Unavailable;
    cwd.writeFile(io, .{
        .sub_path = temporary,
        .data = moved,
    }) catch return error.Unavailable;
    cwd.rename(temporary, cwd, file, io) catch return error.Unavailable;
}

/// The app's folder moved to the project's `.removed-apps`, under a name of its own.
pub fn remove(io: std.Io, gpa: std.mem.Allocator, folder: []const u8, app: []const u8) Problem!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const from = std.fs.path.join(a, &.{ folder, "apps", app }) catch return error.Unavailable;
    cwd.access(io, from, .{}) catch return error.NotFound;
    const kept = std.fs.path.join(a, &.{ folder, ".removed-apps" }) catch return error.Unavailable;
    cwd.createDirPath(io, kept) catch return error.Unavailable;
    var random: [8]u8 = undefined;
    io.random(&random);
    const to = std.fmt.allocPrint(a, "{s}/{s}-{x}", .{ kept, app, random }) catch return error.Unavailable;
    cwd.rename(from, cwd, to, io) catch return error.Unavailable;
}

/// No other app of the project has `path`.
fn noOtherAt(io: std.Io, a: std.mem.Allocator, folder: []const u8, app: []const u8, path: []const u8) Problem!void {
    const apps = std.fs.path.join(a, &.{ folder, "apps" }) catch return error.Unavailable;
    var dir = std.Io.Dir.cwd().openDir(io, apps, .{ .iterate = true }) catch return error.NotFound;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.' or std.mem.eql(u8, entry.name, app)) continue;
        const file = std.fs.path.join(a, &.{ apps, entry.name, "app.zon" }) catch continue;
        const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(64 << 10)) catch continue;
        const mount = std.mem.indexOf(u8, text, ".mount") orelse continue;
        if (std.mem.indexOf(u8, text[mount..], ".subdomain") != null) continue;
        const other = stringAfter(text[mount..], ".path") orelse "/";
        if (std.mem.eql(u8, other, path)) return error.Conflict;
    }
}

/// The value of the first `field = "..."` in `text`.
fn stringAfter(text: []const u8, field: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, field) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, at + field.len, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return null;
    return text[open + 1 .. close];
}

/// `text` with `field`'s string set to `value`; a file without the field gets it on a line of
/// its own after `after`'s.
fn setString(a: std.mem.Allocator, text: []const u8, field: []const u8, value: []const u8, after: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, field)) |at| {
        const open = std.mem.indexOfScalarPos(u8, text, at + field.len, '"') orelse return error.Invalid;
        const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return error.Invalid;
        return std.mem.concat(a, u8, &.{ text[0 .. open + 1], value, text[close..] });
    }
    const at = std.mem.indexOf(u8, text, after) orelse return error.Invalid;
    const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return error.Invalid;
    const line = try std.fmt.allocPrint(a, "\n    {s} = \"{s}\",", .{ field, value });
    return std.mem.concat(a, u8, &.{ text[0..line_end], line, text[line_end..] });
}

/// `text` with its mount's path set to `path`. An app on a subdomain has no path to change.
fn setPath(a: std.mem.Allocator, text: []const u8, path: []const u8) ![]const u8 {
    const mount = std.mem.indexOf(u8, text, ".mount") orelse {
        // No mount is `/`: one is written when it moves.
        if (std.mem.eql(u8, path, "/")) return text;
        const at = std.mem.indexOf(u8, text, ".name") orelse return error.Invalid;
        const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return error.Invalid;
        const line = try std.fmt.allocPrint(a, "\n    .mount = .{{ .path = \"{s}\" }},", .{path});
        return std.mem.concat(a, u8, &.{ text[0..line_end], line, text[line_end..] });
    };
    if (std.mem.indexOf(u8, text[mount..], ".subdomain") != null) return error.Invalid;
    const at = std.mem.indexOf(u8, text[mount..], ".path") orelse return error.Invalid;
    const start = mount + at;
    const open = std.mem.indexOfScalarPos(u8, text, start + ".path".len, '"') orelse return error.Invalid;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return error.Invalid;
    return std.mem.concat(a, u8, &.{ text[0 .. open + 1], path, text[close..] });
}

test "an app's name and path are written into its app.zon" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\.{
        \\    .name = "www",
        \\    .mount = .{ .path = "/" },
        \\}
        \\
    ;
    const named = try setString(a, text, ".label", "Shop", ".name");
    try std.testing.expect(std.mem.indexOf(u8, named, ".label = \"Shop\",") != null);
    const moved = try setPath(a, named, "/shop");
    try std.testing.expect(std.mem.indexOf(u8, moved, ".path = \"/shop\"") != null);
    const renamed = try setString(a, moved, ".label", "Store", ".name");
    try std.testing.expect(std.mem.indexOf(u8, renamed, ".label = \"Store\",") != null);
    try std.testing.expect(validPath("/"));
    try std.testing.expect(validPath("/blog/news"));
    try std.testing.expect(!validPath("/admin"));
    try std.testing.expect(!validPath("/admin/x"));
    try std.testing.expect(validPath("/administration"));
    try std.testing.expect(!validPath("blog"));
    try std.testing.expect(!validPath("/Blog"));
    try std.testing.expect(!validPath("/blog/"));
}
