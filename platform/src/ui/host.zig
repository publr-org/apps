//! PublrEngine's GPU frame (the flat lists `gpu_scene.Scene` builds, `engine/docs/gpu.md`
//! in publr-design) drawn with WebGPU through wgpu-native: what the own-drawn UI (`Ui.draw`)
//! and PublrDesign's canvas both draw with. It holds no view: the caller builds the
//! Scene for what it shows and hands over a target. A port of the browser's host
//! (`publr-design/editor/viewer/gpu.ts`), step for step:
//!
//! Per frame: the engine walks the scene for the view; the path atlas is filled by stencil
//! and cover (4x MSAA at twice the resolution); then the draws run in order: primitives
//! into the current target (batched as the engine grouped them), surfaces begun and ended
//! (offscreen targets for group opacity, blend modes, masks, patterns and effects), and
//! effect passes (compute) on surfaces. A surface whose pixels depend only on its own draws
//! is kept for later frames under the key the engine gave it, and skipped while kept. The
//! target goes onto the window. What the GPU does not draw comes from the CPU: layer tiles
//! of 512 device pixels drawn by `Session.renderLayer`, cached per node part and matrix,
//! composited where the engine put them in the draw order.
//!
//! Where the browser has Web Workers for the CPU layers, this draws them on the main thread
//! between frames, nearest the centre first, within a time budget (`pump`). Where it has a
//! garbage collector, this releases what a frame made once the frame is submitted.

const std = @import("std");
const platform = @import("platform");
const engine = @import("publr_engine");

const c = platform.gpu.c;
const sc = engine.gpu_scene;
const Scene = sc.Scene;
const Session = engine.session.Session;
const Allocator = std.mem.Allocator;

const none = sc.none;
const surface_bit = sc.surface_bit;
const atlas_size = sc.atlas_size;
const glyph_atlas_size = sc.glyph_atlas_size;
/// Side of a CPU layer tile, in device pixels.
const layer_tile: i32 = 512;
const paint_texture: u32 = 7;
const feature_fallback: u32 = 6;
/// Bytes of one uniform slot (the dynamic offset's alignment).
const slot_size: usize = 256;
const target_format = c.WGPUTextureFormat_RGBA16Float;

pub const Stats = struct {
    /// Building the scene in the engine, encoding and submitting, and the GPU until the
    /// frame finished (measured only when asked: it waits), ms.
    scene_ms: f64 = 0,
    encode_ms: f64 = 0,
    gpu_ms: f64 = 0,
    draw_calls: u32 = 0,
    prims: u32 = 0,
    path_entries: u32 = 0,
    atlas_layers: u32 = 0,
    glyphs: u32 = 0,
    glyphs_new: u32 = 0,
    glyphs_cached: u32 = 0,
    /// Text styles drawn as paths for want of glyph masks (more come next frame).
    glyphs_deferred: u32 = 0,
    nodes: u32 = 0,
    fallbacks: u32 = 0,
    /// Fallback layer tiles still to draw.
    pending: u32 = 0,
    surfaces: u32 = 0,
    surfaces_drawn: u32 = 0,
    passes: u32 = 0,
    /// Bytes of GPU textures the canvas holds, and of them kept surfaces.
    texture_bytes: u64 = 0,
    kept_bytes: u64 = 0,
};

const LayerTile = struct {
    base: []const u8,
    ctm_key: [6]u32,
    ctm: [6]f32,
    /// Top space of the ctm it was drawn at: x0, y0, x1, y1.
    rect: [4]i32,
    texture: c.WGPUTexture,
    bytes: u64,
    used: u32,
    made: u64,
};

const LayerJob = struct {
    key: []const u8,
    base: []const u8,
    ctm_key: [6]u32,
    id: []const u8,
    part: u32,
    child: u32,
    ctm: [6]f32,
    rect: [4]i32,
    dist: f64,
};

const ImageTex = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    bytes: u64,
    used: u32,
};

/// A surface kept between frames.
const Kept = struct {
    texture: c.WGPUTexture,
    bytes: u64,
    used: u32,
};

/// A render target of the frame: the frame's own, or a surface.
const Target = struct {
    texture: c.WGPUTexture,
    w: u32,
    h: u32,
    cleared: bool,
};

/// One draw inside a render pass.
const Op = struct {
    pipeline: c.WGPURenderPipeline,
    group: c.WGPUBindGroup,
    count: u32,
    first: u32,
};

/// What the frame records once its uniform slots are final, in order.
const Step = union(enum) {
    render: struct {
        target: c.WGPUTexture,
        load: bool,
        clear: [4]f64,
        slot: u32,
        ops_first: usize,
        ops_count: usize,
    },
    copy: struct {
        src: c.WGPUTexture,
        x: u32,
        y: u32,
        dst: c.WGPUTexture,
        w: u32,
        h: u32,
    },
    compute: struct {
        pipeline: c.WGPUComputePipeline,
        src: c.WGPUTexture,
        dst: c.WGPUTexture,
        slot: u32,
        x: u32,
        y: u32,
    },
};

/// The pass being collected: its target and its first op.
const Open = struct {
    target: *Target,
    ops_first: usize,
    slot: u32,
};

const Pipelines = struct {
    over: c.WGPURenderPipeline,
    replace: c.WGPURenderPipeline,
    max: c.WGPURenderPipeline,
    erase: c.WGPURenderPipeline,
};

const fx_entries = [_][:0]const u8{ "gauss", "box", "progressive", "spread", "noise", "texture", "backdrop" };

