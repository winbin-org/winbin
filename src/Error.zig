//! What failed and the code Windows gave for it, for a failure whose caller decides what
//! happens next. A function that can fail this way takes an `*Error` to fill in and
//! returns `error.Error`.

const Error = @This();

what: [:0]const u8,
code: union(enum) {
    win32: win32.WIN32_ERROR,
    ntstatus: std.os.windows.NTSTATUS,
},

pub fn setWin32(self: *Error, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
    self.* = .{ .what = what, .code = .{ .win32 = code } };
    return error.Error;
}

pub fn setNtstatus(self: *Error, what: [:0]const u8, status: std.os.windows.NTSTATUS) error{Error} {
    self.* = .{ .what = what, .code = .{ .ntstatus = status } };
    return error.Error;
}

pub fn format(self: Error, w: *std.Io.Writer) error{WriteFailed}!void {
    switch (self.code) {
        .win32 => |code| try w.print("{s} failed, error={f}", .{ self.what, code }),
        .ntstatus => |status| try w.print("{s} failed, NTSTATUS 0x{x}", .{ self.what, @backingInt(status) }),
    }
}

const std = @import("std");
const win32 = @import("win32").everything;
