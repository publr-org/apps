//! Site thumbnails: Desktop loads each running site's home page out of sight, in a web view
//! behind Home, and keeps a picture of it, saved as a PNG beside Desktop's other state so
//! the next start shows it at once. One site at a time; taken again at every start.

const std = @import("std");
const platform = @import("platform");
const ui = @import("ui");
const engine = @import("publr_engine");

/// The page as a 1280 x 960 browser window shows it, kept 640 pixels wide.
const page_width = 1280;
const page_height = 960;
const picture_width = 640;

/// Sent by the page once it has loaded and painted.
const ready_message = "desktop:thumb-ready";
const ready_script =
    \\addEventListener('load', () => requestAnimationFrame(() => setTimeout(() => {
    \\  webkit.messageHandlers.native.postMessage('desktop:thumb-ready');
    \\}, 400)));
;

pub const Thumbs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    web: *platform.WebView,
    ui: *ui.Ui,
    /// Sites waiting for a picture: name and address.
    queue: std.ArrayList(Job) = .empty,
    current: ?Job = null,
    /// Called when a picture changed (the app redraws).
    changed: *const fn () void,

    const Job = struct {
        name: []const u8,
        address: [:0]const u8,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, support_dir: []const u8, window: *platform.Window, u: *ui.Ui, changed: *const fn () void) !Thumbs {
        const dir = try std.fs.path.join(gpa, &.{ support_dir, "thumbnails" });
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const web = try window.addWebView();
        web.sendToBack(page_width, page_height);
        web.addUserScript(ready_script);
        return .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .web = web,
            .ui = u,
            .changed = changed,
        };
    }

    /// The picture's name in the `ui` for site `name` (null: none yet).
    pub fn key(self: *Thumbs, buf: []u8, name: []const u8) ?[]const u8 {
        const k = std.fmt.bufPrint(buf, "thumb:{s}", .{name}) catch return null;
        return if (self.ui.hasImage(k)) k else null;
    }

    /// Shows the pictures saved last time for `names`.
    pub fn loadSaved(self: *Thumbs, names: []const []const u8) void {
        for (names) |name| {
            var pb: [1024]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "{s}/{s}.png", .{ self.dir, name }) catch continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(16 << 20)) catch continue;
            defer self.gpa.free(bytes);
            var img = engine.png.decode(self.gpa, bytes) catch continue;
            defer img.deinit(self.gpa);
            var kb: [256]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "thumb:{s}", .{name}) catch continue;
            self.ui.setImage(k, &img) catch continue;
        }
    }

    /// Takes a picture of the site at `address` (after any already waiting).
    pub fn take(self: *Thumbs, name: []const u8, address: []const u8) void {
        const job: Job = .{
            .name = self.gpa.dupe(u8, name) catch return,
            .address = self.gpa.dupeSentinel(u8, address, 0) catch return,
        };
        self.queue.append(self.gpa, job) catch return;
        if (self.current == null) self.next();
    }

    fn next(self: *Thumbs) void {
        if (self.queue.items.len == 0) return;
        const job = self.queue.orderedRemove(0);
        self.current = job;
        self.web.loadUrl(job.address);
    }

    /// A page message: true when it was this one's (the page loaded and painted).
    pub fn onMessage(self: *Thumbs, web: *platform.WebView, text: []const u8) bool {
        if (web != self.web or !std.mem.eql(u8, text, ready_message)) return false;
        if (self.current == null) return true;
        self.web.snapshot(picture_width, self, taken);
        return true;
    }

    fn taken(ctx: ?*anyopaque, pic: ?platform.Picture) void {
        const self: *Thumbs = @ptrCast(@alignCast(ctx));
        const job = self.current orelse return;
        defer {
            self.gpa.free(job.name);
            self.gpa.free(job.address);
            self.current = null;
            self.next();
        }
        const p = pic orelse return;
        // Saved for the next start off the main thread (encoding a PNG takes long enough to
        // stall the window, one picture after another at every start), shown here at once.
        const shown = self.gpa.dupe(u8, p.pixels) catch null;
        save(self, job.name, p);
        var img: engine.Image = .{
            .width = p.width,
            .height = p.height,
            .pixels = shown orelse return,
        };
        defer img.deinit(self.gpa);
        var kb: [256]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, "thumb:{s}", .{job.name}) catch return;
        self.ui.setImage(k, &img) catch return;
        self.changed();
    }

    /// The picture as a PNG at `<dir>/<name>.png`, on a thread of its own, which takes
    /// `pic.pixels` (the C allocator's, freed there).
    fn save(self: *Thumbs, name: []const u8, pic: platform.Picture) void {
        const job = self.gpa.create(Save) catch return std.heap.c_allocator.free(pic.pixels);
        job.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .path = std.fmt.allocPrint(self.gpa, "{s}/{s}.png", .{ self.dir, name }) catch {
                self.gpa.destroy(job);
                return std.heap.c_allocator.free(pic.pixels);
            },
            .pic = pic,
        };
        platform.spawn(Save.run, .{job}) catch job.run();
    }
};

const Save = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pic: platform.Picture,

    fn run(self: *Save) void {
        defer {
            std.heap.c_allocator.free(self.pic.pixels);
            self.gpa.free(self.path);
            self.gpa.destroy(self);
        }
        const bytes = engine.png.encode(self.gpa, self.pic.width, self.pic.height, self.pic.pixels) catch return;
        defer self.gpa.free(bytes);
        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.path,
            .data = bytes,
        }) catch {};
    }
};
