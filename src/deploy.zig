//! Deploying a local site to Publr Cloud, off the main thread: the site packed by its
//! Publr (`publr pack`, in its own folder), the bundle uploaded (`/api/cloud/bundles`),
//! the project made from it at the chosen address (`cloud.deploy_site`), and the
//! folder linked to it (`cloud.json`, as `publr cloud deploy` writes it). The calls are
//! Cloud's (`cloud/docs/projects.md`, "Deploying a site from a machine").

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
    /// The Publr that packs (`$STUDIO_PUBLR`, Studio's own, or `p`'s).
    publr: []const u8,
    site_dir: []const u8,
    base: []const u8,
    token: []const u8,
    space: []const u8,
    name: []const u8,
    slug: []const u8,
    bundle_path: []const u8,
    progress: *Progress,
    /// The live site's and its admin's addresses, or what went wrong.
    address: []const u8 = "",
    admin: []const u8 = "",
    problem: ?[]const u8 = null,
    project: []const u8 = "",
    project_id: []const u8 = "",
    arena: std.heap.ArenaAllocator,
    done: *const fn (job: *Job) void,

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

    fn steps(self: *Job) !void {
        const a = self.arena.allocator();

        // Packed by the site's Publr, in the site's folder (nowhere else: Publr makes a
        // site wherever it is started).
        std.Io.Dir.cwd().deleteFile(self.io, self.bundle_path) catch {};
        const packed_result = try std.process.run(a, self.io, .{
            .argv = &.{ self.publr, "pack", self.bundle_path },
            .cwd = .{ .path = self.site_dir },
            .environ_map = self.env,
        });
        if (packed_result.term != .exited or packed_result.term.exited != 0) {
            std.debug.print("studio: publr pack: {s}{s}\n", .{ packed_result.stdout, packed_result.stderr });
            self.problem = if (std.mem.indexOf(u8, packed_result.stderr, "pack") == null)
                "This Publr cannot pack sites yet. Run p update, then try again."
            else
                "The site could not be packed. See Console for Publr's message.";
            return;
        }
        const bundle = std.Io.Dir.cwd().readFileAlloc(self.io, self.bundle_path, a, .limited(1 << 30)) catch {
            self.problem = "The packed site could not be read.";
            return;
        };

        self.progress.total.store(bundle.len, .release);
        self.progress.stage.store(@intFromEnum(Stage.uploading), .release);
        const upload = try self.uploadBundle(a, bundle) orelse return;

        self.progress.stage.store(@intFromEnum(Stage.starting), .release);
        try self.deploySite(a, upload);
        if (self.problem != null) return;
        self.link(a);
        std.Io.Dir.cwd().deleteFile(self.io, self.bundle_path) catch {};
    }

    /// The bundle sent in pieces, counting what went, so the sheet can show it.
    fn uploadBundle(self: *Job, a: std.mem.Allocator, bundle: []const u8) !?[]const u8 {
        var client: std.http.Client = .{
            .allocator = a,
            .io = self.io,
        };
        defer client.deinit();
        const url = try std.fmt.allocPrint(a, "{s}/api/cloud/bundles", .{self.base});
        const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{self.token});
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .keep_alive = false,
            .headers = .{
                .content_type = .{
                    .override = "application/gzip",
                },
            },
            .extra_headers = &.{.{
                .name = "Authorization",
                .value = bearer,
            }},
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = bundle.len };
        var body = try req.sendBodyUnflushed(&.{});
        var at: usize = 0;
        const piece = 256 * 1024;
        while (at < bundle.len) {
            const n = @min(piece, bundle.len - at);
            try body.writer.writeAll(bundle[at .. at + n]);
            try body.flush();
            at += n;
            self.progress.sent.store(at, .release);
        }
        try body.end();
        try req.connection.?.flush();
        var response = try req.receiveHead(&.{});
        var out: std.Io.Writer.Allocating = .init(a);
        _ = response.reader(&.{}).streamRemaining(&out.writer) catch {};
        if (response.head.status == .unauthorized or response.head.status == .forbidden) {
            self.problem = "Publr Cloud signed Studio out. Sign in again, then deploy.";
            return null;
        }
        if (response.head.status != .created and response.head.status != .ok) {
            self.problem = "Publr Cloud did not take the upload.";
            return null;
        }
        const Answer = struct {
            upload: []const u8,
        };
        const ans = std.json.parseFromSliceLeaky(Answer, a, out.written(), .{
            .ignore_unknown_fields = true,
        }) catch {
            self.problem = "Publr Cloud answered something Studio does not understand.";
            return null;
        };
        return ans.upload;
    }

    fn deploySite(self: *Job, a: std.mem.Allocator, upload: []const u8) !void {
        var client: std.http.Client = .{
            .allocator = a,
            .io = self.io,
        };
        defer client.deinit();
        var body: std.Io.Writer.Allocating = .init(a);
        const payload = try std.json.Stringify.valueAlloc(a, .{
            .space = self.space,
            .name = self.name,
            .slug = self.slug,
            .upload = upload,
        }, .{});
        const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{self.token});
        const result = try client.fetch(.{
            .location = .{
                .url = try std.fmt.allocPrint(a, "{s}/api/cloud/deploy_site", .{self.base}),
            },
            .method = .POST,
            .payload = payload,
            .keep_alive = false,
            .headers = .{
                .content_type = .{
                    .override = "application/json",
                },
            },
            .extra_headers = &.{.{
                .name = "Authorization",
                .value = bearer,
            }},
            .response_writer = &body.writer,
        });
        if (result.status != .ok) {
            const Failure = struct {
                @"error": []const u8 = "",
            };
            const f = std.json.parseFromSliceLeaky(Failure, a, body.written(), .{
                .ignore_unknown_fields = true,
            }) catch Failure{};
            self.problem = problemFor(f.@"error");
            return;
        }
        const Answer = struct {
            id: []const u8 = "",
            project_id: []const u8 = "",
            address: []const u8 = "",
            admin: []const u8 = "",
        };
        const ans = std.json.parseFromSliceLeaky(Answer, a, body.written(), .{
            .ignore_unknown_fields = true,
        }) catch {
            self.problem = "Publr Cloud answered something Studio does not understand.";
            return;
        };
        self.address = ans.address;
        self.admin = ans.admin;
        self.project = ans.id;
        self.project_id = ans.project_id;
    }

    /// The folder now belongs to the Cloud project (the same link `publr cloud deploy`
    /// writes): it is the project's copy on this Mac, never deployed over the live site.
    fn link(self: *Job, a: std.mem.Allocator) void {
        const now = std.Io.Clock.real.now(self.io);
        const json = std.json.Stringify.valueAlloc(a, .{
            .dashboard = self.base,
            .space = self.space,
            .project = self.project,
            .project_id = self.project_id,
            .slug = self.slug,
            .address = self.address,
            .admin = self.admin,
            .deployed_at_ms = @divTrunc(now.nanoseconds, std.time.ns_per_ms),
        }, .{
            .whitespace = .indent_2,
        }) catch return;
        const path = std.fs.path.join(a, &.{ self.site_dir, "cloud.json" }) catch return;
        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = json,
        }) catch {};
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
    return "Publr Cloud did not make the project.";
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
