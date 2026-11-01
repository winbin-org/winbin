//! Reading strings out of JSON by path. There's no tree in memory: each step
//! scans the part of the text it needs, which is what lets an array element be
//! chosen by a field that comes after the one being read.

pub const Segment = union(enum) {
    /// the value of a key in an object
    key: []const u8,
    /// every key of an object, see `KeyIterator`
    any_key,
    /// the one element of an array whose string field has this value
    select: Select,

    pub const Select = struct { field: []const u8, value: []const u8 };
};

pub const Diagnostic = struct {
    /// which segment it's about, from 1
    part: usize = 0,
    message: []const u8 = "",
};

/// `Invalid` is explained by the Diagnostic. The others come from scanning: the
/// text isn't valid JSON, or is nested too deeply, or there wasn't enough memory.
pub const Error = std.json.Scanner.AllocError || error{Invalid};

/// Enough for nesting thousands of levels deep, each level is one bit.
const stack_size = 1024;

/// The string at `segments`, which has no `any_key`, null if a key is missing. It's
/// allocated with `strings`.
pub fn readString(text: []const u8, segments: []const Segment, strings: std.mem.Allocator, diag: *Diagnostic) Error!?[]const u8 {
    try validate(text);
    const value = try locate(text, segments, 0, strings, diag) orelse return null;
    if (!try isString(value)) return fail(diag, segments.len, "the value isn't a string");

    var stack_buf: [stack_size]u8 = undefined;
    var stack: std.heap.FixedBufferAllocator = .init(&stack_buf);
    var scanner: std.json.Scanner = .initCompleteInput(stack.allocator(), value);
    return try nextString(&scanner, strings);
}

/// Each key of the object where `any_key` is, for which the rest of the path is
/// a string. Keys without the rest of the path are skipped.
pub const KeyIterator = struct {
    stack_buf: [stack_size]u8,
    stack: std.heap.FixedBufferAllocator,
    strings: std.mem.Allocator,
    scanner: std.json.Scanner,
    object: []const u8,
    rest: []const Segment,
    /// how many segments come before `rest`
    rest_part: usize,

    /// `segments` has exactly one `any_key`. The iterator can't move after this.
    pub fn init(self: *KeyIterator, text: []const u8, segments: []const Segment, strings: std.mem.Allocator, diag: *Diagnostic) Error!void {
        try validate(text);
        const index = for (segments, 0..) |segment, i| {
            if (segment == .any_key) break i;
        } else unreachable;
        self.object = try locate(text, segments[0..index], 0, strings, diag) orelse
            return fail(diag, index, "a key is missing");
        self.rest = segments[index + 1 ..];
        self.rest_part = index + 1;
        self.stack = .init(&self.stack_buf);
        self.strings = strings;
        self.scanner = .initCompleteInput(self.stack.allocator(), self.object);
        if (try peek(&self.scanner) != .object_begin) return fail(diag, index + 1, "expected an object");
        try enter(&self.scanner);
    }

    /// The key is allocated with `strings`.
    pub fn next(self: *KeyIterator, diag: *Diagnostic) Error!?[]const u8 {
        while (true) {
            if (try peek(&self.scanner) == .object_end) return null;
            const key = try nextString(&self.scanner, self.strings);
            errdefer self.strings.free(key);
            _ = try peek(&self.scanner);
            const start = self.scanner.cursor;
            try self.scanner.skipValue();
            const value = try locate(self.object[start..], self.rest, self.rest_part, self.strings, diag) orelse {
                self.strings.free(key);
                continue;
            };
            if (!try isString(value)) return fail(diag, self.rest_part + self.rest.len, "the value isn't a string");
            return key;
        }
    }
};

fn validate(text: []const u8) Error!void {
    var stack_buf: [stack_size]u8 = undefined;
    var stack: std.heap.FixedBufferAllocator = .init(&stack_buf);
    if (!try std.json.validate(stack.allocator(), text)) return error.SyntaxError;
}