pub const Host = struct {
    gpa: Allocator,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    /// The window's surface format (what `present` writes).
    format: c.WGPUTextureFormat,
    max_dim: u32,
    g0_layout: c.WGPUBindGroupLayout,
    g1_layout: c.WGPUBindGroupLayout,
    atlas_layout: c.WGPUBindGroupLayout,
    present_layout: c.WGPUBindGroupLayout,
    fx_layout: c.WGPUBindGroupLayout,
    /// Prims by how they composite: over, replace (blend modes), max, erase.
    paint: Pipelines,
    stencil_pipeline: c.WGPURenderPipeline,
    cover_pipelines: [2]c.WGPURenderPipeline,
    present_pipeline: c.WGPURenderPipeline,
    glyph_pipeline: c.WGPURenderPipeline,
    fx_pipelines: [fx_entries.len]c.WGPUComputePipeline,
    glyph_atlas: c.WGPUTexture,
    layer_buf: c.WGPUBuffer,
    atlas_group: c.WGPUBindGroup,
    atlas: c.WGPUTexture = null,
    atlas_layers: u32 = 0,
    atlas_views: std.ArrayList(c.WGPUTextureView) = .empty,
    atlas_array_view: c.WGPUTextureView = null,
    msaa_color: c.WGPUTexture,
    msaa_color_view: c.WGPUTextureView,
    msaa_stencil: c.WGPUTexture,
    msaa_stencil_view: c.WGPUTextureView,
    target: c.WGPUTexture = null,
    dummy: c.WGPUTexture,
    dummy_view: c.WGPUTextureView,
    dummy_group: c.WGPUBindGroup,
    backdrop_tex: c.WGPUTexture = null,
    bufs: [Buf.count]?BufEntry = @splat(null),
    slot_buf: c.WGPUBuffer,
    slot_buf_size: u64,
    slots: std.ArrayList(u8) = .empty,
    /// Textures to destroy, and objects to release, once the frame using them is submitted.
    doomed: std.ArrayList(c.WGPUTexture) = .empty,
    transient_views: std.ArrayList(c.WGPUTextureView) = .empty,
    transient_groups: std.ArrayList(c.WGPUBindGroup) = .empty,
    images: std.StringHashMapUnmanaged(ImageTex) = .empty,
    layers: std.StringHashMapUnmanaged(LayerTile) = .empty,
    layer_bytes: u64 = 0,
    /// Layer tiles by node part (`base`), for stand-ins.
    by_base: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    /// Layer tiles the last frame lacked, nearest the centre first.
    queue_jobs: std.ArrayList(LayerJob) = .empty,
    /// What jobs' strings live in (reset when the queue is replaced).
    job_arena: std.heap.ArenaAllocator,
    frame_no: u32 = 0,
    /// Surface textures free for reuse, by size.
    free: std.AutoHashMapUnmanaged([2]u32, std.ArrayList(c.WGPUTexture)) = .empty,
    free_bytes: u64 = 0,
    /// Surfaces kept between frames, by key.
    kept: std.AutoHashMapUnmanaged([2]u32, Kept) = .empty,
    kept_bytes: u64 = 0,
    /// Bumped when the document changes: layers of older ones are dropped.
    gen: u32 = 0,
    stats: Stats = .{},
    /// Cap on cached CPU layer tiles, and on kept surfaces, bytes.
    layer_cap: u64 = 512 * 1048576,
    kept_cap: u64 = 256 * 1048576,
    /// Keep surfaces between frames (off: every frame draws them all, to measure).
    keep: bool = true,

    const Buf = enum(u8) {
        prims,
        paints,
        shapes,
        stops,
        verts,
        glyphs,
        covers,
        present,

        const count = @typeInfo(Buf).@"enum".field_names.len;
    };

    const BufEntry = struct {
        buffer: c.WGPUBuffer,
        size: u64,
    };

    pub fn init(gpa: Allocator, gpu: *platform.gpu.Gpu, format: c.WGPUTextureFormat) !*Host {
        const device = gpu.device;
        var limits = std.mem.zeroes(c.WGPULimits);
        _ = c.wgpuDeviceGetLimits(device, &limits);

        const F = c.WGPUShaderStage_Fragment;
        const V = c.WGPUShaderStage_Vertex;
        const C = c.WGPUShaderStage_Compute;
        const g0_layout = bindGroupLayout(device, &.{
            uniformEntry(0, V | F, true, 16),
            storageEntry(1, V | F),
            storageEntry(2, F),
            storageEntry(3, F),
            storageEntry(4, F),
            textureEntry(5, F, c.WGPUTextureSampleType_Float, c.WGPUTextureViewDimension_2DArray),
        });
        const g1_layout = bindGroupLayout(device, &.{
            textureEntry(0, F, c.WGPUTextureSampleType_UnfilterableFloat, c.WGPUTextureViewDimension_2D),
            textureEntry(1, F, c.WGPUTextureSampleType_UnfilterableFloat, c.WGPUTextureViewDimension_2D),
            textureEntry(2, F, c.WGPUTextureSampleType_UnfilterableFloat, c.WGPUTextureViewDimension_2D),
        });
        const atlas_layout = bindGroupLayout(device, &.{
            uniformEntry(0, V, false, 0),
            textureEntry(1, F, c.WGPUTextureSampleType_Float, c.WGPUTextureViewDimension_2D),
        });
        const present_layout = bindGroupLayout(device, &.{
            textureEntry(0, F, c.WGPUTextureSampleType_UnfilterableFloat, c.WGPUTextureViewDimension_2D),
            uniformEntry(1, F, false, 0),
        });
        var storage_tex = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        storage_tex.binding = 2;
        storage_tex.visibility = C;
        storage_tex.storageTexture.access = c.WGPUStorageTextureAccess_WriteOnly;
        storage_tex.storageTexture.format = target_format;
        storage_tex.storageTexture.viewDimension = c.WGPUTextureViewDimension_2D;
        const fx_layout = bindGroupLayout(device, &.{
            uniformEntry(0, C, true, 144),
            textureEntry(1, C, c.WGPUTextureSampleType_UnfilterableFloat, c.WGPUTextureViewDimension_2D),
            storage_tex,
        });

        const paint_mod = shaderModule(device, sc.shaders.paint, "paint");
        const atlas_mod = shaderModule(device, sc.shaders.atlas, "atlas");
        const present_mod = shaderModule(device, sc.shaders.present, "present");
        const fx_mod = shaderModule(device, sc.shaders.effects, "effects");
        defer for ([_]c.WGPUShaderModule{ paint_mod, atlas_mod, present_mod, fx_mod }) |m| c.wgpuShaderModuleRelease(m);

        const paint_layout = pipelineLayout(device, &.{ g0_layout, g1_layout });
        defer c.wgpuPipelineLayoutRelease(paint_layout);
        const paint: Pipelines = .{
            .over = paintPipeline(device, paint_layout, paint_mod, blendOf(c.WGPUBlendOperation_Add, c.WGPUBlendFactor_One, c.WGPUBlendFactor_OneMinusSrcAlpha)),
            .replace = paintPipeline(device, paint_layout, paint_mod, null),
            .max = paintPipeline(device, paint_layout, paint_mod, blendOf(c.WGPUBlendOperation_Max, c.WGPUBlendFactor_One, c.WGPUBlendFactor_One)),
            .erase = paintPipeline(device, paint_layout, paint_mod, blendOf(c.WGPUBlendOperation_Add, c.WGPUBlendFactor_Zero, c.WGPUBlendFactor_OneMinusSrcAlpha)),
        };
        const atlas_pl = pipelineLayout(device, &.{atlas_layout});
        defer c.wgpuPipelineLayoutRelease(atlas_pl);

        // Stencil: every contour's fan, up on front faces and down on back faces.
        var stencil_attr = std.mem.zeroes(c.WGPUVertexAttribute);
        stencil_attr.format = c.WGPUVertexFormat_Float32x2;
        var stencil_vb = std.mem.zeroes(c.WGPUVertexBufferLayout);
        stencil_vb.arrayStride = 8;
        stencil_vb.stepMode = c.WGPUVertexStepMode_Vertex;
        stencil_vb.attributeCount = 1;
        stencil_vb.attributes = &stencil_attr;
        var stencil_ds = depthStencil();
        stencil_ds.stencilFront = .{
            .compare = c.WGPUCompareFunction_Always,
            .failOp = c.WGPUStencilOperation_Keep,
            .depthFailOp = c.WGPUStencilOperation_Keep,
            .passOp = c.WGPUStencilOperation_IncrementWrap,
        };
        stencil_ds.stencilBack = .{
            .compare = c.WGPUCompareFunction_Always,
            .failOp = c.WGPUStencilOperation_Keep,
            .depthFailOp = c.WGPUStencilOperation_Keep,
            .passOp = c.WGPUStencilOperation_DecrementWrap,
        };
        const stencil_pipeline = renderPipeline(device, .{
            .layout = atlas_pl,
            .module = atlas_mod,
            .vs = "stencil_vs",
            .fs = "stencil_fs",
            .format = c.WGPUTextureFormat_R8Unorm,
            .write_mask = c.WGPUColorWriteMask_None,
            .topology = c.WGPUPrimitiveTopology_TriangleList,
            .buffers = &.{stencil_vb},
            .depth_stencil = &stencil_ds,
            .samples = 4,
        });

        // Cover: a quad per entry where the winding says inside (nonzero, even-odd).
        var cover_attr = std.mem.zeroes(c.WGPUVertexAttribute);
        cover_attr.format = c.WGPUVertexFormat_Uint32x4;
        var cover_vb = std.mem.zeroes(c.WGPUVertexBufferLayout);
        cover_vb.arrayStride = 16;
        cover_vb.stepMode = c.WGPUVertexStepMode_Instance;
        cover_vb.attributeCount = 1;
        cover_vb.attributes = &cover_attr;
        var cover_pipelines: [2]c.WGPURenderPipeline = undefined;
        for ([_]u32{ 0xff, 0x01 }, 0..) |read_mask, k| {
            var ds = depthStencil();
            const face: c.WGPUStencilFaceState = .{
                .compare = c.WGPUCompareFunction_NotEqual,
                .failOp = c.WGPUStencilOperation_Keep,
                .depthFailOp = c.WGPUStencilOperation_Keep,
                .passOp = c.WGPUStencilOperation_Zero,
            };
            ds.stencilFront = face;
            ds.stencilBack = face;
            ds.stencilReadMask = read_mask;
            cover_pipelines[k] = renderPipeline(device, .{
                .layout = atlas_pl,
                .module = atlas_mod,
                .vs = "cover_vs",
                .fs = "cover_fs",
                .format = c.WGPUTextureFormat_R8Unorm,
                .topology = c.WGPUPrimitiveTopology_TriangleStrip,
                .buffers = &.{cover_vb},
                .depth_stencil = &ds,
                .samples = 4,
            });
        }

        // Glyph masks added into atlas entries.
        var glyph_attrs = [2]c.WGPUVertexAttribute{ std.mem.zeroes(c.WGPUVertexAttribute), std.mem.zeroes(c.WGPUVertexAttribute) };
        glyph_attrs[0].format = c.WGPUVertexFormat_Uint32x4;
        glyph_attrs[1].format = c.WGPUVertexFormat_Uint32x4;
        glyph_attrs[1].offset = 16;
        glyph_attrs[1].shaderLocation = 1;
        var glyph_vb = std.mem.zeroes(c.WGPUVertexBufferLayout);
        glyph_vb.arrayStride = 32;
        glyph_vb.stepMode = c.WGPUVertexStepMode_Instance;
        glyph_vb.attributeCount = 2;
        glyph_vb.attributes = &glyph_attrs;
        const glyph_pipeline = renderPipeline(device, .{
            .layout = atlas_pl,
            .module = atlas_mod,
            .vs = "glyph_vs",
            .fs = "glyph_fs",
            .format = c.WGPUTextureFormat_R8Unorm,
            .blend = blendOf(c.WGPUBlendOperation_Add, c.WGPUBlendFactor_One, c.WGPUBlendFactor_One),
            .topology = c.WGPUPrimitiveTopology_TriangleStrip,
            .buffers = &.{glyph_vb},
        });

        const present_pl = pipelineLayout(device, &.{present_layout});
        defer c.wgpuPipelineLayoutRelease(present_pl);
        const present_pipeline = renderPipeline(device, .{
            .layout = present_pl,
            .module = present_mod,
            .vs = "vs",
            .fs = "fs",
            .format = format,
            .topology = c.WGPUPrimitiveTopology_TriangleList,
        });

        const fx_pl = pipelineLayout(device, &.{fx_layout});
        defer c.wgpuPipelineLayoutRelease(fx_pl);
        var fx_pipelines: [fx_entries.len]c.WGPUComputePipeline = undefined;
        for (fx_entries, 0..) |entry, k| {
            var desc = std.mem.zeroes(c.WGPUComputePipelineDescriptor);
            desc.layout = fx_pl;
            desc.compute.module = fx_mod;
            desc.compute.entryPoint = platform.gpu.str(entry);
            fx_pipelines[k] = c.wgpuDeviceCreateComputePipeline(device, &desc);
        }

        const queue = gpu.queue;
        const slot_buf = createBuffer(device, slot_size * 64, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst);
        const layer_buf = createBuffer(device, 16, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst);
        const layer_size = [4]f32{ @floatFromInt(atlas_size), @floatFromInt(atlas_size), 0, 0 };
        c.wgpuQueueWriteBuffer(queue, layer_buf, 0, &layer_size, 16);
        const glyph_atlas = createTexture(device, glyph_atlas_size, glyph_atlas_size, 1, c.WGPUTextureFormat_R8Unorm, c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst, 1, 1);
        const glyph_view = c.wgpuTextureCreateView(glyph_atlas, null);
        defer c.wgpuTextureViewRelease(glyph_view);
        const atlas_group = bindGroup(device, atlas_layout, &.{
            bufferBinding(0, layer_buf, 16),
            textureBinding(1, glyph_view),
        });
        const msaa_color = createTexture(device, atlas_size, atlas_size, 1, c.WGPUTextureFormat_R8Unorm, c.WGPUTextureUsage_RenderAttachment, 1, 4);
        const msaa_stencil = createTexture(device, atlas_size, atlas_size, 1, c.WGPUTextureFormat_Stencil8, c.WGPUTextureUsage_RenderAttachment, 1, 4);
        const dummy = createTexture(device, 1, 1, 1, c.WGPUTextureFormat_RGBA8Unorm, c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst, 1, 1);
        const dummy_view = c.wgpuTextureCreateView(dummy, null);

        const self = try gpa.create(Host);
        self.* = .{
            .gpa = gpa,
            .device = device,
            .queue = queue,
            .format = format,
            .max_dim = limits.maxTextureDimension2D,
            .g0_layout = g0_layout,
            .g1_layout = g1_layout,
            .atlas_layout = atlas_layout,
            .present_layout = present_layout,
            .fx_layout = fx_layout,
            .paint = paint,
            .stencil_pipeline = stencil_pipeline,
            .cover_pipelines = cover_pipelines,
            .present_pipeline = present_pipeline,
            .glyph_pipeline = glyph_pipeline,
            .fx_pipelines = fx_pipelines,
            .glyph_atlas = glyph_atlas,
            .layer_buf = layer_buf,
            .atlas_group = atlas_group,
            .msaa_color = msaa_color,
            .msaa_color_view = c.wgpuTextureCreateView(msaa_color, null),
            .msaa_stencil = msaa_stencil,
            .msaa_stencil_view = c.wgpuTextureCreateView(msaa_stencil, null),
            .dummy = dummy,
            .dummy_view = dummy_view,
            .dummy_group = undefined,
            .slot_buf = slot_buf,
            .slot_buf_size = slot_size * 64,
            .job_arena = .init(gpa),
        };
        self.dummy_group = self.group1Persistent(dummy_view, null, null);
        try self.ensureAtlas(1);
        return self;
    }

    // ------------------------------------------------------------------ resources

    fn buffer(self: *Host, which: Buf, bytes: u64, usage: c.WGPUBufferUsage) c.WGPUBuffer {
        const slot = &self.bufs[@backingInt(which)];
        if (slot.*) |b| if (b.size >= bytes) return b.buffer;
        if (slot.*) |b| self.doomBuffer(b.buffer);
        var size: u64 = 4096;
        while (size < bytes) size *= 2;
        const buf = createBuffer(self.device, size, usage | c.WGPUBufferUsage_CopyDst);
        slot.* = .{
            .buffer = buf,
            .size = size,
        };
        return buf;
    }

    fn doomBuffer(_: *Host, b: c.WGPUBuffer) void {
        // A buffer in this frame's commands stays alive while the queue holds it.
        c.wgpuBufferRelease(b);
    }

    fn view(self: *Host, t: c.WGPUTexture) c.WGPUTextureView {
        const v = c.wgpuTextureCreateView(t, null);
        self.transient_views.append(self.gpa, v) catch {};
        return v;
    }

    fn group1(self: *Host, tex: c.WGPUTextureView, backdrop: ?c.WGPUTextureView, mask: ?c.WGPUTextureView) c.WGPUBindGroup {
        const g = self.group1Persistent(tex, backdrop, mask);
        self.transient_groups.append(self.gpa, g) catch {};
        return g;
    }

    fn group1Persistent(self: *Host, tex: c.WGPUTextureView, backdrop: ?c.WGPUTextureView, mask: ?c.WGPUTextureView) c.WGPUBindGroup {
        return bindGroup(self.device, self.g1_layout, &.{
            textureBinding(0, tex),
            textureBinding(1, backdrop orelse self.dummy_view),
            textureBinding(2, mask orelse self.dummy_view),
        });
    }

    fn ensureAtlas(self: *Host, layers: u32) !void {
        if (self.atlas != null and self.atlas_layers >= layers) return;
        const n = @max(layers, self.atlas_layers, 1);
        if (self.atlas != null) {
            for (self.atlas_views.items) |v| c.wgpuTextureViewRelease(v);
            c.wgpuTextureViewRelease(self.atlas_array_view);
            try self.doomed.append(self.gpa, self.atlas);
        }
        self.atlas = createTexture(self.device, atlas_size, atlas_size, n, c.WGPUTextureFormat_R8Unorm, c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding, 1, 1);
        self.atlas_layers = n;
        self.atlas_views.clearRetainingCapacity();
        for (0..n) |i| {
            var desc = viewDesc(c.WGPUTextureViewDimension_2D);
            desc.baseArrayLayer = @intCast(i);
            desc.arrayLayerCount = 1;
            try self.atlas_views.append(self.gpa, c.wgpuTextureCreateView(self.atlas, &desc));
        }
        var desc = viewDesc(c.WGPUTextureViewDimension_2DArray);
        desc.arrayLayerCount = n;
        self.atlas_array_view = c.wgpuTextureCreateView(self.atlas, &desc);
    }

    fn ensureTarget(self: *Host, w: u32, h: u32) c.WGPUTexture {
        if (self.target == null or c.wgpuTextureGetWidth(self.target) != w or c.wgpuTextureGetHeight(self.target) != h) {
            if (self.target != null) self.doomed.append(self.gpa, self.target) catch {};
            self.target = createTexture(self.device, w, h, 1, target_format, c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopySrc, 1, 1);
        }
        return self.target;
    }

    /// A surface texture of at least `w0` x `h0` (reused when one is free): sizes go up in
    /// steps, so surfaces that change size as the view zooms reuse the same textures. What
    /// lies past `w0` x `h0` stays clear (the first pass clears the whole texture).
    fn acquire(self: *Host, w0: u32, h0: u32) c.WGPUTexture {
        const step = struct {
            fn f(v: u32) u32 {
                return if (v <= 1024) std.mem.alignForward(u32, v, 64) else std.mem.alignForward(u32, v, 256);
            }
        }.f;
        const w = @min(self.max_dim, step(w0));
        const h = @min(self.max_dim, step(h0));
        if (self.free.getPtr(.{ w, h })) |list| if (list.pop()) |t| {
            self.free_bytes -= @as(u64, w) * h * 8;
            return t;
        };
        return createTexture(self.device, w, h, 1, target_format, c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_StorageBinding | c.WGPUTextureUsage_CopySrc | c.WGPUTextureUsage_CopyDst, 1, 1);
    }

    fn release(self: *Host, t: c.WGPUTexture) void {
        const w = c.wgpuTextureGetWidth(t);
        const h = c.wgpuTextureGetHeight(t);
        const got = self.free.getOrPut(self.gpa, .{ w, h }) catch return;
        if (!got.found_existing) got.value_ptr.* = .empty;
        for (got.value_ptr.items) |x| if (x == t) {
            std.debug.print("gpu: a surface texture released twice\n", .{});
            return;
        };
        got.value_ptr.append(self.gpa, t) catch return;
        self.free_bytes += @as(u64, w) * h * 8;
    }

    /// Gives back free surface textures past a budget.
    fn trimFree(self: *Host) void {
        const cap: u64 = 128 * 1048576;
        if (self.free_bytes <= cap) return;
        var it = self.free.iterator();
        while (it.next()) |e| {
            while (self.free_bytes > cap / 2) {
                const t = e.value_ptr.pop() orelse break;
                self.free_bytes -= @as(u64, c.wgpuTextureGetWidth(t)) * c.wgpuTextureGetHeight(t) * 8;
                destroyTexture(t);
            }
        }
    }

    fn backdropFor(self: *Host, w: u32, h: u32) c.WGPUTexture {
        const t = self.backdrop_tex;
        var ow: u32 = 0;
        var oh: u32 = 0;
        if (t != null) {
            ow = c.wgpuTextureGetWidth(t);
            oh = c.wgpuTextureGetHeight(t);
            if (ow >= w and oh >= h) return t;
            // The old one may be in this frame's commands: destroyed after it is submitted.
            self.doomed.append(self.gpa, t) catch {};
        }
        self.backdrop_tex = createTexture(self.device, @max(w, ow, 256), @max(h, oh, 256), 1, target_format, c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst, 1, 1);
        return self.backdrop_tex;
    }

    /// The texture of image `index` of the frame (made once per image).
    fn image(self: *Host, scene: *const Scene, index: u32) !ImageTex {
        const rec = scene.textures.items[index];
        const hash = scene.texture_hashes.items[index];
        // By hash and size: an image decoded more finely later (zoomed in) is a new texture.
        var key_buf: [160]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}@{d}", .{ hash, rec.width });
        if (self.images.getPtr(key)) |img| {
            img.used = self.frame_no;
            return img.*;
        }
        const levels = rec.levels;
        var base: u32 = 0;
        while (base < levels - 1 and ((rec.width >> @intCast(base)) > self.max_dim or (rec.height >> @intCast(base)) > self.max_dim)) base += 1;
        const l0 = scene.textureLevel(index, base) orelse return error.NoSuchLevel;
        const texture = createTexture(self.device, l0.w, l0.h, 1, c.WGPUTextureFormat_RGBA8Unorm, c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst, levels - base, 1);
        var bytes: u64 = 0;
        var l = base;
        while (l < levels) : (l += 1) {
            const lv = scene.textureLevel(index, l) orelse break;
            writeTexture(self.queue, texture, l - base, 0, 0, lv.w, lv.h, lv.data[0 .. lv.w * lv.h * 4], lv.w * 4);
            bytes += lv.data.len;
        }
        const img: ImageTex = .{
            .texture = texture,
            .view = c.wgpuTextureCreateView(texture, null),
            .bytes = bytes,
            .used = self.frame_no,
        };
        try self.images.put(self.gpa, try self.gpa.dupe(u8, key), img);
        return img;
    }

    /// Forgets the GPU's copies of picture `hash` (it was replaced under that name).
    pub fn forgetImage(self: *Host, hash: []const u8) void {
        while (true) {
            var found: ?[]const u8 = null;
            var it = self.images.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (k.len > hash.len and std.mem.startsWith(u8, k, hash) and k[hash.len] == '@') {
                    found = k;
                    break;
                }
            }
            const key = found orelse return;
            const kv = self.images.fetchRemove(key).?;
            c.wgpuTextureViewRelease(kv.value.view);
            self.doomed.append(self.gpa, kv.value.texture) catch destroyTexture(kv.value.texture);
            self.gpa.free(kv.key);
        }
    }

    /// Forgets every image, layer and kept surface (the document changed).
    pub fn clear(self: *Host) void {
        self.gen += 1;
        var ii = self.images.iterator();
        while (ii.next()) |e| {
            c.wgpuTextureViewRelease(e.value_ptr.view);
            destroyTexture(e.value_ptr.texture);
            self.gpa.free(e.key_ptr.*);
        }
        self.images.clearRetainingCapacity();
        self.dropLayers();
        var ki = self.kept.valueIterator();
        while (ki.next()) |k| destroyTexture(k.texture);
        self.kept.clearRetainingCapacity();
        self.kept_bytes = 0;
    }

    fn dropLayers(self: *Host) void {
        var li = self.layers.iterator();
        while (li.next()) |e| {
            destroyTexture(e.value_ptr.texture);
            self.gpa.free(e.key_ptr.*);
        }
        self.layers.clearRetainingCapacity();
        var bi = self.by_base.iterator();
        while (bi.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.by_base.clearRetainingCapacity();
        self.layer_bytes = 0;
        self.queue_jobs.clearRetainingCapacity();
        _ = self.job_arena.reset(.retain_capacity);
    }

    // ------------------------------------------------------------------ frames

    /// Encodes the frame `scene` holds for a view of `w` x `h` device pixels (built by
    /// `Scene.buildPage`) into `out`, a texture view of the host's `format`, over
    /// `background`. The caller may encode more on `encoder` (an overlay), then `submit`.
    /// `complete`: the engine holds everything the frame draws (its surfaces may be kept).
    pub fn encodeView(self: *Host, scene: *Scene, encoder: c.WGPUCommandEncoder, out: c.WGPUTextureView, w: u32, h: u32, background: [3]f32, complete: bool) !void {
        var timer = Timer.start();
        const apron = scene.header.apron;
        const target = self.ensureTarget(w + 2 * apron, h + 2 * apron);
        try self.encodeScene(scene, encoder, target, .{ background[0], background[1], background[2], 1 }, true, complete);
        const off = self.buffer(.present, 16, c.WGPUBufferUsage_Uniform);
        const offset = [4]f32{ @floatFromInt(apron), @floatFromInt(apron), 0, 0 };
        c.wgpuQueueWriteBuffer(self.queue, off, 0, &offset, 16);
        const pass = beginPass(encoder, out, false, .{ 0, 0, 0, 1 });
        c.wgpuRenderPassEncoderSetPipeline(pass, self.present_pipeline);
        const group = bindGroup(self.device, self.present_layout, &.{
            textureBinding(0, self.view(target)),
            bufferBinding(1, off, 16),
        });
        try self.transient_groups.append(self.gpa, group);
        c.wgpuRenderPassEncoderSetBindGroup(pass, 0, group, 0, null);
        c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);
        self.stats.encode_ms = timer.lap();
    }

    /// Submits `encoder` and releases what the frame made.
    pub fn submit(self: *Host, encoder: c.WGPUCommandEncoder) void {
        const cmd = c.wgpuCommandEncoderFinish(encoder, null);
        c.wgpuQueueSubmit(self.queue, 1, &cmd);
        c.wgpuCommandBufferRelease(cmd);
        c.wgpuCommandEncoderRelease(encoder);
        self.afterSubmit();
    }

    /// Waits until the GPU has done everything submitted (for measuring), ms.
    pub fn finish(self: *Host) f64 {
        var timer = Timer.start();
        _ = c.wgpuDevicePoll(self.device, 1, null);
        self.stats.gpu_ms = timer.lap();
        return self.stats.gpu_ms;
    }

    /// Renders node `id` as an export draws it (`width` x `height` at `scale`) and reads
    /// it back as straight RGBA8 (owned by the caller), drawing every CPU layer it needs.
    pub fn renderNode(self: *Host, scene: *Scene, sess: *Session, id: []const u8, scale: f32, width: u32, height: u32) ![]u8 {
        var round: u32 = 0;
        while (true) : (round += 1) {
            scene.motion = false;
            try scene.buildNode(sess, id, scale, width, height);
            const target = createTexture(self.device, width, height, 1, target_format, c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc | c.WGPUTextureUsage_TextureBinding, 1, 1);
            defer destroyTexture(target);
            const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, null);
            try self.encodeScene(scene, encoder, target, .{ 0, 0, 0, 0 }, false, true);
            if ((self.stats.pending > 0 or self.stats.glyphs_deferred > 0) and round < 64) {
                // CPU layers or glyph masks are still to come: draw them, then again.
                self.submit(encoder);
                _ = self.pump(sess, std.math.maxInt(u64));
                continue;
            }
            const bpr = std.mem.alignForward(u32, width * 8, 256);
            const out = createBuffer(self.device, @as(u64, bpr) * height, c.WGPUBufferUsage_CopyDst | c.WGPUBufferUsage_MapRead);
            defer {
                c.wgpuBufferDestroy(out);
                c.wgpuBufferRelease(out);
            }
            copyTextureToBuffer(encoder, target, out, bpr, width, height);
            self.submit(encoder);
            const raw = try mapRead(self.device, out, @as(u64, bpr) * height);
            defer c.wgpuBufferUnmap(out);
            const data = try self.gpa.alloc(u8, @as(usize, width) * height * 4);
            @memset(data, 0);
            for (0..height) |yy| {
                const row: [*]const u16 = @ptrCast(@alignCast(raw.ptr + yy * bpr));
                for (0..width) |xx| {
                    const px = row[xx * 4 ..][0..4];
                    const a = std.math.clamp(half(px[3]), 0, 1);
                    if (a <= 0) continue;
                    const o = (yy * width + xx) * 4;
                    data[o] = to8(half(px[0]) / a);
                    data[o + 1] = to8(half(px[1]) / a);
                    data[o + 2] = to8(half(px[2]) / a);
                    data[o + 3] = to8(a);
                }
            }
            return data;
        }
    }

    /// Encodes the frame the engine built: the atlas, then every draw into `target`
    /// (cleared to `clear_value`).
    fn encodeScene(self: *Host, scene: *Scene, encoder: c.WGPUCommandEncoder, target: c.WGPUTexture, clear_value: [4]f64, wanted: bool, complete: bool) !void {
        self.frame_no += 1;
        self.slots.clearRetainingCapacity();
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const hdr = &scene.header;
        const prims = scene.prims.items;
        const paints = scene.paints.items;
        const stats = &self.stats;
        stats.prims = @intCast(prims.len);
        stats.nodes = hdr.nodes;
        stats.fallbacks = @intCast(scene.fallbacks.items.len);
        stats.path_entries = @intCast(scene.entries.items.len);
        stats.atlas_layers = @intCast(scene.layers.items.len);
        stats.glyphs = @intCast(scene.glyph_draws.items.len);
        stats.glyphs_new = @intCast(scene.glyph_uploads.items.len);
        stats.glyphs_cached = hdr.glyphs_cached;
        stats.surfaces = @intCast(scene.surfaces.items.len);
        stats.passes = @intCast(scene.passes.items.len);
        // Text drawn as paths for want of glyph budget: the next frame takes more masks.
        const deferred = hdr.glyphs_deferred > 0;
        stats.glyphs_deferred = hdr.glyphs_deferred;
        const tw = c.wgpuTextureGetWidth(target);
        const th = c.wgpuTextureGetHeight(target);

        // Fallbacks: their layer tiles become extra prims and paints after the engine's.
        var extra_prims: std.ArrayList(sc.Prim) = .empty;
        var extra_paints: std.ArrayList(sc.Paint) = .empty;
        // Per fallback: the extra prims (index) and their tile textures.
        const FbDraw = struct {
            prim: u32,
            texture: c.WGPUTexture,
        };
        const fb_draws = try arena.alloc(std.ArrayList(FbDraw), scene.fallbacks.items.len);
        var wanted_jobs: std.ArrayList(LayerJob) = .empty;
        const job_a = self.job_arena.allocator();
        var pending: u32 = 0;
        const cx = @as(f64, @floatFromInt(tw)) / 2;
        const cy = @as(f64, @floatFromInt(th)) / 2;
        for (
            scene.fallbacks.items,
            scene.fallback_ids.items,
            scene.fallback_revs.items,
            0..,
        ) |fb, fid, frev, fi| {
            fb_draws[fi] = .empty;
            const list = &fb_draws[fi];
            // The node's content revision is in the key: new content under the same id (a
            // UI's text that changed) is drawn again, not taken from the kept picture.
            const base = try std.fmt.allocPrint(arena, "{d}|{s}|{d}|{d}|{d}", .{ self.gen, fid, frev, fb.part, fb.child });
            const ctm_key = ctmKey(fb.ctm);
            const tmpl = prims[fb.prim];
            const ox = tmpl.ox;
            const oy = tmpl.oy;
            const Add = struct {
                fn tile(h: *Host, ep: *std.ArrayList(sc.Prim), epa: *std.ArrayList(sc.Paint), l: *std.ArrayList(FbDraw), a: Allocator, f: sc.Fallback, t: *LayerTile, inv: [6]f32, bounds: [4]i32, filtered: bool, base_prim: sc.Prim, prim_base: u32, paint_base: u32) !void {
                    const x0 = @max(bounds[0], f.rect[0]);
                    const y0 = @max(bounds[1], f.rect[1]);
                    const x1 = @min(bounds[2], f.rect[2]);
                    const y1 = @min(bounds[3], f.rect[3]);
                    if (x1 <= x0 or y1 <= y0) return;
                    const paint: u32 = paint_base + @as(u32, @intCast(epa.items.len));
                    try epa.append(a, .{
                        .kind = paint_texture,
                        .flags = if (filtered) 1 else 0,
                        .a = 0,
                        .b = 0,
                        .color = .{ 0, 0, 0, 0 },
                        .inv = .{ inv[0], inv[1], inv[2], inv[3] },
                        .inv_t = .{ inv[4], inv[5], @floatFromInt(t.rect[2] - t.rect[0]), @floatFromInt(t.rect[3] - t.rect[1]) },
                    });
                    var p = base_prim;
                    p.x0 = @floatFromInt(x0 + base_prim.ox);
                    p.y0 = @floatFromInt(y0 + base_prim.oy);
                    p.x1 = @floatFromInt(x1 + base_prim.ox);
                    p.y1 = @floatFromInt(y1 + base_prim.oy);
                    p.shape = none;
                    p.shape2 = none;
                    p.paint = paint;
                    p.op = 0;
                    p.feature = feature_fallback;
                    p.opacity = 1;
                    p.blend = 0;
                    p.mask = none;
                    try l.append(a, .{
                        .prim = prim_base + @as(u32, @intCast(ep.items.len)),
                        .texture = t.texture,
                    });
                    try ep.append(a, p);
                    t.used = h.frame_no;
                }
            };
            const prim_base: u32 = @intCast(prims.len);
            const paint_base: u32 = @intCast(paints.len);
            const tx0 = @divFloor(fb.rect[0], layer_tile);
            const ty0 = @divFloor(fb.rect[1], layer_tile);
            const tx1 = @divFloor(fb.rect[2] - 1, layer_tile);
            const ty1 = @divFloor(fb.rect[3] - 1, layer_tile);
            var ty = ty0;
            while (ty <= ty1) : (ty += 1) {
                var tx = tx0;
                while (tx <= tx1) : (tx += 1) {
                    const tr = [4]i32{
                        @max(tx * layer_tile, fb.full[0]),
                        @max(ty * layer_tile, fb.full[1]),
                        @min((tx + 1) * layer_tile, fb.full[2]),
                        @min((ty + 1) * layer_tile, fb.full[3]),
                    };
                    if (tr[2] <= tr[0] or tr[3] <= tr[1]) continue;
                    const key = try std.fmt.allocPrint(arena, "{s}@{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}#{d},{d}", .{ base, ctm_key[0], ctm_key[1], ctm_key[2], ctm_key[3], ctm_key[4], ctm_key[5], tx, ty });
                    if (self.layers.getPtr(key)) |t| {
                        try Add.tile(self, &extra_prims, &extra_paints, list, arena, fb, t, .{ 1, 0, 0, 1, @floatFromInt(-t.rect[0]), @floatFromInt(-t.rect[1]) }, t.rect, false, tmpl, prim_base, paint_base);
                        continue;
                    }
                    pending += 1;
                    const dx = @as(f64, @floatFromInt(@divTrunc(tr[0] + tr[2], 2) + ox)) - cx;
                    const dy = @as(f64, @floatFromInt(@divTrunc(tr[1] + tr[3], 2) + oy)) - cy;
                    try wanted_jobs.append(arena, .{
                        .key = try job_a.dupe(u8, key),
                        .base = try job_a.dupe(u8, base),
                        .ctm_key = ctm_key,
                        .id = try job_a.dupe(u8, fid),
                        .part = fb.part,
                        .child = fb.child,
                        .ctm = fb.ctm,
                        .rect = tr,
                        .dist = std.math.hypot(dx, dy),
                    });
                    // A stand-in: this part's tiles at another matrix, mapped here.
                    const inv = invert(fb.ctm) orelse continue;
                    const others = self.by_base.getPtr(base) orelse continue;
                    var best: ?[6]u32 = null;
                    var best_made: u64 = 0;
                    for (others.items) |k| {
                        const o = self.layers.getPtr(k) orelse continue;
                        if (!std.mem.eql(u32, &o.ctm_key, &ctm_key) and (best == null or o.made > best_made)) {
                            best = o.ctm_key;
                            best_made = o.made;
                        }
                    }
                    const best_key = best orelse continue;
                    for (others.items) |k| {
                        const o = self.layers.getPtr(k) orelse continue;
                        if (!std.mem.eql(u32, &o.ctm_key, &best_key)) continue;
                        // New top space to the old tile's texels.
                        const to_old = mul(o.ctm, inv);
                        const m = mul(.{ 1, 0, 0, 1, @floatFromInt(-o.rect[0]), @floatFromInt(-o.rect[1]) }, to_old);
                        const back = invert(to_old) orelse continue;
                        const pts = [4][2]f32{
                            apply(back, @floatFromInt(o.rect[0]), @floatFromInt(o.rect[1])),
                            apply(back, @floatFromInt(o.rect[2]), @floatFromInt(o.rect[1])),
                            apply(back, @floatFromInt(o.rect[0]), @floatFromInt(o.rect[3])),
                            apply(back, @floatFromInt(o.rect[2]), @floatFromInt(o.rect[3])),
                        };
                        var lo = pts[0];
                        var hi = pts[0];
                        for (pts[1..]) |p| {
                            lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
                            hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
                        }
                        const cut = [4]i32{
                            @max(@as(i32, @intFromFloat(@floor(lo[0]))), tr[0]),
                            @max(@as(i32, @intFromFloat(@floor(lo[1]))), tr[1]),
                            @min(@as(i32, @intFromFloat(@ceil(hi[0]))), tr[2]),
                            @min(@as(i32, @intFromFloat(@ceil(hi[1]))), tr[3]),
                        };
                        try Add.tile(self, &extra_prims, &extra_paints, list, arena, fb, o, m, cut, true, tmpl, prim_base, paint_base);
                    }
                }
            }
        }
        stats.pending = pending;
        if (wanted or pending > 0) {
            std.mem.sort(LayerJob, wanted_jobs.items, {}, struct {
                fn lt(_: void, a: LayerJob, b: LayerJob) bool {
                    return a.dist < b.dist;
                }
            }.lt);
            self.queue_jobs.clearRetainingCapacity();
            try self.queue_jobs.appendSlice(self.gpa, wanted_jobs.items);
        }

        // Upload.
        const prim_bytes = (prims.len + extra_prims.items.len) * @sizeOf(sc.Prim);
        const paint_bytes = (paints.len + extra_paints.items.len) * @sizeOf(sc.Paint);
        const shape_bytes = scene.shapes.items.len * @sizeOf(sc.Shape);
        const stop_bytes = scene.stops.items.len * 16;
        const storage = c.WGPUBufferUsage_Storage;
        const prim_buf = self.buffer(.prims, prim_bytes + 64, storage);
        const paint_buf = self.buffer(.paints, paint_bytes + 64, storage);
        const shape_buf = self.buffer(.shapes, shape_bytes + 128, storage);
        const stop_buf = self.buffer(.stops, stop_bytes + 16, storage);
        const q = self.queue;
        writeSlice(q, prim_buf, 0, std.mem.sliceAsBytes(prims));
        writeSlice(q, prim_buf, prims.len * @sizeOf(sc.Prim), std.mem.sliceAsBytes(extra_prims.items));
        writeSlice(q, paint_buf, 0, std.mem.sliceAsBytes(paints));
        writeSlice(q, paint_buf, paints.len * @sizeOf(sc.Paint), std.mem.sliceAsBytes(extra_paints.items));
        writeSlice(q, shape_buf, 0, std.mem.sliceAsBytes(scene.shapes.items));
        writeSlice(q, stop_buf, 0, std.mem.sliceAsBytes(scene.stops.items));

        // New glyph masks into the glyph atlas.
        for (scene.glyph_uploads.items) |u| {
            if (u.w == 0 or u.h == 0) continue;
            writeTexture(q, self.glyph_atlas, 0, u.x, u.y, u.w, u.h, scene.glyph_bytes.items[u.ptr..][0 .. u.w * u.h], u.w);
        }

        // The path atlas.
        var draw_calls: u32 = 0;
        const layers = scene.layers.items;
        try self.ensureAtlas(@max(1, @as(u32, @intCast(layers.len))));
        if (layers.len > 0) {
            const vert_bytes = scene.verts.items.len * 8;
            const vert_buf = self.buffer(.verts, vert_bytes + 8, c.WGPUBufferUsage_Vertex);
            writeSlice(q, vert_buf, 0, std.mem.sliceAsBytes(scene.verts.items));
            const glyph_bytes = scene.glyph_draws.items.len * 32;
            const glyph_buf = self.buffer(.glyphs, glyph_bytes + 32, c.WGPUBufferUsage_Vertex);
            writeSlice(q, glyph_buf, 0, std.mem.sliceAsBytes(scene.glyph_draws.items));
            // Cover rects per layer, nonzero ones then even-odd ones.
            const entries = scene.entries.items;
            const rects = try arena.alloc([4]u32, entries.len);
            const spans = try arena.alloc([3]u32, layers.len);
            var n: u32 = 0;
            for (layers, 0..) |ly, l| {
                var span = [3]u32{ n, 0, 0 };
                for ([_]u32{ 0, 1 }) |rule| {
                    for (entries[ly.entry_first..][0..ly.entry_count]) |e| {
                        if (e.rule != rule) continue;
                        rects[n] = .{ e.x, e.y, e.w, e.h };
                        n += 1;
                        span[rule + 1] += 1;
                    }
                }
                spans[l] = span;
            }
            const rect_buf = self.buffer(.covers, @as(u64, n) * 16 + 16, c.WGPUBufferUsage_Vertex);
            writeSlice(q, rect_buf, 0, std.mem.sliceAsBytes(rects[0..n]));
            for (layers, 0..) |ly, l| {
                var color = colorAttachment(self.msaa_color_view, true, .{ 0, 0, 0, 0 });
                color.resolveTarget = self.atlas_views.items[l];
                color.storeOp = c.WGPUStoreOp_Discard;
                var ds = std.mem.zeroes(c.WGPURenderPassDepthStencilAttachment);
                ds.view = self.msaa_stencil_view;
                ds.depthLoadOp = c.WGPULoadOp_Undefined;
                ds.depthStoreOp = c.WGPUStoreOp_Undefined;
                ds.depthClearValue = std.math.nan(f32);
                ds.stencilLoadOp = c.WGPULoadOp_Clear;
                ds.stencilStoreOp = c.WGPUStoreOp_Discard;
                ds.stencilClearValue = 0;
                var desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
                desc.colorAttachmentCount = 1;
                desc.colorAttachments = &color;
                desc.depthStencilAttachment = &ds;
                const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &desc);
                c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.atlas_group, 0, null);
                c.wgpuRenderPassEncoderSetStencilReference(pass, 0);
                if (ly.vert_count > 0) {
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.stencil_pipeline);
                    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vert_buf, @as(u64, ly.vert_first) * 8, @as(u64, ly.vert_count) * 8);
                    c.wgpuRenderPassEncoderDraw(pass, ly.vert_count, 1, 0, 0);
                    draw_calls += 1;
                }
                const span = spans[l];
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, rect_buf, 0, c.WGPU_WHOLE_SIZE);
                if (span[1] > 0) {
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.cover_pipelines[0]);
                    c.wgpuRenderPassEncoderDraw(pass, 4, span[1], 0, span[0]);
                    draw_calls += 1;
                }
                if (span[2] > 0) {
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.cover_pipelines[1]);
                    c.wgpuRenderPassEncoderDraw(pass, 4, span[2], 0, span[0] + span[1]);
                    draw_calls += 1;
                }
                c.wgpuRenderPassEncoderEnd(pass);
                c.wgpuRenderPassEncoderRelease(pass);
                if (ly.glyph_count > 0) {
                    const gp = beginPass(encoder, self.atlas_views.items[l], true, .{ 0, 0, 0, 0 });
                    c.wgpuRenderPassEncoderSetPipeline(gp, self.glyph_pipeline);
                    c.wgpuRenderPassEncoderSetBindGroup(gp, 0, self.atlas_group, 0, null);
                    c.wgpuRenderPassEncoderSetVertexBuffer(gp, 0, glyph_buf, 0, c.WGPU_WHOLE_SIZE);
                    c.wgpuRenderPassEncoderDraw(gp, 4, ly.glyph_count, 0, ly.glyph_first);
                    c.wgpuRenderPassEncoderEnd(gp);
                    c.wgpuRenderPassEncoderRelease(gp);
                    draw_calls += 1;
                }
            }
        }

        // Surfaces: kept ones as they are, the rest drawn this frame.
        const surfaces = scene.surfaces.items;
        const surf_tex = try arena.alloc(c.WGPUTexture, surfaces.len);
        @memset(surf_tex, null);
        var drawn: std.ArrayList(c.WGPUTexture) = .empty;
        // Pixels drawn this frame may be kept only when the frame lacked nothing.
        const keepable = self.keep and complete and !deferred and pending == 0;

        // The draws, recorded as steps: render and compute passes are encoded once the
        // uniform slots are final.
        var steps: std.ArrayList(Step) = .empty;
        var ops: std.ArrayList(Op) = .empty;
        var stack: std.ArrayList(*Target) = .empty;
        const root = try arena.create(Target);
        root.* = .{
            .texture = target,
            .w = tw,
            .h = th,
            .cleared = false,
        };
        try stack.append(arena, root);
        var size_slots: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
        var open: ?Open = null;

        const Rec = struct {
            h: *Host,
            a: Allocator,
            steps: *std.ArrayList(Step),
            ops: *std.ArrayList(Op),
            stack: *std.ArrayList(*Target),
            size_slots: *std.AutoHashMapUnmanaged([2]u32, u32),
            open: *?Open,
            root: *Target,
            clear: [4]f64,

            fn top(r: @This()) *Target {
                return r.stack.items[r.stack.items.len - 1];
            }

            fn flush(r: @This()) !void {
                const o = r.open.* orelse return;
                r.open.* = null;
                // Whether this pass clears is decided now (the flag changes before steps run).
                try r.steps.append(r.a, .{
                    .render = .{
                        .target = o.target.texture,
                        .load = o.target.cleared,
                        .clear = if (o.target == r.root) r.clear else .{ 0, 0, 0, 0 },
                        .slot = o.slot,
                        .ops_first = o.ops_first,
                        .ops_count = r.ops.items.len - o.ops_first,
                    },
                });
                o.target.cleared = true;
            }

            fn sizeSlot(r: @This(), w: u32, hh: u32) !u32 {
                const got = try r.size_slots.getOrPut(r.a, .{ w, hh });
                if (!got.found_existing) {
                    const s = try r.h.takeSlot();
                    s.f32s[0] = @floatFromInt(w);
                    s.f32s[1] = @floatFromInt(hh);
                    got.value_ptr.* = s.offset;
                }
                return got.value_ptr.*;
            }

            /// Starts a pass on the current target when none is open there.
            fn ensure(r: @This()) !void {
                const t = r.top();
                if (r.open.*) |o| if (o.target == t) return;
                try r.flush();
                // Prims address the target's texels: NDC over the whole texture.
                const slot = try r.sizeSlot(c.wgpuTextureGetWidth(t.texture), c.wgpuTextureGetHeight(t.texture));
                r.open.* = .{
                    .target = t,
                    .ops_first = r.ops.items.len,
                    .slot = slot,
                };
            }

            fn record(r: @This(), op: Op) !void {
                try r.ensure();
                try r.ops.append(r.a, op);
            }
        };
        const rec: Rec = .{
            .h = self,
            .a = arena,
            .steps = &steps,
            .ops = &ops,
            .stack = &stack,
            .size_slots = &size_slots,
            .open = &open,
            .root = root,
            .clear = clear_value,
        };

        var surfaces_drawn: u32 = 0;
        const draws = scene.draws.items;
        var i: usize = 0;
        while (i < draws.len) : (i += 1) {
            const d = draws[i];
            switch (d.kind) {
                sc.Draw.prims => {
                    const tex = try self.texOf(scene, surf_tex, d.tex);
                    const mask = try self.texOf(scene, surf_tex, d.mask);
                    if ((d.tex != none and tex == null) or (d.mask != none and mask == null)) continue;
                    if (d.flags & sc.Draw.backdrop != 0) {
                        // What is under the prim, copied first (one prim per draw).
                        var k = d.first;
                        while (k < d.first + d.count) : (k += 1) {
                            const p = prims[k];
                            const t = rec.top();
                            const x0: u32 = @intFromFloat(@max(0, @floor(p.x0)));
                            const y0: u32 = @intFromFloat(@max(0, @floor(p.y0)));
                            const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(t.w)), @ceil(p.x1)));
                            const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(t.h)), @ceil(p.y1)));
                            if (x1 <= x0 or y1 <= y0) continue;
                            // Nothing drawn here yet: clear it first.
                            if (!t.cleared and open == null) try rec.ensure();
                            try rec.flush();
                            const bd = self.backdropFor(x1 - x0, y1 - y0);
                            try steps.append(arena, .{
                                .copy = .{
                                    .src = t.texture,
                                    .x = x0,
                                    .y = y0,
                                    .dst = bd,
                                    .w = x1 - x0,
                                    .h = y1 - y0,
                                },
                            });
                            const group = self.group1(tex orelse self.dummy_view, self.view(bd), mask);
                            try rec.record(.{
                                .pipeline = self.paint.replace,
                                .group = group,
                                .count = 1,
                                .first = k,
                            });
                            draw_calls += 1;
                        }
                        continue;
                    }
                    const group = if (tex != null or mask != null) self.group1(tex orelse self.dummy_view, null, mask) else self.dummy_group;
                    const pipe = if (d.flags & sc.Draw.max != 0) self.paint.max else if (d.flags & sc.Draw.erase != 0) self.paint.erase else self.paint.over;
                    try rec.record(.{
                        .pipeline = pipe,
                        .group = group,
                        .count = d.count,
                        .first = d.first,
                    });
                    draw_calls += 1;
                },
                sc.Draw.fallback => {
                    for (fb_draws[d.tex].items) |t| {
                        try rec.record(.{
                            .pipeline = self.paint.over,
                            .group = self.group1(self.view(t.texture), null, null),
                            .count = 1,
                            .first = t.prim,
                        });
                        draw_calls += 1;
                    }
                },
                sc.Draw.begin => {
                    const s = d.first;
                    const surf = surfaces[s];
                    const key = [2]u32{ surf.key_lo, surf.key_hi };
                    const cacheable = surf.flags & sc.Surface.cacheable != 0;
                    if (cacheable and self.keep) if (self.kept.getPtr(key)) |k| {
                        if (c.wgpuTextureGetWidth(k.texture) >= surf.w and c.wgpuTextureGetHeight(k.texture) >= surf.h) {
                            k.used = self.frame_no;
                            surf_tex[s] = k.texture;
                            // Skip to its end.
                            i = surf.end;
                            continue;
                        }
                    };
                    try rec.flush();
                    const t = self.acquire(@max(1, surf.w), @max(1, surf.h));
                    surf_tex[s] = t;
                    try drawn.append(arena, t);
                    surfaces_drawn += 1;
                    const nt = try arena.create(Target);
                    nt.* = .{
                        .texture = t,
                        .w = surf.w,
                        .h = surf.h,
                        .cleared = false,
                    };
                    try stack.append(arena, nt);
                    // Cleared even when nothing draws into it.
                    try rec.ensure();
                },
                sc.Draw.end => {
                    try rec.flush();
                    _ = stack.pop();
                    const s = d.first;
                    const surf = surfaces[s];
                    const key = [2]u32{ surf.key_lo, surf.key_hi };
                    const cacheable = surf.flags & sc.Surface.cacheable != 0;
                    if (keepable and cacheable and surf_tex[s] != null and !self.kept.contains(key)) {
                        const tex = surf_tex[s];
                        const bytes = @as(u64, c.wgpuTextureGetWidth(tex)) * c.wgpuTextureGetHeight(tex) * 8;
                        try self.kept.put(self.gpa, key, .{
                            .texture = tex,
                            .bytes = bytes,
                            .used = self.frame_no,
                        });
                        self.kept_bytes += bytes;
                        for (drawn.items, 0..) |x, at| if (x == tex) {
                            _ = drawn.swapRemove(at);
                            break;
                        };
                    }
                },
                sc.Draw.pass => {
                    try rec.flush();
                    const pr = scene.passes.items[d.first];
                    const dst_tex = surf_tex[pr.dst];
                    if (dst_tex == null) continue;
                    const ds = surfaces[pr.dst];
                    const size = [4]i32{ @intCast(ds.w), @intCast(ds.h), ds.x0, ds.y0 };
                    const tmp = self.acquire(c.wgpuTextureGetWidth(dst_tex), c.wgpuTextureGetHeight(dst_tex));
                    try drawn.append(arena, tmp);
                    const kind = pr.kind;
                    const Fx = struct {
                        fn dispatch(h: *Host, st: *std.ArrayList(Step), a: Allocator, p: sc.Pass, sz: [4]i32, entry: usize, src: c.WGPUTexture, dst: c.WGPUTexture, dir: u32, step_no: u32, per_line: bool) !void {
                            const s = try h.takeSlot();
                            s.u32s[0] = p.kind;
                            s.u32s[1] = dir;
                            s.u32s[2] = step_no;
                            for (0..4) |k| s.u32s[4 + k] = @bitCast(sz[k]);
                            for (0..8) |k| s.u32s[8 + k] = @bitCast(p.i[k]);
                            for (0..20) |k| s.f32s[16 + k] = p.f[k];
                            const w: u32 = @intCast(sz[0]);
                            const hh: u32 = @intCast(sz[1]);
                            try st.append(a, .{
                                .compute = .{
                                    .pipeline = h.fx_pipelines[entry],
                                    .src = src,
                                    .dst = dst,
                                    .slot = s.offset,
                                    .x = if (per_line) std.math.divCeil(u32, if (dir == 0) hh else w, 64) catch 0 else std.math.divCeil(u32, w, 8) catch 0,
                                    .y = if (per_line) 1 else std.math.divCeil(u32, hh, 8) catch 0,
                                },
                            });
                        }
                    };
                    switch (kind) {
                        @backingInt(sc.PassKind.gauss), @backingInt(sc.PassKind.progressive), @backingInt(sc.PassKind.spread) => {
                            const entry: usize = switch (kind) {
                                @backingInt(sc.PassKind.gauss) => 0,
                                @backingInt(sc.PassKind.progressive) => 2,
                                else => 3,
                            };
                            try Fx.dispatch(self, &steps, arena, pr, size, entry, dst_tex, tmp, 0, 0, false);
                            try Fx.dispatch(self, &steps, arena, pr, size, entry, tmp, dst_tex, 1, 0, false);
                        },
                        @backingInt(sc.PassKind.box3) => {
                            for (0..3) |b| {
                                try Fx.dispatch(self, &steps, arena, pr, size, 1, dst_tex, tmp, 0, @intCast(b), true);
                                try Fx.dispatch(self, &steps, arena, pr, size, 1, tmp, dst_tex, 1, @intCast(b), true);
                            }
                        },
                        @backingInt(sc.PassKind.noise), @backingInt(sc.PassKind.texture) => {
                            const src_tex = if (pr.src != none) surf_tex[pr.src] else null;
                            if (src_tex == null) continue;
                            try steps.append(arena, .{
                                .copy = .{
                                    .src = src_tex,
                                    .x = 0,
                                    .y = 0,
                                    .dst = tmp,
                                    .w = c.wgpuTextureGetWidth(src_tex),
                                    .h = c.wgpuTextureGetHeight(src_tex),
                                },
                            });
                            try Fx.dispatch(self, &steps, arena, pr, size, if (kind == @backingInt(sc.PassKind.noise)) 4 else 5, tmp, dst_tex, 0, 0, false);
                        },
                        @backingInt(sc.PassKind.backdrop) => {
                            const t = rec.top();
                            if (!t.cleared) {
                                try rec.ensure();
                                try rec.flush();
                            }
                            try Fx.dispatch(self, &steps, arena, pr, size, 6, t.texture, dst_tex, 0, 0, false);
                        },
                        else => {},
                    }
                    draw_calls += 1;
                },
                else => {},
            }
        }
        try rec.flush();

        // The slots are final: upload them, then record.
        const slot_bytes = self.slots.items.len;
        if (self.slot_buf_size < slot_bytes) {
            self.doomBuffer(self.slot_buf);
            var size = self.slot_buf_size;
            while (size < slot_bytes) size *= 2;
            self.slot_buf = createBuffer(self.device, size, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst);
            self.slot_buf_size = size;
        }
        writeSlice(q, self.slot_buf, 0, self.slots.items);
        // One bind group for every pass (made now: the slot buffer is final).
        const g0 = bindGroup(self.device, self.g0_layout, &.{
            bufferBinding(0, self.slot_buf, 16),
            bufferBinding(1, prim_buf, c.WGPU_WHOLE_SIZE),
            bufferBinding(2, shape_buf, c.WGPU_WHOLE_SIZE),
            bufferBinding(3, paint_buf, c.WGPU_WHOLE_SIZE),
            bufferBinding(4, stop_buf, c.WGPU_WHOLE_SIZE),
            textureBinding(5, self.atlas_array_view),
        });
        try self.transient_groups.append(self.gpa, g0);
        for (steps.items) |step| switch (step) {
            .render => |r| {
                const pass = beginPass(encoder, self.view(r.target), r.load, r.clear);
                const offset = [1]u32{r.slot};
                c.wgpuRenderPassEncoderSetBindGroup(pass, 0, g0, 1, &offset);
                for (ops.items[r.ops_first..][0..r.ops_count]) |op| {
                    c.wgpuRenderPassEncoderSetPipeline(pass, op.pipeline);
                    c.wgpuRenderPassEncoderSetBindGroup(pass, 1, op.group, 0, null);
                    c.wgpuRenderPassEncoderDraw(pass, 4, op.count, 0, op.first);
                }
                c.wgpuRenderPassEncoderEnd(pass);
                c.wgpuRenderPassEncoderRelease(pass);
            },
            .copy => |cp| copyTextureToTexture(encoder, cp.src, cp.x, cp.y, cp.dst, cp.w, cp.h),
            .compute => |cm| {
                const group = bindGroup(self.device, self.fx_layout, &.{
                    bufferBinding(0, self.slot_buf, 144),
                    textureBinding(1, self.view(cm.src)),
                    textureBinding(2, self.view(cm.dst)),
                });
                try self.transient_groups.append(self.gpa, group);
                const cp = c.wgpuCommandEncoderBeginComputePass(encoder, null);
                c.wgpuComputePassEncoderSetPipeline(cp, cm.pipeline);
                const offset = [1]u32{cm.slot};
                c.wgpuComputePassEncoderSetBindGroup(cp, 0, group, 1, &offset);
                c.wgpuComputePassEncoderDispatchWorkgroups(cp, cm.x, cm.y, 1);
                c.wgpuComputePassEncoderEnd(cp);
                c.wgpuComputePassEncoderRelease(cp);
            },
        };
        // Textures of this frame go back to the pool once the GPU is done with them (the
        // queue keeps its order: later frames' writes come after).
        for (drawn.items) |t| self.release(t);
        stats.surfaces_drawn = surfaces_drawn;
        stats.draw_calls = draw_calls;
        var bytes: u64 = 0;
        var ii = self.images.valueIterator();
        while (ii.next()) |img| bytes += img.bytes;
        stats.kept_bytes = self.kept_bytes;
        stats.texture_bytes = bytes + self.layer_bytes + self.kept_bytes + self.free_bytes + @as(u64, self.atlas_layers) * atlas_size * atlas_size + @as(u64, atlas_size) * atlas_size * 8 + @as(u64, tw) * th * 8;
    }

    fn texOf(self: *Host, scene: *const Scene, surf_tex: []c.WGPUTexture, code: u32) !?c.WGPUTextureView {
        if (code == none) return null;
        if (code & surface_bit != 0) {
            const t = surf_tex[code & ~surface_bit];
            return if (t != null) self.view(t) else null;
        }
        return (try self.image(scene, code)).view;
    }

    const Slot = struct {
        offset: u32,
        u32s: *[slot_size / 4]u32,
        f32s: *[slot_size / 4]f32,
    };

    /// A fresh uniform slot: its byte offset and views over it.
    fn takeSlot(self: *Host) !Slot {
        const offset = self.slots.items.len;
        try self.slots.appendNTimes(self.gpa, 0, slot_size);
        const bytes = self.slots.items[offset..][0..slot_size];
        return .{
            .offset = @intCast(offset),
            .u32s = @ptrCast(@alignCast(bytes)),
            .f32s = @ptrCast(@alignCast(bytes)),
        };
    }

    // ------------------------------------------------------------------ CPU layers

    /// Draws queued layer tiles, nearest the centre first, until `budget_ns` is spent.
    /// Answers whether any was drawn (the next frame shows it).
    pub fn pump(self: *Host, sess: *Session, budget_ns: u64) bool {
        var timer = Timer.start();
        var any = false;
        while (self.queue_jobs.items.len > 0) {
            if (timer.elapsedNs() >= budget_ns) break;
            const job = self.queue_jobs.orderedRemove(0);
            if (self.layers.contains(job.key)) continue;
            self.drawLayer(sess, job) catch |e| std.debug.print("layer {s}: {}\n", .{ job.key, e });
            any = true;
        }
        return any;
    }

    pub fn pendingLayers(self: *const Host) usize {
        return self.queue_jobs.items.len;
    }

    fn drawLayer(self: *Host, sess: *Session, job: LayerJob) !void {
        const part = std.enums.fromInt(Session.LayerPart, job.part) orelse return error.BadPart;
        const w: u32 = @intCast(job.rect[2] - job.rect[0]);
        const h: u32 = @intCast(job.rect[3] - job.rect[1]);
        var px = try sess.renderLayer(job.id, part, job.child, .{
            .a = job.ctm[0],
            .b = job.ctm[1],
            .c = job.ctm[2],
            .d = job.ctm[3],
            .e = job.ctm[4],
            .f = job.ctm[5],
        }, .{
            .x0 = job.rect[0],
            .y0 = job.rect[1],
            .x1 = job.rect[2],
            .y1 = job.rect[3],
        });
        defer px.deinit(self.gpa);
        // Premultiplied RGBA8, as the browser's workers hand it over.
        const data = try self.gpa.alloc(u8, @as(usize, w) * h * 4);
        defer self.gpa.free(data);
        for (px.data, 0..) |v, i| {
            inline for (0..4) |k| data[i * 4 + k] = @intFromFloat(@round(std.math.clamp(v[k], 0, 1) * 255));
        }
        const texture = createTexture(self.device, w, h, 1, c.WGPUTextureFormat_RGBA8Unorm, c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst, 1, 1);
        writeTexture(self.queue, texture, 0, 0, 0, w, h, data, w * 4);
        const key = try self.gpa.dupe(u8, job.key);
        const got_base = try self.by_base.getOrPut(self.gpa, job.base);
        if (!got_base.found_existing) {
            got_base.key_ptr.* = try self.gpa.dupe(u8, job.base);
            got_base.value_ptr.* = .empty;
        }
        try got_base.value_ptr.append(self.gpa, key);
        try self.layers.put(self.gpa, key, .{
            .base = got_base.key_ptr.*,
            .ctm_key = job.ctm_key,
            .ctm = job.ctm,
            .rect = job.rect,
            .texture = texture,
            .bytes = @as(u64, w) * h * 4,
            .used = self.frame_no,
            .made = nowNs(),
        });
        self.layer_bytes += @as(u64, w) * h * 4;
    }

    /// Drops the least recently drawn layer tiles and kept surfaces past their caps
    /// (never this frame's).
    fn evict(self: *Host) void {
        if (self.layer_bytes > self.layer_cap) {
            while (self.layer_bytes > self.layer_cap * 9 / 10) {
                var oldest: ?[]const u8 = null;
                var oldest_used: u32 = std.math.maxInt(u32);
                var it = self.layers.iterator();
                while (it.next()) |e| if (e.value_ptr.used < self.frame_no and e.value_ptr.used < oldest_used) {
                    oldest = e.key_ptr.*;
                    oldest_used = e.value_ptr.used;
                };
                const key = oldest orelse break;
                const t = self.layers.fetchRemove(key).?;
                destroyTexture(t.value.texture);
                self.layer_bytes -= t.value.bytes;
                if (self.by_base.getPtr(t.value.base)) |list| {
                    for (list.items, 0..) |k, at| if (k.ptr == key.ptr) {
                        _ = list.swapRemove(at);
                        break;
                    };
                }
                self.gpa.free(key);
            }
        }
        if (self.kept_bytes > self.kept_cap) {
            while (self.kept_bytes > self.kept_cap * 8 / 10) {
                var oldest: ?[2]u32 = null;
                var oldest_used: u32 = std.math.maxInt(u32);
                var it = self.kept.iterator();
                while (it.next()) |e| if (e.value_ptr.used < self.frame_no and e.value_ptr.used < oldest_used) {
                    oldest = e.key_ptr.*;
                    oldest_used = e.value_ptr.used;
                };
                const key = oldest orelse break;
                const k = self.kept.fetchRemove(key).?;
                self.kept_bytes -= k.value.bytes;
                self.release(k.value.texture);
            }
        }
    }

    /// What waits for a frame to be submitted: what the frame made is released, and
    /// textures past their budgets go.
    fn afterSubmit(self: *Host) void {
        for (self.transient_groups.items) |g| c.wgpuBindGroupRelease(g);
        self.transient_groups.clearRetainingCapacity();
        for (self.transient_views.items) |v| c.wgpuTextureViewRelease(v);
        self.transient_views.clearRetainingCapacity();
        self.evict();
        self.trimFree();
        for (self.doomed.items) |t| destroyTexture(t);
        self.doomed.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------- helpers

fn ctmKey(m: [6]f32) [6]u32 {
    var k: [6]u32 = undefined;
    for (m, 0..) |v, i| k[i] = @bitCast(v);
    return k;
}

fn invert(m: [6]f32) ?[6]f32 {
    const det = m[0] * m[3] - m[1] * m[2];
    if (@abs(det) < 1e-12) return null;
    const id = 1 / det;
    return .{ m[3] * id, -m[1] * id, -m[2] * id, m[0] * id, (m[2] * m[5] - m[3] * m[4]) * id, (m[1] * m[4] - m[0] * m[5]) * id };
}

/// `a` after `b`.
fn mul(a: [6]f32, b: [6]f32) [6]f32 {
    return .{
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    };
}

fn apply(m: [6]f32, x: f32, y: f32) [2]f32 {
    return .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
}

fn half(h: u16) f32 {
    return @floatCast(@as(f16, @bitCast(h)));
}

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

pub fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub const Timer = struct {
    t: u64,

    pub fn start() Timer {
        return .{
            .t = nowNs(),
        };
    }

    pub fn elapsedNs(self: *const Timer) u64 {
        return nowNs() - self.t;
    }

    /// Milliseconds since the start or the last lap.
    pub fn lap(self: *Timer) f64 {
        const n = nowNs();
        const ms = @as(f64, @floatFromInt(n - self.t)) / std.time.ns_per_ms;
        self.t = n;
        return ms;
    }
};

fn destroyTexture(t: c.WGPUTexture) void {
    c.wgpuTextureDestroy(t);
    c.wgpuTextureRelease(t);
}

pub fn createTexture(device: c.WGPUDevice, w: u32, h: u32, layers: u32, format: c.WGPUTextureFormat, usage: c.WGPUTextureUsage, mips: u32, samples: u32) c.WGPUTexture {
    var desc = std.mem.zeroes(c.WGPUTextureDescriptor);
    desc.usage = usage;
    desc.dimension = c.WGPUTextureDimension_2D;
    desc.size = .{
        .width = w,
        .height = h,
        .depthOrArrayLayers = layers,
    };
    desc.format = format;
    desc.mipLevelCount = mips;
    desc.sampleCount = samples;
    return c.wgpuDeviceCreateTexture(device, &desc);
}

pub fn createBuffer(device: c.WGPUDevice, size: u64, usage: c.WGPUBufferUsage) c.WGPUBuffer {
    var desc = std.mem.zeroes(c.WGPUBufferDescriptor);
    desc.usage = usage;
    desc.size = size;
    return c.wgpuDeviceCreateBuffer(device, &desc);
}

fn viewDesc(dim: c.WGPUTextureViewDimension) c.WGPUTextureViewDescriptor {
    var desc = std.mem.zeroes(c.WGPUTextureViewDescriptor);
    desc.dimension = dim;
    desc.mipLevelCount = c.WGPU_MIP_LEVEL_COUNT_UNDEFINED;
    desc.arrayLayerCount = c.WGPU_ARRAY_LAYER_COUNT_UNDEFINED;
    desc.aspect = c.WGPUTextureAspect_All;
    return desc;
}

pub fn writeSlice(q: c.WGPUQueue, buf: c.WGPUBuffer, offset: usize, bytes: []const u8) void {
    if (bytes.len == 0) return;
    c.wgpuQueueWriteBuffer(q, buf, offset, bytes.ptr, bytes.len);
}

fn writeTexture(q: c.WGPUQueue, tex: c.WGPUTexture, mip: u32, x: u32, y: u32, w: u32, h: u32, data: []const u8, bytes_per_row: u32) void {
    var dst = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    dst.texture = tex;
    dst.mipLevel = mip;
    dst.origin = .{
        .x = x,
        .y = y,
        .z = 0,
    };
    dst.aspect = c.WGPUTextureAspect_All;
    var layout = std.mem.zeroes(c.WGPUTexelCopyBufferLayout);
    layout.bytesPerRow = bytes_per_row;
    layout.rowsPerImage = h;
    const size: c.WGPUExtent3D = .{
        .width = w,
        .height = h,
        .depthOrArrayLayers = 1,
    };
    c.wgpuQueueWriteTexture(q, &dst, data.ptr, data.len, &layout, &size);
}

fn copyTextureToTexture(enc: c.WGPUCommandEncoder, src: c.WGPUTexture, x: u32, y: u32, dst: c.WGPUTexture, w: u32, h: u32) void {
    var s = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    s.texture = src;
    s.origin = .{
        .x = x,
        .y = y,
        .z = 0,
    };
    s.aspect = c.WGPUTextureAspect_All;
    var d = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    d.texture = dst;
    d.aspect = c.WGPUTextureAspect_All;
    const size: c.WGPUExtent3D = .{
        .width = w,
        .height = h,
        .depthOrArrayLayers = 1,
    };
    c.wgpuCommandEncoderCopyTextureToTexture(enc, &s, &d, &size);
}

pub fn copyTextureToBuffer(enc: c.WGPUCommandEncoder, src: c.WGPUTexture, dst: c.WGPUBuffer, bpr: u32, w: u32, h: u32) void {
    var s = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    s.texture = src;
    s.aspect = c.WGPUTextureAspect_All;
    var d = std.mem.zeroes(c.WGPUTexelCopyBufferInfo);
    d.buffer = dst;
    d.layout.bytesPerRow = bpr;
    d.layout.rowsPerImage = h;
    const size: c.WGPUExtent3D = .{
        .width = w,
        .height = h,
        .depthOrArrayLayers = 1,
    };
    c.wgpuCommandEncoderCopyTextureToBuffer(enc, &s, &d, &size);
}

/// Maps `buf` for reading and waits: its bytes, valid until it is unmapped.
pub fn mapRead(device: c.WGPUDevice, buf: c.WGPUBuffer, size: u64) ![]const u8 {
    const State = struct {
        done: bool = false,
        ok: bool = false,

        fn cb(status: c.WGPUMapAsyncStatus, _: c.WGPUStringView, ud: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(ud));
            s.ok = status == c.WGPUMapAsyncStatus_Success;
            s.done = true;
        }
    };
    var st: State = .{};
    _ = c.wgpuBufferMapAsync(buf, c.WGPUMapMode_Read, 0, size, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = State.cb,
        .userdata1 = &st,
        .userdata2 = null,
    });
    while (!st.done) _ = c.wgpuDevicePoll(device, 1, null);
    if (!st.ok) return error.MapFailed;
    const p: [*]const u8 = @ptrCast(c.wgpuBufferGetConstMappedRange(buf, 0, size) orelse return error.MapFailed);
    return p[0..size];
}

