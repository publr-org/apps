//! Desktop's words in the language the person chose (Settings › Language), or the Mac's own
//! when they chose none. Words are marked where they are written, as Publr marks its own:
//! `translated("Settings")`, `translated_in("verb", "Open")`,
//! `translated_count("{count} project", "{count} projects", n)`; Publr's extractor
//! (`zig run ../../publr/scripts/i18n.zig -- src`) collects them for translators. Translations are
//! PO files, `i18n/<language>.po`, read with Publr's own catalogue. A word a file does not
//! translate stays in English.

const std = @import("std");
const platform = @import("platform");
const catalog_module = @import("publr_i18n");

/// What the person chose: the Mac's language, or one of Desktop's.
pub const Choice = enum {
    system,
    en,
    pl,

    pub fn label(c: Choice) []const u8 {
        return switch (c) {
            // translators: Desktop follows the language the Mac is set to.
            .system => translated("Same as the Mac"),
            .en => "English",
            .pl => "Polski",
        };
    }
};

/// The languages Desktop speaks besides English, each with its PO file.
const files = [_]struct {
    code: []const u8,
    po: []const u8,
}{
    .{
        .code = "pl",
        .po = @embedFile("desktop_pl"),
    },
};

/// Each language's catalogue, read the first time it is spoken and kept: words already
/// handed out (a stored problem, a status) stay valid when the language changes.
var loaded: [files.len]?catalog_module.Catalog = @splat(null);
var current: ?*const catalog_module.Catalog = null;
/// The language spoken now (`en`, `pl`).
var spoken: []const u8 = "en";

/// Speaks `choice`: the Mac's language when it is `system`, English when Desktop has none of
/// it.
pub fn use(choice: Choice) void {
    current = null;
    spoken = "en";
    var buf: [64]u8 = undefined;
    const code = switch (choice) {
        .system => base(platform.preferredLanguage(&buf)),
        .en => "en",
        .pl => "pl",
    };
    inline for (files, 0..) |f, i| if (std.mem.eql(u8, f.code, code)) {
        if (loaded[i] == null) {
            const sources = [_]catalog_module.Source{.{
                .provider = "desktop",
                .first_party = true,
                .po = f.po,
            }};
            loaded[i] = catalog_module.Catalog.init(std.heap.page_allocator, f.code, &sources, &.{}) catch |e| {
                std.debug.print("desktop: the {s} translation: {t}\n", .{ f.code, e });
                return;
            };
        }
        current = &loaded[i].?;
        spoken = f.code;
    };
}

/// The language spoken now (`en`, `pl`).
pub fn language() []const u8 {
    return spoken;
}

/// `pl-PL` is `pl`.
fn base(code: []const u8) []const u8 {
    const dash = std.mem.indexOfAny(u8, code, "-_") orelse code.len;
    return code[0..dash];
}

pub fn translated(text: []const u8) []const u8 {
    const c = current orelse return text;
    return c.lookup("", text, null) orelse text;
}

/// The same words meaning another thing, told apart by `context` ("verb").
pub fn translated_in(context: []const u8, text: []const u8) []const u8 {
    const c = current orelse return text;
    return c.lookup(context, text, null) orelse text;
}

/// The form for `count` (Polish has three); `{count}` in it is left for `fill`.
pub fn translated_count(one: []const u8, other: []const u8, count: u64) []const u8 {
    const english = if (count == 1) one else other;
    const c = current orelse return english;
    return c.lookup("", one, @floatFromInt(count)) orelse english;
}

/// `text` with each `{name}` replaced by `values.name` (text or a number), in `buf`; as much
/// as fits.
pub fn fill(buf: []u8, text: []const u8, values: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    outer: while (i < text.len) {
        if (text[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, text, i, '}')) |end| {
                const name = text[i + 1 .. end];
                inline for (comptime std.meta.fieldNames(@TypeOf(values))) |field| {
                    if (std.mem.eql(u8, field, name)) {
                        const value = @field(values, field);
                        switch (@typeInfo(@TypeOf(value))) {
                            .int, .comptime_int => w.print("{d}", .{value}) catch break :outer,
                            else => w.writeAll(value) catch break :outer,
                        }
                        i = end + 1;
                        continue :outer;
                    }
                }
            }
        }
        w.writeByte(text[i]) catch break;
        i += 1;
    }
    return w.buffered();
}

test "words stay English without a translation, and placeholders are filled" {
    use(.en);
    try std.testing.expectEqualStrings("Settings", translated("Settings"));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("3 projects", fill(&buf, translated_count("{count} project", "{count} projects", 3), .{ .count = 3 }));
    try std.testing.expectEqualStrings("Hi Ada, 2", fill(&buf, "Hi {name}, {n}", .{ .name = "Ada", .n = 2 }));
}

test "Polish has its words and its three plural forms" {
    use(.pl);
    defer use(.en);
    try std.testing.expectEqualStrings("pl", language());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1 projekt", fill(&buf, translated_count("{count} project", "{count} projects", 1), .{ .count = 1 }));
    try std.testing.expectEqualStrings("3 projekty", fill(&buf, translated_count("{count} project", "{count} projects", 3), .{ .count = 3 }));
    try std.testing.expectEqualStrings("5 projektów", fill(&buf, translated_count("{count} project", "{count} projects", 5), .{ .count = 5 }));
}