/// What's left of the text starting at the value `segments` leads to, null if a
/// key is missing. `part` is how many segments came before these.
fn locate(text: []const u8, segments: []const Segment, part: usize, strings: std.mem.Allocator, diag: *Diagnostic) Error!?[]const u8 {
    var value = text;
    for (segments, part + 1..) |segment, number| value = switch (segment) {
        .key => |key| try findKey(value, key, number, strings, diag) orelse return null,
        .select => |select| try selectElement(value, select, number, strings, diag),
        .any_key => unreachable,
    };
    return value;
}

fn findKey(object: []const u8, wanted: []const u8, part: usize, strings: std.mem.Allocator, diag: *Diagnostic) Error!?[]const u8 {
    var stack_buf: [stack_size]u8 = undefined;
    var stack: std.heap.FixedBufferAllocator = .init(&stack_buf);
    var scanner: std.json.Scanner = .initCompleteInput(stack.allocator(), object);
    if (try peek(&scanner) != .object_begin) return fail(diag, part, "expected an object");
    try enter(&scanner);
    var found: ?[]const u8 = null;
    while (try peek(&scanner) != .object_end) {
        const key = try nextString(&scanner, strings);
        defer strings.free(key);
        _ = try peek(&scanner);
        if (std.mem.eql(u8, key, wanted)) {
            if (found != null) return fail(diag, part, "the object has this key twice");
            found = object[scanner.cursor..];
        }
        try scanner.skipValue();
    }
    return found;
}

fn selectElement(array: []const u8, select: Segment.Select, part: usize, strings: std.mem.Allocator, diag: *Diagnostic) Error![]const u8 {
    var stack_buf: [stack_size]u8 = undefined;
    var stack: std.heap.FixedBufferAllocator = .init(&stack_buf);
    var scanner: std.json.Scanner = .initCompleteInput(stack.allocator(), array);
    if (try peek(&scanner) != .array_begin) return fail(diag, part, "expected an array");
    try enter(&scanner);
    var found: ?[]const u8 = null;
    while (try peek(&scanner) != .array_end) {
        const element = array[scanner.cursor..];
        if (try fieldEquals(element, select, part, strings, diag)) {
            if (found != null) return fail(diag, part, "more than one element matches");
            found = element;
        }
        try scanner.skipValue();
    }
    return found orelse fail(diag, part, "no element matches");
}

fn fieldEquals(element: []const u8, select: Segment.Select, part: usize, strings: std.mem.Allocator, diag: *Diagnostic) Error!bool {
    var stack_buf: [stack_size]u8 = undefined;
    var stack: std.heap.FixedBufferAllocator = .init(&stack_buf);
    var scanner: std.json.Scanner = .initCompleteInput(stack.allocator(), element);
    if (try peek(&scanner) != .object_begin) return false;
    const value = try findKey(element, select.field, part, strings, diag) orelse return false;
    if (!try isString(value)) return false;

    var value_stack_buf: [stack_size]u8 = undefined;
    var value_stack: std.heap.FixedBufferAllocator = .init(&value_stack_buf);
    var value_scanner: std.json.Scanner = .initCompleteInput(value_stack.allocator(), value);
    const string = try nextString(&value_scanner, strings);
    defer strings.free(string);
    return std.mem.eql(u8, string, select.value);
}

fn isString(value: []const u8) Error!bool {
    var stack_buf: [stack_size]u8 = undefined;
    var stack: std.heap.FixedBufferAllocator = .init(&stack_buf);
    var scanner: std.json.Scanner = .initCompleteInput(stack.allocator(), value);
    return try peek(&scanner) == .string;
}

fn peek(scanner: *std.json.Scanner) Error!std.json.Scanner.TokenType {
    return scanner.peekNextTokenType() catch |e| switch (e) {
        // not possible with complete input
        error.BufferUnderrun => unreachable,
        else => |err| return err,
    };
}

fn enter(scanner: *std.json.Scanner) Error!void {
    _ = scanner.next() catch |e| switch (e) {
        // not possible with complete input
        error.BufferUnderrun => unreachable,
        else => |err| return err,
    };
}

fn nextString(scanner: *std.json.Scanner, strings: std.mem.Allocator) Error![]const u8 {
    return switch (try scanner.nextAllocMax(strings, .alloc_if_needed, std.math.maxInt(usize))) {
        .string => |s| try strings.dupe(u8, s),
        .allocated_string => |s| s,
        else => unreachable,
    };
}