pub fn colorAttachment(v: c.WGPUTextureView, clear: bool, value: [4]f64) c.WGPURenderPassColorAttachment {
    var att = std.mem.zeroes(c.WGPURenderPassColorAttachment);
    att.view = v;
    att.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
    att.loadOp = if (clear) c.WGPULoadOp_Clear else c.WGPULoadOp_Load;
    att.storeOp = c.WGPUStoreOp_Store;
    att.clearValue = .{
        .r = value[0],
        .g = value[1],
        .b = value[2],
        .a = value[3],
    };
    return att;
}

/// A render pass on `v`: kept (`load`) or cleared to `value`.
pub fn beginPass(enc: c.WGPUCommandEncoder, v: c.WGPUTextureView, load: bool, value: [4]f64) c.WGPURenderPassEncoder {
    var att = colorAttachment(v, !load, value);
    var desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
    desc.colorAttachmentCount = 1;
    desc.colorAttachments = &att;
    return c.wgpuCommandEncoderBeginRenderPass(enc, &desc);
}

pub fn shaderModule(device: c.WGPUDevice, code: []const u8, label: []const u8) c.WGPUShaderModule {
    var wgsl = std.mem.zeroes(c.WGPUShaderSourceWGSL);
    wgsl.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    wgsl.code = platform.gpu.str(code);
    var desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
    desc.nextInChain = &wgsl.chain;
    desc.label = platform.gpu.str(label);
    return c.wgpuDeviceCreateShaderModule(device, &desc);
}

