//! winbin for the end-to-end tests, failing on memory it didn't free, and on freeing
//! something wrong, which an arena wouldn't notice.

pub const std_options = winbin.std_options;
pub const panic = winbin.panic;

pub fn main(init: std.process.Init.Minimal) void {
    winbin.crash.install();
    var debug: std.heap.DebugAllocator(.{}) = .init;
    winbin.main2(init, debug.allocator());
    if (debug.deinit() == .leak) winbin.errExit("leaked memory", .{});
}

const std = @import("std");
const winbin = @import("winbin");
