//! HTTP GET through WinHTTP. It's part of Windows, so the binary carries no
//! TLS implementation or root certificates, and it gets the system's proxy
//! settings and certificate store. When followed, redirects can't go from HTTPS
//! to HTTP. A failure here ends the program, naming the URL.

/// `url` is already validated: http(s)://HOST[:PORT]/PATH
pub const Response = struct {
    session: Handle,
    connection: Handle,
    request: Handle,
    url: []const u8,
    status: u32,

    pub const Redirects = enum { follow, stop };

    pub fn get(arena: std.mem.Allocator, url: []const u8, redirects: Redirects) Response {
        const secure = std.mem.startsWith(u8, url, "https://");
        const after_scheme = url[if (secure) "https://".len else "http://".len..];
        const slash = std.mem.findScalar(u8, after_scheme, '/').?;
        const authority = after_scheme[0..slash];
        const colon = std.mem.findScalar(u8, authority, ':');
        const port: u16 = if (colon) |c|
            std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch main.fatal("invalid port in url: {s}", .{url})
        else if (secure) 443 else 80;

        const host = toWide(arena, authority[0 .. colon orelse authority.len], url);
        defer arena.free(host);
        const path = toWide(arena, after_scheme[slash..], url);
        defer arena.free(path);

        const user_agent = std.unicode.wtf8ToWtf16LeStringLiteral("winbin");
        const session = WinHttpOpen(user_agent, access_type_automatic_proxy, null, null, 0) orelse
            fail("WinHttpOpen", url);
        const connection = WinHttpConnect(session, host, port, 0) orelse
            fail("WinHttpConnect", url);
        const request = WinHttpOpenRequest(
            connection,
            std.unicode.wtf8ToWtf16LeStringLiteral("GET"),
            path,
            null,
            null,
            null,
            if (secure) flag_secure else 0,
        ) orelse fail("WinHttpOpenRequest", url);
        if (redirects == .stop) {
            const never: u32 = redirect_policy_never;
            if (WinHttpSetOption(request, option_redirect_policy, &never, @sizeOf(u32)) == 0)
                fail("WinHttpSetOption", url);
        }
        if (WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) fail("WinHttpSendRequest", url);
        if (WinHttpReceiveResponse(request, null) == 0) fail("WinHttpReceiveResponse", url);

        var status: u32 = 0;
        var status_size: u32 = @sizeOf(u32);
        if (WinHttpQueryHeaders(request, query_status_code | query_flag_number, null, &status, &status_size, null) == 0)
            fail("WinHttpQueryHeaders", url);
        return .{ .session = session, .connection = connection, .request = request, .url = url, .status = status };
    }

    pub fn location(self: *const Response, arena: std.mem.Allocator) ?[]const u8 {
        // asking with no buffer says how big one has to be
        var size: u32 = 0;
        if (WinHttpQueryHeaders(self.request, query_location, null, null, &size, null) == 0) {
            switch (@backingInt(std.os.windows.teb().LastErrorValue)) {
                error_header_not_found => return null,
                error_insufficient_buffer => {},
                else => fail("WinHttpQueryHeaders", self.url),
            }
        }
        const wide = arena.alloc(u16, size / 2) catch |e| main.oom(e);
        defer arena.free(wide);
        if (WinHttpQueryHeaders(self.request, query_location, null, wide.ptr, &size, null) == 0)
            fail("WinHttpQueryHeaders", self.url);
        return std.unicode.wtf16LeToWtf8Alloc(arena, wide[0 .. size / 2]) catch |e| main.oom(e);
    }

    /// Reads the body, returning 0 at the end. WinHTTP checks the length of
    /// the body against its Content-Length, failing here if it was cut short.
    pub fn read(self: *const Response, buf: []u8) usize {
        var n: u32 = 0;
        if (WinHttpReadData(self.request, buf.ptr, @intCast(buf.len), &n) == 0) fail("WinHttpReadData", self.url);
        return n;
    }

    pub fn close(self: *const Response) void {
        _ = WinHttpCloseHandle(self.request);
        _ = WinHttpCloseHandle(self.connection);
        _ = WinHttpCloseHandle(self.session);
    }
};

pub fn readBody(response: *const Response, arena: std.mem.Allocator) []const u8 {
    var body: std.ArrayList(u8) = .empty;
    while (true) {
        body.ensureUnusedCapacity(arena, 64 * 1024) catch |e| main.oom(e);
        const unused = body.unusedCapacitySlice();
        const n = response.read(unused[0..@min(unused.len, std.math.maxInt(u32))]);
        if (n == 0) return body.toOwnedSlice(arena) catch |e| main.oom(e);
        body.items.len += n;
    }
}

fn toWide(arena: std.mem.Allocator, s: []const u8, url: []const u8) [:0]const u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, s) catch |e| switch (e) {
        error.OutOfMemory => |oom_err| main.oom(oom_err),
        error.InvalidWtf8 => main.fatal("invalid url: {s}", .{url}),
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
    main.fatal("{s} failed for {s}: error {d}{s}", .{ function, url, code, meaning });
}

const Handle = *opaque {};

const access_type_automatic_proxy = 4;
const flag_secure = 0x00800000;
const option_redirect_policy = 88;
const redirect_policy_never = 0;
const error_header_not_found = 12150;
const error_insufficient_buffer = 122;
const query_location = 33;
const query_status_code = 19;
const query_flag_number = 0x20000000;

extern "winhttp" fn WinHttpOpen(
    agent: [*:0]const u16,
    access_type: u32,
    proxy: ?[*:0]const u16,
    bypass: ?[*:0]const u16,
    flags: u32,
) callconv(.winapi) ?Handle;
extern "winhttp" fn WinHttpConnect(
    session: Handle,
    server: [*:0]const u16,
    port: u16,
    reserved: u32,
) callconv(.winapi) ?Handle;
extern "winhttp" fn WinHttpOpenRequest(
    connection: Handle,
    verb: [*:0]const u16,
    object: [*:0]const u16,
    version: ?[*:0]const u16,
    referrer: ?[*:0]const u16,
    accept_types: ?[*]const ?[*:0]const u16,
    flags: u32,
) callconv(.winapi) ?Handle;
extern "winhttp" fn WinHttpSetOption(
    handle: Handle,
    option: u32,
    buffer: *const anyopaque,
    len: u32,
) callconv(.winapi) i32;
extern "winhttp" fn WinHttpSendRequest(
    request: Handle,
    headers: ?[*]const u16,
    headers_len: u32,
    optional: ?*anyopaque,
    optional_len: u32,
    total_len: u32,
    context: usize,
) callconv(.winapi) i32;
extern "winhttp" fn WinHttpReceiveResponse(request: Handle, reserved: ?*anyopaque) callconv(.winapi) i32;
extern "winhttp" fn WinHttpQueryHeaders(
    request: Handle,
    info_level: u32,
    name: ?[*:0]const u16,
    buffer: ?*anyopaque,
    buffer_len: *u32,
    index: ?*u32,
) callconv(.winapi) i32;
extern "winhttp" fn WinHttpReadData(request: Handle, buffer: [*]u8, len: u32, read: *u32) callconv(.winapi) i32;
extern "winhttp" fn WinHttpCloseHandle(handle: Handle) callconv(.winapi) i32;

const std = @import("std");
const main = @import("main.zig");