pub fn bindGroupLayout(device: c.WGPUDevice, entries: []const c.WGPUBindGroupLayoutEntry) c.WGPUBindGroupLayout {
    var desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
    desc.entryCount = entries.len;
    desc.entries = entries.ptr;
    return c.wgpuDeviceCreateBindGroupLayout(device, &desc);
}

pub fn uniformEntry(binding: u32, visibility: c.WGPUShaderStage, dynamic: bool, min_size: u64) c.WGPUBindGroupLayoutEntry {
    var e = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
    e.binding = binding;
    e.visibility = visibility;
    e.buffer.type = c.WGPUBufferBindingType_Uniform;
    e.buffer.hasDynamicOffset = @intFromBool(dynamic);
    e.buffer.minBindingSize = min_size;
    return e;
}

fn storageEntry(binding: u32, visibility: c.WGPUShaderStage) c.WGPUBindGroupLayoutEntry {
    var e = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
    e.binding = binding;
    e.visibility = visibility;
    e.buffer.type = c.WGPUBufferBindingType_ReadOnlyStorage;
    return e;
}

fn textureEntry(binding: u32, visibility: c.WGPUShaderStage, sample: c.WGPUTextureSampleType, dim: c.WGPUTextureViewDimension) c.WGPUBindGroupLayoutEntry {
    var e = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
    e.binding = binding;
    e.visibility = visibility;
    e.texture.sampleType = sample;
    e.texture.viewDimension = dim;
    return e;
}

