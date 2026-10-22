//! The macOS backend: AppKit through the Objective-C runtime. One NSApplication, windows
//! whose content is a CAMetalLayer (drawn by the app on the GPU), web views (WKWebView), or
//! both: a GPU bar above web views. Every input event becomes a `native.Event`.

const std = @import("std");
const objc = @import("objc.zig");
const ev = @import("../event.zig");

const id = objc.id;
const SEL = objc.SEL;
const Event = ev.Event;

pub const Content = enum {
    /// A CAMetalLayer the app draws on (`Window.metalLayer`).
    gpu,
    /// Web views (`Window.addWebView`), filling the window below the bar, if it has one.
    web,
};

/// The window's bar.
pub const Titlebar = enum {
    /// The system's bar with the title.
    standard,
    /// No bar: the content runs to the top edge, the traffic lights float over it centred in
    /// the top 38 points, and the app draws its own bar there (tabs, buttons) and says which
    /// parts drag the window (`dragWindow`, or `data-window-drag` in a page).
    custom,
    /// `custom` with a taller bar (52 points, as a window with a toolbar).
    custom_tall,
};

pub const WindowOptions = struct {
    title: [:0]const u8 = "",
    titlebar: Titlebar = .standard,
    width: f64 = 1200,
    height: f64 = 800,
    content: Content = .gpu,
    /// A `.web` window: the top this many points are a GPU bar the app draws
    /// (`metalLayer`, events with their positions in it), the web views below it.
    bar_height: f64 = 0,
    /// Smallest size the window may be resized to, in points.
    min_width: f64 = 320,
    min_height: f64 = 240,
};

/// What a window tells the app: every event, with the context it was given.
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    on_event: *const fn (ctx: ?*anyopaque, window: *Window, event: Event) void,
    /// Messages a web view's page posts (`webkit.messageHandlers.native.postMessage(text)`).
    on_message: ?*const fn (ctx: ?*anyopaque, web: *WebView, text: []const u8) void = null,
};