fn fail(diag: *Diagnostic, part: usize, message: []const u8) error{Invalid} {
    diag.* = .{ .part = part, .message = message };
    return error.Invalid;
}

fn k(name: []const u8) Segment {
    return .{ .key = name };
}

fn sel(field: []const u8, value: []const u8) Segment {
    return .{ .select = .{ .field = field, .value = value } };
}

fn testStrings() std.mem.Allocator {
    const static = struct {
        var buf: [64 * 1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
    };
    static.fba.reset();
    return static.fba.allocator();
}

fn read(text: []const u8, segments: []const Segment) Error!?[]const u8 {
    var diag: Diagnostic = .{};
    return readString(text, segments, testStrings(), &diag);
}

fn expectFailure(text: []const u8, segments: []const Segment, part: usize, message: []const u8) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(error.Invalid, readString(text, segments, testStrings(), &diag));
    try testing.expectEqual(part, diag.part);
    try testing.expectEqualStrings(message, diag.message);
}

test "readString follows keys" {
    const text = "  { \"a\": {\"b\": \"x\"}, \"tag_name\" : \"v1.2\" }  ";
    try testing.expectEqualStrings("v1.2", (try read(text, &.{k("tag_name")})).?);
    try testing.expectEqualStrings("x", (try read(text, &.{ k("a"), k("b") })).?);
}

test "readString: a key can have dots in it" {
    try testing.expectEqualStrings("x", (try read("{\"0.17.0\":{\"a\":\"x\"}}", &.{ k("0.17.0"), k("a") })).?);
}

test "readString: a missing key is null" {
    try testing.expectEqual(null, try read("{\"a\":\"x\"}", &.{k("b")}));
    try testing.expectEqual(null, try read("{\"a\":{}}", &.{ k("a"), k("b") }));
}

test "readString decodes escapes in values and keys" {
    try testing.expectEqualStrings("https://e.com/a\"b", (try read("{\"a\":\"https:\\/\\/e.com\\/a\\\"b\"}", &.{k("a")})).?);
    try testing.expectEqualStrings("x", (try read("{\"\\u0061\":\"x\"}", &.{k("a")})).?);
}

test "readString only reads strings" {
    try expectFailure("{\"a\":1}", &.{k("a")}, 1, "the value isn't a string");
    try expectFailure("{\"a\":null}", &.{k("a")}, 1, "the value isn't a string");
    try expectFailure("{\"a\":{}}", &.{k("a")}, 1, "the value isn't a string");
}

test "readString fails on the wrong shape, naming the part" {
    try expectFailure("[]", &.{k("a")}, 1, "expected an object");
    try expectFailure("{\"a\":\"x\"}", &.{ k("a"), k("b") }, 2, "expected an object");
    try expectFailure("{\"a\":{}}", &.{ k("a"), sel("n", "v") }, 2, "expected an array");
}

test "readString fails on a duplicate key" {
    try expectFailure("{\"a\":\"x\",\"a\":\"y\"}", &.{k("a")}, 1, "the object has this key twice");
}

test "readString rejects invalid JSON, even after the value it wants" {
    try testing.expectError(error.SyntaxError, read("{\"a\":\"x\",}", &.{k("a")}));
    try testing.expectError(error.SyntaxError, read("{\"a\":\"x\"} trailing", &.{k("a")}));
    try testing.expectError(error.SyntaxError, read("<html>", &.{k("a")}));
    try testing.expectError(error.SyntaxError, read("{\"a\":\"x\"", &.{k("a")}));
    try testing.expectError(error.SyntaxError, read("", &.{k("a")}));
}

const release =
    \\{ "tag_name": "v2.0.0", "assets": [
    \\  { "name": "a.zip", "digest": "sha256:aa", "url": "https://e.com/a.zip" },
    \\  { "url": "https://e.com/b.zip", "digest": "sha256:bb", "name": "b.zip" },
    \\  { "digest": "sha256:nameless" },
    \\  { "name": 3, "digest": "sha256:number" },
    \\  "not an object"
    \\] }
;

