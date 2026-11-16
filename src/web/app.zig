//! The web backend: an app in a browser page, built for wasm32-wasi. One window, a canvas
//! the page puts beside it (`desktop.js` in the page that runs it): the page sends its
//! events and frames in through the exports below, and the app's frames go out as pixels
//! (`present`). Web views are iframes the page places over the canvas; menus, the
//! keychain and other windows are the page's or nothing.

const std = @import("std");
const ev = @import("../event.zig");

const Event = ev.Event;

/// What the page that runs the app does for it.
const page = struct {
    extern "desktop" fn present(pixels: [*]const u8, len: usize, width: u32, height: u32) void;
    extern "desktop" fn set_cursor(cursor: u32) void;
    extern "desktop" fn set_title(title: [*]const u8, len: usize) void;
    extern "desktop" fn open_url(url: [*]const u8, len: usize) void;
    extern "desktop" fn text_input(on: bool) void;
    extern "desktop" fn wake() void;
};

pub const Content = enum {
    gpu,
    web,
};

pub const Titlebar = enum {
    standard,
    custom,
    custom_tall,
};

pub const WindowOptions = struct {
    title: [:0]const u8 = "",
    titlebar: Titlebar = .standard,
    width: f64 = 1200,
    height: f64 = 800,
    content: Content = .gpu,
    bar_height: f64 = 0,
    min_width: f64 = 320,
    min_height: f64 = 240,
};

pub const Handler = struct {
    ctx: ?*anyopaque = null,
    on_event: *const fn (ctx: ?*anyopaque, window: *Window, event: Event) void,
    on_message: ?*const fn (ctx: ?*anyopaque, web: *WebView, text: []const u8) void = null,
    on_new_window: ?*const fn (ctx: ?*anyopaque, web: *WebView, url: []const u8) bool = null,
};

/// A size in points.
pub const Size = struct {
    w: f64,
    h: f64,
};

pub const Window = struct {
    handler: Handler,
    width: f64,
    height: f64,
    pixel_scale: f64 = 1,
    webs: std.ArrayList(*WebView) = .empty,

    pub fn create(handler: Handler, options: WindowOptions) !*Window {
        if (the_window != null) return error.OneWindow;

        const self = try std.heap.c_allocator.create(Window);
        self.* = .{
            .handler = handler,
            .width = options.width,
            .height = options.height,
        };
        the_window = self;
        page.set_title(options.title.ptr, options.title.len);
        return self;
    }

    /// Web views are iframes the page will hold; until it does, a view loads nothing.
    pub fn addWebView(self: *Window) !*WebView {
        const web = try std.heap.c_allocator.create(WebView);
        web.* = .{
            .window = self,
        };
        try self.webs.append(std.heap.c_allocator, web);
        return web;
    }

    pub fn setBarHeight(self: *Window, height: f64) void {
        _ = self;
        _ = height;
    }

    pub fn setWebArea(self: *Window, left: f64, top: f64) void {
        _ = self;
        _ = left;
        _ = top;
    }

    pub fn size(self: *const Window) Size {
        return .{
            .w = self.width,
            .h = self.height,
        };
    }

    pub fn scale(self: *const Window) f64 {
        return self.pixel_scale;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = self;
        page.set_title(title.ptr, title.len);
    }

    pub fn setCursor(self: *Window, cursor: ev.Cursor) void {
        _ = self;
        page.set_cursor(@intFromEnum(cursor));
    }

    pub fn number(self: *const Window) usize {
        _ = self;
        return 1;
    }

    /// The page's frame drags nothing: the window stays where the page put it.
    pub fn dragWindow(self: *Window) void {
        _ = self;
    }

    pub fn titlebarDoubleClick(self: *Window) void {
        _ = self;
    }

    pub fn setTextInput(self: *Window, on: bool) void {
        _ = self;
        page.text_input(on);
    }

    pub fn setTextCaret(self: *Window, x: f64, y: f64, h: f64) void {
        _ = self;
        _ = x;
        _ = y;
        _ = h;
    }

    pub fn focusApp(self: *Window) void {
        _ = self;
    }

    pub fn focus(self: *Window) void {
        _ = self;
    }

    pub fn close(self: *Window) void {
        self.handler.on_event(self.handler.ctx, self, .close);
    }

    /// Puts a frame the app drew (premultiplied RGBA, device pixels, opaque) on the canvas.
    pub fn present(self: *Window, pixels: []const u8, width: u32, height: u32) void {
        _ = self;
        std.debug.assert(pixels.len == @as(usize, width) * height * 4);
        page.present(pixels.ptr, pixels.len, width, height);
    }
};

