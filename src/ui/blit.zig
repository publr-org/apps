//! Puts a frame the UI drew (premultiplied RGBA, device pixels) on a GPU surface: one
//! texture, uploaded when the frame changes, drawn as a full-target triangle.

const std = @import("std");
const gpu = @import("native").gpu;
const c = gpu.c;
const Pixmap = @import("publr_engine").pixmap.Pixmap;

const shader =
    \\@group(0) @binding(0) var tex: texture_2d<f32>;
    \\struct Out { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> Out {
    \\  let uv = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    \\  var o: Out;
    \\  o.pos = vec4f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    \\  o.uv = uv;
    \\  return o;
    \\}
    \\@fragment fn fs(o: Out) -> @location(0) vec4f {
    \\  return textureLoad(tex, vec2i(o.pos.xy), 0);
    \\}
;

pub const Blit = struct {
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    pipeline: c.WGPURenderPipeline,
    layout: c.WGPUBindGroupLayout,
    texture: c.WGPUTexture = null,
    bind: c.WGPUBindGroup = null,
    width: u32 = 0,
    height: u32 = 0,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(g: *gpu.Gpu, format: c.WGPUTextureFormat) Blit {
        var wgsl = std.mem.zeroes(c.WGPUShaderSourceWGSL);
        wgsl.chain.sType = c.WGPUSType_ShaderSourceWGSL;
        wgsl.code = gpu.str(shader);
        var sm_desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
        sm_desc.nextInChain = &wgsl.chain;
        const module = c.wgpuDeviceCreateShaderModule(g.device, &sm_desc);
        defer c.wgpuShaderModuleRelease(module);

        var entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        entry.binding = 0;
        entry.visibility = c.WGPUShaderStage_Fragment;
        entry.texture.sampleType = c.WGPUTextureSampleType_Float;
        entry.texture.viewDimension = c.WGPUTextureViewDimension_2D;
        var bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
        bgl_desc.entryCount = 1;
        bgl_desc.entries = &entry;
        const layout = c.wgpuDeviceCreateBindGroupLayout(g.device, &bgl_desc);
        var pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
        pl_desc.bindGroupLayoutCount = 1;
        pl_desc.bindGroupLayouts = &layout;
        const pl = c.wgpuDeviceCreatePipelineLayout(g.device, &pl_desc);
        defer c.wgpuPipelineLayoutRelease(pl);

        var target = std.mem.zeroes(c.WGPUColorTargetState);
        target.format = format;
        target.writeMask = c.WGPUColorWriteMask_All;
        var frag = std.mem.zeroes(c.WGPUFragmentState);
        frag.module = module;
        frag.entryPoint = gpu.str("fs");
        frag.targetCount = 1;
        frag.targets = &target;
        var desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
        desc.layout = pl;
        desc.vertex.module = module;
        desc.vertex.entryPoint = gpu.str("vs");
        desc.primitive.topology = c.WGPUPrimitiveTopology_TriangleList;
        desc.multisample.count = 1;
        desc.multisample.mask = 0xffffffff;
        desc.fragment = &frag;
        return .{
            .device = g.device,
            .queue = g.queue,
            .pipeline = c.wgpuDeviceCreateRenderPipeline(g.device, &desc),
            .layout = layout,
        };
    }

    /// Uploads a whole frame (its rect at 0, 0) or a part of one (`Ui.renderRegion`, into
    /// the frame uploaded before); the next `draw` shows it.
    pub fn upload(self: *Blit, gpa: std.mem.Allocator, px: *const Pixmap) !void {
        const w = px.rect.width();
        const h = px.rect.height();
        const part = px.rect.x0 != 0 or px.rect.y0 != 0 or w != self.width or h != self.height;
        if (part and self.texture != null and px.rect.x1 <= self.width and px.rect.y1 <= self.height) {
            return self.write(gpa, px, @intCast(px.rect.x0), @intCast(px.rect.y0));
        }
        if (w != self.width or h != self.height) {
            if (self.bind != null) c.wgpuBindGroupRelease(self.bind);
            if (self.texture != null) c.wgpuTextureRelease(self.texture);
            var td = std.mem.zeroes(c.WGPUTextureDescriptor);
            td.usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst;
            td.dimension = c.WGPUTextureDimension_2D;
            td.size = .{
                .width = w,
                .height = h,
                .depthOrArrayLayers = 1,
            };
            td.format = c.WGPUTextureFormat_RGBA8Unorm;
            td.mipLevelCount = 1;
            td.sampleCount = 1;
            self.texture = c.wgpuDeviceCreateTexture(self.device, &td);
            const view = c.wgpuTextureCreateView(self.texture, null);
            defer c.wgpuTextureViewRelease(view);
            var be = std.mem.zeroes(c.WGPUBindGroupEntry);
            be.binding = 0;
            be.textureView = view;
            var bd = std.mem.zeroes(c.WGPUBindGroupDescriptor);
            bd.layout = self.layout;
            bd.entryCount = 1;
            bd.entries = &be;
            self.bind = c.wgpuDeviceCreateBindGroup(self.device, &bd);
            self.width = w;
            self.height = h;
        }
        try self.write(gpa, px, 0, 0);
    }

    fn write(self: *Blit, gpa: std.mem.Allocator, px: *const Pixmap, x: u32, y: u32) !void {
        const w = px.rect.width();
        const h = px.rect.height();
        try self.bytes.resize(gpa, @as(usize, w) * h * 4);
        // Opaque frames (the UI paints its background): premultiplied is straight.
        for (px.data, 0..) |p, i| inline for (0..4) |k| {
            self.bytes.items[i * 4 + k] = @intFromFloat(@round(std.math.clamp(p[k], 0, 1) * 255));
        };
        var dst = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
        dst.texture = self.texture;
        dst.aspect = c.WGPUTextureAspect_All;
        dst.origin = .{
            .x = x,
            .y = y,
            .z = 0,
        };
        var layout = std.mem.zeroes(c.WGPUTexelCopyBufferLayout);
        layout.bytesPerRow = w * 4;
        layout.rowsPerImage = h;
        c.wgpuQueueWriteTexture(self.queue, &dst, self.bytes.items.ptr, self.bytes.items.len, &layout, &.{
            .width = w,
            .height = h,
            .depthOrArrayLayers = 1,
        });
    }

    /// Draws the last uploaded frame over all of `target`.
    pub fn draw(self: *Blit, target: c.WGPUTextureView) void {
        if (self.bind == null) return;
        const enc = c.wgpuDeviceCreateCommandEncoder(self.device, null);
        var att = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        att.view = target;
        att.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
        att.loadOp = c.WGPULoadOp_Clear;
        att.storeOp = c.WGPUStoreOp_Store;
        var pd = std.mem.zeroes(c.WGPURenderPassDescriptor);
        pd.colorAttachmentCount = 1;
        pd.colorAttachments = &att;
        const pass = c.wgpuCommandEncoderBeginRenderPass(enc, &pd);
        c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
        c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind, 0, null);
        c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);
        const cmd = c.wgpuCommandEncoderFinish(enc, null);
        c.wgpuQueueSubmit(self.queue, 1, &cmd);
        c.wgpuCommandBufferRelease(cmd);
        c.wgpuCommandEncoderRelease(enc);
    }
};