test "select finds the one element with the field" {
    try testing.expectEqualStrings("sha256:aa", (try read(release, &.{ k("assets"), sel("name", "a.zip"), k("digest") })).?);
    // the field can come after what's being read
    try testing.expectEqualStrings("https://e.com/b.zip", (try read(release, &.{ k("assets"), sel("name", "b.zip"), k("url") })).?);
}

test "select has to find exactly one" {
    const path: []const Segment = &.{ k("assets"), sel("name", "nope"), k("digest") };
    try expectFailure(release, path, 2, "no element matches");
    try expectFailure(
        "{\"assets\":[{\"name\":\"a\"},{\"name\":\"a\"}]}",
        &.{ k("assets"), sel("name", "a"), k("digest") },
        2,
        "more than one element matches",
    );
}

test "select: a missing key after it is null" {
    try testing.expectEqual(null, try read(release, &.{ k("assets"), sel("name", "a.zip"), k("nope") }));
}

fn expectKeys(text: []const u8, segments: []const Segment, expected: []const []const u8) !void {
    var diag: Diagnostic = .{};
    var it: KeyIterator = undefined;
    try it.init(text, segments, testStrings(), &diag);
    for (expected) |want| try testing.expectEqualStrings(want, (try it.next(&diag)).?);
    try testing.expectEqual(null, try it.next(&diag));
}

const zig_index =
    \\{ "master": { "version": "0.18.0-dev", "x86_64-windows": { "tarball": "m" } },
    \\  "0.17.0": { "x86_64-windows": { "tarball": "a" }, "x86-windows": { "tarball": "b" } },
    \\  "0.16.0": { "x86-windows": { "tarball": "c" } },
    \\  "0.15.0": { "x86_64-windows": {} } }
;

test "KeyIterator: only keys with the rest of the path" {
    try expectKeys(zig_index, &.{ .any_key, k("x86_64-windows"), k("tarball") }, &.{ "master", "0.17.0" });
    try expectKeys(zig_index, &.{ .any_key, k("x86-windows"), k("tarball") }, &.{ "0.17.0", "0.16.0" });
    try expectKeys(zig_index, &.{ .any_key, k("nope"), k("tarball") }, &.{});
}

test "KeyIterator: every key when nothing follows, if they're strings" {
    try expectKeys("{\"a\":\"1\",\"b\":\"2\"}", &.{.any_key}, &.{ "a", "b" });
    try expectKeys("{}", &.{.any_key}, &.{});
}

test "KeyIterator: below other keys" {
    try expectKeys("{\"x\":{\"a\":{\"t\":\"1\"},\"b\":{}}}", &.{ k("x"), .any_key, k("t") }, &.{"a"});
}

test "KeyIterator fails on the wrong shape" {
    var diag: Diagnostic = .{};
    var it: KeyIterator = undefined;
    try testing.expectError(error.Invalid, it.init("[]", &.{.any_key}, testStrings(), &diag));
    try testing.expectEqualStrings("expected an object", diag.message);
    try testing.expectError(error.Invalid, it.init("{}", &.{ k("x"), .any_key }, testStrings(), &diag));
    try testing.expectEqualStrings("a key is missing", diag.message);

    try it.init("{\"a\":1}", &.{ .any_key, k("t") }, testStrings(), &diag);
    try testing.expectError(error.Invalid, it.next(&diag));
    try testing.expectEqualStrings("expected an object", diag.message);
    try testing.expectEqual(2, diag.part);

    try it.init("{\"a\":{\"t\":1}}", &.{ .any_key, k("t") }, testStrings(), &diag);
    try testing.expectError(error.Invalid, it.next(&diag));
    try testing.expectEqualStrings("the value isn't a string", diag.message);
}

test "KeyIterator rejects invalid JSON" {
    var diag: Diagnostic = .{};
    var it: KeyIterator = undefined;
    try testing.expectError(error.SyntaxError, it.init("{\"a\":{}} x", &.{.any_key}, testStrings(), &diag));
}

test "a string with escapes can be any length" {
    const long: [8192]u8 = @splat('b');
    const value = (try read("{\"\\u0061\":\"a\\n" ++ long ++ "\"}", &.{k("a")})).?;
    try testing.expectEqual(2 + 8192, value.len);
    try testing.expectEqualStrings("a\n", value[0..2]);
}

const std = @import("std");
const testing = std.testing;
