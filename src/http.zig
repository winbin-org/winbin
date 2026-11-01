//! HTTP GET through WinHTTP. It's part of Windows, so the binary carries no
//! TLS implementation or root certificates, and it gets the system's proxy
//! settings and certificate store. When followed, redirects can't go from HTTPS
//! to HTTP. A failure here ends the program, naming the URL.

/// winhttp.dll's functions, loaded rather than imported. A command that makes no requests
/// doesn't pay for it, and an import would take a winhttp.dll from next to winbin.exe
/// first, which is usually where packages install, so a package could put its own there.
pub const WinHttp = struct {
    WinHttpOpen: *const @TypeOf(win32.WinHttpOpen),
    WinHttpConnect: *const @TypeOf(win32.WinHttpConnect),
    WinHttpOpenRequest: *const @TypeOf(win32.WinHttpOpenRequest),
    WinHttpSetOption: *const @TypeOf(win32.WinHttpSetOption),
    WinHttpSendRequest: *const @TypeOf(win32.WinHttpSendRequest),
    WinHttpReceiveResponse: *const @TypeOf(win32.WinHttpReceiveResponse),
    WinHttpQueryHeaders: *const @TypeOf(win32.WinHttpQueryHeaders),
    WinHttpReadData: *const @TypeOf(win32.WinHttpReadData),
    WinHttpCloseHandle: *const @TypeOf(win32.WinHttpCloseHandle),

    /// Only from System32.
    pub fn load(err: *Error) error{Error}!WinHttp {
        const dll = win32.LoadLibraryExW(
            std.unicode.wtf8ToWtf16LeStringLiteral("winhttp.dll"),
            null,
            win32.LOAD_LIBRARY_SEARCH_SYSTEM32,
        ) orelse return err.setWin32("LoadLibraryExW(winhttp.dll)", win32.GetLastError());
        var winhttp: WinHttp = undefined;
        inline for (@typeInfo(WinHttp).@"struct".field_names) |name| {
            @field(winhttp, name) = @ptrCast(win32.GetProcAddress(dll, name) orelse
                return err.setWin32("GetProcAddress(winhttp.dll, " ++ name ++ ")", win32.GetLastError()));
        }
        return winhttp;
    }
};

