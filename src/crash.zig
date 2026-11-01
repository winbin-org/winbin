//! What's printed when winbin panics or crashes. wintrace's trace needs no PDB, so it's
//! what a shipped exe gives, and `wintrace-symbolize` names its frames later with the PDB
//! that was kept. A debug build adds std's trace, which has the names on the spot.
//! wintrace doesn't support x86, so there it's only a panic's message.

const has_wintrace = builtin.cpu.arch != .x86;
const wintrace = if (has_wintrace) @import("wintrace") else {};

pub const panic = std.debug.FullPanic(onPanic);

/// Enough stack left after an overflow for `onException` to report it.
const stack_guarantee = 32 * 1024;

pub fn install() void {
    if (!has_wintrace) return;
    _ = SetUnhandledExceptionFilter(onException);
    var size: u32 = stack_guarantee;
    if (SetThreadStackGuarantee(&size) == 0)
        main.fatal("SetThreadStackGuarantee failed: error {d}", .{@backingInt(std.os.windows.teb().LastErrorValue)});
}

/// Set first, so that crashing while reporting a crash can't go around again until the
/// stack runs out. WinHTTP's threads can get here too, but then this is only less careful
/// about two crashes at once.
var reporting = false;

/// Not on the stack: there's little of it left after an overflow.
var stderr_buf: [4096]u8 = undefined;

fn startReport() void {
    if (reporting) std.process.exit(exit_code);
    reporting = true;
}

/// What std's own panic exits with.
const exit_code = 3;

fn onPanic(message: []const u8, first_address: ?usize) noreturn {
    startReport();
    var stderr = std.Io.File.stderr().writerStreaming(main.io, &stderr_buf);
    const w = &stderr.interface;
    w.print("winbin: panic: {s}\n", .{message}) catch {};
    if (has_wintrace) wintrace.writeCurrentStackTrace(w, first_address) catch {};
    // first, so that it's there even if std's trace fails while the process is crashing
    w.flush() catch {};
    if (builtin.mode == .debug) {
        const terminal = std.debug.lockStderr(&.{}).terminal();
        std.debug.writeCurrentStackTrace(.{
            .first_address = first_address orelse @returnAddress(),
            .allow_unsafe_unwind = true,
        }, terminal) catch {};
    }
    std.process.exit(exit_code);
}

fn onException(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    startReport();
    var stderr = std.Io.File.stderr().writerStreaming(main.io, &stderr_buf);
    const w = &stderr.interface;
    const code = info.ExceptionRecord.ExceptionCode;
    w.print("winbin: crash: {s} (exception 0x{x})\n", .{ exceptionName(code), code }) catch {};
    wintrace.writeStackTrace(w, info.ContextRecord) catch {};
    w.flush() catch {};
    // std needs around a megabyte of stack to read a PDB
    if (builtin.mode == .debug and code != windows.EXCEPTION_STACK_OVERFLOW) {
        const context = std.debug.cpu_context.fromWindowsContext(info.ContextRecord);
        const terminal = std.debug.lockStderr(&.{}).terminal();
        std.debug.writeCurrentStackTrace(.{ .context = &context, .allow_unsafe_unwind = true }, terminal) catch {};
    }
    std.process.exit(exit_code);
}

fn exceptionName(code: u32) []const u8 {
    return switch (code) {
        windows.EXCEPTION_ACCESS_VIOLATION => "access violation",
        windows.EXCEPTION_DATATYPE_MISALIGNMENT => "unaligned memory access",
        windows.EXCEPTION_ILLEGAL_INSTRUCTION => "illegal instruction",
        windows.EXCEPTION_STACK_OVERFLOW => "stack overflow",
        else => "unhandled exception",
    };
}

extern "kernel32" fn SetUnhandledExceptionFilter(
    filter: *const fn (*windows.EXCEPTION_POINTERS) callconv(.winapi) c_long,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetThreadStackGuarantee(size: *u32) callconv(.winapi) i32;

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const main = @import("main.zig");
