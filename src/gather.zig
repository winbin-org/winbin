//! Running a manifest's `let` lines, the only part that makes requests other than its
//! download. What they come to is held by a `Gather`, and what's left of a manifest
//! reads it from there.

pub const Resolved = struct {
    url: []const u8,
    hash: ?[]const u8,
    extract: bool,

    pub fn deinit(self: Resolved, arena: std.mem.Allocator) void {
        arena.free(self.url);
        if (self.hash) |hash| arena.free(hash);
    }
};

/// A response a manifest can read from any number of times, so a host is only asked
/// once.
const Fetched = struct {
    variable: []const u8,
    url: []const u8,
    body: []const u8,
};

const List = struct { variable: []const u8, keys: manifest.Value.Keys };

/// `name` is the caller's to free.
pub const Install = struct {
    kind: enum { exe, exelink, dir },
    name: []const u8,
    line: u32,
};

pub const Gather = struct {
    package: []const u8,
    arena: std.mem.Allocator,
    vars: manifest.Vars = .{},
    fetched: [manifest.max_vars]Fetched = undefined,
    fetched_len: usize = 0,
    lists: [manifest.max_vars]List = undefined,
    lists_len: usize = 0,

    pub fn init(package: []const u8, arena: std.mem.Allocator) Gather {
        return .{ .package = package, .arena = arena };
    }

    pub fn deinit(self: *const Gather) void {
        for (self.vars.values[0..self.vars.len]) |value| self.arena.free(value);
        for (self.fetched[0..self.fetched_len]) |fetched| {
            self.arena.free(fetched.url);
            self.arena.free(fetched.body);
        }
    }

    pub fn resolve(self: *Gather, text: []const u8) Resolved {
        var download_url: ?[]const u8 = null;
        var hash: ?[]const u8 = null;
        var extract = false;
        var it = manifest.statements(text);
        while (it.next()) |numbered| {
            const line = numbered.number;
            switch (numbered.statement) {
                .let => |let| self.runLet(line, let.name, let.value),
                .download => |url| download_url = self.evalUrl(line, url),
                .verify => |expected| {
                    const value = self.eval(expected);
                    if (!manifest.isHash(value))
                        main.fatal("{s}, line {d}: '{s}' isn't sha256: and 64 hex digits", .{ self.package, line, value });
                    hash = value;
                },
                .extract => extract = true,
                else => {},
            }
        }
        return .{ .url = download_url.?, .hash = hash, .extract = extract };
    }

    /// Allocated, for the caller to free.
    pub fn eval(self: *const Gather, expr: manifest.Expr) []const u8 {
        return manifest.eval(expr, &self.vars, self.arena) catch |e| main.oom(e);
    }

    fn runLet(self: *Gather, line: u32, name: []const u8, value: manifest.Value) void {
        const result = switch (value) {
            .map_arch => |args| self.dupe(manifest.mapArch(args, host_arch) orelse
                main.fatal("package '{s}' isn't available for {s}", .{ self.package, host_arch })),
            .fetch => |url| return self.fetch(line, name, url),
            .json_keys => |keys| {
                self.lists[self.lists_len] = .{ .variable = name, .keys = keys };
                self.lists_len += 1;
                return;
            },
            .fetch_redirect => |url| self.fetchRedirect(line, url),
            .match_text => |read| self.matchText(read),
            .json_value => |read| self.jsonValue(line, read),
            .newest => |source| self.newestKey(line, source),
            .expr => |expr| self.eval(expr),
        };
        self.vars.set(name, result);
    }

    fn dupe(self: *const Gather, s: []const u8) []const u8 {
        return self.arena.dupe(u8, s) catch |e| main.oom(e);
    }

    fn findFetched(self: *const Gather, variable: []const u8) ?*const Fetched {
        for (self.fetched[0..self.fetched_len]) |*f| if (std.mem.eql(u8, f.variable, variable)) return f;
        return null;
    }

    /// Validation requires it to be set by here.
    fn getFetched(self: *const Gather, variable: []const u8) *const Fetched {
        return self.findFetched(variable).?;
    }

    fn fetch(self: *Gather, line: u32, variable: []const u8, expr: manifest.Expr) void {
        const url = self.evalUrl(line, expr);
        const response: http.Response = .get(self.arena, url, .stop);
        defer response.close();
        switch (response.status) {
            200 => {},
            300...399 => main.fatal("{s}: expected a body from {s}, it redirected to {s}", .{
                self.package,
                url,
                response.location(self.arena) orelse "somewhere it didn't say",
            }),
            else => main.fatal("{s}: GET {s}: HTTP {d}{f}", .{ self.package, url, response.status, errorText(&response) }),
        }
        self.fetched[self.fetched_len] = .{ .variable = variable, .url = url, .body = http.readBody(&response, self.arena) };
        self.fetched_len += 1;
    }

    fn fetchRedirect(self: *const Gather, line: u32, expr: manifest.Expr) []const u8 {
        const url = self.evalUrl(line, expr);
        defer self.arena.free(url);
        const response: http.Response = .get(self.arena, url, .stop);
        defer response.close();
        switch (response.status) {
            300...399 => {},
            200...299 => main.fatal("{s}: expected a redirect from {s}, it returned a body", .{ self.package, url }),
            else => main.fatal("{s}: GET {s}: HTTP {d}{f}", .{ self.package, url, response.status, errorText(&response) }),
        }
        return response.location(self.arena) orelse main.fatal("{s}: expected a redirect from {s}", .{ self.package, url });
    }

    fn jsonFatal(self: *const Gather, line: u32, url: []const u8, path: []const u8, diag: *const json.Diagnostic, err: json.Error) noreturn {
        switch (err) {
            error.Invalid => {
                const expanded = manifest.expand(path, &self.vars, self.arena) catch path;
                main.fatal("{s}, line {d}: {s}, part {d} of {s}: {s}", .{ self.package, line, url, diag.part, expanded, diag.message });
            },
            error.SyntaxError, error.UnexpectedEndOfInput => main.fatal("{s}, line {d}: {s} isn't valid JSON", .{ self.package, line, url }),
            // it's the scanner's small fixed stack that runs out, far more likely than memory
            error.OutOfMemory, error.ValueTooLong => main.fatal("{s}, line {d}: {s} is nested too deeply to read, or there isn't enough memory", .{ self.package, line, url }),
        }
    }

    fn jsonValue(self: *const Gather, line: u32, read: manifest.Value.Read) []const u8 {
        const response = self.getFetched(read.source);
        const segments = manifest.expandPath(read.arg, &self.vars, self.arena) catch |e| main.oom(e);
        defer manifest.freePath(segments, self.arena);
        var diag: json.Diagnostic = .{};
        const value = json.readString(response.body, segments, self.arena, &diag) catch |e|
            self.jsonFatal(line, response.url, read.arg, &diag, e);
        return value orelse {
            const expanded = manifest.expand(read.arg, &self.vars, self.arena) catch read.arg;
            main.fatal("{s}, line {d}: {s} has nothing at {s}", .{ self.package, line, response.url, expanded });
        };
    }

    /// Picks from a list, and only the newest gets its other values worked out: bad
    /// data in an older one can't block installing this one.
    fn newestKey(self: *const Gather, line: u32, source: []const u8) []const u8 {
        const keys_def = for (self.lists[0..self.lists_len]) |list| {
            if (std.mem.eql(u8, list.variable, source)) break list.keys;
        } else unreachable;
        const response = self.getFetched(keys_def.source);
        const segments = manifest.expandPath(keys_def.path, &self.vars, self.arena) catch |e| main.oom(e);
        defer manifest.freePath(segments, self.arena);
        var diag: json.Diagnostic = .{};
        var keys: json.KeyIterator = undefined;
        keys.init(response.body, segments, self.arena, &diag) catch |e| self.jsonFatal(line, response.url, keys_def.path, &diag, e);

        var newest: ?[]const u8 = null;
        while (keys.next(&diag) catch |e| self.jsonFatal(line, response.url, keys_def.path, &diag, e)) |key| {
            if (keys_def.except) |except| if (std.mem.eql(u8, key, except)) {
                self.arena.free(key);
                continue;
            };
            if (!manifest.isVersion(key))
                main.fatal("{s}, line {d}: @compare_version can't read the key '{s}' in {s}, it isn't dot separated numbers", .{ self.package, line, key, response.url });
            const replace = if (newest) |n| switch (manifest.compareVersions(key, n)) {
                .gt => true,
                .lt => false,
                .eq => main.fatal("{s}, line {d}: '{s}' and '{s}' in {s} are the same version, so neither is newer", .{ self.package, line, key, n, response.url }),
            } else true;
            if (replace) {
                if (newest) |n| self.arena.free(n);
                newest = key;
            } else self.arena.free(key);
        }
        return newest orelse main.fatal("{s}, line {d}: {s} has no keys for {s}", .{ self.package, line, response.url, keys_def.path });
    }

    fn matchText(self: *const Gather, read: manifest.Value.Read) []const u8 {
        const response = self.findFetched(read.source);
        const text = if (response) |r| r.body else self.vars.get(read.source).?;
        // the URL says where to look, a value is short enough to show
        const where = if (response) |r| r.url else text;
        return switch (manifest.matchOne(read.arg, text, &self.vars)) {
            .one => |capture| self.dupe(capture),
            .none => main.fatal("{s}: nothing in '{s}' matches \"{s}\"", .{ self.package, where, read.arg }),
            .several => |captures| main.fatal("{s}: \"{s}\" has to match exactly once in '{s}', but it matches more than once, capturing '{s}' and '{s}'", .{
                self.package,
                read.arg,
                where,
                captures[0],
                captures[1],
            }),
        };
    }

    fn evalUrl(self: *const Gather, line: u32, expr: manifest.Expr) []const u8 {
        const url = self.eval(expr);
        if (manifest.urlScheme(url)) |scheme| if (!std.mem.eql(u8, scheme, "https") and !std.mem.eql(u8, scheme, "http"))
            main.fatal("{s}, line {d}: unsupported URL scheme '{s}' in '{s}', expected https:// or http://", .{ self.package, line, scheme, url });
        if (!manifest.isUrl(url)) main.fatal("{s}, line {d}: '{s}' isn't an https://HOST/PATH URL", .{ self.package, line, url });
        return url;
    }

    /// A name that goes next to winbin.exe. It can come from the network, so it's
    /// checked again once it's known.
    pub fn evalExeName(self: *const Gather, line: u32, expr: manifest.Expr) []const u8 {
        const dest = self.eval(expr);
        if (!manifest.isExeName(dest))
            main.fatal("{s}, line {d}: '{s}' isn't a plain NAME.exe that can be installed", .{ self.package, line, dest });
        return dest;
    }

    pub fn evalDirName(self: *const Gather, line: u32, expr: manifest.Expr) []const u8 {
        const dest = self.eval(expr);
        if (!manifest.isDirName(dest))
            main.fatal("{s}, line {d}: '{s}' isn't a plain name that can be installed as a directory", .{ self.package, line, dest });
        return dest;
    }

    pub fn evalArchivePath(self: *const Gather, line: u32, expr: manifest.Expr) []const u8 {
        const path = self.eval(expr);
        if (!manifest.isSafePath(path))
            main.fatal("{s}, line {d}: '{s}' isn't a relative path that stays in the archive", .{ self.package, line, path });
        return path;
    }

    pub fn installs(self: *const Gather, text: []const u8) InstallIterator {
        return .{ .gather = self, .it = manifest.statements(text) };
    }
};