pub const Window = struct {
    ns_window: id,
    /// The view the app draws on and gets events from (the bar of a `.web` window).
    view: id,
    layer: id = null,
    webs: std.ArrayList(*WebView) = .empty,
    handler: Handler,
    display_link: id = null,
    bar_height: f64 = 0,
    closed: bool = false,
    /// A text field of the app's has the keyboard: keys go through the input system.
    text_input: bool = false,
    /// Composition under way (an input method's marked text).
    marked: bool = false,
    /// Where the caret is, in the view's points: input methods put their window there.
    caret: objc.CGRect = .{
        .origin = .{
            .x = 0,
            .y = 0,
        },
        .size = .{
            .w = 0,
            .h = 0,
        },
    },

    pub fn create(handler: Handler, options: WindowOptions) !*Window {
        const self = try std.heap.c_allocator.create(Window);
        errdefer std.heap.c_allocator.destroy(self);
        const full_size: usize = if (options.titlebar == .standard) 0 else 1 << 15;
        const ns_window = objc.send(*const fn (id, SEL, objc.CGRect, usize, usize, bool) callconv(.c) id)(
            objc.msg(objc.class("NSWindow"), "alloc"),
            objc.sel("initWithContentRect:styleMask:backing:defer:"),
            rect(0, 0, options.width, options.height),
            1 | 2 | 4 | 8 | full_size, // titled, closable, miniaturizable, resizable
            2, // buffered
            false,
        );
        if (options.titlebar != .standard) {
            objc.msgBool(ns_window, "setTitlebarAppearsTransparent:", true);
            _ = objc.msgUsize(ns_window, "setTitleVisibility:", 1); // hidden
            // An empty toolbar sets the bar's height and centres the traffic lights in it.
            const toolbar = objc.msg(objc.class("NSToolbar"), "new");
            objc.msgBool(toolbar, "setShowsBaselineSeparator:", false);
            _ = objc.msgId(ns_window, "setToolbar:", toolbar);
            _ = objc.msgUsize(ns_window, "setToolbarStyle:", if (options.titlebar == .custom) 4 else 3); // unified compact / unified
            // The app's bar is its content: the window moves only where the app says.
            objc.msgBool(ns_window, "setMovableByWindowBackground:", false);
        }
        // AppKit must not free the window behind our back: we release it on close.
        objc.msgBool(ns_window, "setReleasedWhenClosed:", false);
        objc.msgBool(ns_window, "setAcceptsMouseMovedEvents:", true);
        _ = objc.msgId(ns_window, "setTitle:", objc.string(options.title));
        objc.send(*const fn (id, SEL, objc.CGSize) callconv(.c) void)(ns_window, objc.sel("setContentMinSize:"), .{
            .w = options.min_width,
            .h = options.min_height,
        });
        _ = objc.msgId(ns_window, "setDelegate:", classes.window_delegate_instance);

        const view = objc.msg(classes.view, "new");
        self.* = .{
            .ns_window = ns_window,
            .view = view,
            .handler = handler,
        };
        try windows.append(std.heap.c_allocator, self);

        const has_layer = options.content == .gpu or options.bar_height > 0;
        if (has_layer) {
            self.layer = objc.msg(objc.class("CAMetalLayer"), "layer");
            _ = objc.msgId(view, "setLayer:", self.layer);
            objc.msgBool(view, "setWantsLayer:", true);
            setF64(self.layer, "setContentsScale:", self.scale());
            // The engine's values are sRGB, as on a browser canvas: tag them so a wide-gamut
            // display shows the same colours.
            const srgb = objc.CGColorSpaceCreateWithName(objc.kCGColorSpaceSRGB);
            _ = objc.msgId(self.layer, "setColorspace:", srgb);
            objc.CFRelease(srgb);
        }
        switch (options.content) {
            .gpu => _ = objc.msgId(ns_window, "setContentView:", view),
            .web => {
                // A plain container (bottom-left origin): the bar pinned to the top, the web
                // views filling the rest.
                const content = objc.msg(ns_window, "contentView");
                const bounds = objc.msgRect(content, "bounds");
                self.bar_height = options.bar_height;
                if (options.bar_height > 0) {
                    setFrame(view, rect(0, bounds.size.h - options.bar_height, bounds.size.w, options.bar_height));
                    _ = objc.msgUsize(view, "setAutoresizingMask:", 2 | 8); // width sizable, bottom margin flexible
                    _ = objc.msgId(content, "addSubview:", view);
                }
            },
        }
        // Moves and leaves reach the view even while a web view has the keyboard.
        const tracking = objc.send(*const fn (id, SEL, objc.CGRect, usize, id, id) callconv(.c) id)(
            objc.msg(objc.class("NSTrackingArea"), "alloc"),
            objc.sel("initWithRect:options:owner:userInfo:"),
            rect(0, 0, 0, 0),
            1 | 2 | 0x80 | 0x200, // entered/exited, moved, always active, the visible rect
            view,
            null,
        );
        _ = objc.msgId(view, "addTrackingArea:", tracking);
        _ = objc.msgId(ns_window, "makeFirstResponder:", view);
        _ = objc.msgId(ns_window, "center", null);
        _ = objc.msgId(ns_window, "makeKeyAndOrderFront:", null);

        // Frames at the display's refresh rate, also while resizing or tracking the mouse.
        self.display_link = objc.send(*const fn (id, SEL, id, SEL) callconv(.c) id)(view, objc.sel("displayLinkWithTarget:selector:"), view, objc.sel("nativeFrame:"));
        _ = objc.send(*const fn (id, SEL, id, id) callconv(.c) id)(self.display_link, objc.sel("addToRunLoop:forMode:"), objc.msg(objc.class("NSRunLoop"), "mainRunLoop"), objc.NSRunLoopCommonModes);
        return self;
    }

    /// A new web view filling the web area of a `.web` window, shown on top of the others
    /// and given the keyboard. Every web view of the window shares one cookie store.
    pub fn addWebView(self: *Window) !*WebView {
        const config = objc.msg(objc.class("WKWebViewConfiguration"), "new");
        const ucc = objc.msg(config, "userContentController");
        _ = objc.send(*const fn (id, SEL, id, id) callconv(.c) id)(ucc, objc.sel("addScriptMessageHandler:name:"), classes.message_handler_instance, objc.string("native"));
        const script = objc.send(*const fn (id, SEL, id, isize, bool) callconv(.c) id)(
            objc.msg(objc.class("WKUserScript"), "alloc"),
            objc.sel("initWithSource:injectionTime:forMainFrameOnly:"),
            objc.string(window_drag_script),
            0, // at document start
            true,
        );
        _ = objc.msgId(ucc, "addUserScript:", script);
        const content = objc.msg(self.ns_window, "contentView");
        const bounds = objc.msgRect(content, "bounds");
        const wk = objc.send(*const fn (id, SEL, objc.CGRect, id) callconv(.c) id)(
            objc.msg(objc.class("WKWebView"), "alloc"),
            objc.sel("initWithFrame:configuration:"),
            rect(0, 0, bounds.size.w, bounds.size.h - self.bar_height),
            config,
        );
        _ = objc.msgUsize(wk, "setAutoresizingMask:", 2 | 16); // width and height sizable
        // Web Inspector for the window (Safari > Develop), as in a browser.
        objc.msgBool(wk, "setInspectable:", true);
        _ = objc.msgId(wk, "setUIDelegate:", classes.ui_delegate_instance);
        _ = objc.msgId(content, "addSubview:", wk);
        _ = objc.msgId(self.ns_window, "makeFirstResponder:", wk);
        const web = try std.heap.c_allocator.create(WebView);
        web.* = .{
            .wk = wk,
            .window = self,
            .scripts = ucc,
        };
        try self.webs.append(std.heap.c_allocator, web);
        return web;
    }

    /// A `.web` window's bar grows or shrinks to `height` points (the whole window: the app
    /// draws everything, its web views hidden); the web views take the rest.
    pub fn setBarHeight(self: *Window, height: f64) void {
        // Filling the window, the bar follows its height; a bar keeps its own.
        _ = objc.msgUsize(self.view, "setAutoresizingMask:", if (height >= objc.msgRect(objc.msg(self.ns_window, "contentView"), "bounds").size.h) 2 | 16 else 2 | 8);
        const content = objc.msg(self.ns_window, "contentView");
        const bounds = objc.msgRect(content, "bounds");
        const h = @min(height, bounds.size.h);
        self.bar_height = h;
        setFrame(self.view, rect(0, bounds.size.h - h, bounds.size.w, h));
        for (self.webs.items) |web| if (!web.fixed) setFrame(web.wk, rect(0, 0, bounds.size.w, bounds.size.h - h));
        const s = self.size();
        self.emit(.{ .resize = .{
            .width = s.w,
            .height = s.h,
            .scale = self.scale(),
        } });
    }

    /// The content's size in points (a `.web` window with a bar: the bar's).
    pub fn size(self: *const Window) objc.CGSize {
        if (self.layer == null and self.webs.items.len > 0) return objc.msgRect(self.webs.items[0].wk, "bounds").size;
        return objc.msgRect(self.view, "bounds").size;
    }

    /// Device pixels per point (2 on a Retina display).
    pub fn scale(self: *const Window) f64 {
        return objc.msgF64(self.ns_window, "backingScaleFactor");
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = objc.msgId(self.ns_window, "setTitle:", objc.string(title));
    }

    /// The CAMetalLayer of a `.gpu` window or a `.web` window's bar, for the GPU surface.
    pub fn metalLayer(self: *const Window) ?*anyopaque {
        return self.layer;
    }

    pub fn setCursor(self: *Window, cursor: ev.Cursor) void {
        _ = self;
        const name: [*:0]const u8 = switch (cursor) {
            .arrow => "arrowCursor",
            .pointer => "pointingHandCursor",
            .text => "IBeamCursor",
            .grab => "openHandCursor",
            .grabbing => "closedHandCursor",
            .crosshair => "crosshairCursor",
        };
        _ = objc.msg(objc.msg(objc.class("NSCursor"), name), "set");
    }

    /// The window server's number for the window (`screencapture -l<number>` takes it).
    pub fn number(self: *const Window) usize {
        return @intFromPtr(objc.msg(self.ns_window, "windowNumber"));
    }

    /// Moves the window with the mouse: call on a mouse-down in the app's own bar.
    pub fn dragWindow(self: *Window) void {
        const event = objc.msg(objc.msg(objc.class("NSApplication"), "sharedApplication"), "currentEvent");
        if (event != null) _ = objc.msgId(self.ns_window, "performWindowDragWithEvent:", event);
    }

    /// What a double click on a title bar does, as the person set it in System Settings
    /// (zoom, minimise or nothing): call on a double click in the app's own bar.
    pub fn titlebarDoubleClick(self: *Window) void {
        const defaults = objc.msg(objc.class("NSUserDefaults"), "standardUserDefaults");
        const action = objc.msgId(defaults, "stringForKey:", objc.string("AppleActionOnDoubleClick"));
        if (action != null) {
            const utf8: [*:0]const u8 = @ptrCast(objc.msg(action, "UTF8String"));
            const a = std.mem.span(utf8);
            if (std.mem.eql(u8, a, "None")) return;
            if (std.mem.eql(u8, a, "Minimize")) {
                _ = objc.msgId(self.ns_window, "performMiniaturize:", null);
                return;
            }
        }
        _ = objc.msgId(self.ns_window, "performZoom:", null);
    }

    /// While on, typing goes through the system's input methods (dead keys, accents, CJK,
    /// emoji) and arrives as `.text` events instead of `.key_down`; call with false when the
    /// app's text field loses focus.
    pub fn setTextInput(self: *Window, on: bool) void {
        if (!on and self.marked) {
            _ = objc.msg(objc.msg(self.view, "inputContext"), "discardMarkedText");
            self.marked = false;
        }
        self.text_input = on;
        if (on) self.focusApp();
    }

    /// Where the field's caret is (points, from the content's top left), for input methods'
    /// windows.
    pub fn setTextCaret(self: *Window, x: f64, y: f64, h: f64) void {
        self.caret = rect(x, y, 1, h);
    }

    /// Gives the keyboard to what the app draws (a `.web` window's bar view), away from its
    /// web views.
    pub fn focusApp(self: *Window) void {
        _ = objc.msgId(self.ns_window, "makeFirstResponder:", self.view);
    }

    /// Brings the window to the front and gives it the keyboard.
    pub fn focus(self: *Window) void {
        _ = objc.msgId(self.ns_window, "makeKeyAndOrderFront:", null);
    }

    pub fn close(self: *Window) void {
        _ = objc.msg(self.ns_window, "performClose:");
    }

    fn emit(self: *Window, event: Event) void {
        self.handler.on_event(self.handler.ctx, self, event);
    }
};