pub fn bindGroup(device: c.WGPUDevice, layout: c.WGPUBindGroupLayout, entries: []const c.WGPUBindGroupEntry) c.WGPUBindGroup {
    var desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
    desc.layout = layout;
    desc.entryCount = entries.len;
    desc.entries = entries.ptr;
    return c.wgpuDeviceCreateBindGroup(device, &desc);
}

pub fn bufferBinding(binding: u32, buf: c.WGPUBuffer, size: u64) c.WGPUBindGroupEntry {
    var e = std.mem.zeroes(c.WGPUBindGroupEntry);
    e.binding = binding;
    e.buffer = buf;
    e.size = size;
    return e;
}

pub fn textureBinding(binding: u32, v: c.WGPUTextureView) c.WGPUBindGroupEntry {
    var e = std.mem.zeroes(c.WGPUBindGroupEntry);
    e.binding = binding;
    e.textureView = v;
    return e;
}

pub fn pipelineLayout(device: c.WGPUDevice, groups: []const c.WGPUBindGroupLayout) c.WGPUPipelineLayout {
    var desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
    desc.bindGroupLayoutCount = groups.len;
    desc.bindGroupLayouts = groups.ptr;
    return c.wgpuDeviceCreatePipelineLayout(device, &desc);
}

pub fn blendOf(op: c.WGPUBlendOperation, src: c.WGPUBlendFactor, dst: c.WGPUBlendFactor) c.WGPUBlendState {
    const comp: c.WGPUBlendComponent = .{
        .operation = op,
        .srcFactor = src,
        .dstFactor = dst,
    };
    return .{
        .color = comp,
        .alpha = comp,
    };
}

