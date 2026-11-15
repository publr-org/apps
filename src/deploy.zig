//! Deploying a local site to Publr Cloud, off the main thread: `publr deploy`, the command
//! Studio carries, run in the site's folder. It exports the site with its own Publr, uploads
//! it in parts, makes the project at the chosen address and links the folder (`cloud.json`);
//! its `--progress json` lines say how far it is.

const std = @import("std");
const native = @import("native");

pub const Stage = enum(u8) {
    packing,
    uploading,
    starting,
    done,
    failed,
};

/// What the sheet shows while it runs (written by the job, read each frame).
pub const Progress = struct {
    stage: std.atomic.Value(u8) = .init(@intFromEnum(Stage.packing)),
    sent: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),

    pub fn get(p: *const Progress) Stage {
        return @enumFromInt(p.stage.load(.acquire));
    }
};

pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// The `publr` command Studio carries.
    publr: []const u8,
    site_dir: []const u8,
    base: []const u8,
    token: []const u8,
    space: []const u8,
    name: []const u8,
    slug: []const u8,
    progress: *Progress,
    /// The live site's and its admin's addresses, or what went wrong.
    address: []const u8 = "",
    admin: []const u8 = "",
    problem: ?[]const u8 = null,
    project: []const u8 = "",
    project_id: []const u8 = "",
    arena: std.heap.ArenaAllocator,
    done: *const fn (job: *Job) void,
    /// The command's progress page, once it names it; `shown` is called with it on the main
    /// thread.
    page: [:0]const u8 = "",
    shown: *const fn (job: *Job) void,

    pub fn start(self: *Job) !void {
        const t = try std.Thread.spawn(.{}, run, .{self});
        t.detach();
    }

    fn run(self: *Job) void {
        self.steps() catch |e| {
            if (self.problem == null) self.problem = switch (e) {
                error.OutOfMemory => "Studio ran out of memory.",
                else => "Publr Cloud could not be reached.",
            };
        };
        self.progress.stage.store(@intFromEnum(if (self.problem == null) Stage.done else Stage.failed), .release);
        native.runOnMain(self, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.done(self);
    }

    fn pageNamed(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.shown(self);
    }

    /// `publr deploy` in the site's folder, the command Studio carries: it exports the site
    /// with the site's own Publr, uploads it in parts, makes the project and links the
    /// folder (`cloud.json`). Its `--progress json` lines drive the sheet.
    fn steps(self: *Job) !void {
        const a = self.arena.allocator();
        var env = try self.env.clone(a);
        try env.put("PUBLR_CLOUD_TOKEN", self.token);

        var child = try std.process.spawn(self.io, .{
            .argv = &.{
                self.publr, "deploy",
                "--space",  self.space,
                "--slug",   self.slug,
                "--name",   self.name,
                "--cloud",  self.base,
                "--progress", "json",
            },
            .cwd = .{ .path = self.site_dir },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        var buffer: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(self.io, &buffer);
        const Event = struct {
            stage: []const u8 = "",
            done: u64 = 0,
            total: u64 = 0,
            address: []const u8 = "",
            admin: []const u8 = "",
            project: []const u8 = "",
            project_id: []const u8 = "",
            @"error": []const u8 = "",
            message: []const u8 = "",
            url: []const u8 = "",
        };
        var failed: ?Event = null;
        while (reader.interface.takeDelimiter('\n') catch null) |line| {
            const event = std.json.parseFromSliceLeaky(Event, a, line, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch continue;
            // The progress page, shown in the project's tab while the deploy goes on.
            if (std.mem.eql(u8, event.stage, "page") and event.url.len > 0 and self.page.len == 0) {
                self.page = a.dupeZ(u8, event.url) catch continue;
                native.runOnMain(self, pageNamed);
                continue;
            }
            const stage = std.meta.stringToEnum(Stage, event.stage) orelse continue;
            switch (stage) {
                .uploading => {
                    self.progress.total.store(event.total, .release);
                    self.progress.sent.store(event.done, .release);
                },
                .done => {
                    self.address = event.address;
                    self.admin = event.admin;
                    self.project = event.project;
                    self.project_id = event.project_id;
                },
                .failed => failed = event,
                else => {},
            }
            if (stage != .failed) self.progress.stage.store(@intFromEnum(stage), .release);
        }
        var errors: [4096]u8 = undefined;
        var err_reader = child.stderr.?.readerStreaming(self.io, &errors);
        const said = err_reader.interface.allocRemaining(a, .limited(1 << 16)) catch "";
        const term = try child.wait(self.io);
        if (term == .exited and term.exited == 0 and self.address.len > 0) return;
        if (said.len > 0) std.debug.print("studio: publr deploy: {s}\n", .{said});
        if (failed) |f| {
            const known = problemFor(f.@"error");
            self.problem = if (known.len > 0) known else if (f.message.len > 0) f.message else "Publr Cloud did not make the project.";
            return;
        }
        // The command's first line says why; its last only names the error.
        var lines = std.mem.tokenizeScalar(u8, said, '\n');
        const first = std.mem.trim(u8, lines.next() orelse "", " \r\t");
        self.problem = if (first.len > 0) first else "The site could not be deployed.";
    }
};

fn problemFor(code: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "Conflict", "That address was just taken. Pick another." },
        .{ "Invalid", "That address cannot be used. Pick another." },
        .{ "NotFound", "That space is not yours any more." },
        .{ "NoUpload", "The upload was lost. Try again." },
        .{ "NotASite", "Publr Cloud could not read the packed site." },
        .{ "NewerSite", "This site was made by a newer Publr than Publr Cloud runs." },
        .{ "Unverified", "Verify your email address first (Publr Cloud sent you a link)." },
        .{ "TooMany", "You made many projects today. Try again tomorrow." },
        .{ "Unavailable", "Publr Cloud cannot start sites right now. Try again in a moment." },
    };
    for (table) |t| if (std.mem.eql(u8, code, t[0])) return t[1];
    return "";
}

/// The deploy link a folder carries (`cloud.json`), if it was deployed.
pub const Link = struct {
    address: []const u8 = "",
    admin: []const u8 = "",
    slug: []const u8 = "",
};

pub fn readLink(a: std.mem.Allocator, io: std.Io, site_dir: []const u8) ?Link {
    const path = std.fs.path.join(a, &.{ site_dir, "cloud.json" }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(Link, a, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// A job run with `publr` standing in as a script that prints `events` and exits `code`.
fn tryDeploy(events: []const u8, code: u8) !struct { Job, std.heap.ArenaAllocator } {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    const script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\ncat <<'END'\n{s}END\nexit {d}\n", .{ events, code });
    defer std.testing.allocator.free(script);
    try tmp.dir.writeFile(io, .{
        .sub_path = "publr",
        .data = script,
        .flags = .{
            .permissions = .executable_file,
        },
    });
    const folder = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(folder);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const a = arena.allocator();
    const env = try a.create(std.process.Environ.Map);
    env.* = .init(a);
    const progress = try a.create(Progress);
    progress.* = .{};
    var job: Job = .{
        .gpa = std.testing.allocator,
        .io = io,
        .env = env,
        .publr = try std.fs.path.join(a, &.{ folder, "publr" }),
        .site_dir = try a.dupe(u8, folder),
        .base = "http://cloud.test",
        .token = "t",
        .space = "s",
        .name = "n",
        .slug = "x",
        .progress = progress,
        .arena = .init(a),
        .done = undefined,
        .shown = undefined,
    };
    job.steps() catch {};
    return .{ job, arena };
}

test "a deploy follows the command's events: progress, then the project" {
    const job, var arena = try tryDeploy(
        \\{"stage":"packing"}
        \\{"stage":"uploading","done":5,"total":10}
        \\{"stage":"starting"}
        \\{"stage":"done","address":"https://x.publr.app","admin":"https://x--admin.publr.app/admin","project":"p","project_id":"q"}
        \\
    , 0);
    defer arena.deinit();
    try std.testing.expect(job.problem == null);
    try std.testing.expectEqualStrings("https://x.publr.app", job.address);
    try std.testing.expectEqualStrings("q", job.project_id);
    try std.testing.expectEqual(@as(u64, 10), job.progress.total.load(.acquire));
    try std.testing.expectEqual(Stage.done, job.progress.get());
}

test "a refused deploy says why, in Studio's words when Cloud named the reason" {
    const job, var arena = try tryDeploy(
        \\{"stage":"packing"}
        \\{"stage":"failed","error":"Conflict","message":"taken"}
        \\
    , 1);
    defer arena.deinit();
    try std.testing.expectEqualStrings("That address was just taken. Pick another.", job.problem.?);
}
