//! A project elsewhere (Publr Cloud, or any Publr), through its own interfaces: its apps,
//! read over REST with this computer's device token for it, and the project cloned to this
//! Mac by the `publr` command. Both run off the main thread.

const std = @import("std");
const core = @import("publr_cli");
const project = @import("project.zig");

const reply_bytes_max: u32 = 1 << 20;
const apps_max: u32 = 64;

/// This computer's device token for `address`, from the command's sign-ins; null when it
/// has none.
pub fn tokenFor(
    io: std.Io,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    address: []const u8,
) ?[]const u8 {
    const path = blk: {
        if (env.get("PUBLR_CREDENTIALS")) |own| if (own.len > 0) break :blk own;
        const root = core.config.root_of(arena, env) catch return null;
        break :blk std.fs.path.join(arena, &.{ root, core.credentials.file_name }) catch return null;
    };
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(core.credentials.file_bytes_max)) catch return null;
    const File = struct {
        sites: []const core.credentials.Site = &.{},
    };
    const file = std.json.parseFromSliceLeaky(File, arena, text, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const wanted = (core.credentials.normalize(arena, address) catch return null) orelse return null;
    for (file.sites) |site| {
        if (std.mem.eql(u8, site.address, wanted)) return site.token;
    }
    return null;
}

/// The project's apps, as its Publr lists them (`apps.files`, then each `app.zon` by
/// `apps.read`). Empty when it cannot be reached or refuses.
pub fn apps(io: std.Io, arena: std.mem.Allocator, address: []const u8, token: []const u8) []project.App {
    const base = std.mem.trimEnd(u8, address, "/");
    const Files = struct {
        files: []const struct {
            path: []const u8,
        } = &.{},
    };
    const listed = call(Files, io, arena, base, "apps.files", "{}", token) orelse return &.{};
    var found: std.ArrayList(project.App) = .empty;
    for (listed.files) |file| {
        // `<app>/app.zon`, one level down.
        const slash = std.mem.indexOfScalar(u8, file.path, '/') orelse continue;
        if (!std.mem.eql(u8, file.path[slash + 1 ..], "app.zon")) continue;
        if (found.items.len == apps_max) break;
        const Read = struct {
            content: []const u8 = "",
        };
        const body = std.json.Stringify.valueAlloc(arena, .{ .path = file.path }, .{}) catch continue;
        const read = call(Read, io, arena, base, "apps.read", body, token) orelse continue;
        found.append(arena, project.appOf(arena, file.path[0..slash], read.content, base)) catch break;
    }
    project.sortApps(found.items);
    return found.items;
}

fn call(
    comptime Out: type,
    io: std.Io,
    arena: std.mem.Allocator,
    base: []const u8,
    operation: []const u8,
    body: []const u8,
    token: []const u8,
) ?Out {
    const url = std.fmt.allocPrint(arena, "{s}/api/{s}", .{ base, operation }) catch return null;
    const reply = core.remote.post(io, arena, .{
        .url = url,
        .payload = body,
        .token = token,
    }) catch return null;
    if (reply.status != .ok or reply.body.len > reply_bytes_max) return null;
    return std.json.parseFromSliceLeaky(Out, arena, reply.body, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

/// The last line of `text` with something on it: what a failed command said last.
pub fn lastLine(text: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, " \r\n\t"), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

test "a failed command's last line" {
    try std.testing.expectEqualStrings("publr: NotFound", lastLine("cloning…\npublr: NotFound\n\n"));
    try std.testing.expectEqualStrings("", lastLine("\n \n"));
}