fn depthStencil() c.WGPUDepthStencilState {
    var ds = std.mem.zeroes(c.WGPUDepthStencilState);
    ds.format = c.WGPUTextureFormat_Stencil8;
    ds.depthWriteEnabled = c.WGPUOptionalBool_False;
    ds.depthCompare = c.WGPUCompareFunction_Always;
    ds.stencilReadMask = 0xff;
    ds.stencilWriteMask = 0xff;
    return ds;
}

/// The inputs of a render pipeline, after WebGPU's `WGPURenderPipelineDescriptor`.
pub const PipelineDescriptor = struct {
    layout: c.WGPUPipelineLayout,
    module: c.WGPUShaderModule,
    vs: []const u8,
    fs: []const u8,
    format: c.WGPUTextureFormat,
    blend: ?c.WGPUBlendState = null,
    write_mask: c.WGPUColorWriteMask = c.WGPUColorWriteMask_All,
    topology: c.WGPUPrimitiveTopology,
    buffers: []const c.WGPUVertexBufferLayout = &.{},
    depth_stencil: ?*const c.WGPUDepthStencilState = null,
    samples: u32 = 1,
};

pub fn renderPipeline(device: c.WGPUDevice, descriptor: PipelineDescriptor) c.WGPURenderPipeline {
    var blend = descriptor.blend orelse undefined;
    var target = std.mem.zeroes(c.WGPUColorTargetState);
    target.format = descriptor.format;
    target.blend = if (descriptor.blend != null) &blend else null;
    target.writeMask = descriptor.write_mask;
    var frag = std.mem.zeroes(c.WGPUFragmentState);
    frag.module = descriptor.module;
    frag.entryPoint = platform.gpu.str(descriptor.fs);
    frag.targetCount = 1;
    frag.targets = &target;
    var desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
    desc.layout = descriptor.layout;
    desc.vertex.module = descriptor.module;
    desc.vertex.entryPoint = platform.gpu.str(descriptor.vs);
    desc.vertex.bufferCount = descriptor.buffers.len;
    desc.vertex.buffers = descriptor.buffers.ptr;
    desc.primitive.topology = descriptor.topology;
    desc.primitive.frontFace = c.WGPUFrontFace_CCW;
    desc.primitive.cullMode = c.WGPUCullMode_None;
    desc.depthStencil = descriptor.depth_stencil;
    desc.multisample.count = descriptor.samples;
    desc.multisample.mask = 0xFFFFFFFF;
    desc.fragment = &frag;
    return c.wgpuDeviceCreateRenderPipeline(device, &desc);
}

fn paintPipeline(device: c.WGPUDevice, layout: c.WGPUPipelineLayout, module: c.WGPUShaderModule, blend: ?c.WGPUBlendState) c.WGPURenderPipeline {
    return renderPipeline(device, .{
        .layout = layout,
        .module = module,
        .vs = "vs",
        .fs = "fs",
        .format = target_format,
        .blend = blend,
        .topology = c.WGPUPrimitiveTopology_TriangleStrip,
    });
}