/// A page in a window: shown or hidden, loaded, scripted. The window's web views lie on
/// top of each other in its web area; a tabbed app shows one at a time.
pub const WebView = struct {
    wk: id,
    window: *Window,
    /// Sent to the back with a size of its own: the web area's changes leave it alone.
    fixed: bool = false,
    /// The page's user content controller: where scripts of the app's go.
    scripts: id,

    /// Runs `js` in every page this web view loads from now on, when its document starts.
    pub fn addUserScript(self: *WebView, js: [:0]const u8) void {
        const script = objc.send(*const fn (id, SEL, id, isize, bool) callconv(.c) id)(
            objc.msg(objc.class("WKUserScript"), "alloc"),
            objc.sel("initWithSource:injectionTime:forMainFrameOnly:"),
            objc.string(js),
            0,
            true,
        );
        _ = objc.msgId(self.scripts, "addUserScript:", script);
    }

    pub fn loadUrl(self: *WebView, url: [:0]const u8) void {
        const nsurl = objc.msgId(objc.class("NSURL"), "URLWithString:", objc.string(url));
        _ = objc.msgId(self.wk, "loadRequest:", objc.msgId(objc.class("NSURLRequest"), "requestWithURL:", nsurl));
    }

    pub fn loadHtml(self: *WebView, html: [:0]const u8) void {
        _ = objc.send(*const fn (id, SEL, id, id) callconv(.c) id)(self.wk, objc.sel("loadHTMLString:baseURL:"), objc.string(html), null);
    }

    /// Runs `js` in the page; the result is not waited for.
    pub fn evaluate(self: *WebView, js: [:0]const u8) void {
        _ = objc.send(*const fn (id, SEL, id, id) callconv(.c) id)(self.wk, objc.sel("evaluateJavaScript:completionHandler:"), objc.string(js), null);
    }

    pub fn reload(self: *WebView) void {
        _ = objc.msg(self.wk, "reload");
    }

    /// The address the page shows (empty before the first load); valid until the next call
    /// into the web view.
    pub fn address(self: *WebView) []const u8 {
        const u = objc.msg(self.wk, "URL");
        if (u == null) return "";
        const abs = objc.msg(u, "absoluteString");
        const utf8: [*:0]const u8 = @ptrCast(objc.msg(abs, "UTF8String"));
        return std.mem.span(utf8);
    }

    /// Shows it (and gives it the keyboard) or hides it.
    pub fn setVisible(self: *WebView, visible: bool) void {
        objc.msgBool(self.wk, "setHidden:", !visible);
        if (visible) _ = objc.msgId(self.window.ns_window, "makeFirstResponder:", self.wk);
    }

    /// Puts it under everything else in the window (a page loaded out of sight, behind what
    /// the app draws), `width` x `height` points from the window's corner.
    pub fn sendToBack(self: *WebView, width: f64, height: f64) void {
        const content = objc.msg(self.window.ns_window, "contentView");
        _ = objc.msg(self.wk, "removeFromSuperview");
        _ = objc.msgUsize(self.wk, "setAutoresizingMask:", 0);
        self.fixed = true;
        setFrame(self.wk, rect(0, 0, width, height));
        _ = objc.send(*const fn (id, SEL, id, isize, id) callconv(.c) id)(content, objc.sel("addSubview:positioned:relativeTo:"), self.wk, -1, null);
    }

    /// A picture of the page, `width` device pixels wide, given to `done` (RGBA, straight
    /// alpha, rows top down; the caller owns `pixels`) or null when WebKit could not take it.
    pub fn snapshot(self: *WebView, width: f64, ctx: ?*anyopaque, done: *const fn (ctx: ?*anyopaque, pic: ?Picture) void) void {
        const config = objc.msg(objc.class("WKSnapshotConfiguration"), "new");
        // The width in points, as an NSNumber.
        const points = objc.send(*const fn (id, SEL, f64) callconv(.c) id)(objc.class("NSNumber"), objc.sel("numberWithDouble:"), width / self.window.scale());
        _ = objc.msgId(config, "setSnapshotWidth:", points);
        const block = std.heap.c_allocator.create(SnapshotBlock) catch return done(ctx, null);
        block.* = .{
            .isa = &objc._NSConcreteStackBlock,
            .flags = 0,
            .reserved = 0,
            .invoke = &SnapshotBlock.run,
            .descriptor = &SnapshotBlock.the_descriptor,
            .ctx = ctx,
            .done_fn = @ptrCast(done),
        };
        // WebKit copies the block (bytes and all, it has no helpers); ours is freed after.
        _ = objc.send(*const fn (id, SEL, id, *SnapshotBlock) callconv(.c) id)(self.wk, objc.sel("takeSnapshotWithConfiguration:completionHandler:"), config, block);
        std.heap.c_allocator.destroy(block);
    }

    /// Takes it out of the window and frees it.
    pub fn destroy(self: *WebView) void {
        _ = objc.msg(self.wk, "removeFromSuperview");
        const webs = &self.window.webs;
        for (webs.items, 0..) |w, i| if (w == self) {
            _ = webs.orderedRemove(i);
            break;
        };
        std.heap.c_allocator.destroy(self);
    }
};

pub const Picture = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

