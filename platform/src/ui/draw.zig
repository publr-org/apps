//! The UI on the GPU: the frame's nodes become the page of the UI's session, the engine
//! builds its GPU frame from them (`gpu_scene.Scene`), and the host draws it (`host.zig`),
//! as PublrDesign's canvas draws a document.
//!
//! The scene keeps what it worked out for a node (paths, text layouts with the node's
//! paints, polylines) under the node's address, and the host keeps effect surfaces under
//! keys made from the address and the node's `tree_rev`. A document's nodes stay put; the
//! UI's are made again every frame, often at the same addresses with other content, in
//! memory the next frame reuses. So each address keeps a copy of its node's content: a
//! node whose content (all but its place and children) hashes as before is pointed at the
//! copy, so what the scene kept stays true and its memory stays alive; one whose content
//! changed, or that the frame no longer uses, is forgotten (`Session.forgetNode`) before
//! the frame is built. `rev` is the content's hash, `tree_rev` that of the content and the
//! children (with their places): a still or scrolled UI keeps nearly everything.

const std = @import("std");
const platform = @import("platform");
const engine = @import("publr_engine");
const host_mod = @import("host.zig");
const Ui = @import("ui.zig").Ui;
const Color = @import("ui.zig").Color;

const c = platform.gpu.c;
const m = engine.model;
const Host = host_mod.Host;
const Scene = engine.gpu_scene.Scene;
const Wyhash = std.hash.Wyhash;

pub const Gpu = struct {
    gpa: std.mem.Allocator,
    device: c.WGPUDevice,
    host: *Host,
    scene: Scene,
    /// Each address's copy of its node's content, and the addresses this frame used.
    kept: std.AutoHashMapUnmanaged(usize, *Kept) = .empty,
    seen: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// The last frame: building it, encoding it, ms.
    scene_ms: f64 = 0,
    encode_ms: f64 = 0,

    pub fn create(gpa: std.mem.Allocator, gpu: *platform.gpu.Gpu, format: c.WGPUTextureFormat) !*Gpu {
        const self = try gpa.create(Gpu);
        self.* = .{
            .gpa = gpa,
            .device = gpu.device,
            .host = try Host.init(gpa, gpu, format),
            .scene = Scene.init(gpa),
        };
        return self;
    }

    pub fn destroy(self: *Gpu) void {
        self.scene.deinit();
        var it = self.kept.valueIterator();
        while (it.next()) |k| k.*.destroy(self.gpa);
        self.kept.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn draw(self: *Gpu, ui: *Ui, target: c.WGPUTextureView, width: u32, height: u32, scale: f32, background: Color) !bool {
        var timer = host_mod.Timer.start();
        const sess = ui.session;
        self.seen.clearRetainingCapacity();
        for (ui.nodes.items) |*n| _ = try self.mark(sess, n);
        // Addresses this frame no longer uses: whatever comes there next is new.
        var gone: std.ArrayList(usize) = .empty;
        defer gone.deinit(self.gpa);
        var it = self.kept.keyIterator();
        while (it.next()) |addr| if (!self.seen.contains(addr.*)) try gone.append(self.gpa, addr.*);
        for (gone.items) |addr| {
            try sess.forgetNode(addr);
            const k = self.kept.fetchRemove(addr).?;
            k.value.destroy(self.gpa);
        }

        try sess.showNodes(.{
            .id = "ui",
            .kind = .page,
            .children = ui.nodes.items,
        });
        self.scene.motion = false;
        try self.scene.buildPage(sess, 0, 0, 0, scale, width, height);
        self.scene_ms = timer.lap();
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, null);
        try self.host.encodeView(&self.scene, encoder, target, width, height, .{ background.r, background.g, background.b }, true);
        self.host.submit(encoder);
        // What the GPU leaves to the CPU (rare in a UI), a few ms of it per frame.
        if (self.host.pendingLayers() > 0) _ = self.host.pump(sess, 4 * std.time.ns_per_ms);
        self.encode_ms = timer.lap();
        return self.host.stats.pending > 0 or self.host.stats.glyphs_deferred > 0;
    }

    /// Hashes `n` and its children (theirs first) into their revisions, and points
    /// `n` at its address's copy of its content (made again, and the address forgotten,
    /// when the content changed). Answers the hash of its subtree.
    fn mark(self: *Gpu, sess: *engine.session.Session, n: *m.Node) !u64 {
        var tree = Wyhash.init(1);
        for (n.children) |*ch| {
            const v = try self.mark(sess, ch);
            hashValue(&tree, ch.transform);
            tree.update(std.mem.asBytes(&v));
        }
        var own_h = Wyhash.init(0);
        hashOwn(&own_h, n);
        const own = own_h.final();
        tree.update(std.mem.asBytes(&own));
        const t = tree.final();
        const addr = @intFromPtr(n);
        try self.seen.put(self.gpa, addr, {});
        const got = try self.kept.getOrPut(self.gpa, addr);
        if (got.found_existing and got.value_ptr.*.own == own) {
            got.value_ptr.*.applyTo(n);
        } else {
            if (got.found_existing) {
                try sess.forgetNode(addr);
                got.value_ptr.*.destroy(self.gpa);
            }
            got.value_ptr.* = try Kept.make(self.gpa, n, own);
            got.value_ptr.*.applyTo(n);
        }
        n.rev = @truncate(own);
        n.tree_rev = @truncate(t ^ (t >> 32));
        return t;
    }
};

