//! A browser keeps no secrets for the app: nothing is found, nothing is kept.

const std = @import("std");

pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ?[]u8 {
    _ = gpa;
    _ = service;
    _ = account;
    return null;
}

pub fn set(service: []const u8, account: []const u8, secret: []const u8) bool {
    _ = service;
    _ = account;
    _ = secret;
    return false;
}

pub fn remove(service: []const u8, account: []const u8) void {
    _ = service;
    _ = account;
}
