//! The GPU through WebGPU (wgpu-native): one device for the app, and a surface per `.gpu`
//! window. The calls are the WebGPU API a browser has, so code drawing with it reads like
//! the browser's.

const std = @import("std");
const builtin = @import("builtin");
pub const c = @import("wgpu");

pub const Error = error{
    NoAdapter,
    NoDevice,
    NoSurface,
};

/// A WebGPU string from a Zig slice.
pub fn str(s: []const u8) c.WGPUStringView {
    return .{
        .data = s.ptr,
        .length = s.len,
    };
}

pub fn span(s: c.WGPUStringView) []const u8 {
    if (s.data == null) return "";
    if (s.length == std.math.maxInt(usize)) return std.mem.span(@as([*:0]const u8, @ptrCast(s.data)));
    return s.data[0..s.length];
}

/// The instance, adapter, device and queue the app draws with.
pub const Gpu = struct {
    instance: c.WGPUInstance,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    pub fn init() Error!Gpu {
        const instance = c.wgpuCreateInstance(null) orelse return error.NoAdapter;
        var got: Got(c.WGPUAdapter) = .{};
        var opts = std.mem.zeroes(c.WGPURequestAdapterOptions);
        opts.powerPreference = c.WGPUPowerPreference_HighPerformance;
        _ = c.wgpuInstanceRequestAdapter(instance, &opts, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowSpontaneous,
            .callback = Got(c.WGPUAdapter).adapterCallback,
            .userdata1 = &got,
            .userdata2 = null,
        });
        while (!got.done) c.wgpuInstanceProcessEvents(instance);
        const adapter = got.value orelse return error.NoAdapter;

        var dgot: Got(c.WGPUDevice) = .{};
        var desc = std.mem.zeroes(c.WGPUDeviceDescriptor);
        desc.label = str("native");
        desc.uncapturedErrorCallbackInfo = .{
            .nextInChain = null,
            .callback = uncapturedError,
            .userdata1 = null,
            .userdata2 = null,
        };
        // The adapter's own limits: a design canvas needs large textures and buffers.
        var limits = std.mem.zeroes(c.WGPULimits);
        if (c.wgpuAdapterGetLimits(adapter, &limits) == c.WGPUStatus_Success) desc.requiredLimits = &limits;
        _ = c.wgpuAdapterRequestDevice(adapter, &desc, .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowSpontaneous,
            .callback = Got(c.WGPUDevice).deviceCallback,
            .userdata1 = &dgot,
            .userdata2 = null,
        });
        while (!dgot.done) c.wgpuInstanceProcessEvents(instance);
        const device = dgot.value orelse return error.NoDevice;
        return .{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = c.wgpuDeviceGetQueue(device),
        };
    }

    pub fn deinit(self: *Gpu) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuInstanceRelease(self.instance);
    }

    /// The surface of a `.gpu` window (its CAMetalLayer on macOS).
    pub fn surface(self: *Gpu, window: anytype) Error!Surface {
        var desc = std.mem.zeroes(c.WGPUSurfaceDescriptor);
        var metal: c.WGPUSurfaceSourceMetalLayer = undefined;
        switch (builtin.os.tag) {
            .macos => {
                metal = .{
                    .chain = .{
                        .next = null,
                        .sType = c.WGPUSType_SurfaceSourceMetalLayer,
                    },
                    .layer = window.metalLayer() orelse return error.NoSurface,
                };
                desc.nextInChain = &metal.chain;
            },
            else => @compileError("native: no GPU surface for this platform yet"),
        }
        const s = c.wgpuInstanceCreateSurface(self.instance, &desc) orelse return error.NoSurface;
        var caps = std.mem.zeroes(c.WGPUSurfaceCapabilities);
        _ = c.wgpuSurfaceGetCapabilities(s, self.adapter, &caps);
        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);
        // A plain 8-bit format: the engine writes sRGB-encoded values itself.
        var format: c.WGPUTextureFormat = c.WGPUTextureFormat_BGRA8Unorm;
        if (caps.formatCount > 0) {
            format = caps.formats[0];
            for (caps.formats[0..caps.formatCount]) |f| if (f == c.WGPUTextureFormat_BGRA8Unorm or f == c.WGPUTextureFormat_RGBA8Unorm) {
                format = f;
                break;
            };
        }
        return .{
            .gpu = self,
            .surface = s,
            .format = format,
        };
    }
};

fn Got(comptime T: type) type {
    return struct {
        value: ?T = null,
        done: bool = false,

        fn adapterCallback(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: c.WGPUStringView, ud: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ud));
            if (status == c.WGPURequestAdapterStatus_Success) self.value = adapter else std.debug.print("gpu: no adapter: {s}\n", .{span(message)});
            self.done = true;
        }

        fn deviceCallback(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: c.WGPUStringView, ud: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ud));
            if (status == c.WGPURequestDeviceStatus_Success) self.value = device else std.debug.print("gpu: no device: {s}\n", .{span(message)});
            self.done = true;
        }
    };
}

fn uncapturedError(_: [*c]const c.WGPUDevice, kind: c.WGPUErrorType, message: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("gpu error {d}: {s}\n", .{ kind, span(message) });
}

/// A window's swap chain: configure it to the window's size in device pixels, then each
/// frame take a texture, draw into it and present it.
pub const Surface = struct {
    gpu: *Gpu,
    surface: c.WGPUSurface,
    format: c.WGPUTextureFormat,
    width: u32 = 0,
    height: u32 = 0,

    pub fn configure(self: *Surface, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        if (width == self.width and height == self.height) return;
        self.width = width;
        self.height = height;
        var cfg = std.mem.zeroes(c.WGPUSurfaceConfiguration);
        cfg.device = self.gpu.device;
        cfg.format = self.format;
        cfg.usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopyDst;
        cfg.width = width;
        cfg.height = height;
        cfg.presentMode = c.WGPUPresentMode_Fifo;
        cfg.alphaMode = c.WGPUCompositeAlphaMode_Opaque;
        c.wgpuSurfaceConfigure(self.surface, &cfg);
    }

    /// This frame's texture, or null when the surface must be configured again first.
    pub fn acquire(self: *Surface) ?Frame {
        var st = std.mem.zeroes(c.WGPUSurfaceTexture);
        c.wgpuSurfaceGetCurrentTexture(self.surface, &st);
        switch (st.status) {
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal, c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal => {},
            else => {
                if (st.texture != null) c.wgpuTextureRelease(st.texture);
                self.width = 0;
                return null;
            },
        }
        return .{
            .texture = st.texture,
            .view = c.wgpuTextureCreateView(st.texture, null),
        };
    }

    pub fn present(self: *Surface, frame: Frame) void {
        _ = c.wgpuSurfacePresent(self.surface);
        c.wgpuTextureViewRelease(frame.view);
        c.wgpuTextureRelease(frame.texture);
    }

    pub fn deinit(self: *Surface) void {
        c.wgpuSurfaceRelease(self.surface);
    }
};

pub const Frame = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
};