const SnapshotBlock = extern struct {
    isa: *anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *const fn (*SnapshotBlock, id, id) callconv(.c) void,
    descriptor: *const objc.BlockDescriptor,
    ctx: ?*anyopaque,
    /// A `Done` (an extern struct holds it as an opaque pointer).
    done_fn: *const anyopaque,

    const Done = *const fn (ctx: ?*anyopaque, pic: ?Picture) void;

    fn done(self: *SnapshotBlock, ctx: ?*anyopaque, pic: ?Picture) void {
        const f: Done = @ptrCast(@alignCast(self.done_fn));
        f(ctx, pic);
    }

    const the_descriptor: objc.BlockDescriptor = .{
        .size = @sizeOf(SnapshotBlock),
    };

    fn run(self: *SnapshotBlock, image: id, err: id) callconv(.c) void {
        if (image == null) {
            if (err != null) {
                const d: [*:0]const u8 = @ptrCast(objc.msg(objc.msg(err, "localizedDescription"), "UTF8String"));
                std.debug.print("native: snapshot failed: {s}\n", .{d});
            }
            return self.done(self.ctx, null);
        }
        // The image's pixels through a bitmap of it (its own CGImage is not always made).
        const rep = objc.msgId(objc.class("NSBitmapImageRep"), "imageRepWithData:", objc.msg(image, "TIFFRepresentation"));
        const cg: ?*anyopaque = if (rep != null) objc.msg(rep, "CGImage") else null;
        if (cg == null) return self.done(self.ctx, null);
        const w = objc.CGImageGetWidth(cg);
        const h = objc.CGImageGetHeight(cg);
        const pixels = std.heap.c_allocator.alloc(u8, w * h * 4) catch return self.done(self.ctx, null);
        const space = objc.CGColorSpaceCreateWithName(objc.kCGColorSpaceSRGB);
        defer objc.CFRelease(space);
        // Premultiplied RGBA is what a bitmap context draws; pages are opaque, so the same
        // as straight.
        const bc = objc.CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, 1);
        defer objc.CGContextRelease(bc);
        objc.CGContextDrawImage(bc, rect(0, 0, @floatFromInt(w), @floatFromInt(h)), cg);
        self.done(self.ctx, .{
            .width = @intCast(w),
            .height = @intCast(h),
            .pixels = pixels,
        });
    }
};

fn setFrame(view: id, r: objc.CGRect) void {
    objc.send(*const fn (id, SEL, objc.CGRect) callconv(.c) void)(view, objc.sel("setFrame:"), r);
}

var windows: std.ArrayList(*Window) = .empty;

fn byView(view: id) ?*Window {
    for (windows.items) |w| if (w.view == view) return w;
    return null;
}

fn byNsWindow(ns_window: id) ?*Window {
    for (windows.items) |w| if (w.ns_window == ns_window) return w;
    return null;
}

const Classes = struct {
    view: id = null,
    window_delegate_instance: id = null,
    message_handler_instance: id = null,
    app_delegate_instance: id = null,
    ui_delegate_instance: id = null,
    menu_target_instance: id = null,
};
var classes: Classes = .{};

