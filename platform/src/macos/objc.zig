//! The Objective-C runtime and the few C calls the macOS backend makes, typed by hand.

pub const id = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Class = ?*anyopaque;

pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "c" fn sel_getName(sel: SEL) [*:0]const u8;
extern "c" fn objc_msgSend() void;
pub extern "c" fn objc_allocateClassPair(super: Class, name: [*:0]const u8, extra: usize) Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;
pub extern "c" fn class_addProtocol(cls: Class, proto: ?*anyopaque) bool;
pub extern "c" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;

/// `NSRunLoopCommonModes`: the display link keeps ticking during live resize and tracking.
pub extern "c" var NSRunLoopCommonModes: id;
pub extern "c" var NSAppearanceNameAqua: id;
pub extern "c" var NSAppearanceNameDarkAqua: id;

pub const CGPoint = extern struct {
    x: f64,
    y: f64,
};
pub const CGSize = extern struct {
    w: f64,
    h: f64,
};
pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

pub extern "c" var kCGColorSpaceSRGB: ?*anyopaque;
pub extern "c" fn CGColorSpaceCreateWithName(name: ?*anyopaque) ?*anyopaque;
pub extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: isize) ?*anyopaque;
pub extern "c" fn CFRelease(o: ?*anyopaque) void;
pub extern "c" fn CGDataProviderCreateWithCFData(data: ?*anyopaque) ?*anyopaque;
pub extern "c" fn CGDataProviderRelease(p: ?*anyopaque) void;
pub extern "c" fn CGImageCreate(
    width: usize,
    height: usize,
    bits_per_component: usize,
    bits_per_pixel: usize,
    bytes_per_row: usize,
    space: ?*anyopaque,
    bitmap_info: u32,
    provider: ?*anyopaque,
    decode: ?*const f64,
    interpolate: bool,
    intent: i32,
) ?*anyopaque;
pub extern "c" fn CGImageRelease(img: ?*anyopaque) void;
pub extern "c" fn CGImageGetWidth(img: ?*anyopaque) usize;
pub extern "c" fn CGImageGetHeight(img: ?*anyopaque) usize;
pub extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: ?*anyopaque, bitmap_info: u32) ?*anyopaque;
pub extern "c" fn CGContextDrawImage(ctx: ?*anyopaque, r: CGRect, img: ?*anyopaque) void;
pub extern "c" fn CGContextRelease(ctx: ?*anyopaque) void;

/// What a block a method keeps is copied from (clang's layout for blocks).
pub extern "c" var _NSConcreteStackBlock: anyopaque;

pub const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn class(name: [*:0]const u8) id {
    return objc_getClass(name);
}

/// `objc_msgSend` cast to the signature of the method called.
pub fn send(comptime F: type) F {
    return @ptrCast(&objc_msgSend);
}

pub fn msg(o: id, s: [*:0]const u8) id {
    return send(*const fn (id, SEL) callconv(.c) id)(o, sel(s));
}

pub fn msgId(o: id, s: [*:0]const u8, a: id) id {
    return send(*const fn (id, SEL, id) callconv(.c) id)(o, sel(s), a);
}

pub fn msgUsize(o: id, s: [*:0]const u8, a: usize) id {
    return send(*const fn (id, SEL, usize) callconv(.c) id)(o, sel(s), a);
}

pub fn msgBool(o: id, s: [*:0]const u8, a: bool) void {
    _ = send(*const fn (id, SEL, bool) callconv(.c) id)(o, sel(s), a);
}

pub fn msgF64(o: id, s: [*:0]const u8) f64 {
    return send(*const fn (id, SEL) callconv(.c) f64)(o, sel(s));
}

pub fn msgRect(o: id, s: [*:0]const u8) CGRect {
    return send(*const fn (id, SEL) callconv(.c) CGRect)(o, sel(s));
}

pub fn string(s: [*:0]const u8) id {
    return send(*const fn (id, SEL, [*:0]const u8) callconv(.c) id)(class("NSString"), sel("stringWithUTF8String:"), s);
}

pub const Method = struct { [*:0]const u8, *const anyopaque, [*:0]const u8 };

/// A class made at run time: `methods` are (selector, function, type encoding).
pub fn makeClass(super: [*:0]const u8, name: [*:0]const u8, methods: []const Method) id {
    return makeClassWith(super, name, methods, &.{});
}

/// `makeClass` adopting `protocols`.
pub fn makeClassWith(super: [*:0]const u8, name: [*:0]const u8, methods: []const Method, protocols: []const [*:0]const u8) id {
    const c = objc_allocateClassPair(class(super), name, 0);
    for (methods) |mth| _ = class_addMethod(c, sel(mth[0]), mth[1], mth[2]);
    for (protocols) |p| _ = class_addProtocol(c, objc_getProtocol(p));
    objc_registerClassPair(c);
    return c;
}