pub const WebView = struct {
    window: *Window,
    url: []const u8 = "",
    visible: bool = true,

    pub fn addUserScript(self: *WebView, js: [:0]const u8) void {
        _ = self;
        _ = js;
    }

    pub fn loadUrl(self: *WebView, url: [:0]const u8) void {
        self.url = std.heap.c_allocator.dupe(u8, url) catch return;
    }

    pub fn loadHtml(self: *WebView, html: [:0]const u8) void {
        _ = self;
        _ = html;
    }

    pub fn evaluate(self: *WebView, js: [:0]const u8) void {
        _ = self;
        _ = js;
    }

    pub fn reload(self: *WebView) void {
        _ = self;
    }

    pub fn address(self: *WebView) []const u8 {
        return self.url;
    }

    pub fn setVisible(self: *WebView, visible: bool) void {
        self.visible = visible;
    }

    pub fn sendToBack(self: *WebView, width: f64, height: f64) void {
        _ = self;
        _ = width;
        _ = height;
    }

    /// No picture of a page yet: `done` hears there is none.
    pub fn snapshot(self: *WebView, width: f64, ctx: ?*anyopaque, done: *const fn (ctx: ?*anyopaque, pic: ?Picture) void) void {
        _ = self;
        _ = width;
        done(ctx, null);
    }

    pub fn destroy(self: *WebView) void {
        const window = self.window;

        for (window.webs.items, 0..) |held, index| {
            if (held == self) {
                _ = window.webs.orderedRemove(index);
                break;
            }
        }

        std.heap.c_allocator.destroy(self);
    }
};

pub const Picture = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

pub const MenuItem = struct {
    title: [:0]const u8 = "",
    key: [:0]const u8 = "",
    tag: u32 = 0,
    checked: bool = false,
    separator: bool = false,
};

var the_window: ?*Window = null;
var menu_handler: ?*const fn (ctx: ?*anyopaque, tag: u32) void = null;
var menu_ctx: ?*anyopaque = null;

/// Work for the main thread, which here is the only one: run before the next frame.
const Queued = struct {
    ctx: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
};
var queued: std.ArrayList(Queued) = .empty;

pub fn init(app_name: [:0]const u8) void {
    _ = app_name;
}

pub fn appearance() ev.Appearance {
    return .light;
}

/// The page runs the loop: `run` returns, and frames and events arrive through the exports.
pub fn run() void {}

pub fn activate() void {}

pub fn quit() void {}

pub fn onMenu(ctx: ?*anyopaque, handler: *const fn (ctx: ?*anyopaque, tag: u32) void) void {
    menu_ctx = ctx;
    menu_handler = handler;
}

/// The page has no menu bar: the app's menus are not shown.
pub fn setMenu(title: [:0]const u8, items: []const MenuItem) void {
    _ = title;
    _ = items;
}

pub fn setAppMenuItems(items: []const MenuItem) void {
    _ = items;
}