/// Sets up the application and its menu bar. Call once, before any window.
pub fn init(app_name: [:0]const u8) void {
    const app = objc.msg(objc.class("NSApplication"), "sharedApplication");
    _ = objc.msgUsize(app, "setActivationPolicy:", 0);

    classes.view = objc.makeClassWith("NSView", "NativeView", &.{
        .{ "insertText:replacementRange:", @ptrCast(&onInsertText), "v@:@{_NSRange=QQ}" },
        .{ "setMarkedText:selectedRange:replacementRange:", @ptrCast(&onSetMarked), "v@:@{_NSRange=QQ}{_NSRange=QQ}" },
        .{ "unmarkText", @ptrCast(&onUnmark), "v@:" },
        .{ "hasMarkedText", @ptrCast(&onHasMarked), "c@:" },
        .{ "markedRange", @ptrCast(&onMarkedRange), "{_NSRange=QQ}@:" },
        .{ "selectedRange", @ptrCast(&onSelectedRange), "{_NSRange=QQ}@:" },
        .{ "validAttributesForMarkedText", @ptrCast(&onValidAttributes), "@@:" },
        .{ "attributedSubstringForProposedRange:actualRange:", @ptrCast(&onSubstring), "@@:{_NSRange=QQ}^{_NSRange=QQ}" },
        .{ "characterIndexForPoint:", @ptrCast(&onCharacterIndex), "Q@:{CGPoint=dd}" },
        .{ "firstRectForCharacterRange:actualRange:", @ptrCast(&onFirstRect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}" },
        .{ "doCommandBySelector:", @ptrCast(&onCommand), "v@::" },
        .{ "copy:", @ptrCast(&onCopy), "v@:@" },
        .{ "cut:", @ptrCast(&onCut), "v@:@" },
        .{ "paste:", @ptrCast(&onPaste), "v@:@" },
        .{ "selectAll:", @ptrCast(&onSelectAll), "v@:@" },
        .{ "isFlipped", @ptrCast(&yes0), "c@:" },
        .{ "acceptsFirstResponder", @ptrCast(&yes0), "c@:" },
        .{ "acceptsFirstMouse:", @ptrCast(&yes1), "c@:@" },
        .{ "nativeFrame:", @ptrCast(&onFrame), "v@:@" },
        .{ "mouseDown:", @ptrCast(&onMouseDown), "v@:@" },
        .{ "mouseUp:", @ptrCast(&onMouseUp), "v@:@" },
        .{ "rightMouseDown:", @ptrCast(&onMouseDown), "v@:@" },
        .{ "rightMouseUp:", @ptrCast(&onMouseUp), "v@:@" },
        .{ "otherMouseDown:", @ptrCast(&onMouseDown), "v@:@" },
        .{ "otherMouseUp:", @ptrCast(&onMouseUp), "v@:@" },
        .{ "mouseMoved:", @ptrCast(&onMouseMove), "v@:@" },
        .{ "mouseDragged:", @ptrCast(&onMouseMove), "v@:@" },
        .{ "rightMouseDragged:", @ptrCast(&onMouseMove), "v@:@" },
        .{ "otherMouseDragged:", @ptrCast(&onMouseMove), "v@:@" },
        .{ "mouseExited:", @ptrCast(&onMouseExit), "v@:@" },
        .{ "scrollWheel:", @ptrCast(&onScroll), "v@:@" },
        .{ "magnifyWithEvent:", @ptrCast(&onMagnify), "v@:@" },
        .{ "keyDown:", @ptrCast(&onKeyDown), "v@:@" },
        .{ "keyUp:", @ptrCast(&onKeyUp), "v@:@" },
        .{ "flagsChanged:", @ptrCast(&onFlags), "v@:@" },
    }, &.{"NSTextInputClient"});
    const WindowDelegate = objc.makeClass("NSObject", "NativeWindowDelegate", &.{
        .{ "windowDidResize:", @ptrCast(&onResize), "v@:@" },
        .{ "windowDidChangeBackingProperties:", @ptrCast(&onResize), "v@:@" },
        .{ "windowDidBecomeKey:", @ptrCast(&onFocus), "v@:@" },
        .{ "windowDidResignKey:", @ptrCast(&onBlur), "v@:@" },
        .{ "windowWillClose:", @ptrCast(&onClose), "v@:@" },
    });
    classes.window_delegate_instance = objc.msg(WindowDelegate, "new");
    const MessageHandler = objc.makeClassWith("NSObject", "NativeMessageHandler", &.{
        .{ "userContentController:didReceiveScriptMessage:", @ptrCast(&onScriptMessage), "v@:@@" },
    }, &.{"WKScriptMessageHandler"});
    classes.message_handler_instance = objc.msg(MessageHandler, "new");
    const UiDelegate = objc.makeClassWith("NSObject", "NativeUiDelegate", &.{
        .{ "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", @ptrCast(&onNewWindow), "@@:@@@@" },
        .{ "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:", @ptrCast(&onOpenPanel), "v@:@@@@" },
    }, &.{"WKUIDelegate"});
    classes.ui_delegate_instance = objc.msg(UiDelegate, "new");
    const MenuTarget = objc.makeClass("NSObject", "NativeMenuTarget", &.{
        .{ "nativeMenuItem:", @ptrCast(&onMenuItem), "v@:@" },
    });
    classes.menu_target_instance = objc.msg(MenuTarget, "new");
    const AppDelegate = objc.makeClass("NSObject", "NativeAppDelegate", &.{
        .{ "applicationShouldTerminateAfterLastWindowClosed:", @ptrCast(&yes1), "c@:@" },
        .{ "nativeAppearanceChanged:", @ptrCast(&onAppearanceChanged), "v@:@" },
    });
    classes.app_delegate_instance = objc.msg(AppDelegate, "new");
    _ = objc.msgId(app, "setDelegate:", classes.app_delegate_instance);
    // Light or dark switched in System Settings (or by the time of day).
    _ = objc.send(*const fn (id, SEL, id, SEL, id, id) callconv(.c) id)(
        objc.msg(objc.class("NSDistributedNotificationCenter"), "defaultCenter"),
        objc.sel("addObserver:selector:name:object:"),
        classes.app_delegate_instance,
        objc.sel("nativeAppearanceChanged:"),
        objc.string("AppleInterfaceThemeChangedNotification"),
        null,
    );

    buildMenuBar(app, app_name);
}

/// Whether the system is set to light or dark.
pub fn appearance() ev.Appearance {
    const app = objc.msg(objc.class("NSApplication"), "sharedApplication");
    const current = objc.msg(app, "effectiveAppearance");
    // Not `arrayWithObjects:`: variadic arguments travel differently on arm64.
    const list = [_]id{ objc.NSAppearanceNameAqua, objc.NSAppearanceNameDarkAqua };
    const names = objc.send(*const fn (id, SEL, [*]const id, usize) callconv(.c) id)(objc.class("NSArray"), objc.sel("arrayWithObjects:count:"), &list, list.len);
    const best = objc.msgId(current, "bestMatchFromAppearancesWithNames:", names);
    const dark = objc.send(*const fn (id, SEL, id) callconv(.c) bool)(best, objc.sel("isEqualToString:"), objc.NSAppearanceNameDarkAqua);
    return if (dark) .dark else .light;
}

/// Runs the event loop until the last window closes or `quit` is called.
pub fn run() void {
    const app = objc.msg(objc.class("NSApplication"), "sharedApplication");
    objc.msgBool(app, "activateIgnoringOtherApps:", true);
    _ = objc.msg(app, "run");
}

pub fn activate() void {
    objc.msgBool(objc.msg(objc.class("NSApplication"), "sharedApplication"), "activateIgnoringOtherApps:", true);
}

pub fn quit() void {
    _ = objc.msgId(objc.msg(objc.class("NSApplication"), "sharedApplication"), "terminate:", null);
}

/// An item of an app menu (`setMenu`).
pub const MenuItem = struct {
    title: [:0]const u8 = "",
    /// The key with Command ("r"); an upper-case letter adds Shift.
    key: [:0]const u8 = "",
    /// What `on_item` receives when the item is chosen.
    tag: u32 = 0,
    checked: bool = false,
    separator: bool = false,
};

var menu_handler: ?*const fn (ctx: ?*anyopaque, tag: u32) void = null;
var menu_ctx: ?*anyopaque = null;

/// Where chosen app menu items go.
pub fn onMenu(ctx: ?*anyopaque, handler: *const fn (ctx: ?*anyopaque, tag: u32) void) void {
    menu_ctx = ctx;
    menu_handler = handler;
}

/// Adds the menu `title` to the menu bar, before Window, or replaces its items if it is
/// there already. Chosen items go to the `onMenu` handler with their tag.
pub fn setMenu(title: [:0]const u8, items: []const MenuItem) void {
    const app = objc.msg(objc.class("NSApplication"), "sharedApplication");
    const bar = objc.msg(app, "mainMenu");
    var menu = objc.msgId(bar, "itemWithTitle:", objc.string(title));
    if (menu == null) {
        const item = objc.msg(objc.class("NSMenuItem"), "new");
        _ = objc.msgId(item, "setTitle:", objc.string(title));
        const sub = objc.msgId(objc.msg(objc.class("NSMenu"), "alloc"), "initWithTitle:", objc.string(title));
        _ = objc.msgId(item, "setSubmenu:", sub);
        const count: usize = @intFromPtr(objc.msg(bar, "numberOfItems"));
        _ = objc.send(*const fn (id, SEL, id, usize) callconv(.c) id)(bar, objc.sel("insertItem:atIndex:"), item, count - 1);
        menu = item;
    }
    const sub = objc.msg(menu, "submenu");
    _ = objc.msg(sub, "removeAllItems");
    for (items) |it| {
        if (it.separator) {
            addSeparator(sub);
            continue;
        }
        const item = objc.send(*const fn (id, SEL, id, SEL, id) callconv(.c) id)(sub, objc.sel("addItemWithTitle:action:keyEquivalent:"), objc.string(it.title), objc.sel("nativeMenuItem:"), objc.string(it.key));
        _ = objc.msgId(item, "setTarget:", classes.menu_target_instance);
        _ = objc.msgUsize(item, "setTag:", it.tag);
        _ = objc.msgUsize(item, "setState:", if (it.checked) 1 else 0);
    }
}

extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

/// Runs `work(ctx)` on the main thread, where windows may be touched; callable from any
/// thread.
pub fn runOnMain(ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void {
    dispatch_async_f(&_dispatch_main_q, ctx, work);
}

/// Opens `url` in the person's default browser.
pub fn openInBrowser(url: [:0]const u8) void {
    const nsurl = objc.msgId(objc.class("NSURL"), "URLWithString:", objc.string(url));
    if (nsurl == null) return;
    _ = objc.msgId(objc.msg(objc.class("NSWorkspace"), "sharedWorkspace"), "openURL:", nsurl);
}

/// The app menu (About, Hide, Quit), Edit (what text fields in a web view need for the
/// keyboard shortcuts to work) and Window. Items go to the first responder, as in any app.
fn buildMenuBar(app: id, app_name: [:0]const u8) void {
    const bar = objc.msg(objc.class("NSMenu"), "new");
    var buf: [256]u8 = undefined;

    const app_menu = submenu(bar, app_name);
    addItem(app_menu, fmt(&buf, "About {s}", .{app_name}), "orderFrontStandardAboutPanel:", "");
    addSeparator(app_menu);
    addItem(app_menu, fmt(&buf, "Hide {s}", .{app_name}), "hide:", "h");
    addItem(app_menu, "Show All", "unhideAllApplications:", "");
    addSeparator(app_menu);
    addItem(app_menu, fmt(&buf, "Quit {s}", .{app_name}), "terminate:", "q");

    const edit = submenu(bar, "Edit");
    addItem(edit, "Undo", "undo:", "z");
    addItem(edit, "Redo", "redo:", "Z");
    addSeparator(edit);
    addItem(edit, "Cut", "cut:", "x");
    addItem(edit, "Copy", "copy:", "c");
    addItem(edit, "Paste", "paste:", "v");
    addItem(edit, "Select All", "selectAll:", "a");

    const window_menu = submenu(bar, "Window");
    addItem(window_menu, "Minimize", "performMiniaturize:", "m");
    addItem(window_menu, "Zoom", "performZoom:", "");
    // Command-Shift-W closes the window: Command-W is the app's (a tabbed app closes a tab).
    addItem(window_menu, "Close Window", "performClose:", "W");
    _ = objc.msgId(app, "setWindowsMenu:", window_menu);

    _ = objc.msgId(app, "setMainMenu:", bar);
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, f, args) catch "";
}

fn submenu(bar: id, title: [:0]const u8) id {
    const item = objc.msg(objc.class("NSMenuItem"), "new");
    const menu = objc.msgId(objc.msg(objc.class("NSMenu"), "alloc"), "initWithTitle:", objc.string(title));
    _ = objc.msgId(item, "setSubmenu:", menu);
    _ = objc.msgId(bar, "addItem:", item);
    return menu;
}

fn addItem(menu: id, title: [:0]const u8, action: [*:0]const u8, key: [*:0]const u8) void {
    _ = objc.send(*const fn (id, SEL, id, SEL, id) callconv(.c) id)(menu, objc.sel("addItemWithTitle:action:keyEquivalent:"), objc.string(title), objc.sel(action), objc.string(key));
}

fn addSeparator(menu: id) void {
    _ = objc.msgId(menu, "addItem:", objc.msg(objc.class("NSMenuItem"), "separatorItem"));
}

fn rect(x: f64, y: f64, w: f64, h: f64) objc.CGRect {
    return .{
        .origin = .{
            .x = x,
            .y = y,
        },
        .size = .{
            .w = w,
            .h = h,
        },
    };
}

fn setF64(o: id, s: [*:0]const u8, v: f64) void {
    objc.send(*const fn (id, SEL, f64) callconv(.c) void)(o, objc.sel(s), v);
}

fn yes0(_: id, _: SEL) callconv(.c) bool {
    return true;
}

fn yes1(_: id, _: SEL, _: id) callconv(.c) bool {
    return true;
}

// Events.

fn mods(event: id) ev.Mods {
    const flags: usize = @intFromPtr(objc.msg(event, "modifierFlags"));
    return .{
        .shift = flags & (1 << 17) != 0,
        .control = flags & (1 << 18) != 0,
        .option = flags & (1 << 19) != 0,
        .command = flags & (1 << 20) != 0,
    };
}

fn point(view: id, event: id) objc.CGPoint {
    const in_window = objc.send(*const fn (id, SEL) callconv(.c) objc.CGPoint)(event, objc.sel("locationInWindow"));
    return objc.send(*const fn (id, SEL, objc.CGPoint, id) callconv(.c) objc.CGPoint)(view, objc.sel("convertPoint:fromView:"), in_window, null);
}

fn button(event: id) ev.MouseButton {
    const n: usize = @intFromPtr(objc.msg(event, "buttonNumber"));
    return switch (n) {
        0 => .left,
        1 => .right,
        else => .middle,
    };
}

fn mouseEvent(view: id, event: id) ev.Mouse {
    const p = point(view, event);
    return .{
        .x = p.x,
        .y = p.y,
        .button = button(event),
        .clicks = @intCast(@intFromPtr(objc.msg(event, "clickCount"))),
        .mods = mods(event),
    };
}

fn onFrame(view: id, _: SEL, _: id) callconv(.c) void {
    const w = byView(view) orelse return;
    if (!w.closed) w.emit(.frame);
}

fn onMouseDown(view: id, _: SEL, event: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.{ .mouse_down = mouseEvent(view, event) });
}

