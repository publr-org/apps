//! Desktop's own updates. Each start (and Settings' Check for updates) asks for the newest
//! release, off the main thread; one newer than this Desktop is downloaded, checked against
//! Publr's signed checksums (the key Publr's and the command's updates trust) and against
//! the Developer ID it is signed with, then laid beside the app and swapped in. The running
//! Desktop carries on as it was; the next start is the new one, or now with Restart to
//! update. Nothing here ever waits on the network on the main thread.
//!
//! A release is the apps repository's `desktop-v<version>` (the repository holds the other
//! apps' releases too), with `Publr-Desktop-<version>-<os>-<cpu>.<ext>` for every platform
//! and one `SHA256SUMS` and `SHA256SUMS.sig` over them (`.github/workflows/desktop-release.yml`).
//! Where releases are listed and fetched from: `DESKTOP_RELEASES_LIST` and
//! `DESKTOP_RELEASES_URL` change it (for tests).
//!
//! An app Desktop cannot replace (in a folder this account cannot write, run from the disk
//! image, or moved aside by macOS) is told about the release and links to its download.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const core = @import("publr_cli");
const build_info = @import("build_info");

pub const version = build_info.version;
pub const repository = "publr-org/apps";
/// Desktop's releases among the repository's: `desktop-v0.2.0`.
const tag_prefix = "desktop-v";
/// The newest releases first; Desktop's newest is among them unless the other apps made
/// a hundred releases since.
const list_default = "https://api.github.com/repos/" ++ repository ++ "/releases?per_page=100";
const downloads_default = "https://github.com/" ++ repository ++ "/releases/download";
const page_default = "https://github.com/" ++ repository ++ "/releases?q=" ++ tag_prefix;
/// The Developer ID team Desktop is signed by; an update signed by any other is refused.
const team = "8RHXG5NFYU";
const app_name = "Publr Desktop.app";
const image_bytes_max = 256 << 20;

pub const State = enum {
    /// Not asked yet, or this build has no updates (one built from source).
    idle,
    checking,
    up_to_date,
    downloading,
    /// The newer release is in place: the next start runs it.
    ready,
    /// A newer release is out, and this app cannot be replaced from here.
    available,
    /// A newer release is out, but it needs a newer macOS than this Mac's: not installed.
    unsupported,
    failed,
};

pub const Updater = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    state: State = .idle,
    /// The newer release's version, once known.
    newer: []const u8 = "",
    /// What went wrong last, for the log.
    problem: []const u8 = "",
    /// The macOS the newer release needs, and this Mac's, when it needs a newer one.
    needs: []const u8 = "",
    has: []const u8 = "",
    /// This app's folder (`/Applications/Publr Desktop.app`); empty when not run as an app.
    bundle: []const u8 = "",
    /// Called on the main thread when the state changes.
    changed: *const fn () void,

    /// Finds this app's folder and clears what an earlier update left aside.
    pub fn init(self: *Updater) void {
        if (comptime builtin.os.tag != .macos) return;
        self.bundle = bundleOf(self.gpa, self.io) orelse "";
        if (self.bundle.len == 0) return;
        const aside = sibling(self.gpa, self.bundle, ".old") catch return;
        defer self.gpa.free(aside);
        std.Io.Dir.cwd().deleteTree(self.io, aside) catch {};
    }

    /// Whether this Desktop takes updates: a release build run as an app.
    pub fn enabled(self: *const Updater) bool {
        if (comptime builtin.os.tag != .macos) return false;
        return self.bundle.len > 0 and !std.mem.eql(u8, version, "0.0.0");
    }

    /// Asks for the newest release, and takes it when it is newer.
    pub fn check(self: *Updater) void {
        if (comptime builtin.os.tag != .macos) return;
        if (!self.enabled()) return;
        switch (self.state) {
            .checking, .downloading, .ready => return,
            else => {},
        }
        self.state = .checking;
        platform.spawn(Job.run, .{self}) catch {
            self.state = .failed;
        };
    }

    /// Starts the new Desktop once this one has quit, then quits.
    pub fn restart(self: *Updater) void {
        if (comptime builtin.os.tag != .macos) return;
        if (self.state != .ready) return;
        var pid_buffer: [16]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buffer, "{d}", .{std.c.getpid()}) catch return;
        // A shell of its own, in a process group of its own so it outlives this process
        // (and whatever started it): it waits for this one to end, then opens the app at the
        // same place.
        _ = std.process.spawn(self.io, .{
            .argv = &.{
                "/bin/sh",
                "-c",
                "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
                "sh",
                pid,
                self.bundle,
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch return;
        platform.quit();
    }

    /// Where the release can be downloaded by hand.
    pub fn page(self: *const Updater) []const u8 {
        return self.env.get("DESKTOP_RELEASES_PAGE") orelse page_default;
    }
};

const Job = struct {
    fn run(self: *Updater) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const outcome = take(self, arena.allocator()) catch |e| blk: {
            self.problem = @errorName(e);
            std.debug.print("desktop: update: {t}\n", .{e});
            break :blk State.failed;
        };
        Done.post(self, outcome);
    }
};

