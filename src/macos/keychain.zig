//! Secrets in the macOS keychain (a generic password per service and account), through
//! the Security framework's C API.

const std = @import("std");

const CFTypeRef = ?*const anyopaque;
const CFDictionaryKeyCallBacks = opaque {};
const CFDictionaryValueCallBacks = opaque {};

extern "c" const kSecClass: CFTypeRef;
extern "c" const kSecClassGenericPassword: CFTypeRef;
extern "c" const kSecAttrService: CFTypeRef;
extern "c" const kSecAttrAccount: CFTypeRef;
extern "c" const kSecValueData: CFTypeRef;
extern "c" const kSecReturnData: CFTypeRef;
extern "c" const kSecMatchLimit: CFTypeRef;
extern "c" const kSecMatchLimitOne: CFTypeRef;
extern "c" const kCFBooleanTrue: CFTypeRef;
extern "c" const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
extern "c" const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;

extern "c" fn CFDictionaryCreate(alloc: ?*anyopaque, keys: [*]const CFTypeRef, values: [*]const CFTypeRef, n: isize, kcb: *const CFDictionaryKeyCallBacks, vcb: *const CFDictionaryValueCallBacks) CFTypeRef;
extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, n: isize, encoding: u32, external: bool) CFTypeRef;
extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, n: isize) CFTypeRef;
extern "c" fn CFDataGetBytePtr(data: CFTypeRef) [*]const u8;
extern "c" fn CFDataGetLength(data: CFTypeRef) isize;
extern "c" fn CFRelease(o: CFTypeRef) void;
extern "c" fn SecItemAdd(attrs: CFTypeRef, result: ?*CFTypeRef) i32;
extern "c" fn SecItemCopyMatching(query: CFTypeRef, result: ?*CFTypeRef) i32;
extern "c" fn SecItemDelete(query: CFTypeRef) i32;

const utf8: u32 = 0x08000100;

fn cfString(s: []const u8) CFTypeRef {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), utf8, false);
}

fn dictionary(keys: []const CFTypeRef, values: []const CFTypeRef) CFTypeRef {
    return CFDictionaryCreate(null, keys.ptr, values.ptr, @intCast(keys.len), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

/// The secret kept for `service` and `account` (owned by the caller), or null.
pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ?[]u8 {
    const s = cfString(service);
    defer CFRelease(s);
    const a = cfString(account);
    defer CFRelease(a);
    const query = dictionary(
        &.{ kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit },
        &.{ kSecClassGenericPassword, s, a, kCFBooleanTrue, kSecMatchLimitOne },
    );
    defer CFRelease(query);
    var found: CFTypeRef = null;
    if (SecItemCopyMatching(query, &found) != 0 or found == null) return null;
    defer CFRelease(found);
    const n: usize = @intCast(CFDataGetLength(found));
    return gpa.dupe(u8, CFDataGetBytePtr(found)[0..n]) catch null;
}

/// Keeps `secret` for `service` and `account`, replacing what was there.
pub fn set(service: []const u8, account: []const u8, secret: []const u8) bool {
    remove(service, account);
    const s = cfString(service);
    defer CFRelease(s);
    const a = cfString(account);
    defer CFRelease(a);
    const data = CFDataCreate(null, secret.ptr, @intCast(secret.len));
    defer CFRelease(data);
    const attrs = dictionary(
        &.{ kSecClass, kSecAttrService, kSecAttrAccount, kSecValueData },
        &.{ kSecClassGenericPassword, s, a, data },
    );
    defer CFRelease(attrs);
    return SecItemAdd(attrs, null) == 0;
}

pub fn remove(service: []const u8, account: []const u8) void {
    const s = cfString(service);
    defer CFRelease(s);
    const a = cfString(account);
    defer CFRelease(a);
    const query = dictionary(
        &.{ kSecClass, kSecAttrService, kSecAttrAccount },
        &.{ kSecClassGenericPassword, s, a },
    );
    defer CFRelease(query);
    _ = SecItemDelete(query);
}
