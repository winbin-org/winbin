//! For test/crash.zig: panics or crashes the way its argument says, through `crash.zig`.

pub const std_options = winbin.std_options;
pub const panic = crash.panic;

pub fn main(init: std.process.Init.Minimal) void {
    crash.install();
    var args = init.args.iterateAllocator(std.heap.page_allocator) catch |e| winbin.oom(e);
    _ = args.skip();
    const what = args.next() orelse winbin.fatal("expected what to do", .{});
    if (std.mem.eql(u8, what, "panic")) @panic("the test's panic");
    if (std.mem.eql(u8, what, "access-violation")) {
        const address: *volatile u8 = @ptrFromInt(0x10);
        address.* = 1;
    }
    if (std.mem.eql(u8, what, "stack-overflow")) std.mem.doNotOptimizeAway(recurse(0));
    winbin.fatal("unknown '{s}'", .{what});
}

noinline fn recurse(depth: usize) usize {
    var buf: [4096]u8 = undefined;
    buf[depth % buf.len] = @truncate(depth);
    std.mem.doNotOptimizeAway(&buf);
    return recurse(depth + 1) +% buf[depth % buf.len];
}

const std = @import("std");
const crash = @import("crash.zig");
const winbin = @import("main.zig");