pub fn runOnMain(ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void {
    queued.append(std.heap.c_allocator, .{
        .ctx = ctx,
        .work = work,
    }) catch return;
    page.wake();
}

/// Background work, on the one thread there is: it runs before the next frame, after the
/// event that started it.
pub fn spawn(comptime function: anytype, args: anytype) !void {
    const Args = @TypeOf(args);
    const Closure = struct {
        args: Args,

        fn call(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            defer std.heap.c_allocator.destroy(self);

            const result = @call(.auto, function, self.args);

            if (@typeInfo(@TypeOf(result)) == .error_union) {
                _ = result catch |err| std.debug.print("native: background work: {t}\n", .{err});
            }
        }
    };
    const closure = try std.heap.c_allocator.create(Closure);
    closure.* = .{
        .args = args,
    };
    runOnMain(closure, Closure.call);
}

pub fn openInBrowser(url: [:0]const u8) void {
    page.open_url(url.ptr, url.len);
}

pub fn clipboardText(gpa: std.mem.Allocator) ?[]u8 {
    _ = gpa;
    return null;
}

pub fn setClipboardText(text: []const u8) void {
    _ = text;
}

fn drain() void {
    while (queued.items.len > 0) {
        const next = queued.orderedRemove(0);
        next.work(next.ctx);
    }
}

fn send(event: Event) void {
    const window = the_window orelse return;

    window.handler.on_event(window.handler.ctx, window, event);
}

fn mods_of(bits: u32) ev.Mods {
    return .{
        .shift = bits & 1 != 0,
        .control = bits & 2 != 0,
        .option = bits & 4 != 0,
        .command = bits & 8 != 0,
    };
}

fn mouse_of(x: f64, y: f64, button: u32, clicks: u32, mods: u32) ev.Mouse {
    return .{
        .x = x,
        .y = y,
        .button = switch (button) {
            1 => .middle,
            2 => .right,
            else => .left,
        },
        .clicks = clicks,
        .dragging = false,
        .mods = mods_of(mods),
    };
}

/// A buffer the page writes text into before `desktop_text` and `desktop_key`.
var text_buffer: [256]u8 = undefined;

export fn desktop_text_buffer() [*]u8 {
    return &text_buffer;
}

export fn desktop_frame() void {
    drain();
    send(.frame);
}

export fn desktop_resize(width: f64, height: f64, pixel_scale: f64) void {
    const window = the_window orelse return;

    window.width = width;
    window.height = height;
    window.pixel_scale = pixel_scale;
    send(.{
        .resize = .{
            .width = width,
            .height = height,
            .scale = pixel_scale,
        },
    });
}

export fn desktop_mouse(kind: u32, x: f64, y: f64, button: u32, clicks: u32, mods: u32) void {
    var mouse = mouse_of(x, y, button, clicks, mods);

    switch (kind) {
        0 => send(.{
            .mouse_down = mouse,
        }),
        1 => send(.{
            .mouse_up = mouse,
        }),
        2 => send(.{
            .mouse_move = mouse,
        }),
        3 => {
            mouse.dragging = true;
            send(.{
                .mouse_move = mouse,
            });
        },
        else => send(.mouse_leave),
    }
}

export fn desktop_scroll(x: f64, y: f64, dx: f64, dy: f64, precise: bool, mods: u32) void {
    send(.{
        .scroll = .{
            .x = x,
            .y = y,
            .dx = dx,
            .dy = dy,
            .precise = precise,
            .mods = mods_of(mods),
        },
    });
}

/// A key: `code` is a `KeyCode`, the characters it types already in the text buffer.
export fn desktop_key(down: bool, code: u32, mods: u32, text_len: u32, repeat: bool) void {
    var key: ev.Key = .{
        .code = std.enums.fromInt(ev.KeyCode, code) orelse .other,
        .mods = mods_of(mods),
        .repeat = repeat,
    };
    const length = @min(text_len, key.text_buf.len);

    @memcpy(key.text_buf[0..length], text_buffer[0..length]);
    key.text_len = @intCast(length);

    if (down) {
        send(.{
            .key_down = key,
        });
    } else {
        send(.{
            .key_up = key,
        });
    }
}

/// Typed text (in the text buffer), while the app takes text input.
export fn desktop_text(len: u32) void {
    send(.{
        .text = .of(.insert, text_buffer[0..@min(len, text_buffer.len)]),
    });
}

/// An editing key while the app takes text input: `command` is a `TextCommand`.
export fn desktop_text_command(command: u32) void {
    const known = std.enums.fromInt(ev.TextCommand, command) orelse return;

    send(.{
        .text_command = known,
    });
}

export fn desktop_focus(on: bool) void {
    send(.{
        .focus = on,
    });
}