fn onMouseUp(view: id, _: SEL, event: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.{ .mouse_up = mouseEvent(view, event) });
}

fn onMouseMove(view: id, _: SEL, event: id) callconv(.c) void {
    const w = byView(view) orelse return;
    const pressed: usize = @intFromPtr(objc.msg(objc.class("NSEvent"), "pressedMouseButtons"));
    var m = mouseEvent(view, event);
    m.dragging = pressed != 0;
    w.emit(.{ .mouse_move = m });
}

fn onMouseExit(view: id, _: SEL, _: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.mouse_leave);
}

fn onScroll(view: id, _: SEL, event: id) callconv(.c) void {
    const w = byView(view) orelse return;
    const p = point(view, event);
    const phase: usize = @intFromPtr(objc.msg(event, "momentumPhase"));
    w.emit(.{ .scroll = .{
        .x = p.x,
        .y = p.y,
        .dx = objc.msgF64(event, "scrollingDeltaX"),
        .dy = objc.msgF64(event, "scrollingDeltaY"),
        .precise = objc.send(*const fn (id, SEL) callconv(.c) bool)(event, objc.sel("hasPreciseScrollingDeltas")),
        .momentum = phase != 0,
        .mods = mods(event),
    } });
}

fn onMagnify(view: id, _: SEL, event: id) callconv(.c) void {
    const w = byView(view) orelse return;
    const p = point(view, event);
    w.emit(.{ .magnify = .{
        .x = p.x,
        .y = p.y,
        .amount = objc.msgF64(event, "magnification"),
    } });
}