/// `url` is already validated: http(s)://HOST[:PORT]/PATH
pub const Response = struct {
    winhttp: *const WinHttp,
    session: *anyopaque,
    connection: *anyopaque,
    request: *anyopaque,
    url: []const u8,
    status: u32,

    pub const Redirects = enum { follow, stop };

    pub fn get(winhttp: *const WinHttp, arena: std.mem.Allocator, url: []const u8, redirects: Redirects) Response {
        const secure = std.mem.startsWith(u8, url, "https://");
        const after_scheme = url[if (secure) "https://".len else "http://".len..];
        const slash = std.mem.findScalar(u8, after_scheme, '/').?;
        const authority = after_scheme[0..slash];
        const colon = std.mem.findScalar(u8, authority, ':');
        const port: u16 = if (colon) |c|
            std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch main.errExit("invalid port in url: {s}", .{url})
        else if (secure) 443 else 80;

        const host = toWide(arena, authority[0 .. colon orelse authority.len], url);
        defer arena.free(host);
        const path = toWide(arena, after_scheme[slash..], url);
        defer arena.free(path);

        const session = winhttp.WinHttpOpen(
            std.unicode.wtf8ToWtf16LeStringLiteral("winbin"),
            win32.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            null,
            null,
            0,
        ) orelse fail("WinHttpOpen", url);
        const connection = winhttp.WinHttpConnect(session, host, port, 0) orelse
            fail("WinHttpConnect", url);
        const request = winhttp.WinHttpOpenRequest(
            connection,
            std.unicode.wtf8ToWtf16LeStringLiteral("GET"),
            path,
            null,
            null,
            null,
            if (secure) win32.WINHTTP_FLAG_SECURE else .{},
        ) orelse fail("WinHttpOpenRequest", url);
        if (redirects == .stop) {
            var never: u32 = win32.WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
            if (winhttp.WinHttpSetOption(request, win32.WINHTTP_OPTION_REDIRECT_POLICY, @ptrCast(&never), @sizeOf(u32)) == 0)
                fail("WinHttpSetOption", url);
        }
        if (winhttp.WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) fail("WinHttpSendRequest", url);
        if (winhttp.WinHttpReceiveResponse(request, null) == 0) fail("WinHttpReceiveResponse", url);

        var status: u32 = 0;
        var status_size: u32 = @sizeOf(u32);
        const status_code = win32.WINHTTP_QUERY_STATUS_CODE | win32.WINHTTP_QUERY_FLAG_NUMBER;
        if (winhttp.WinHttpQueryHeaders(request, status_code, null, &status, &status_size, null) == 0)
            fail("WinHttpQueryHeaders", url);
        return .{ .winhttp = winhttp, .session = session, .connection = connection, .request = request, .url = url, .status = status };
    }

    pub fn location(self: *const Response, arena: std.mem.Allocator) ?[]const u8 {
        // asking with no buffer says how big one has to be
        var size: u32 = 0;
        if (self.winhttp.WinHttpQueryHeaders(self.request, win32.WINHTTP_QUERY_LOCATION, null, null, &size, null) == 0) {
            switch (@backingInt(std.os.windows.teb().LastErrorValue)) {
                win32.ERROR_WINHTTP_HEADER_NOT_FOUND => return null,
                @backingInt(win32.ERROR_INSUFFICIENT_BUFFER) => {},
                else => fail("WinHttpQueryHeaders", self.url),
            }
        }
        const wide = arena.alloc(u16, size / 2) catch |e| oom(e);
        defer arena.free(wide);
        if (self.winhttp.WinHttpQueryHeaders(self.request, win32.WINHTTP_QUERY_LOCATION, null, wide.ptr, &size, null) == 0)
            fail("WinHttpQueryHeaders", self.url);
        return std.unicode.wtf16LeToWtf8Alloc(arena, wide[0 .. size / 2]) catch |e| oom(e);
    }

    /// Null if the response doesn't say, like one that's sent in chunks.
    fn contentLength(self: *const Response) ?u64 {
        var len: u64 = 0;
        var size: u32 = @sizeOf(u64);
        const content_length = win32.WINHTTP_QUERY_CONTENT_LENGTH | win32.WINHTTP_QUERY_FLAG_NUMBER64;
        if (self.winhttp.WinHttpQueryHeaders(self.request, content_length, null, &len, &size, null) == 0) {
            switch (@backingInt(std.os.windows.teb().LastErrorValue)) {
                win32.ERROR_WINHTTP_HEADER_NOT_FOUND => return null,
                else => fail("WinHttpQueryHeaders", self.url),
            }
        }
        return len;
    }

    /// Reads the body, returning 0 at the end. WinHTTP checks the length of
    /// the body against its Content-Length, failing here if it was cut short.
    pub fn read(self: *const Response, buf: []u8) usize {
        var n: u32 = 0;
        const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        if (self.winhttp.WinHttpReadData(self.request, buf.ptr, len, &n) == 0) fail("WinHttpReadData", self.url);
        return n;
    }

    pub fn close(self: *const Response) void {
        if (self.winhttp.WinHttpCloseHandle(self.request) == 0) fail("WinHttpCloseHandle", self.url);
        if (self.winhttp.WinHttpCloseHandle(self.connection) == 0) fail("WinHttpCloseHandle", self.url);
        if (self.winhttp.WinHttpCloseHandle(self.session) == 0) fail("WinHttpCloseHandle", self.url);
    }
};

/// One allocation of the right size when the response says how long it is.
pub fn readBody(response: *const Response, arena: std.mem.Allocator) []const u8 {
    if (response.contentLength()) |content_length| {
        const len = std.math.cast(usize, content_length) orelse
            main.errExit("{s}: its Content-Length of {d} is too big to hold in memory", .{ response.url, content_length });
        const body = arena.alloc(u8, len) catch |e| oom(e);
        var filled: usize = 0;
        while (filled < len) {
            const n = response.read(body[filled..]);
            if (n == 0) main.errExit("{s}: the body ended after {d} of {d} bytes", .{ response.url, filled, len });
            filled += n;
        }
        return body;
    }
    var body: std.ArrayList(u8) = .empty;
    while (true) {
        body.ensureUnusedCapacity(arena, 64 * 1024) catch |e| oom(e);
        const n = response.read(body.unusedCapacitySlice());
        if (n == 0) return body.toOwnedSlice(arena) catch |e| oom(e);
        body.items.len += n;
    }
}

fn toWide(arena: std.mem.Allocator, s: []const u8, url: []const u8) [:0]const u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, s) catch |e| switch (e) {
        error.OutOfMemory => |oom_err| oom(oom_err),
        error.InvalidWtf8 => main.errExit("invalid url: {s}", .{url}),
    };
}

fn fail(function: []const u8, url: []const u8) noreturn {
    const code: u32 = @backingInt(std.os.windows.teb().LastErrorValue);
    const meaning: []const u8 = switch (code) {
        12002 => " (timed out)",
        12007 => " (can't resolve the host name)",
        12029 => " (can't connect)",
        12030 => " (connection lost)",
        12175 => " (TLS or certificate failure)",
        else => "",
    };
    main.errExit("{s} failed for {s}: error {d}{s}", .{ function, url, code, meaning });
}

fn oom(err: error{OutOfMemory}) noreturn {
    main.errExit("{t}", .{err});
}

const std = @import("std");
const win32 = @import("win32").everything;
const Error = @import("Error.zig");
const main = @import("main.zig");