/// The state handed back on the main thread.
const Done = struct {
    updater: *Updater,
    state: State,

    fn post(updater: *Updater, state: State) void {
        const done = updater.gpa.create(Done) catch return;
        done.* = .{
            .updater = updater,
            .state = state,
        };
        platform.runOnMain(done, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Done = @ptrCast(@alignCast(ctx));
        defer self.updater.gpa.destroy(self);
        self.updater.state = self.state;
        self.updater.changed();
    }
};

/// The newest release, and when newer: in place (`ready`), or only told of (`available`).
fn take(self: *Updater, arena: std.mem.Allocator) !State {
    const newest = try latest(self, arena);
    const mine = try std.SemanticVersion.parse(version);
    const theirs = std.SemanticVersion.parse(newest) catch return error.BadRelease;
    if (theirs.order(mine) != .gt) return .up_to_date;

    // Read on the main thread only once the state says so.
    self.newer = try self.gpa.dupe(u8, newest);
    if (!replaceable(self)) return .available;
    Done.post(self, .downloading);

    const name = try std.fmt.allocPrint(arena, "Publr-Desktop-{s}-macos-{s}.dmg", .{ newest, cpu() });
    const base = self.env.get("DESKTOP_RELEASES_URL") orelse downloads_default;
    var files: [3][]const u8 = undefined;
    for ([_][]const u8{ name, "SHA256SUMS", "SHA256SUMS.sig" }, 0..) |file, i| {
        const url = try std.fmt.allocPrint(arena, "{s}/" ++ tag_prefix ++ "{s}/{s}", .{ base, newest, file });
        var body: std.Io.Writer.Allocating = .init(arena);
        try core.versions.get(self.io, url, &body.writer);
        if (body.written().len > image_bytes_max) return error.TooBig;
        files[i] = body.written();
    }
    if (core.versions.verified_file(files[0], name, files[1], files[2])) |problem| {
        std.debug.print("desktop: update {s} refused: {s}\n", .{ newest, problem });
        return error.NotVerified;
    }

    install(self, arena, files[0]) catch |e| switch (e) {
        error.NeedsNewerMacOS => return .unsupported,
        else => return e,
    };
    return .ready;
}

/// The newest Desktop release's version, from where releases are listed: the highest
/// `desktop-v<version>` that is neither a draft nor a pre-release.
fn latest(self: *Updater, arena: std.mem.Allocator) ![]const u8 {
    const url = self.env.get("DESKTOP_RELEASES_LIST") orelse list_default;
    var body: std.Io.Writer.Allocating = .init(arena);
    try core.versions.get(self.io, url, &body.writer);
    return newestOf(arena, body.written()) orelse error.BadRelease;
}

const Release = struct {
    tag_name: []const u8,
    draft: bool = false,
    prerelease: bool = false,
};

fn newestOf(arena: std.mem.Allocator, listed: []const u8) ?[]const u8 {
    const releases = std.json.parseFromSliceLeaky([]const Release, arena, listed, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    var best: ?[]const u8 = null;
    var best_version: std.SemanticVersion = undefined;
    for (releases) |r| {
        if (r.draft or r.prerelease or !std.mem.startsWith(u8, r.tag_name, tag_prefix)) continue;
        const v = r.tag_name[tag_prefix.len..];
        const parsed = std.SemanticVersion.parse(v) catch continue;
        if (best == null or parsed.order(best_version) == .gt) {
            best = v;
            best_version = parsed;
        }
    }
    return best;
}

/// The disk image's app laid beside this one, its signature checked, then swapped in: this
/// app moved aside (cleared at the next start), the new one renamed into its place.
fn install(self: *Updater, arena: std.mem.Allocator, image: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const work = try sibling(arena, self.bundle, ".update");
    try cwd.deleteTree(self.io, work);
    try cwd.createDirPath(self.io, work);
    defer cwd.deleteTree(self.io, work) catch {};

    const dmg = try std.fs.path.join(arena, &.{ work, "update.dmg" });
    try cwd.writeFile(self.io, .{
        .sub_path = dmg,
        .data = image,
    });
    const mount = try std.fs.path.join(arena, &.{ work, "mount" });
    try cwd.createDirPath(self.io, mount);
    try runChecked(self.io, &.{ "/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dmg });
    const fresh = try sibling(arena, self.bundle, ".new");
    try cwd.deleteTree(self.io, fresh);
    const copied = runChecked(self.io, &.{ "/usr/bin/ditto", try std.fs.path.join(arena, &.{ mount, app_name }), fresh });
    runChecked(self.io, &.{ "/usr/bin/hdiutil", "detach", "-quiet", "-force", mount }) catch {};
    try copied;
    errdefer cwd.deleteTree(self.io, fresh) catch {};

    // Signed by Publr's Developer ID, every part of it, or not taken.
    try runChecked(self.io, &.{
        "/usr/bin/codesign",                                                             "--verify", "--deep", "--strict",
        "-R=anchor apple generic and certificate leaf[subject.OU] = \"" ++ team ++ "\"", fresh,
    });

    // Built for a newer macOS than this Mac's, it would not open: kept out, this app stays.
    try supported(self, arena, fresh);

    const aside = try sibling(arena, self.bundle, ".old");
    try cwd.deleteTree(self.io, aside);
    try cwd.rename(self.bundle, cwd, aside, self.io);
    cwd.rename(fresh, cwd, self.bundle, self.io) catch |e| {
        // Put back as it was.
        cwd.rename(aside, cwd, self.bundle, self.io) catch {};
        return e;
    };
}

/// Whether this app's folder can be swapped: its parent writable, not on the disk image.
fn replaceable(self: *Updater) bool {
    const parent = std.fs.path.dirname(self.bundle) orelse return false;
    // Run from the disk image, or moved aside by macOS (App Translocation): read-only.
    if (std.mem.startsWith(u8, parent, "/Volumes/") or std.mem.indexOf(u8, parent, "/AppTranslocation/") != null) return false;
    std.Io.Dir.cwd().access(self.io, parent, .{
        .write = true,
    }) catch return false;
    return true;
}

/// `/Applications/.Publr Desktop<suffix>.app` for `/Applications/Publr Desktop.app`: hidden,
/// on the same disk, so a rename swaps it.
fn sibling(gpa: std.mem.Allocator, bundle: []const u8, suffix: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(bundle) orelse return error.NoBundle;
    const base = std.fs.path.basename(bundle);
    const stem = if (std.mem.endsWith(u8, base, ".app")) base[0 .. base.len - 4] else base;
    return std.fmt.allocPrint(gpa, "{s}/.{s}{s}.app", .{ parent, stem, suffix });
}

/// The app folder this executable is in (`…/Publr Desktop.app/Contents/MacOS/…`), or null.
fn bundleOf(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const dir = std.process.executableDirPathAlloc(io, gpa) catch return null;
    defer gpa.free(dir);
    const suffix = "/Contents/MacOS";
    if (!std.mem.endsWith(u8, dir, suffix)) return null;
    const bundle = dir[0 .. dir.len - suffix.len];
    if (!std.mem.endsWith(u8, bundle, ".app")) return null;
    return gpa.dupe(u8, bundle) catch null;
}

fn cpu() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "unsupported",
    };
}

fn runChecked(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

test newestOf {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const listed =
        \\[{"tag_name":"design-v0.9.0"},{"tag_name":"desktop-v0.3.0","draft":true},
        \\ {"tag_name":"desktop-v0.2.1-beta","prerelease":true},{"tag_name":"desktop-v0.2.0"},
        \\ {"tag_name":"desktop-v0.10.0"},{"tag_name":"desktop-vx"}]
    ;
    try std.testing.expectEqualStrings("0.10.0", newestOf(arena.allocator(), listed).?);
    try std.testing.expect(newestOf(arena.allocator(), "[]") == null);
}

test sibling {
    const gpa = std.testing.allocator;
    const got = try sibling(gpa, "/Applications/Publr Desktop.app", ".new");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Applications/.Publr Desktop.new.app", got);
}

/// Every program in `app` (`Contents/MacOS`) opens on this Mac: none needs a newer macOS than
/// it runs. Read from the programs themselves, as macOS does when it opens them, not from
/// Info.plist, which a build can get wrong.
fn supported(self: *Updater, arena: std.mem.Allocator, app: []const u8) !void {
    const has = try macosVersion();
    const programs = try std.fs.path.join(arena, &.{ app, "Contents", "MacOS" });
    var dir = try std.Io.Dir.cwd().openDir(self.io, programs, .{ .iterate = true });
    defer dir.close(self.io);
    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try dir.readFileAlloc(self.io, entry.name, arena, .limited(image_bytes_max));
        const needs = minimumOf(bytes) orelse continue;
        if (needs.order(has) == .gt) {
            self.needs = try std.fmt.allocPrint(self.gpa, "{d}.{d}", .{ needs.major, needs.minor });
            self.has = try std.fmt.allocPrint(self.gpa, "{d}.{d}", .{ has.major, has.minor });
            return error.NeedsNewerMacOS;
        }
    }
}

/// This Mac's macOS version (`kern.osproductversion`: 26.2).
fn macosVersion() !std.SemanticVersion {
    var buffer: [32]u8 = undefined;
    var len: usize = buffer.len;
    if (std.c.sysctlbyname("kern.osproductversion", &buffer, &len, null, 0) != 0) return error.UnknownMacOS;
    const text = std.mem.sliceTo(buffer[0..len], 0);
    return parseMacOS(text) orelse error.UnknownMacOS;
}

/// `26`, `26.2` or `26.2.1` as a version, the parts left out zero.
fn parseMacOS(text: []const u8) ?std.SemanticVersion {
    var parts = std.mem.splitScalar(u8, text, '.');
    var numbers: [3]usize = .{ 0, 0, 0 };
    for (&numbers) |*n| {
        const part = parts.next() orelse break;
        n.* = std.fmt.parseInt(usize, part, 10) catch return null;
    }
    return .{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2] };
}

/// The oldest macOS a 64-bit Mach-O program opens on (LC_BUILD_VERSION, or the older
/// LC_VERSION_MIN_MACOSX); null for anything else.
fn minimumOf(bytes: []const u8) ?std.SemanticVersion {
    const header_len = 32;
    if (bytes.len < header_len) return null;
    if (std.mem.readInt(u32, bytes[0..4], .little) != 0xfeedfacf) return null;
    const commands = std.mem.readInt(u32, bytes[16..20], .little);
    var at: usize = header_len;
    for (0..commands) |_| {
        if (at + 16 > bytes.len) return null;
        const command = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const encoded = switch (command) {
            0x32 => std.mem.readInt(u32, bytes[at + 12 ..][0..4], .little),
            0x24 => std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little),
            else => null,
        };
        if (encoded) |v| return .{ .major = v >> 16, .minor = (v >> 8) & 0xff, .patch = v & 0xff };
        if (size < 8) return null;
        at += size;
    }
    return null;
}

test "a program's minimum macOS is read from its build version" {
    var bytes: [56]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0xfeedfacf, .little);
    std.mem.writeInt(u32, bytes[16..20], 1, .little);
    std.mem.writeInt(u32, bytes[32..36], 0x32, .little);
    std.mem.writeInt(u32, bytes[36..40], 24, .little);
    std.mem.writeInt(u32, bytes[44..48], (26 << 16) | (7 << 8) | 2, .little);
    const needs = minimumOf(&bytes).?;
    try std.testing.expectEqual(@as(usize, 26), needs.major);
    try std.testing.expectEqual(@as(usize, 7), needs.minor);
    try std.testing.expect(needs.order(parseMacOS("26.2").?) == .gt);
    try std.testing.expect(parseMacOS("15.0").?.order(parseMacOS("26.2").?) == .lt);
    try std.testing.expect(minimumOf("not a program") == null);
}