fn keyEvent(event: id) ev.Key {
    const code: u16 = @intCast(@intFromPtr(objc.msg(event, "keyCode")));
    const chars = objc.msg(event, "characters");
    var k: ev.Key = .{
        .code = keyCode(code),
        .mods = mods(event),
        .repeat = objc.send(*const fn (id, SEL) callconv(.c) bool)(event, objc.sel("isARepeat")),
    };
    if (chars != null) {
        const utf8: ?[*:0]const u8 = @ptrCast(objc.msg(chars, "UTF8String"));
        if (utf8) |s| {
            const t = std.mem.span(s);
            const n = @min(t.len, k.text_buf.len);
            @memcpy(k.text_buf[0..n], t[0..n]);
            k.text_len = @intCast(n);
        }
    }
    return k;
}

/// Mac virtual key codes (kVK_*) for the keys an app handles by name.
fn keyCode(code: u16) ev.KeyCode {
    return switch (code) {
        0x24 => .enter,
        0x30 => .tab,
        0x31 => .space,
        0x33 => .backspace,
        0x35 => .escape,
        0x75 => .delete,
        0x7B => .left,
        0x7C => .right,
        0x7D => .down,
        0x7E => .up,
        0x73 => .home,
        0x77 => .end,
        0x74 => .page_up,
        0x79 => .page_down,
        else => .other,
    };
}

fn onKeyDown(view: id, _: SEL, event: id) callconv(.c) void {
    const w = byView(view) orelse return;
    if (w.text_input) {
        // Through the input system: text comes back as insertText / setMarkedText, keys
        // like Return and the arrows as doCommandBySelector.
        const events = objc.send(*const fn (id, SEL, [*]const id, usize) callconv(.c) id)(objc.class("NSArray"), objc.sel("arrayWithObjects:count:"), &[_]id{event}, 1);
        _ = objc.msgId(view, "interpretKeyEvents:", events);
        return;
    }
    w.emit(.{ .key_down = keyEvent(event) });
}

const NSRange = extern struct {
    location: usize,
    length: usize,
};

const not_found: usize = std.math.maxInt(isize);

/// The text of an NSString or NSAttributedString, valid until the next call into AppKit.
fn plainText(obj: id) []const u8 {
    const str = if (objc.send(*const fn (id, SEL, id) callconv(.c) bool)(obj, objc.sel("isKindOfClass:"), objc.class("NSAttributedString"))) objc.msg(obj, "string") else obj;
    const utf8: ?[*:0]const u8 = @ptrCast(objc.msg(str, "UTF8String"));
    return if (utf8) |p| std.mem.span(p) else "";
}

fn onInsertText(view: id, _: SEL, text: id, _: NSRange) callconv(.c) void {
    const w = byView(view) orelse return;
    w.marked = false;
    w.emit(.{ .text = ev.Text.of(.insert, plainText(text)) });
}

fn onSetMarked(view: id, _: SEL, text: id, _: NSRange, _: NSRange) callconv(.c) void {
    const w = byView(view) orelse return;
    const t = plainText(text);
    w.marked = t.len > 0;
    w.emit(.{ .text = ev.Text.of(.marked, t) });
}

fn onUnmark(view: id, _: SEL) callconv(.c) void {
    const w = byView(view) orelse return;
    w.marked = false;
    w.emit(.{ .text = ev.Text.of(.marked, "") });
}

fn onHasMarked(view: id, _: SEL) callconv(.c) bool {
    const w = byView(view) orelse return false;
    return w.marked;
}

fn onMarkedRange(view: id, _: SEL) callconv(.c) NSRange {
    const w = byView(view) orelse return .{
        .location = not_found,
        .length = 0,
    };
    return if (w.marked) .{
        .location = 0,
        .length = 1,
    } else .{
        .location = not_found,
        .length = 0,
    };
}

fn onSelectedRange(_: id, _: SEL) callconv(.c) NSRange {
    return .{
        .location = 0,
        .length = 0,
    };
}

fn onValidAttributes(_: id, _: SEL) callconv(.c) id {
    return objc.msg(objc.class("NSArray"), "array");
}

fn onSubstring(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) id {
    return null;
}

fn onCharacterIndex(_: id, _: SEL, _: objc.CGPoint) callconv(.c) usize {
    return not_found;
}

/// Where the caret is on screen: input methods open their candidate window there.
fn onFirstRect(view: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) objc.CGRect {
    const w = byView(view) orelse return rect(0, 0, 0, 0);
    const in_window = objc.send(*const fn (id, SEL, objc.CGRect, id) callconv(.c) objc.CGRect)(view, objc.sel("convertRect:toView:"), w.caret, null);
    return objc.send(*const fn (id, SEL, objc.CGRect) callconv(.c) objc.CGRect)(w.ns_window, objc.sel("convertRectToScreen:"), in_window);
}

/// Keys the input system turns into editing commands.
fn onCommand(view: id, _: SEL, selector: SEL) callconv(.c) void {
    const w = byView(view) orelse return;
    const name = std.mem.span(objc.sel_getName(selector));
    const commands = [_]struct { []const u8, ev.TextCommand }{
        .{ "deleteBackward:", .delete_backward },
        .{ "deleteForward:", .delete_forward },
        .{ "deleteWordBackward:", .delete_word_backward },
        .{ "deleteToBeginningOfLine:", .delete_to_start },
        .{ "moveLeft:", .left },
        .{ "moveRight:", .right },
        .{ "moveWordLeft:", .word_left },
        .{ "moveWordRight:", .word_right },
        .{ "moveToBeginningOfLine:", .start },
        .{ "moveToLeftEndOfLine:", .start },
        .{ "moveToEndOfLine:", .end },
        .{ "moveToRightEndOfLine:", .end },
        .{ "moveUp:", .start },
        .{ "moveDown:", .end },
        .{ "moveLeftAndModifySelection:", .select_left },
        .{ "moveRightAndModifySelection:", .select_right },
        .{ "moveWordLeftAndModifySelection:", .select_word_left },
        .{ "moveWordRightAndModifySelection:", .select_word_right },
        .{ "moveToBeginningOfLineAndModifySelection:", .select_to_start },
        .{ "moveToLeftEndOfLineAndModifySelection:", .select_to_start },
        .{ "moveToEndOfLineAndModifySelection:", .select_to_end },
        .{ "moveToRightEndOfLineAndModifySelection:", .select_to_end },
        .{ "insertNewline:", .enter },
        .{ "insertTab:", .tab },
        .{ "insertBacktab:", .backtab },
        .{ "cancelOperation:", .escape },
    };
    for (commands) |c| if (std.mem.eql(u8, name, c[0])) return w.emit(.{ .text_command = c[1] });
}

fn onCopy(view: id, _: SEL, _: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.{ .text_command = .copy });
}

fn onCut(view: id, _: SEL, _: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.{ .text_command = .cut });
}

