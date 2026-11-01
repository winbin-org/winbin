//! What a panic or a crash prints, from a small exe that uses src/crash.zig.

fn run(exe: []const u8, what: []const u8) !std.process.RunResult {
    return std.process.run(testing.allocator, testing.io, .{ .argv = &.{ exe, what } });
}

/// A trace that can be symbolized later: frames, and the PDB identity of its own module.
fn expectWintrace(stderr: []const u8, exe_name: []const u8) !void {
    try testing.expect(std.mem.find(u8, stderr, "    wintrace\n") != null);
    var frame_buf: [64]u8 = undefined;
    const frame = try std.fmt.bufPrint(&frame_buf, "    {s}+0x", .{exe_name});
    try testing.expect(std.mem.find(u8, stderr, frame) != null);
    var module_buf: [64]u8 = undefined;
    const module = try std.fmt.bufPrint(&module_buf, "    module {s} | ", .{exe_name});
    try testing.expect(std.mem.find(u8, stderr, module) != null);
}

fn expectReport(exe: []const u8, what: []const u8, message: []const u8) ![]const u8 {
    const result = try run(exe, what);
    defer testing.allocator.free(result.stdout);
    errdefer testing.allocator.free(result.stderr);
    errdefer std.debug.print("{s}: {any}\nstderr: {s}\n", .{ what, result.term, result.stderr });
    try testing.expect(result.term == .exited and result.term.exited == 3);
    try testing.expect(std.mem.find(u8, result.stderr, message) != null);
    try expectWintrace(result.stderr, std.fs.path.basename(exe));
    return result.stderr;
}

const messages = [_]struct { what: []const u8, message: []const u8 }{
    .{ .what = "panic", .message = "winbin: panic: the test's panic\n" },
    .{ .what = "access-violation", .message = "winbin: crash: access violation (exception 0xc0000005)\n" },
    .{ .what = "stack-overflow", .message = "winbin: crash: stack overflow (exception 0xc00000fd)\n" },
};

test "a release build needs no PDB for its traces, and has no names in them" {
    for (messages) |m| {
        const stderr = try expectReport(paths.release, m.what, m.message);
        defer testing.allocator.free(stderr);
        try testing.expect(std.mem.find(u8, stderr, "crash_test_main.zig") == null);
    }
}

test "a debug build has std's trace too, with names, unless the stack has run out" {
    for (messages) |m| {
        const stderr = try expectReport(paths.debug, m.what, m.message);
        defer testing.allocator.free(stderr);
        const has_names = std.mem.find(u8, stderr, "crash_test_main.zig") != null;
        try testing.expectEqual(!std.mem.eql(u8, m.what, "stack-overflow"), has_names);
    }
}

const std = @import("std");
const testing = std.testing;
const paths = @import("paths");