pub const InstallIterator = struct {
    gather: *const Gather,
    it: manifest.StatementIterator,

    pub fn next(self: *InstallIterator) ?Install {
        while (self.it.next()) |numbered| {
            const line = numbered.number;
            switch (numbered.statement) {
                .install_exe => |install| return .{ .kind = .exe, .line = line, .name = self.gather.evalExeName(line, install.dest) },
                .install_exelink => |link| return .{ .kind = .exelink, .line = line, .name = self.gather.evalExeName(line, link.dest) },
                .install_dir => |install| return .{ .kind = .dir, .line = line, .name = self.gather.evalDirName(line, install.dest) },
                else => {},
            }
        }
        return null;
    }
};

const host_arch = switch (@import("builtin").cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .x86 => "x86",
    else => @compileError("unsupported arch"),
};

/// ": WHAT THE SERVER SAID" for a failed request, which is often the only thing that
/// explains it, like a rate limit. It's from the network, so it's cut at anything that
/// can't be printed.
fn errorText(response: *const http.Response) ErrorText {
    var text: ErrorText = .{ .buf = undefined, .len = 0 };
    const n = response.read(&text.buf);
    text.len = for (text.buf[0..n], 0..) |c, i| {
        if (c < ' ' or c >= 0x7f) break i;
    } else n;
    return text;
}

const ErrorText = struct {
    buf: [512]u8,
    len: usize,

    pub fn format(self: ErrorText, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.len != 0) try w.print(": {s}", .{self.buf[0..self.len]});
    }
};

const std = @import("std");
const main = @import("main.zig");
const json = @import("json.zig");
const manifest = @import("manifest.zig");
const http = @import("http.zig");