fn onPaste(view: id, _: SEL, _: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.{ .text_command = .paste });
}

fn onSelectAll(view: id, _: SEL, _: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.{ .text_command = .select_all });
}

/// The text on the clipboard (owned by the caller), or null.
pub fn clipboardText(gpa: std.mem.Allocator) ?[]u8 {
    const pb = objc.msg(objc.class("NSPasteboard"), "generalPasteboard");
    const str = objc.msgId(pb, "stringForType:", objc.string("public.utf8-plain-text"));
    if (str == null) return null;
    return gpa.dupe(u8, plainText(str)) catch null;
}

/// Puts `text` on the clipboard.
pub fn setClipboardText(text: []const u8) void {
    const pb = objc.msg(objc.class("NSPasteboard"), "generalPasteboard");
    _ = objc.msg(pb, "clearContents");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.c_allocator);
    buf.appendSlice(std.heap.c_allocator, text) catch return;
    buf.append(std.heap.c_allocator, 0) catch return;
    const s: [*:0]const u8 = @ptrCast(buf.items.ptr);
    _ = objc.send(*const fn (id, SEL, id, id) callconv(.c) bool)(pb, objc.sel("setString:forType:"), objc.string(s), objc.string("public.utf8-plain-text"));
}

fn onKeyUp(view: id, _: SEL, event: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.{ .key_up = keyEvent(event) });
}

fn onFlags(view: id, _: SEL, event: id) callconv(.c) void {
    const w = byView(view) orelse return;
    w.emit(.{ .modifiers = mods(event) });
}

fn notificationWindow(note: id) ?*Window {
    return byNsWindow(objc.msg(note, "object"));
}

fn onResize(_: id, _: SEL, note: id) callconv(.c) void {
    const w = notificationWindow(note) orelse return;
    if (w.layer != null) setF64(w.layer, "setContentsScale:", w.scale());
    const s = w.size();
    w.emit(.{ .resize = .{
        .width = s.w,
        .height = s.h,
        .scale = w.scale(),
    } });
}

fn onFocus(_: id, _: SEL, note: id) callconv(.c) void {
    const w = notificationWindow(note) orelse return;
    w.emit(.{ .focus = true });
}

fn onBlur(_: id, _: SEL, note: id) callconv(.c) void {
    const w = notificationWindow(note) orelse return;
    w.emit(.{ .focus = false });
}

fn onClose(_: id, _: SEL, note: id) callconv(.c) void {
    const w = notificationWindow(note) orelse return;
    w.closed = true;
    if (w.display_link != null) _ = objc.msg(w.display_link, "invalidate");
    w.emit(.close);
    for (windows.items, 0..) |x, i| if (x == w) {
        _ = windows.swapRemove(i);
        break;
    };
}

/// In every page of a web window: an element marked `data-window-drag` (and not a control
/// inside it) moves the window, and a double click on it zooms or minimises it.
const window_drag_script =
    \\(() => {
    \\  const skip = 'a,button,input,select,textarea,label,[contenteditable],[role=button],[data-no-window-drag]';
    \\  const inBar = (e) => e.button === 0 && e.target.closest && e.target.closest('[data-window-drag]') && !e.target.closest(skip);
    \\  addEventListener('mousedown', (e) => {
    \\    if (!inBar(e)) return;
    \\    webkit.messageHandlers.native.postMessage(e.detail === 2 ? '\u0001zoom' : '\u0001drag');
    \\  }, true);
    \\})();
;

fn onScriptMessage(_: id, _: SEL, controller: id, message: id) callconv(.c) void {
    _ = controller;
    const wk = objc.msg(message, "webView");
    for (windows.items) |w| for (w.webs.items) |web| if (web.wk == wk) {
        const body = objc.msg(message, "body");
        // Only strings cross: the page sends text (JSON when it needs structure).
        if (!objc.send(*const fn (id, SEL, id) callconv(.c) bool)(body, objc.sel("isKindOfClass:"), objc.class("NSString"))) return;
        const utf8: [*:0]const u8 = @ptrCast(objc.msg(body, "UTF8String"));
        const text = std.mem.span(utf8);
        // The window's own messages (the drag script), never the app's.
        if (std.mem.eql(u8, text, "\x01drag")) return w.dragWindow();
        if (std.mem.eql(u8, text, "\x01zoom")) return w.titlebarDoubleClick();
        const handler = w.handler.on_message orelse return;
        handler(w.handler.ctx, web, text);
        return;
    };
}

fn onAppearanceChanged(_: id, _: SEL, _: id) callconv(.c) void {
    // The notification comes before AppKit has the new appearance: ask once it has.
    runOnMain(null, tellAppearance);
}

fn tellAppearance(_: ?*anyopaque) callconv(.c) void {
    const a = appearance();
    for (windows.items) |w| w.emit(.{ .appearance = a });
}

fn onMenuItem(_: id, _: SEL, sender: id) callconv(.c) void {
    const handler = menu_handler orelse return;
    const tag: usize = @intFromPtr(objc.msg(sender, "tag"));
    handler(menu_ctx, @intCast(tag));
}

/// A page asks for a new window (a link with `target="_blank"`, `window.open`): it opens in
/// the person's browser, as a desktop app's links do; no second web view.
fn onNewWindow(_: id, _: SEL, _: id, _: id, action: id, _: id) callconv(.c) id {
    const nsurl = objc.msg(objc.msg(action, "request"), "URL");
    if (nsurl != null) _ = objc.msgId(objc.msg(objc.class("NSWorkspace"), "sharedWorkspace"), "openURL:", nsurl);
    return null;
}

/// The layout of an Objective-C block: what WebKit's completion handlers are.
const Block = extern struct {
    isa: ?*anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *const anyopaque,
};

/// `<input type=file>`: the system's open panel, its choice handed back to the page.
fn onOpenPanel(_: id, _: SEL, _: id, params: id, _: id, done: ?*Block) callconv(.c) void {
    const panel = objc.msg(objc.class("NSOpenPanel"), "openPanel");
    objc.msgBool(panel, "setCanChooseFiles:", true);
    objc.msgBool(panel, "setCanChooseDirectories:", objc.send(*const fn (id, SEL) callconv(.c) bool)(params, objc.sel("allowsDirectories")));
    objc.msgBool(panel, "setAllowsMultipleSelection:", objc.send(*const fn (id, SEL) callconv(.c) bool)(params, objc.sel("allowsMultipleSelection")));
    const response: isize = @bitCast(@intFromPtr(objc.msg(panel, "runModal")));
    const urls = if (response == 1) objc.msg(panel, "URLs") else null;
    const block = done orelse return;
    const invoke: *const fn (*Block, id) callconv(.c) void = @ptrCast(@alignCast(block.invoke));
    invoke(block, urls);
}