/// A copy of a node's content (not its place or children), in memory of its own.
const Kept = struct {
    arena: std.heap.ArenaAllocator,
    node: m.Node,
    own: u64,

    fn make(gpa: std.mem.Allocator, n: *const m.Node, own: u64) !*Kept {
        const k = try gpa.create(Kept);
        errdefer gpa.destroy(k);
        k.* = .{
            .arena = .init(gpa),
            .node = undefined,
            .own = own,
        };
        errdefer k.arena.deinit();
        var src = n.*;
        src.children = &.{};
        k.node = try dupe(k.arena.allocator(), src);
        return k;
    }

    /// `n` takes the copy's content, keeping its place and children.
    fn applyTo(self: *const Kept, n: *m.Node) void {
        const transform = n.transform;
        const children = n.children;
        n.* = self.node;
        n.transform = transform;
        n.children = children;
    }

    fn destroy(self: *Kept, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// `v` with everything its slices hold copied into `a`.
fn dupe(a: std.mem.Allocator, v: anytype) std.mem.Allocator.Error!@TypeOf(v) {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => return if (v) |x| try dupe(a, x) else null,
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.sentinel_ptr != null) @compileError("ui: cannot copy " ++ @typeName(T));
                const out = try a.alloc(p.child, v.len);
                for (v, out) |x, *o| o.* = try dupe(a, x);
                return out;
            },
            else => @compileError("ui: cannot copy " ++ @typeName(T)),
        },
        .array => {
            var out: T = undefined;
            for (v, &out) |x, *o| o.* = try dupe(a, x);
            return out;
        },
        .@"struct" => |st| {
            var out: T = v;
            inline for (st.field_names) |f_name| @field(out, f_name) = try dupe(a, @field(v, f_name));
            return out;
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("ui: cannot copy " ++ @typeName(T));
            switch (v) {
                inline else => |x, tag| return @unionInit(T, @tagName(tag), try dupe(a, x)),
            }
        },
        else => return v,
    }
}

/// A node's own content: every field but its place and children (hashed by `mark`) and
/// its revisions (made from this).
fn hashOwn(h: *Wyhash, n: *const m.Node) void {
    inline for (comptime std.meta.fieldNames(m.Node)) |f_name| {
        if (comptime std.mem.eql(u8, f_name, "children") or std.mem.eql(u8, f_name, "transform") or std.mem.eql(u8, f_name, "rev") or std.mem.eql(u8, f_name, "tree_rev")) continue;
        hashValue(h, @field(n.*, f_name));
    }
}

/// Any value of the model, deeply: numbers by their bits, slices by their items.
fn hashValue(h: *Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => h.update(std.mem.asBytes(&v)),
        .void, .null => {},
        .optional => if (v) |x| {
            h.update("\x01");
            hashValue(h, x);
        } else h.update("\x00"),
        .pointer => |p| switch (p.size) {
            .slice => {
                h.update(std.mem.asBytes(&v.len));
                if (p.child == u8) h.update(v) else for (v) |x| hashValue(h, x);
            },
            .one => hashValue(h, v.*),
            else => @compileError("ui: cannot hash " ++ @typeName(T)),
        },
        .array => for (v) |x| hashValue(h, x),
        .@"struct" => |s| inline for (s.field_names) |f_name| hashValue(h, @field(v, f_name)),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("ui: cannot hash " ++ @typeName(T));
            h.update(std.mem.asBytes(&@backingInt(std.meta.activeTag(v))));
            switch (v) {
                inline else => |x| hashValue(h, x),
            }
        },
        else => @compileError("ui: cannot hash " ++ @typeName(T)),
    }
}
