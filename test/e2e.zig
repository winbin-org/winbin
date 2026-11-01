//! `zig build test`: the exe for this machine's arch, run for real in a temporary
//! directory, against a server in this process serving generated zips. Nothing here
//! touches the internet, or anywhere a real winbin is installed.

/// Serves files from `site_root`, one request at a time, for as long as the tests run.
/// `NAME.redirect` redirects to what's in that file instead.
const Site = struct {
    var port: u16 = 0;
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var root_len: std.atomic.Value(usize) = .init(0);

    fn ensureStarted() !void {
        if (port != 0) return;
        var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try address.listen(testing.io, .{ .reuse_address = true });
        port = server.socket.address.getPort();
        const thread = try std.Thread.spawn(.{}, serve, .{server});
        thread.detach();
    }

    fn setRoot(path: []const u8) void {
        @memcpy(root_buf[0..path.len], path);
        root_len.store(path.len, .release);
    }

    fn serve(listener: std.Io.net.Server) void {
        var server = listener;
        while (true) {
            const stream = server.accept(testing.io) catch continue;
            defer stream.close(testing.io);
            handle(stream) catch {};
        }
    }

    fn handle(stream: std.Io.net.Stream) !void {
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(testing.io, &read_buf);
        const request_line = try reader.interface.takeDelimiterInclusive('\n');
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        _ = parts.next();
        var url_path_buf: [1024]u8 = undefined;
        const url_path_raw = parts.next() orelse return error.BadRequest;
        const url_path = url_path_buf[0..url_path_raw.len];
        @memcpy(url_path, url_path_raw);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
        }

        var write_buf: [64 * 1024]u8 = undefined;
        var writer = stream.writer(testing.io, &write_buf);
        const w = &writer.interface;
        const root = std.Io.Dir.cwd().openDir(testing.io, root_buf[0..root_len.load(.acquire)], .{}) catch return error.NoRoot;
        defer root.close(testing.io);
        const sub_path = url_path[1..];

        var redirect_name_buf: [1100]u8 = undefined;
        const redirect_name = try std.fmt.bufPrint(&redirect_name_buf, "{s}.redirect", .{sub_path});
        var target_buf: [32 * 1024]u8 = undefined;
        if (root.readFile(testing.io, redirect_name, &target_buf)) |target| {
            try w.print("HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{target});
            return w.flush();
        } else |_| {}

        const file = root.openFile(testing.io, sub_path, .{}) catch {
            const message = "{\"message\":\"Not Found\"}";
            try w.print("HTTP/1.1 404 Not Found\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ message.len, message });
            return w.flush();
        };
        defer file.close(testing.io);
        const size = (try file.stat(testing.io)).size;
        try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{size});
        var file_buf: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(testing.io, &file_buf);
        _ = try w.sendFileAll(&file_reader, .unlimited);
        try w.flush();
    }
};

const Entry = struct { name: []const u8, data: []const u8 = "" };

/// A zip with nothing compressed, and exactly the names asked for, however bad.
fn makeZip(a: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var central: std.Io.Writer.Allocating = .init(a);
    const c = &central.writer;
    for (entries) |entry| {
        const offset: u32 = @intCast(out.written().len);
        const crc = std.hash.Crc32.hash(entry.data);
        const size: u32 = @intCast(entry.data.len);
        const name_len: u16 = @intCast(entry.name.len);
        try w.writeAll("PK\x03\x04");
        for ([_]u16{ 20, 0, 0, 0, 0x21 }) |v| try w.writeInt(u16, v, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u16, name_len, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(entry.name);
        try w.writeAll(entry.data);

        try c.writeAll("PK\x01\x02");
        for ([_]u16{ 20, 20, 0, 0, 0, 0x21 }) |v| try c.writeInt(u16, v, .little);
        try c.writeInt(u32, crc, .little);
        try c.writeInt(u32, size, .little);
        try c.writeInt(u32, size, .little);
        try c.writeInt(u16, name_len, .little);
        for ([_]u16{ 0, 0, 0, 0 }) |v| try c.writeInt(u16, v, .little);
        try c.writeInt(u32, 0, .little);
        try c.writeInt(u32, offset, .little);
        try c.writeAll(entry.name);
    }
    const central_start: u32 = @intCast(out.written().len);
    try w.writeAll(central.written());
    try w.writeAll("PK\x05\x06");
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u32, @intCast(central.written().len), .little);
    try w.writeInt(u32, central_start, .little);
    try w.writeInt(u16, 0, .little);
    return out.written();
}

const Output = struct {
    code: ?u8,
    stdout: []const u8,
    stderr: []const u8,

    fn expectOk(self: Output) !void {
        if (self.code != 0) {
            std.debug.print("expected success, got {?d}\nstdout: {s}\nstderr: {s}\n", .{ self.code, self.stdout, self.stderr });
            return error.TestUnexpectedResult;
        }
    }

    fn expectError(self: Output, expected: []const u8) !void {
        if (self.code != 1 or std.mem.find(u8, self.stderr, expected) == null) {
            std.debug.print("expected failing with '{s}', got {?d}\nstdout: {s}\nstderr: {s}\n", .{ expected, self.code, self.stdout, self.stderr });
            return error.TestUnexpectedResult;
        }
    }

    fn expectOut(self: Output, expected: []const u8) !void {
        try self.expectOk();
        if (std.mem.find(u8, self.stdout, expected) == null) {
            std.debug.print("expected output with '{s}', got:\n{s}\nstderr: {s}\n", .{ expected, self.stdout, self.stderr });
            return error.TestUnexpectedResult;
        }
    }
};

/// A winbin in a directory of its own.
const Env = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    /// What's next to winbin.exe.
    bin: std.Io.Dir,
    bin_path: []const u8,
    exe: []const u8,
    manifests_path: []const u8,
    site: std.Io.Dir,

    fn init() !*Env {
        try Site.ensureStarted();
        const self = try testing.allocator.create(Env);
        self.arena = .init(testing.allocator);
        self.tmp = testing.tmpDir(.{});
        const arena = self.arena.allocator();
        try self.tmp.dir.createDirPath(testing.io, "bin");
        try self.tmp.dir.createDirPath(testing.io, "m");
        try self.tmp.dir.createDirPath(testing.io, "site");
        self.bin = try self.tmp.dir.openDir(testing.io, "bin", .{ .iterate = true });
        self.site = try self.tmp.dir.openDir(testing.io, "site", .{});
        self.bin_path = try self.tmp.dir.realPathFileAlloc(testing.io, "bin", arena);
        self.manifests_path = try self.tmp.dir.realPathFileAlloc(testing.io, "m", arena);
        self.exe = try std.fs.path.join(arena, &.{ self.bin_path, "winbin.exe" });
        try std.Io.Dir.cwd().copyFile(paths.winbin, self.bin, "winbin.exe", testing.io, .{});
        Site.setRoot(try self.tmp.dir.realPathFileAlloc(testing.io, "site", arena));
        return self;
    }

    fn deinit(self: *Env) void {
        self.bin.close(testing.io);
        self.site.close(testing.io);
        self.tmp.cleanup();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    fn a(self: *Env) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn url(self: *Env, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a(), "http://127.0.0.1:{d}/{s}", .{ Site.port, path });
    }

    fn serveZip(self: *Env, name: []const u8, entries: []const Entry) !void {
        try self.site.writeFile(testing.io, .{ .sub_path = name, .data = try makeZip(self.a(), entries) });
    }

    /// A manifest with `{site}` standing for the server. Returns what to install it from.
    fn manifest(self: *Env, name: []const u8, text: []const u8) ![]const u8 {
        return self.manifestIn(self.manifests_path, name, text);
    }

    fn manifestIn(self: *Env, dir: []const u8, name: []const u8, text: []const u8) ![]const u8 {
        const base = try std.fmt.allocPrint(self.a(), "http://127.0.0.1:{d}", .{Site.port});
        const replaced = try std.mem.replaceOwned(u8, self.a(), text, "{site}", base);
        const path = try std.fs.path.join(self.a(), &.{ dir, name });
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = replaced });
        return self.fileUrl(path);
    }

    fn fileUrl(self: *Env, path: []const u8) ![]const u8 {
        const slashes = try std.mem.replaceOwned(u8, self.a(), path, "\\", "/");
        const encoded = try std.mem.replaceOwned(u8, self.a(), slashes, " ", "%20");
        return std.mem.concat(self.a(), u8, &.{ "file:///", encoded });
    }

    fn urlOf(self: *Env, name: []const u8) ![]const u8 {
        return self.fileUrl(try std.fs.path.join(self.a(), &.{ self.manifests_path, name }));
    }

    fn recordOf(self: *Env, name: []const u8) !?[]const u8 {
        const dir = self.bin.openDir(testing.io, ".winbin\\installed", .{ .iterate = true }) catch return null;
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.name.len > name.len and std.mem.startsWith(u8, entry.name, name) and entry.name[name.len] == '-')
                return try std.fmt.allocPrint(self.a(), ".winbin\\installed\\{s}", .{entry.name});
        }
        return null;
    }

    fn run(self: *Env, args: []const []const u8) !Output {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.a(), self.exe);
        try argv.appendSlice(self.a(), args);
        const result = try std.process.run(self.a(), testing.io, .{ .argv = argv.items, .create_no_window = false });
        return .{
            .code = switch (result.term) {
                .exited => |code| code,
                else => null,
            },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }

    fn install(self: *Env, from: []const u8) !Output {
        return self.run(&.{ "install", from });
    }

    fn update(self: *Env, from: []const u8) !Output {
        return self.run(&.{ "update", from });
    }

    fn uninstall(self: *Env, name: []const u8) !Output {
        return self.run(&.{ "uninstall", try self.urlOf(name) });
    }

    fn exists(self: *Env, path: []const u8) bool {
        self.bin.access(testing.io, path, .{}) catch return false;
        return true;
    }

    fn read(self: *Env, path: []const u8) ![]const u8 {
        return self.bin.readFileAlloc(testing.io, path, self.a(), .limited(16 * 1024 * 1024));
    }

    fn write(self: *Env, path: []const u8, data: []const u8) !void {
        try self.bin.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    /// What's next to winbin.exe, sorted and joined by spaces.
    fn files(self: *Env) ![]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var it = self.bin.iterate();
        while (try it.next(testing.io)) |entry| {
            if (std.mem.eql(u8, entry.name, "winbin.exe") or std.mem.eql(u8, entry.name, ".winbin")) continue;
            try names.append(self.a(), try self.a().dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.lessThan(u8, l, r);
            }
        }.lessThan);
        return std.mem.join(self.a(), " ", names.items);
    }

    fn expectFiles(self: *Env, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, try self.files());
    }

    /// Nothing left mid-change.
    fn expectSettled(self: *Env) !void {
        for ([_][]const u8{ ".winbin\\journal", ".winbin\\publish", ".winbin\\delete", ".winbin\\deferred-cleanup" }) |path| {
            if (self.exists(path)) {
                std.debug.print("'{s}' was left behind\n", .{path});
                return error.TestUnexpectedResult;
            }
        }
    }

    fn tmpCount(self: *Env) !usize {
        const tmp = self.bin.openDir(testing.io, ".winbin\\tmp", .{ .iterate = true }) catch return 0;
        defer tmp.close(testing.io);
        var count: usize = 0;
        var it = tmp.iterate();
        while (try it.next(testing.io)) |_| count += 1;
        return count;
    }

    /// A real exe to run, the one thing here that isn't generated.
    fn realExe(self: *Env) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, "C:\\Windows\\System32\\PING.EXE", self.a(), .limited(16 * 1024 * 1024));
    }

    fn spawn(self: *Env, args: []const []const u8) !std.process.Child {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.a(), self.exe);
        try argv.appendSlice(self.a(), args);
        return std.process.spawn(testing.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore, .create_no_window = false });
    }
};

const flat_entries = [_]Entry{ .{ .name = "tool.exe", .data = "the exe" }, .{ .name = "data.txt", .data = "data" } };

fn serveTool(env: *Env, version: []const u8) !void {
    const a = env.a();
    try env.serveZip(try std.fmt.allocPrint(a, "tool-{s}.zip", .{version}), &.{
        .{ .name = try std.fmt.allocPrint(a, "tool-{s}/bin/tool.exe", .{version}), .data = "the exe" },
        .{ .name = try std.fmt.allocPrint(a, "tool-{s}/share/version.txt", .{version}), .data = version },
        .{ .name = try std.fmt.allocPrint(a, "tool-{s}/share/empty/", .{version}) },
    });
}

fn toolManifest(env: *Env, version: []const u8) ![]const u8 {
    return env.manifest("tool", try std.fmt.allocPrint(env.a(),
        \\let v = "{s}"
        \\
        \\download "{{site}}/tool-{{v}}.zip"
        \\extract
        \\install dir "tool-{{v}}"
        \\install exelink "tool.exe" -> "tool-{{v}}/bin/tool.exe"
        \\
    , .{version}));
}

test "--help says where packages go, and a bad command fails" {
    const env = try Env.init();
    defer env.deinit();
    try (try env.run(&.{"--help"})).expectOut(env.bin_path);
    try (try env.run(&.{"nope"})).expectError("unknown command 'nope'");
    try (try env.run(&.{"uninstall"})).expectError("expected 'uninstall NAME|URL...'");
    try (try env.run(&.{ "uninstall", "a", "b" })).expectError("'a' isn't installed");
    try (try env.run(&.{ "update", "a", "b" })).expectError("'a' isn't installed");
    try (try env.run(&.{"install"})).expectError("expected 'install NAME|URL...'");
    try (try env.run(&.{"update"})).expectError("expected 'update NAME|URL...'");
    try (try env.run(&.{ "update", "--nope" })).expectError("invalid package name '--nope'");
    try (try env.run(&.{ "available", "a" })).expectError("'available' takes no arguments");
    try (try env.run(&.{ "installed", "a" })).expectError("'installed' takes no arguments");
    try (try env.run(&.{ "install", "ftp://e.com/a" })).expectError("unsupported URL scheme 'ftp'");
    try (try env.run(&.{ "uninstall", "nope" })).expectError("'nope' isn't installed");
    try (try env.run(&.{ "update", "nope" })).expectError("'nope' isn't installed");
    try (try env.run(&.{ "uninstall", "https://e.com/nope" })).expectError("'https://e.com/nope' isn't installed");
    try (try env.run(&.{"installed"})).expectOk();
}

test "a package is a name or a URL, and a file's URL is its absolute path" {
    const env = try Env.init();
    defer env.deinit();
    const no_path = "isn't a package name or a URL";
    for ([_][]const u8{ "install", "update", "uninstall" }) |command| {
        for ([_][]const u8{ "./foo", "../x", "pkgs/foo", "pkgs\\foo", "C:\\pkgs\\foo", "C:/pkgs/foo" }) |path| {
            try (try env.run(&.{ command, path })).expectError(no_path);
        }
        for ([_][]const u8{ "file://C:/foo", "file://host/foo", "file://foo" }) |url| {
            try (try env.run(&.{ command, url })).expectError("a file needs its absolute path");
        }
        try (try env.run(&.{ command, "Foo" })).expectError("invalid package name");
        try (try env.run(&.{ command, "file:///C:/pkgs/Foo" })).expectError("gives the package name 'Foo'");
        try (try env.run(&.{ command, "https://e.com/" })).expectError("gives the package name ''");
    }
    // the path is only read when there's a manifest to read from it
    for ([_][]const u8{ "file:///foo", "file:///C:/a/../foo", "file:///C:/a b/foo" }) |url| {
        try (try env.run(&.{ "install", url })).expectError("a file needs its absolute path");
    }
    const missing = try env.urlOf("missing");
    try (try env.install(missing)).expectError("read manifest");
}

test "a file's URL can have spaces in it, encoded" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.tmp.dir.createDirPath(testing.io, "with space");
    const dir = try env.tmp.dir.realPathFileAlloc(testing.io, "with space", env.a());
    const url = try env.manifestIn(dir, "spaced", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"tool.exe\"\n");
    try testing.expect(std.mem.find(u8, url, "with%20space/spaced") != null);
    try (try env.install(url)).expectOut("installed spaced");
    try (try env.run(&.{ "uninstall", url })).expectOut("uninstalled spaced");
}

test "a URL is the package: a name or another URL is a different one" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.tmp.dir.createDirPath(testing.io, "one");
    try env.tmp.dir.createDirPath(testing.io, "two");
    const one_dir = try env.tmp.dir.realPathFileAlloc(testing.io, "one", env.a());
    const two_dir = try env.tmp.dir.realPathFileAlloc(testing.io, "two", env.a());
    const one = try env.manifestIn(one_dir, "foo", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"one.exe\" from \"tool.exe\"\n");
    const two = try env.manifestIn(two_dir, "foo", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"two.exe\" from \"tool.exe\"\n");

    // the same last part, and they sit side by side
    try (try env.install(one)).expectOut("installed foo");
    try (try env.install(two)).expectOut("installed foo");
    try env.expectFiles("one.exe two.exe");
    const listed = try env.run(&.{"installed"});
    try listed.expectOut(one);
    try listed.expectOut(two);

    // only the exact URL means either of them
    try (try env.run(&.{ "uninstall", "foo" })).expectError("'foo' isn't installed");
    try (try env.run(&.{ "update", "foo" })).expectError("'foo' isn't installed");
    try env.expectFiles("one.exe two.exe");

    try (try env.update(one)).expectOut("already the latest version");
    try (try env.run(&.{ "uninstall", one })).expectOut("uninstalled foo");
    try env.expectFiles("two.exe");
    try (try env.run(&.{ "uninstall", one })).expectError("isn't installed");
    try (try env.run(&.{ "uninstall", two })).expectOut("uninstalled foo");
    try env.expectFiles("");
}

/// As if the registry's `seeded` had been installed: nothing here can reach the registry.
fn seedRegistryPackage(env: *Env) !void {
    const data = "the exe";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const exe_hex = std.fmt.bytesToHex(digest, .lower);
    std.crypto.hash.sha2.Sha256.hash(registry_seeded, &digest, .{});
    const url_hex = std.fmt.bytesToHex(digest[0..8].*, .lower);
    try env.bin.createDirPath(testing.io, ".winbin\\installed");
    try env.write("seeded.exe", data);
    try env.write(try std.fmt.allocPrint(env.a(), ".winbin\\installed\\seeded-{s}", .{&url_hex}), try std.fmt.allocPrint(env.a(),
        \\installed-url https://e.com/seeded.zip
        \\installed-hash sha256:{s}
        \\installed-exe seeded.exe sha256:{s}
        \\installed-from {s}
        \\the manifest
        \\
    , .{ &exe_hex, &exe_hex, registry_seeded }));
}

const registry_seeded = "https://winbin-org.github.io/pkg/seeded";

test "a package in the registry is only ever called by its name" {
    const env = try Env.init();
    defer env.deinit();

    const already = blk: {
        try seedRegistryPackage(env);
        break :blk try env.run(&.{ "install", "seeded" });
    };
    try already.expectOut("seeded is already installed");
    const listed = try env.run(&.{"installed"});
    try testing.expectEqualStrings("seeded\n", listed.stdout);

    // what an error says to uninstall has to be something uninstall takes
    try env.serveZip("flat.zip", &flat_entries);
    const refused = try env.install(try env.manifest("taker", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"seeded.exe\" from \"tool.exe\"\n"));
    try refused.expectError("it belongs to seeded, uninstall that first");

    try (try env.run(&.{ "uninstall", "seeded" })).expectOut("uninstalled seeded");
    try env.expectFiles("");
    try (try env.run(&.{ "uninstall", "seeded" })).expectError("'seeded' isn't installed");
    try (try env.run(&.{ "update", "seeded" })).expectError("'seeded' isn't installed");

    // a replaced exe
    try seedRegistryPackage(env);
    try env.write("seeded.exe", "replaced");
    const replaced_install = try env.run(&.{ "install", "seeded" });
    try replaced_install.expectError("isn't the file seeded installed");
    try replaced_install.expectError("'winbin install seeded' puts it back");
    try (try env.run(&.{ "uninstall", "seeded" })).expectError("isn't the file seeded installed");
    try testing.expectEqualStrings("replaced", try env.read("seeded.exe"));
    try env.bin.deleteFile(testing.io, "seeded.exe");

    // a bad record
    try seedRegistryPackage(env);
    const record_path = (try env.recordOf("seeded")).?;
    try env.write(record_path, "not a record");
    const bad = "the installed record of seeded is invalid";
    try (try env.run(&.{ "install", "seeded" })).expectError(bad);
    try (try env.run(&.{ "uninstall", "seeded" })).expectError(bad);
}

test "the case of a registry URL doesn't get it past being refused" {
    const env = try Env.init();
    defer env.deinit();
    try seedRegistryPackage(env);
    for ([_][]const u8{ "install", "update", "uninstall" }) |command| {
        for ([_][]const u8{
            "https://WINBIN-ORG.GITHUB.IO/PKG/seeded",
            "https://winbin-org.GITHUB.io/pkg/seeded",
            "https://Winbin-Org.github.IO/pkg/seeded",
            "https://winbin-org.github.io/Pkg/seeded",
            "http://WINBIN-ORG.github.io/pKg/seeded",
        }) |url| {
            try (try env.run(&.{ command, url })).expectError("is in the registry, use its name instead: seeded");
        }
        // names are lowercase, so this one can't be suggested as it's written
        try (try env.run(&.{ command, "https://winbin-org.github.io/pkg/SEEDED" })).expectError("is in the registry, use the package's name instead");
    }
    try testing.expect(env.exists("seeded.exe"));
    try testing.expectEqualStrings("seeded\n", (try env.run(&.{"installed"})).stdout);
}

test "a scheme has to be lowercase, so it can't make a second copy of a package" {
    const env = try Env.init();
    defer env.deinit();
    try seedRegistryPackage(env);
    const cases = [_]struct { url: []const u8, scheme: []const u8 }{
        .{ .url = "HTTPS://winbin-org.github.io/pkg/seeded", .scheme = "HTTPS" },
        .{ .url = "Https://winbin-org.github.io/pkg/seeded", .scheme = "Https" },
        .{ .url = "hTTp://WINBIN-ORG.GITHUB.IO/pkg/seeded", .scheme = "hTTp" },
        .{ .url = "HTTPS://e.com/seeded", .scheme = "HTTPS" },
        .{ .url = "HTTP://e.com/seeded", .scheme = "HTTP" },
        .{ .url = "FILE:///C:/pkgs/seeded", .scheme = "FILE" },
    };
    for ([_][]const u8{ "install", "update", "uninstall" }) |command| {
        for (cases) |case| {
            const expected = try std.fmt.allocPrint(env.a(), "unsupported URL scheme '{s}'", .{case.scheme});
            try (try env.run(&.{ command, case.url })).expectError(expected);
        }
    }
    try testing.expect(env.exists("seeded.exe"));
}

test "a URL into the registry is refused, however it's spelled" {
    const env = try Env.init();
    defer env.deinit();
    try seedRegistryPackage(env);
    for ([_][]const u8{ "install", "update", "uninstall" }) |command| {
        for ([_][]const u8{
            registry_seeded,
            "http://winbin-org.github.io/pkg/seeded",
            "https://WinBin-Org.GitHub.io/pkg/seeded",
            "https://winbin-org.github.io/PKG/seeded",
            "https://winbin-org.github.io/pkg/seeded/",
            "https://winbin-org.github.io/pkg/seeded?x=1",
            "https://winbin-org.github.io/pkg/seeded/more",
        }) |url| {
            try (try env.run(&.{ command, url })).expectError("is in the registry, use its name instead: seeded");
        }
        for ([_][]const u8{
            "https://winbin-org.github.io:443/pkg/seeded",
            "https://winbin-org.github.io./pkg/seeded",
            "https://me@winbin-org.github.io/pkg/seeded",
        }) |url| {
            try (try env.run(&.{ command, url })).expectError("is in the registry, use its name instead: seeded");
        }
        // anywhere else on the host, there's no name to suggest
        for ([_][]const u8{
            "https://winbin-org.github.io/pkg/",
            "https://winbin-org.github.io/names",
            "https://winbin-org.github.io/seeded",
            "https://winbin-org.github.io/other/seeded",
            "https://winbin-org.github.io/",
            "https://winbin-org.github.io",
            "http://WINBIN-ORG.GITHUB.IO/seeded",
        }) |url| {
            try (try env.run(&.{ command, url })).expectError("is in the registry, use the package's name instead");
        }
    }
    try testing.expect(env.exists("seeded.exe"));

    // elsewhere with the same name is its own package
    for ([_][]const u8{
        "https://e.com/pkg/seeded",
        "https://winbin-org.github.io.e.com/pkg/seeded",
        "https://mirror.winbin-org.github.io/pkg/seeded",
    }) |url| {
        try (try env.run(&.{ "uninstall", url })).expectError(try std.fmt.allocPrint(env.a(), "'{s}' isn't installed", .{url}));
    }
}

test "there's no limit on the size of a manifest, a response, a value or a redirect" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const install_flat = "extract\ndiscard \"data.txt\"\ninstall exe \"tool.exe\"\n";

    const comment = try env.a().alloc(u8, 256 * 1024);
    @memset(comment, 'x');
    const big = try env.manifest("big", try std.mem.concat(env.a(), u8, &.{ "# ", comment, "\ndownload \"{site}/flat.zip\"\n", install_flat }));
    try (try env.install(big)).expectOut("installed big");
    try (try env.install(big)).expectOut("already installed");
    try (try env.update(big)).expectOut("already the latest version");
    try (try env.run(&.{"installed"})).expectOut(big);
    try (try env.uninstall("big")).expectOut("uninstalled big");
    try env.expectFiles("");

    const padding = try env.a().alloc(u8, 8 * 1024 * 1024);
    @memset(padding, 'p');
    const long = try env.a().alloc(u8, 256 * 1024);
    @memset(long, 'a');
    try env.site.writeFile(testing.io, .{ .sub_path = "huge.json", .data = try std.mem.concat(env.a(), u8, &.{
        "{\"padding\":\"",
        padding,
        "\",\"value\":\"",
        long,
        "=flat\\n\"}",
    }) });
    try (try env.install(try env.manifest("huge", try std.mem.concat(env.a(), u8, &.{
        \\let index = @fetch("{site}/huge.json")
        \\let value = @json_value(index, "/value")
        \\let file = @match_text(value, "={*}")
        \\download "{site}/{file}.zip"
        \\
        ,
        install_flat,
    })))).expectOut("installed huge");
    try (try env.uninstall("huge")).expectOut("uninstalled huge");

    const long_path = try env.a().alloc(u8, 10 * 1024);
    @memset(long_path, 'r');
    try env.site.writeFile(testing.io, .{
        .sub_path = "go.redirect",
        .data = try std.fmt.allocPrint(env.a(), "{s}?{s}&file=flat&", .{ try env.url("x"), long_path }),
    });
    try (try env.install(try env.manifest("far", try std.mem.concat(env.a(), u8, &.{
        \\let location = @fetch_redirect("{site}/go")
        \\let file = @match_text(location, "file={*}&")
        \\download "{site}/{file}.zip"
        \\
        ,
        install_flat,
    })))).expectOut("installed far");
}

test "errors while installing say what was typed" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const url = try env.manifest("typed", "download \"{site}/flat.zip\"\nextract\ninstall exe \"tool.exe\"\n");
    try (try env.install(url)).expectError(try std.fmt.allocPrint(env.a(), "{s}: nothing installs or discards 'data.txt'", .{url}));
    const bad = try env.manifest("typed", "nope\n");
    try (try env.install(bad)).expectError(try std.fmt.allocPrint(env.a(), "manifest of '{s}'", .{bad}));
}

test "a package can't take what another one installed, the error says whose it is" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const text = "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"tool.exe\"\n";
    const first = try env.manifest("first", text);
    const second = try env.manifest("second", text);
    try (try env.install(first)).expectOk();
    const refused = try env.install(second);
    try refused.expectError(try std.fmt.allocPrint(env.a(), "{s} can't install 'tool.exe', it belongs to {s}", .{ second, first }));
    try env.expectFiles("tool.exe");
    try (try env.uninstall("first")).expectOk();
    try (try env.install(second)).expectOut("installed second");
}

test "installing, running, and uninstalling a single exe" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &.{ .{ .name = "tool.exe", .data = try env.realExe() }, .{ .name = "data.txt", .data = "data" } });
    const from = try env.manifest("flat",
        \\download "{site}/flat.zip"
        \\extract
        \\discard "data.txt"
        \\install exe "flat.exe" from "tool.exe"
        \\
    );
    try (try env.install(from)).expectOut("installed flat");
    try env.expectFiles("flat.exe");
    try env.expectSettled();
    try testing.expectEqual(0, try env.tmpCount());

    // it really runs
    const installed_exe = try std.fs.path.join(env.a(), &.{ env.bin_path, "flat.exe" });
    const ran = try std.process.run(env.a(), testing.io, .{ .argv = &.{ installed_exe, "-n", "1", "127.0.0.1" }, .create_no_window = false });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, ran.term);

    try (try env.install(from)).expectOut("already installed");
    try (try env.update(from)).expectOut("already the latest version");
    try (try env.run(&.{"installed"})).expectOut("flat");
    try (try env.uninstall("flat")).expectOut("uninstalled flat");
    try env.expectFiles("");
    try (try env.run(&.{"installed"})).expectOk();
}

test "a manifest from an http:// URL, downloading over http://" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const text = try std.fmt.allocPrint(env.a(),
        \\download "{s}"
        \\extract
        \\discard "data.txt"
        \\install exe "tool.exe"
        \\
    , .{try env.url("flat.zip")});

    try env.site.writeFile(testing.io, .{ .sub_path = "flat", .data = text });
    const from_http = try env.url("flat");
    const by_http = try env.install(from_http);
    try by_http.expectOut("installed flat");
    try testing.expectEqualStrings("", by_http.stderr);
    try (try env.update(from_http)).expectOut("already the latest version");
    try (try env.run(&.{"installed"})).expectOut(from_http);
    try (try env.run(&.{ "uninstall", from_http })).expectOut("uninstalled flat");
    try env.expectFiles("");
}

test "everything in the archive has to be accounted for" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const from = try env.manifest("left",
        \\download "{site}/flat.zip"
        \\extract
        \\install exe "tool.exe"
        \\
    );
    try (try env.install(from)).expectError("nothing installs or discards 'data.txt'");
    try env.expectFiles("");
    try env.expectSettled();
}

test "discard: of something missing, of a folder, and inside a dir" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try (try env.install(try env.manifest("gone",
        \\download "{site}/flat.zip"
        \\extract
        \\discard "data.txt"
        \\discard "nope.txt"
        \\install exe "tool.exe"
        \\
    ))).expectError("can't discard 'nope.txt', it isn't in the archive");
    try env.expectFiles("");

    try serveTool(env, "1.0");
    try (try env.install(try env.manifest("trim",
        \\download "{site}/tool-1.0.zip"
        \\extract
        \\discard "tool-1.0/share"
        \\install dir "trim-1.0" from "tool-1.0"
        \\install exelink "trim.exe" -> "trim-1.0/bin/tool.exe"
        \\
    ))).expectOut("installed trim");
    try env.expectFiles("trim-1.0 trim.exe");
    try testing.expect(env.exists("trim-1.0\\bin\\tool.exe"));
    try testing.expect(!env.exists("trim-1.0\\share"));
}

test "install: wrong kinds, twice, missing, and order" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try serveTool(env, "1.0");
    const cases = [_]struct { text: []const u8, message: []const u8 }{
        .{ .text = "download \"{site}/tool-1.0.zip\"\nextract\ninstall exe \"a.exe\" from \"tool-1.0\"\n", .message = "is a directory, not an exe" },
        .{ .text = "download \"{site}/flat.zip\"\nextract\ninstall dir \"d\" from \"tool.exe\"\n", .message = "is a file, not a directory" },
        .{ .text = "download \"{site}/flat.zip\"\nextract\ninstall exe \"a.exe\" from \"tool.exe\"\ninstall exe \"a.exe\" from \"data.txt\"\n", .message = "is installed twice" },
        .{ .text = "download \"{site}/flat.zip\"\nextract\ninstall exe \"nope.exe\"\n", .message = "it isn't in the archive" },
        .{ .text = "download \"{site}/flat.zip\"\nextract\ninstall exe \"a.exe\" from \"tool.exe\"\ndiscard \"data.txt\"\n", .message = "'discard' must come before 'install'" },
        .{ .text = "download \"{site}/flat.zip\"\nextract\ninstall dir \".\"\n", .message = "a directory is installed as a plain name" },
        .{ .text = "download \"{site}/tool-1.0.zip\"\nextract\ninstall dir \"d\" from \"tool-1.0\"\ninstall exelink \"a.exe\" -> \"d/nope.exe\"\n", .message = "which isn't in an installed directory" },
        .{ .text = "download \"{site}/bare.exe\"\nextract\ninstall exe \"bare.exe\"\n", .message = "HTTP 404" },
    };
    for (cases) |case| {
        try (try env.install(try env.manifest("wrong", case.text))).expectError(case.message);
        try env.expectFiles("");
    }
}

test "the whole archive needs a name" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try (try env.install(try env.manifest("whole",
        \\let v = "1"
        \\download "{site}/flat.zip"
        \\extract
        \\install dir "whole-{v}" from "."
        \\install exelink "whole.exe" -> "whole-{v}/tool.exe"
        \\
    ))).expectOut("installed whole");
    try env.expectFiles("whole-1 whole.exe");
    try testing.expect(env.exists("whole-1\\data.txt"));
    try (try env.uninstall("whole")).expectOut("uninstalled");
    try env.expectFiles("");
}

test "a download that is the exe" {
    const env = try Env.init();
    defer env.deinit();
    try env.site.writeFile(testing.io, .{ .sub_path = "bare.exe", .data = "the exe" });
    try (try env.install(try env.manifest("bare",
        \\download "{site}/bare.exe"
        \\install exe "renamed.exe" from "bare.exe"
        \\
    ))).expectOut("installed bare");
    try env.expectFiles("renamed.exe");
    try testing.expectEqualStrings("the exe", try env.read("renamed.exe"));

    try (try env.install(try env.manifest("wrongname",
        \\download "{site}/bare.exe"
        \\install exe "other.exe"
        \\
    ))).expectError("can't install 'other.exe'");

    try (try env.install(try env.manifest("notazip",
        \\download "{site}/bare.exe"
        \\extract
        \\install exe "bare.exe"
        \\
    ))).expectError("read zip");
}

test "a wrong hash stops it before anything is extracted" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const data = try env.site.readFileAlloc(testing.io, "flat.zip", env.a(), .unlimited);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    const bad = try env.manifest("bad",
        \\download "{site}/flat.zip"
        \\verify "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        \\extract
        \\discard "data.txt"
        \\install exe "tool.exe"
        \\
    );
    try (try env.install(bad)).expectError("has the wrong hash");
    try env.expectFiles("");
    var it = try env.bin.walk(env.a());
    while (try it.next(testing.io)) |entry| {
        try testing.expect(std.mem.find(u8, entry.path, "staging\\") == null);
    }

    // either case of hex works
    const upper = try std.ascii.allocUpperString(env.a(), &hex);
    const good = try env.manifest("good", try std.fmt.allocPrint(env.a(),
        \\download "{{site}}/flat.zip"
        \\verify "sha256:{s}"
        \\extract
        \\discard "data.txt"
        \\install exe "tool.exe"
        \\
    , .{upper}));
    try (try env.install(good)).expectOut("installed good");
}

test "values can't escape, whether from a manifest or the network" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try serveTool(env, "1.0");
    for ([_][]const u8{ "..", "../x", "C:", "a:b", "nul" }) |bad| {
        try (try env.install(try env.manifest("baddir", try std.fmt.allocPrint(env.a(),
            \\let v = "{s}"
            \\download "{{site}}/flat.zip"
            \\extract
            \\install dir "{{v}}" from "."
            \\install exelink "b.exe" -> "{{v}}/tool.exe"
            \\
        , .{bad})))).expectError("isn't a plain name");
    }
    try (try env.install(try env.manifest("badexe",
        \\let v = "../evil"
        \\download "{site}/flat.zip"
        \\extract
        \\discard "data.txt"
        \\install exe "{v}.exe" from "tool.exe"
        \\
    ))).expectError("isn't a plain NAME.exe");
    try (try env.install(try env.manifest("badfrom",
        \\let v = ".."
        \\download "{site}/flat.zip"
        \\extract
        \\discard "data.txt"
        \\install exe "a.exe" from "{v}/tool.exe"
        \\
    ))).expectError("isn't a relative path that stays in the archive");
    try (try env.install(try env.manifest("badlink",
        \\let v = ".."
        \\download "{site}/tool-1.0.zip"
        \\extract
        \\install dir "bl" from "tool-1.0"
        \\install exelink "bl.exe" -> "{v}/winbin.exe"
        \\
    ))).expectError("isn't a path into an installed directory");
    try env.expectFiles("");
}

test "a malicious zip is refused, and nothing escapes" {
    const env = try Env.init();
    defer env.deinit();
    const cases = [_]struct { path: []const u8, message: []const u8 }{
        .{ .path = "C:/winbin-e2e-evil.txt", .message = "isn't safe to extract" },
        .{ .path = "C:winbin-e2e-evil.txt", .message = "isn't safe to extract" },
        .{ .path = "a.txt:stream", .message = "isn't safe to extract" },
        .{ .path = ".. /winbin-e2e-evil.txt", .message = "isn't safe to extract" },
        .{ .path = "nul", .message = "isn't safe to extract" },
        .{ .path = "../winbin-e2e-evil.txt", .message = "ZipBadFilename" },
        .{ .path = "..\\winbin-e2e-evil.txt", .message = "ZipBadFilename" },
    };
    for (cases) |case| {
        try env.serveZip("evil.zip", &.{ .{ .name = "tool.exe", .data = "x" }, .{ .name = case.path, .data = "evil" } });
        try (try env.install(try env.manifest("evil",
            \\download "{site}/evil.zip"
            \\extract
            \\install exe "tool.exe"
            \\
        ))).expectError(case.message);
        try env.expectFiles("");
    }
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, "C:\\winbin-e2e-evil.txt", .{}));
}

test "a new version replaces the old, and a manifest change reinstalls" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try serveTool(env, "2.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOut("installed tool");
    try env.expectFiles("tool-1.0 tool.exe");

    const from = try toolManifest(env, "2.0");
    try (try env.update(from)).expectOut("updated tool");
    try env.expectFiles("tool-2.0 tool.exe");
    try testing.expectEqualStrings("2.0", try env.read("tool-2.0\\share\\version.txt"));

    // the same directory name: it can't go side by side
    const changed = try env.manifest("tool", "# a change\nlet v = \"2.0\"\ndownload \"{site}/tool-{v}.zip\"\nextract\ninstall dir \"tool-{v}\"\ninstall exelink \"tool.exe\" -> \"tool-{v}/bin/tool.exe\"\n");
    try (try env.update(changed)).expectOut("reinstalled tool");
    try env.expectFiles("tool-2.0 tool.exe");
    try env.expectSettled();
}

test "something missing gets put back" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    const from = try toolManifest(env, "1.0");
    try (try env.install(from)).expectOk();
    try env.bin.deleteTree(testing.io, "tool-1.0");
    try (try env.install(from)).expectOut("tool-1.0 is missing");
    try env.expectFiles("tool-1.0 tool.exe");
    try env.bin.deleteFile(testing.io, "tool.exe");
    try (try env.install(from)).expectOut("tool.exe is missing");
    try env.expectFiles("tool-1.0 tool.exe");
}

test "a package changing what it installs" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try serveTool(env, "1.0");
    const first = try env.manifest("shift", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"s1.exe\" from \"tool.exe\"\n");
    try (try env.install(first)).expectOk();
    try env.expectFiles("s1.exe");
    const second = try env.manifest("shift", "download \"{site}/tool-1.0.zip\"\nextract\ninstall dir \"shift-1\" from \"tool-1.0\"\ninstall exelink \"s2.exe\" -> \"shift-1/bin/tool.exe\"\n");
    try (try env.update(second)).expectOut("updated shift");
    try env.expectFiles("s2.exe shift-1");
    try (try env.uninstall("shift")).expectOk();
    try env.expectFiles("");
}

test "a failed update leaves the old version whole" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    const failing = try env.manifest("tool", "let v = \"9.9\"\ndownload \"{site}/tool-{v}.zip\"\nextract\ninstall dir \"tool-{v}\"\ninstall exelink \"tool.exe\" -> \"tool-{v}/bin/tool.exe\"\n");
    try (try env.update(failing)).expectError("HTTP 404");
    try env.expectFiles("tool-1.0 tool.exe");
    try testing.expectEqualStrings("1.0", try env.read("tool-1.0\\share\\version.txt"));
}

const question = "Replace them? [y/N]";

/// A winbin waiting on its question, nothing having been answered.
const Asking = struct {
    env: *Env,
    child: std.process.Child,
    stderr: std.ArrayList(u8) = .empty,

    fn readSome(self: *Asking, file: std.Io.File, out: *std.ArrayList(u8)) !bool {
        var buf: [4096]u8 = undefined;
        const n = file.readStreaming(testing.io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => return false,
            else => return e,
        };
        try out.appendSlice(self.env.a(), buf[0..n]);
        return true;
    }

    fn answer(self: *Asking, text: []const u8) !Output {
        const stdin = self.child.stdin.?;
        try stdin.writeStreamingAll(testing.io, text);
        stdin.close(testing.io);
        self.child.stdin = null;
        var stdout: std.ArrayList(u8) = .empty;
        while (try self.readSome(self.child.stdout.?, &stdout)) {}
        while (try self.readSome(self.child.stderr.?, &self.stderr)) {}
        const term = try self.child.wait(testing.io);
        return .{
            .code = switch (term) {
                .exited => |code| code,
                else => null,
            },
            .stdout = stdout.items,
            .stderr = self.stderr.items,
        };
    }
};

fn startAsking(env: *Env, from: []const u8) !Asking {
    return startAskingArgv(env, &.{ env.exe, "install", from });
}

fn startAskingArgv(env: *Env, argv: []const []const u8) !Asking {
    var asking: Asking = .{
        .env = env,
        .child = try std.process.spawn(testing.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = false,
        }),
    };
    errdefer asking.child.kill(testing.io);
    while (std.mem.find(u8, asking.stderr.items, question) == null) {
        if (!try asking.readSome(asking.child.stderr.?, &asking.stderr)) {
            std.debug.print("expected the question, got: {s}\n", .{asking.stderr.items});
            return error.TestUnexpectedResult;
        }
    }
    return asking;
}

fn expectNotAsked(output: Output) !void {
    try testing.expect(std.mem.find(u8, output.stderr, question) == null);
}

const mine_text = "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"mine.exe\" from \"tool.exe\"\n";

fn exeText(comptime name: []const u8) []const u8 {
    return "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"" ++ name ++ ".exe\" from \"tool.exe\"\n";
}

test "install takes several packages, one after another" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const one = try env.manifest("one", exeText("one"));
    const two = try env.manifest("two", exeText("two"));

    const both = try env.run(&.{ "install", one, two });
    try both.expectOut("installed one");
    try both.expectOut("installed two");
    try env.expectFiles("one.exe two.exe");
    try env.expectSettled();

    // what's installed already doesn't get in the way of what isn't
    const three = try env.manifest("three", exeText("three"));
    const mixed = try env.run(&.{ "install", one, three, two });
    try mixed.expectOut("is already installed");
    try mixed.expectOut("installed three");
    try env.expectFiles("one.exe three.exe two.exe");
    try testing.expect(std.mem.find(u8, mixed.stdout, "installed one") == null);
    try env.expectSettled();
}

test "--version is the date it was built" {
    const env = try Env.init();
    defer env.deinit();
    const output = try env.run(&.{"--version"});
    try output.expectOk();
    const version = std.mem.trimEnd(u8, output.stdout, "\n");
    try testing.expectEqual("vYYYY_MM_DD".len, version.len);
    try testing.expectEqual('v', version[0]);
    try testing.expectEqual('_', version[5]);
    try testing.expectEqual('_', version[8]);
    for ([_][]const u8{ version[1..5], version[6..8], version[9..11] }) |digits| {
        _ = try std.fmt.parseInt(u16, digits, 10);
    }
}

const pdb_entries = [_]Entry{ .{ .name = "tool.exe", .data = "the exe" }, .{ .name = "tool.pdb", .data = "the pdb" } };
const pdb_text = "download \"{site}/pdb.zip\"\nextract\ninstall exe \"tool.exe\"\ninstall pdb \"tool.pdb\"\n";

fn recordHasPdb(env: *Env, name: []const u8) !bool {
    return std.mem.find(u8, try env.read((try env.recordOf(name)).?), "installed-pdb ") != null;
}

test "a PDB is dropped, unless it's asked for" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("pdb.zip", &pdb_entries);
    const tool = try env.manifest("tool", pdb_text);

    // it isn't left over, nothing says it should be discarded
    try (try env.install(tool)).expectOut("installed tool");
    try env.expectFiles("tool.exe");
    try testing.expect(!try recordHasPdb(env, "tool"));
    try env.expectSettled();
    try (try env.install(tool)).expectOut("is already installed");

    // asking for it later gets it
    try (try env.run(&.{ "install", "--pdbs", tool })).expectOut("reinstalled tool");
    try env.expectFiles("tool.exe tool.pdb");
    try testing.expectEqualStrings("the pdb", try env.read("tool.pdb"));
    try testing.expect(try recordHasPdb(env, "tool"));
    try env.expectSettled();
    try (try env.run(&.{ "install", "--pdbs", tool })).expectOut("is already installed");

    // it stays how it was installed
    try (try env.install(tool)).expectOut("is already installed");
    try env.expectFiles("tool.exe tool.pdb");

    // uninstalling takes it too
    try (try env.uninstall("tool")).expectOk();
    try env.expectFiles("");
    try env.expectSettled();
}

test "update keeps a package's PDB, and updates it" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("pdb.zip", &pdb_entries);
    const tool = try env.manifest("tool", pdb_text);
    const plain = try env.manifest("plain", "download \"{site}/plain.zip\"\nextract\ninstall exe \"plain.exe\"\ninstall pdb \"plain.pdb\"\n");
    try env.serveZip("plain.zip", &.{ .{ .name = "plain.exe", .data = "one" }, .{ .name = "plain.pdb", .data = "one" } });
    try (try env.run(&.{ "install", "--pdbs", tool, "--end-pdbs", plain })).expectOk();
    try env.expectFiles("plain.exe tool.exe tool.pdb");

    try env.serveZip("pdb.zip", &.{ .{ .name = "tool.exe", .data = "new exe" }, .{ .name = "tool.pdb", .data = "new pdb" } });
    _ = try env.manifest("tool", comptime pdb_text ++ "\n");
    _ = try env.manifest("plain", "download \"{site}/plain.zip\"\nextract\ninstall exe \"plain.exe\"\ninstall pdb \"plain.pdb\"\n\n");
    try (try env.run(&.{ "update", tool, plain })).expectOk();
    try env.expectFiles("plain.exe tool.exe tool.pdb");
    try testing.expectEqualStrings("new exe", try env.read("tool.exe"));
    try testing.expectEqualStrings("new pdb", try env.read("tool.pdb"));
    try env.expectSettled();

    // and a release that stops having one takes it away
    _ = try env.manifest("tool", "download \"{site}/noexe.zip\"\nextract\ninstall exe \"tool.exe\"\n");
    try env.serveZip("noexe.zip", &.{.{ .name = "tool.exe", .data = "new exe" }});
    try (try env.update(tool)).expectOk();
    try env.expectFiles("plain.exe tool.exe");
    try env.expectSettled();
}

test "--pdbs and --end-pdbs choose which packages have their PDBs" {
    const env = try Env.init();
    defer env.deinit();
    for ([_][]const u8{ "a", "b", "c" }) |name| {
        const zip = try std.fmt.allocPrint(env.a(), "{s}.zip", .{name});
        try env.serveZip(zip, &.{
            .{ .name = try std.fmt.allocPrint(env.a(), "{s}.exe", .{name}), .data = "exe" },
            .{ .name = try std.fmt.allocPrint(env.a(), "{s}.pdb", .{name}), .data = "pdb" },
        });
    }
    var froms: [3][]const u8 = undefined;
    for ([_][]const u8{ "a", "b", "c" }, &froms) |name, *from| from.* = try env.manifest(name, try std.fmt.allocPrint(
        env.a(),
        "download \"{{site}}/{s}.zip\"\nextract\ninstall exe \"{s}.exe\"\ninstall pdb \"{s}.pdb\"\n",
        .{ name, name, name },
    ));
    try (try env.run(&.{ "install", froms[0], "--pdbs", froms[1], "--end-pdbs", froms[2] })).expectOk();
    try env.expectFiles("a.exe b.exe b.pdb c.exe");
    try env.expectSettled();
}

test "--pdbs is only for install, and has to make sense" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("pdb.zip", &pdb_entries);
    const tool = try env.manifest("tool", pdb_text);
    try (try env.run(&.{ "install", "--pdbs" })).expectError("expected 'install NAME|URL...'");
    try (try env.run(&.{ "install", "--end-pdbs", tool })).expectError("'--end-pdbs' needs a '--pdbs' before it");
    try (try env.run(&.{ "install", "--pdbs", "--pdbs", tool })).expectError("'--pdbs' is given again before '--end-pdbs'");
    try (try env.run(&.{ "update", "--pdbs", tool })).expectError("invalid package name '--pdbs'");
    try (try env.run(&.{ "uninstall", "--pdbs", tool })).expectError("invalid package name '--pdbs'");
    try (try env.run(&.{ "install", "--pdbs", tool, "--end-pdbs", tool })).expectError("is given more than once");
    try env.expectFiles("");

    // what's between them doesn't need an end
    try (try env.run(&.{ "install", "--pdbs", tool })).expectOk();
    try env.expectFiles("tool.exe tool.pdb");
}

test "a package with no PDB to give doesn't reinstall for --pdbs" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const one = try env.manifest("one", exeText("one"));
    try (try env.install(one)).expectOk();
    try (try env.run(&.{ "install", "--pdbs", one })).expectOut("one is already the latest version");
    try env.expectFiles("one.exe");
}

test "a PDB has to be in the archive, and has to go with an exe" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("noexe.zip", &.{.{ .name = "tool.exe", .data = "the exe" }});
    const missing = try env.manifest("missing", "download \"{site}/noexe.zip\"\nextract\ninstall exe \"tool.exe\"\ninstall pdb \"tool.pdb\"\n");
    try (try env.install(missing)).expectError("can't install 'tool.pdb', it isn't in the archive");
    try env.expectFiles("");
    try (try env.run(&.{ "install", "--pdbs", missing })).expectError("can't install 'tool.pdb', it isn't in the archive");
    try env.expectFiles("");

    try env.serveZip("pdb.zip", &pdb_entries);
    const wrong = try env.manifest("wrong", "download \"{site}/pdb.zip\"\nextract\ninstall exe \"tool.exe\"\ninstall pdb \"other.pdb\" from \"tool.pdb\"\n");
    try (try env.install(wrong)).expectError("nothing installs the exe that 'other.pdb' is for, 'other.exe'");
    try env.expectFiles("");
}

test "a PDB is left alone like anything else in the way" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("pdb.zip", &pdb_entries);
    try env.write("tool.pdb", "mine");
    const tool = try env.manifest("tool", pdb_text);

    // dropped, so it isn't in the way
    try (try env.install(tool)).expectOut("installed tool");
    try testing.expectEqualStrings("mine", try env.read("tool.pdb"));
    try (try env.uninstall("tool")).expectOk();
    try testing.expectEqualStrings("mine", try env.read("tool.pdb"));

    const output = try env.run(&.{ "install", "--pdbs", tool });
    try output.expectError("there's no one to answer, nothing was changed");
    try testing.expectEqualStrings("mine", try env.read("tool.pdb"));
}

test "a step only happens when its condition holds" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("pdb.zip", &pdb_entries);
    try env.serveZip("noexe.zip", &.{.{ .name = "tool.exe", .data = "the exe" }});

    // what differs between arches, without knowing which arch this is
    const skipped = try env.manifest("skipped", "let arch = \"x86\"\ndownload \"{site}/noexe.zip\"\nextract\ninstall exe \"tool.exe\"\nif arch != \"x86\" | install pdb \"tool.pdb\"\n");
    try (try env.run(&.{ "install", "--pdbs", skipped })).expectOk();
    try env.expectFiles("tool.exe");
    try (try env.uninstall("skipped")).expectOk();

    const taken = try env.manifest("taken", "let arch = \"x86_64\"\ndownload \"{site}/pdb.zip\"\nextract\ninstall exe \"tool.exe\"\nif arch != \"x86\" | install pdb \"tool.pdb\"\n");
    try (try env.run(&.{ "install", "--pdbs", taken })).expectOk();
    try env.expectFiles("tool.exe tool.pdb");
    try (try env.uninstall("taken")).expectOk();

    // what differs between versions
    const entries = [_]Entry{ .{ .name = "new/tool.exe", .data = "new" }, .{ .name = "old/tool.exe", .data = "old" } };
    try env.serveZip("moved.zip", &entries);
    const moved = "download \"{site}/moved.zip\"\nextract\nif v >= \"2.0\" | discard \"old\"\nif v < \"2.0\" | discard \"new\"\nif v >= \"2.0\" | install exe \"tool.exe\" from \"new/tool.exe\"\nif v < \"2.0\" | install exe \"tool.exe\" from \"old/tool.exe\"\n";
    const newer = try env.manifest("newer", "let v = \"2.1\"\n" ++ moved);
    try (try env.install(newer)).expectOk();
    try testing.expectEqualStrings("new", try env.read("tool.exe"));
    try (try env.uninstall("newer")).expectOk();
    const older = try env.manifest("older", "let v = \"1.10\"\n" ++ moved);
    try (try env.install(older)).expectOk();
    try testing.expectEqualStrings("old", try env.read("tool.exe"));
    try (try env.uninstall("older")).expectOk();

    // several conditions all have to hold
    const both = try env.manifest("both", "let a = \"x\"\nlet b = \"y\"\ndownload \"{site}/pdb.zip\"\nextract\nif a == \"x\", b == \"z\" | discard \"tool.pdb\"\nif a == \"x\", b == \"y\" | install pdb \"tool.pdb\"\ninstall exe \"tool.exe\"\n");
    try (try env.run(&.{ "install", "--pdbs", both })).expectOk();
    try env.expectFiles("tool.exe tool.pdb");
    try env.expectSettled();
    try (try env.uninstall("both")).expectOk();

    // a line after a group is on its own again
    const grouped = try env.manifest("grouped", "let a = \"x\"\ndownload \"{site}/pdb.zip\"\nextract\nif a == \"nope\" | install pdb \"tool.pdb\"\n                | discard \"nothing\"\ninstall exe \"tool.exe\"\ninstall pdb \"tool.pdb\"\n");
    try (try env.run(&.{ "install", "--pdbs", grouped })).expectError("'discard' must come before 'install'");
}

test "what a skipped step would have handled is still noticed" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const output = try env.install(try env.manifest("left", "let a = \"x\"\ndownload \"{site}/flat.zip\"\nextract\nif a == \"nope\" | discard \"data.txt\"\ninstall exe \"tool.exe\"\n"));
    try output.expectError("nothing installs or discards 'data.txt'");
    try env.expectFiles("");
}

test "comparing something that isn't a version is an error, not a skipped step" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const output = try env.install(try env.manifest("tag", "let v = \"nightly\"\ndownload \"{site}/flat.zip\"\nextract\nif v < \"2.0\" | discard \"data.txt\"\ninstall exe \"tool.exe\"\n"));
    try output.expectError("'nightly' isn't dot separated numbers, so it can't be compared like a version");
    try env.expectFiles("");
}

test "giving a package more than once is an error, before anything's changed" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const one = try env.manifest("one", exeText("one"));
    const two = try env.manifest("two", exeText("two"));
    for ([_][]const u8{ "install", "update", "uninstall" }) |command| {
        try (try env.run(&.{ command, one, two, one })).expectError("is given more than once");
    }
    try env.expectFiles("");
}

test "update takes several packages, and all of them have to be installed" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const one = try env.manifest("one", exeText("one"));
    const two = try env.manifest("two", exeText("two"));
    const three = try env.manifest("three", exeText("three"));
    try (try env.run(&.{ "install", one, two })).expectOk();

    const current = try env.run(&.{ "update", one, two });
    try current.expectOut("one is already the latest version");
    try current.expectOut("two is already the latest version");

    // a changed manifest is something to update, so nothing's been done if this is refused
    _ = try env.manifest("one", comptime exeText("one") ++ "\n");
    const refused = try env.run(&.{ "update", one, three });
    try refused.expectError("isn't installed");
    try testing.expect(std.mem.find(u8, refused.stdout, "reinstalled") == null);

    _ = try env.manifest("two", comptime exeText("two") ++ "\n");
    const both = try env.run(&.{ "update", one, two });
    try both.expectOut("reinstalled one");
    try both.expectOut("reinstalled two");
    try env.expectFiles("one.exe two.exe");
    try env.expectSettled();
}

test "uninstall takes several packages, and all of them have to be installed" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const one = try env.manifest("one", exeText("one"));
    const two = try env.manifest("two", exeText("two"));
    const three = try env.manifest("three", exeText("three"));
    try (try env.run(&.{ "install", one, two })).expectOk();

    try (try env.run(&.{ "uninstall", one, three })).expectError("isn't installed");
    try env.expectFiles("one.exe two.exe");

    const both = try env.run(&.{ "uninstall", one, two });
    try both.expectOut("uninstalled one");
    try both.expectOut("uninstalled two");
    try env.expectFiles("");
    try env.expectSettled();
}

test "a bad argument to install fails before any package is touched" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const one = try env.manifest("one", exeText("one"));
    const bad = try env.run(&.{ "install", one, "NOT A NAME" });
    try bad.expectError("invalid package name 'NOT A NAME'");
    try testing.expect(std.mem.find(u8, bad.stdout, "downloading") == null);
    try env.expectFiles("");
}

test "a package that fails stops install, and what's installed stays" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const one = try env.manifest("one", exeText("one"));
    const broken = try env.manifest("broken", "download \"{site}/nope.zip\"\nextract\n");
    const two = try env.manifest("two", exeText("two"));
    const failed = try env.run(&.{ "install", one, broken, two });
    try testing.expectEqual(@as(?u8, 1), failed.code);
    try testing.expect(std.mem.find(u8, failed.stdout, "installed one") != null);
    try testing.expect(std.mem.find(u8, failed.stdout, "installed two") == null);
    try env.expectFiles("one.exe");
    try env.expectSettled();
}

test "each package installing over something asks, and answers can all be given at once" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.write("one.exe", "mine");
    try env.write("two.exe", "mine");
    const one = try env.manifest("one", exeText("one"));
    const two = try env.manifest("two", exeText("two"));

    var asking = try startAskingArgv(env, &.{ env.exe, "install", one, two });
    const output = try asking.answer("y\ny\n");
    try output.expectOut("installed one");
    try output.expectOut("installed two");
    try testing.expectEqualStrings("the exe", try env.read("one.exe"));
    try testing.expectEqualStrings("the exe", try env.read("two.exe"));
}

test "what winbin didn't install is only replaced on a yes" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.write("mine.exe", "mine");
    const from = try env.manifest("mine", mine_text);

    const unanswered = try env.install(from);
    try unanswered.expectError("there's no one to answer, nothing was changed");
    try testing.expect(std.mem.find(u8, unanswered.stderr, "mine.exe") != null);
    try testing.expect(std.mem.find(u8, unanswered.stderr, from) != null);
    try testing.expect(std.mem.find(u8, unanswered.stdout, "downloading") == null);

    for ([_][]const u8{ "n\n", "\n", "\r\n", "no\n", "maybe\n", "yy\n" }) |no| {
        var asking = try startAsking(env, from);
        const output = try asking.answer(no);
        try output.expectError("winbin: user cancelled install");
        try testing.expect(std.mem.find(u8, output.stderr, "error:") == null);
        try testing.expect(std.mem.find(u8, output.stdout, "downloading") == null);
        try testing.expectEqualStrings("mine", try env.read("mine.exe"));
        try testing.expect(try env.recordOf("mine") == null);
        try testing.expectEqual(0, try env.tmpCount());
    }

    for ([_][]const u8{ "y\n", "Y\r\n", " yes \r\n", "y" }) |yes| {
        var asking = try startAsking(env, from);
        try (try asking.answer(yes)).expectOut("installed mine");
        try testing.expectEqualStrings("the exe", try env.read("mine.exe"));
        try env.expectSettled();

        // it's the package's now, so there's nothing more to ask about
        try (try env.install(from)).expectOut("already installed");
        try (try env.update(from)).expectOut("already the latest version");
        try (try env.uninstall("mine")).expectOut("uninstalled mine");
        try env.expectFiles("");
        try env.write("mine.exe", "mine");
    }
}

test "everything in the way is one question, whatever kind it is" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const from = try env.manifest("whole", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall dir \"whole\" from \".\"\ninstall exelink \"whole.exe\" -> \"whole/tool.exe\"\n");

    try env.bin.createDirPath(testing.io, "whole\\sub");
    try env.write("whole\\sub\\keep.txt", "keep");
    try env.write("whole.exe", "mine");
    var asking = try startAsking(env, from);
    const declined = try asking.answer("n\n");
    try declined.expectError("whole\\ and everything in it");
    try declined.expectError("whole.exe");
    try testing.expectEqual(1, std.mem.count(u8, declined.stderr, question));
    try testing.expectEqualStrings("keep", try env.read("whole\\sub\\keep.txt"));
    try testing.expectEqualStrings("mine", try env.read("whole.exe"));

    asking = try startAsking(env, from);
    try (try asking.answer("y\n")).expectOut("installed whole");
    try env.expectFiles("whole whole.exe");
    try testing.expect(env.exists("whole\\tool.exe"));
    try testing.expect(!env.exists("whole\\sub"));
    try env.expectSettled();
    try (try env.uninstall("whole")).expectOk();
    try env.expectFiles("");

    // a directory where a file goes, a file where a directory goes
    try env.bin.createDirPath(testing.io, "whole.exe\\sub");
    try env.write("whole", "a file");
    asking = try startAsking(env, from);
    try (try asking.answer("y\n")).expectOut("installed whole");
    try testing.expect(env.exists("whole\\tool.exe"));
    try testing.expect(!env.exists("whole.exe\\sub"));
    try env.expectSettled();
    try (try env.uninstall("whole")).expectOk();
    try env.expectFiles("");

    try env.bin.createDirPath(testing.io, "mine.exe");
    asking = try startAsking(env, try env.manifest("mine", mine_text));
    try (try asking.answer("y\n")).expectOut("installed mine");
    try testing.expectEqualStrings("the exe", try env.read("mine.exe"));
    try env.expectSettled();
}

test "replacing a junction leaves what it points to alone" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.tmp.dir.createDirPath(testing.io, "elsewhere");
    try env.tmp.dir.writeFile(testing.io, .{ .sub_path = "elsewhere\\precious.txt", .data = "precious" });
    const target = try env.tmp.dir.realPathFileAlloc(testing.io, "elsewhere", env.a());
    const link = try std.fs.path.join(env.a(), &.{ env.bin_path, "whole" });
    const made = try std.process.run(env.a(), testing.io, .{ .argv = &.{ "cmd", "/c", "mklink", "/J", link, target }, .create_no_window = false });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, made.term);

    var asking = try startAsking(env, try env.manifest("whole", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall dir \"whole\" from \".\"\ninstall exelink \"whole.exe\" -> \"whole/tool.exe\"\n"));
    try (try asking.answer("y\n")).expectOut("installed whole");
    try testing.expect(env.exists("whole\\tool.exe"));
    try testing.expectEqualStrings("precious", try env.tmp.dir.readFileAlloc(testing.io, "elsewhere\\precious.txt", env.a(), .unlimited));
    try env.expectSettled();
}

test "what another package installed isn't asked about, it's refused" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const first = try env.manifest("first", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"tool.exe\"\n");
    try (try env.install(first)).expectOk();

    const belongs = "can't install 'tool.exe', it belongs to";

    const second = try env.manifest("second", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"tool.exe\"\n");
    const same = try env.install(second);
    try same.expectError(belongs);
    try same.expectError(first);
    try expectNotAsked(same);

    // not even a yes helps, so it doesn't ask about the rest either
    try env.write("other.exe", "mine");
    try env.write("before.exe", "mine");
    const mixed = try env.install(try env.manifest("mixed", "download \"{site}/flat.zip\"\nextract\ninstall exe \"before.exe\" from \"data.txt\"\ninstall exe \"tool.exe\"\n"));
    try mixed.expectError(belongs);
    try expectNotAsked(mixed);
    try testing.expectEqualStrings("mine", try env.read("before.exe"));

    // names ignore case
    const upper = try env.install(try env.manifest("upper", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"TOOL.exe\" from \"tool.exe\"\n"));
    try upper.expectError("can't install 'TOOL.exe', it belongs to");

    // uninstalling the first would delete it, even though it's missing right now
    try env.bin.deleteFile(testing.io, "tool.exe");
    try (try env.install(second)).expectError(belongs);
    try env.expectFiles("before.exe other.exe");
    try (try env.install(first)).expectOut("tool.exe is missing");

    try (try env.uninstall("first")).expectOk();
    try (try env.install(second)).expectOut("installed second");
}

test "an update is asked about what's new to it, not what it already has" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const from = try env.manifest("grow", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"tool.exe\"\n");
    try (try env.install(from)).expectOk();

    try env.write("new.exe", "mine");
    _ = try env.manifest("grow", "download \"{site}/flat.zip\"\nextract\ninstall exe \"tool.exe\"\ninstall exe \"new.exe\" from \"data.txt\"\n");
    const update = try env.update(from);
    try update.expectError("there's no one to answer");
    try update.expectError("new.exe");
    try testing.expect(std.mem.find(u8, update.stderr, "tool.exe") == null);
    try testing.expectEqualStrings("mine", try env.read("new.exe"));

    var asking: Asking = .{
        .env = env,
        .child = try std.process.spawn(testing.io, .{
            .argv = &.{ env.exe, "update", from },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = false,
        }),
    };
    try (try asking.answer("y\n")).expectOut("reinstalled grow");
    try testing.expectEqualStrings("data", try env.read("new.exe"));
}

const non_interactive_message = "--non-interactive was given, but winbin needs to ask whether to replace them, nothing was changed";

test "what can't be written to in the way is reported as in the way first" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.write("mine.exe", "mine");
    const path = try std.fs.path.join(env.a(), &.{ env.bin_path, "mine.exe" });
    try attrib(env, "+r", path);
    defer attrib(env, "-r", path) catch {};
    const from = try env.manifest("mine", mine_text);

    const refused = try env.run(&.{ "install", "--non-interactive", from });
    try refused.expectError(non_interactive_message);
    try testing.expect(std.mem.find(u8, refused.stderr, "mine.exe") != null);
    try testing.expect(std.mem.find(u8, refused.stderr, "AccessDenied") == null);
    try testing.expect(std.mem.find(u8, refused.stdout, "downloading") == null);
    try testing.expectEqualStrings("mine", try env.read("mine.exe"));

    // and saying yes replaces it, since it can still be moved aside
    var asking = try startAsking(env, from);
    try (try asking.answer("y\n")).expectOut("installed mine");
    try testing.expectEqualStrings("the exe", try env.read("mine.exe"));
    try env.expectSettled();
}

fn attrib(env: *Env, change: []const u8, path: []const u8) !void {
    const result = try std.process.run(env.a(), testing.io, .{ .argv = &.{ "attrib", change, path }, .create_no_window = false });
    if (result.term != .exited or result.term.exited != 0) return error.TestUnexpectedResult;
}

test "--non-interactive fails where it would have asked, wherever it's given" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.write("one.exe", "mine");
    const one = try env.manifest("one", exeText("one"));
    for ([_][]const []const u8{
        &.{ "install", "--non-interactive", one },
        &.{ "install", one, "--non-interactive" },
        &.{ "i", "--non-interactive", one },
    }) |args| {
        const output = try env.run(args);
        try output.expectError(non_interactive_message);
        try testing.expectEqualStrings("mine", try env.read("one.exe"));
    }

    // it doesn't matter with nothing to ask, and it applies to update and uninstall too
    try env.bin.deleteFile(testing.io, "one.exe");
    try (try env.run(&.{ "install", "--non-interactive", one })).expectOut("installed one");
    try (try env.run(&.{ "update", one, "--non-interactive" })).expectOut("already the latest version");

    // an update that would replace something new asks too
    try env.write("two.exe", "mine");
    _ = try env.manifest("one", comptime exeText("one") ++ "install exe \"two.exe\" from \"data.txt\"\n");
    try (try env.run(&.{ "update", "--non-interactive", one })).expectError(non_interactive_message);
    try testing.expectEqualStrings("mine", try env.read("two.exe"));

    try (try env.run(&.{ "uninstall", "--non-interactive", one })).expectOut("uninstalled one");
    try (try env.run(&.{ "install", "--non-interactive" })).expectError("expected 'install NAME|URL...'");
    try (try env.run(&.{ "installed", "--non-interactive" })).expectError("'installed' takes no arguments");
    try (try env.run(&.{ "available", "--non-interactive" })).expectError("'available' takes no arguments");
    try env.expectSettled();
}

test "something running in the way is asked about, then replaced" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    var running = try startRunning(env, "mine.exe");
    var killed = false;
    defer if (!killed) running.kill(testing.io);
    const from = try env.manifest("mine", mine_text);

    const unanswered = try env.run(&.{ "install", "--non-interactive", from });
    try unanswered.expectError(non_interactive_message);
    try testing.expect(std.mem.find(u8, unanswered.stderr, "mine.exe") != null);

    var asking = try startAsking(env, from);
    try (try asking.answer("n\n")).expectError("user cancelled install");
    try testing.expect(!std.mem.eql(u8, "the exe", try env.read("mine.exe")));

    asking = try startAsking(env, from);
    try (try asking.answer("y\n")).expectOut("installed mine");
    try testing.expectEqualStrings("the exe", try env.read("mine.exe"));
    try testing.expect(env.exists(".winbin\\delete\\mine.exe"));

    running.kill(testing.io);
    killed = true;
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "a package's own exe that's running isn't asked about, it's replaced" {
    const env = try Env.init();
    defer env.deinit();
    const real = try env.realExe();
    try env.serveZip("real.zip", &.{.{ .name = "own.exe", .data = real }});
    const from = try env.manifest("own", "download \"{site}/real.zip\"\nextract\ninstall exe \"own.exe\"\n");
    try (try env.install(from)).expectOk();
    const own_exe = try std.fs.path.join(env.a(), &.{ env.bin_path, "own.exe" });
    var running = try std.process.spawn(testing.io, .{ .argv = &.{ own_exe, "-n", "60", "127.0.0.1" }, .stdout = .ignore, .stderr = .ignore, .create_no_window = false });
    var killed = false;
    defer if (!killed) running.kill(testing.io);
    try testing.io.sleep(.fromMilliseconds(300), .awake);

    try env.serveZip("real.zip", &.{.{ .name = "own.exe", .data = "new" }});
    _ = try env.manifest("own", "download \"{site}/real.zip\"\nextract\ninstall exe \"own.exe\"\n\n");
    const output = try env.update(from);
    try output.expectOut("reinstalled own");
    try expectNotAsked(output);
    try testing.expectEqualStrings("new", try env.read("own.exe"));

    // what's still running stays out of the way, and isn't worth mentioning
    const quiet = try env.run(&.{"installed"});
    try quiet.expectOk();
    try testing.expectEqualStrings("", quiet.stderr);
    try testing.expect(env.exists(".winbin\\delete\\own.exe"));

    running.kill(testing.io);
    killed = true;
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "while it's waiting for an answer it holds nothing, and what changed gets noticed" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const from = try env.manifest("pair", "download \"{site}/flat.zip\"\nextract\ninstall exe \"tool.exe\"\ninstall exe \"pair.exe\" from \"data.txt\"\n");

    try env.write("tool.exe", "mine");
    var asking = try startAsking(env, from);
    defer asking.child.kill(testing.io);
    // these would wait forever if it was holding the lock
    try (try env.run(&.{"installed"})).expectOk();
    const other = try env.manifest("other", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"other.exe\" from \"tool.exe\"\n");
    try (try env.install(other)).expectOut("installed other");
    // something new appears, which nobody has said yes to
    try env.write("pair.exe", "mine too");
    const appeared = try asking.answer("y\n");
    try appeared.expectError("pair.exe' has appeared");
    try testing.expectEqualStrings("mine", try env.read("tool.exe"));
    try testing.expectEqualStrings("mine too", try env.read("pair.exe"));
    try env.expectSettled();

    // something it was asked about goes away, which there's no harm in
    try env.bin.deleteFile(testing.io, "pair.exe");
    asking = try startAsking(env, from);
    try env.bin.deleteFile(testing.io, "tool.exe");
    try (try asking.answer("y\n")).expectOut("installed pair");
    try (try env.uninstall("pair")).expectOk();

    // another package takes it, which even a yes doesn't get past
    try env.write("tool.exe", "mine");
    asking = try startAsking(env, from);
    try env.bin.deleteFile(testing.io, "tool.exe");
    const taker = try env.manifest("taker", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"tool.exe\"\n");
    try (try env.install(taker)).expectOut("installed taker");
    try (try asking.answer("y\n")).expectError("it belongs to");
    try env.expectFiles("other.exe tool.exe");
    try env.expectSettled();
}

test "a package installing over winbin is only asked about, like anything else" {
    for ([_][]const u8{
        "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"winbin.exe\" from \"tool.exe\"\n",
        "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"WinBin.exe\" from \"tool.exe\"\n",
        "let v = \"winbin.exe\"\ndownload \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"{v}\" from \"tool.exe\"\n",
        "download \"{site}/flat.zip\"\nextract\ninstall dir \"winbin.exe\" from \".\"\n",
        "download \"{site}/flat.zip\"\nextract\ninstall dir \"d\" from \".\"\ninstall exelink \"winbin.exe\" -> \"d/tool.exe\"\n",
    }) |text| {
        const env = try Env.init();
        defer env.deinit();
        try env.serveZip("flat.zip", &flat_entries);
        const original = try env.read("winbin.exe");
        const from = try env.manifest("self", text);

        const unanswered = try env.run(&.{ "install", "--non-interactive", from });
        try unanswered.expectError(non_interactive_message);
        try testing.expect(std.mem.find(u8, unanswered.stderr, "is it running") == null);
        try testing.expectEqualStrings(original, try env.read("winbin.exe"));

        var asking = try startAsking(env, from);
        try (try asking.answer("n\n")).expectError("user cancelled install");
        try testing.expectEqualStrings(original, try env.read("winbin.exe"));

        // whether it's a good idea is the person's to decide
        asking = try startAsking(env, from);
        try (try asking.answer("y\n")).expectOut("installed self");
    }
}

test "a package can't replace winbin's own directory" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const output = try env.install(try env.manifest("self", "download \"{site}/flat.zip\"\nextract\ninstall dir \".winbin\" from \".\"\n"));
    try output.expectError("a directory is installed as a plain name");
    try expectNotAsked(output);
}

test "a replaced exe is left alone, until it's deleted" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const from = try env.manifest("plain", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"plain.exe\" from \"tool.exe\"\n");
    try (try env.install(from)).expectOk();
    try env.write("plain.exe", "replaced");
    const message = try std.fmt.allocPrint(env.a(), "isn't the file {s} installed", .{from});
    try (try env.install(from)).expectError(message);
    try (try env.update(from)).expectError(message);
    try (try env.uninstall("plain")).expectError(message);
    try testing.expectEqualStrings("replaced", try env.read("plain.exe"));

    try env.bin.deleteFile(testing.io, "plain.exe");
    try (try env.install(from)).expectOut("plain.exe is missing");
    try testing.expectEqualStrings("the exe", try env.read("plain.exe"));
}

test "an exelink runs its target, and can be updated while it's running" {
    const env = try Env.init();
    defer env.deinit();
    const real = try env.realExe();
    for ([_][]const u8{ "1.0", "2.0" }) |version| {
        try env.serveZip(try std.fmt.allocPrint(env.a(), "ping-{s}.zip", .{version}), &.{
            .{ .name = try std.fmt.allocPrint(env.a(), "ping-{s}/ping.exe", .{version}), .data = real },
        });
    }
    const v1 = try env.manifest("ping", "let v = \"1.0\"\ndownload \"{site}/ping-{v}.zip\"\nextract\ninstall dir \"ping-{v}\"\ninstall exelink \"ping.exe\" -> \"ping-{v}/ping.exe\"\n");
    try (try env.install(v1)).expectOk();
    try env.expectFiles("ping-1.0 ping.exe");

    const link = try std.fs.path.join(env.a(), &.{ env.bin_path, "ping.exe" });
    const ok = try std.process.run(env.a(), testing.io, .{ .argv = &.{ link, "-n", "1", "127.0.0.1" }, .create_no_window = false });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, ok.term);
    // the target's exit code comes through
    const failed = try std.process.run(env.a(), testing.io, .{ .argv = &.{ link, "/nope" }, .create_no_window = false });
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, failed.term);

    var running = try std.process.spawn(testing.io, .{ .argv = &.{ link, "-n", "60", "127.0.0.1" }, .stdout = .ignore, .stderr = .ignore, .create_no_window = false });
    defer running.kill(testing.io);
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    const v2 = try env.manifest("ping", "let v = \"2.0\"\ndownload \"{site}/ping-{v}.zip\"\nextract\ninstall dir \"ping-{v}\"\ninstall exelink \"ping.exe\" -> \"ping-{v}/ping.exe\"\n");
    try (try env.update(v2)).expectOk();
    try testing.expect(env.exists("ping-2.0\\ping.exe"));
    try testing.expect(!env.exists("ping-1.0"));
    const updated = try std.process.run(env.a(), testing.io, .{ .argv = &.{ link, "-n", "1", "127.0.0.1" }, .create_no_window = false });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, updated.term);
    running.kill(testing.io);

    // whatever a link does to its target, give the system a moment to let go of it
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        try (try env.run(&.{"installed"})).expectOk();
        if (!env.exists(".winbin\\delete")) break;
        if (attempts == 20) return error.TestUnexpectedResult;
        try testing.io.sleep(.fromMilliseconds(250), .awake);
    }
    try env.expectFiles("ping-2.0 ping.exe");
    try env.expectSettled();
}

test "the folder can be moved" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("ping.zip", &.{.{ .name = "p/ping.exe", .data = try env.realExe() }});
    try (try env.install(try env.manifest("p", "download \"{site}/ping.zip\"\nextract\ninstall dir \"p\"\ninstall exelink \"pl.exe\" -> \"p/ping.exe\"\n"))).expectOk();
    env.bin.close(testing.io);
    try env.tmp.dir.rename("bin", env.tmp.dir, "moved", testing.io);
    env.bin = try env.tmp.dir.openDir(testing.io, "moved", .{ .iterate = true });
    const moved = try env.tmp.dir.realPathFileAlloc(testing.io, "moved\\pl.exe", env.a());
    const ran = try std.process.run(env.a(), testing.io, .{ .argv = &.{ moved, "-n", "1", "127.0.0.1" }, .create_no_window = false });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, ran.term);
}

test "lookups: JSON, text and a redirect" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("widget-2.0-x.zip", &.{.{ .name = "widget.exe", .data = "w" }});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try env.site.readFileAlloc(testing.io, "widget-2.0-x.zip", env.a(), .unlimited), &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try env.site.writeFile(testing.io, .{ .sub_path = "index.json", .data = try std.fmt.allocPrint(env.a(),
        \\{{ "master": {{ "t": {{ "u": "nope" }} }},
        \\   "1.10.0": {{ "t": {{ "u": "{s}widget-2.0-x.zip", "h": "{s}" }} }},
        \\   "1.9.0": {{ "t": {{ "u": "older" }} }} }}
    , .{ try env.url(""), &hex }) });
    try (try env.install(try env.manifest("newest",
        \\let arch = "t"
        \\let index = @fetch("{site}/index.json")
        \\let versions = @json_keys(index, "/{*}/{arch}/u", except="master")
        \\let version = @newest(versions, @compare_version)
        \\let url = @json_value(index, "/{version}/{arch}/u")
        \\let hash = @json_value(index, "/{version}/{arch}/h")
        \\
        \\download url
        \\verify "sha256:{hash}"
        \\extract
        \\install exe "widget.exe"
        \\
    ))).expectOut("installed newest");

    try env.bin.deleteFile(testing.io, "widget.exe");
    try (try env.uninstall("newest")).expectOk();

    try (try env.install(try env.manifest("noexcept",
        \\let index = @fetch("{site}/index.json")
        \\let versions = @json_keys(index, "/{*}/t/u")
        \\let version = @newest(versions, @compare_version)
        \\download "{site}/widget-2.0-x.zip"
        \\install exe "widget.exe" from "widget-2.0-x.zip"
        \\
    ))).expectError("can't read the key 'master'");

    try env.site.writeFile(testing.io, .{ .sub_path = "latest.txt", .data = "name 2.0-x\n" });
    try (try env.install(try env.manifest("text",
        \\let page = @fetch("{site}/latest.txt")
        \\let version = @match_text(page, "name {*}")
        \\download "{site}/widget-{version}.zip"
        \\extract
        \\install exe "widget.exe"
        \\
    ))).expectOut("installed text");
    try (try env.uninstall("text")).expectOk();

    try env.site.writeFile(testing.io, .{ .sub_path = "twice.txt", .data = "v1\nv2\n" });
    try (try env.install(try env.manifest("twice",
        \\let page = @fetch("{site}/twice.txt")
        \\let version = @match_text(page, "v{*}")
        \\download "{site}/widget-{version}.zip"
        \\install exe "widget.exe"
        \\
    ))).expectError("has to match exactly once");

    try env.site.writeFile(testing.io, .{ .sub_path = "go.redirect", .data = try env.url("dl-2.0-x/widget") });
    try (try env.install(try env.manifest("redir",
        \\let location = @fetch_redirect("{site}/go")
        \\let version = @match_text(location, "/dl-{*}/widget")
        \\download "{site}/widget-{version}.zip"
        \\extract
        \\install exe "widget.exe"
        \\
    ))).expectOut("installed redir");

    try (try env.install(try env.manifest("noredirect",
        \\let location = @fetch_redirect("{site}/latest.txt")
        \\download "{site}/widget-2.0-x.zip"
        \\install exe "w.exe" from "widget-2.0-x.zip"
        \\
    ))).expectError("expected a redirect");
    try (try env.install(try env.manifest("is404",
        \\let page = @fetch("{site}/missing.txt")
        \\let version = @match_text(page, "v{*}")
        \\download "{site}/widget-{version}.zip"
        \\install exe "w.exe"
        \\
    ))).expectError("Not Found");
    try (try env.install(try env.manifest("notjson",
        \\let page = @fetch("{site}/latest.txt")
        \\let version = @json_value(page, "/a")
        \\download "{site}/widget-{version}.zip"
        \\install exe "w.exe"
        \\
    ))).expectError("isn't valid JSON");
}

test "a package that isn't for this arch says so" {
    const env = try Env.init();
    defer env.deinit();
    const builtin = @import("builtin");
    const other = if (builtin.cpu.arch == .x86) "aarch64" else "x86";
    try (try env.install(try env.manifest("other", try std.fmt.allocPrint(env.a(),
        \\let arch = @map_arch({s}="a")
        \\download "{{site}}/a.zip"
        \\install exe "a.exe"
        \\
    , .{other})))).expectError("isn't available for");
}

test "a word winbin doesn't know might be from a newer winbin" {
    const env = try Env.init();
    defer env.deinit();
    const hint = "may need a newer winbin";
    try (try env.install(try env.manifest("hint", "nonsense\n"))).expectError("to update it, run this in PowerShell: irm https://winbin-org.github.io/install.ps1 | iex");
    try (try env.install(try env.manifest("a", "let x = @frobnicate(\"y\")\ndownload \"{site}/a.zip\"\ninstall exe \"a.exe\"\n"))).expectError(hint);
    try (try env.install(try env.manifest("b", "mirror \"https://e.com/\"\ndownload \"{site}/a.zip\"\ninstall exe \"a.exe\"\n"))).expectError(hint);
}

test "a record doesn't depend on being able to read its manifest" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    const record_path = (try env.recordOf("tool")).?;
    const record = try env.read(record_path);
    const manifest_start = std.mem.find(u8, record, "let v").?;
    try env.write(record_path, try std.mem.concat(env.a(), u8, &.{ record[0..manifest_start], "frobnicate \"this\"\n@@@\n" }));
    try (try env.run(&.{"installed"})).expectOut("tool");
    try (try env.uninstall("tool")).expectOut("uninstalled tool");
    try env.expectFiles("");
}

test "a bad record doesn't block the others" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const manifest_text = "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"{name}.exe\" from \"tool.exe\"\n";
    for ([_][]const u8{ "pkga", "pkgb" }) |name| {
        const text = try std.mem.replaceOwned(u8, env.a(), manifest_text, "{name}", name);
        try (try env.install(try env.manifest(name, text))).expectOk();
    }
    const record_path = (try env.recordOf("pkga")).?;
    const size = (try env.read(record_path)).len;
    const zeros = try env.a().alloc(u8, size);
    @memset(zeros, 0);
    try env.write(record_path, zeros);

    const listed = try env.run(&.{"installed"});
    try listed.expectOut("pkgb");
    try testing.expect(std.mem.find(u8, listed.stderr, "is invalid") != null);
    try testing.expect(std.mem.find(u8, listed.stderr, "pkga-") != null);
    try (try env.install(try env.urlOf("pkga"))).expectError("To reinstall it, delete");
    try (try env.uninstall("pkga")).expectError("To reinstall it, delete");
}

fn runTogether(env: *Env, comptime count: usize, args: [count][]const []const u8) !void {
    var children: [count]std.process.Child = undefined;
    for (&children, args) |*child, arg| child.* = try env.spawn(arg);
    for (&children) |*child| {
        const term = try child.wait(testing.io);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    }
}

test "different packages at the same time" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    var args: [8][]const []const u8 = undefined;
    for (&args, 0..) |*arg, i| {
        const name = try std.fmt.allocPrint(env.a(), "pkg{d}", .{i});
        const from = try env.manifest(name, try std.fmt.allocPrint(env.a(), "download \"{{site}}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"{s}.exe\" from \"tool.exe\"\n", .{name}));
        arg.* = try env.a().dupe([]const u8, &.{ "install", from });
    }
    for (0..3) |_| {
        try runTogether(env, 8, args);
        try env.expectFiles("pkg0.exe pkg1.exe pkg2.exe pkg3.exe pkg4.exe pkg5.exe pkg6.exe pkg7.exe");
        try env.expectSettled();
        try testing.expectEqual(0, try env.tmpCount());
        for (0..8) |i| try (try env.uninstall(try std.fmt.allocPrint(env.a(), "pkg{d}", .{i}))).expectOk();
    }
}

test "the same package at the same time" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    const from = try toolManifest(env, "1.0");
    const arg: []const []const u8 = &.{ "install", from };
    for (0..3) |_| {
        try runTogether(env, 4, .{ arg, arg, arg, arg });
        try env.expectFiles("tool-1.0 tool.exe");
        try env.expectSettled();
        try testing.expectEqual(0, try env.tmpCount());
        try (try env.uninstall("tool")).expectOk();
    }
}

test "two packages claiming the same exe: one gets it, the other gets an error" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.site.writeFile(testing.io, .{ .sub_path = "bare.exe", .data = "other" });
    const one = try env.manifest("claim1", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"shared.exe\" from \"tool.exe\"\n");
    const two = try env.manifest("claim2", "download \"{site}/bare.exe\"\ninstall exe \"shared.exe\" from \"bare.exe\"\n");
    for (0..10) |_| {
        var first = try env.spawn(&.{ "install", one });
        var second = try env.spawn(&.{ "install", two });
        const a = try first.wait(testing.io);
        const b = try second.wait(testing.io);
        const installed_one = try env.recordOf("claim1") != null;
        const installed_two = try env.recordOf("claim2") != null;
        try testing.expect(installed_one != installed_two);
        const successes = @intFromBool(a == .exited and a.exited == 0) + @intFromBool(b == .exited and b.exited == 0);
        try testing.expectEqual(1, successes);
        try (try env.uninstall(if (installed_one) "claim1" else "claim2")).expectOk();
        try env.expectFiles("");
    }
}

/// A package with enough in it that moving it into place takes a while.
const many_exes = 120;

fn serveMany(env: *Env, version: []const u8) ![]const u8 {
    const a = env.a();
    var entries: std.ArrayList(Entry) = .empty;
    try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "tree-{s}/version.txt", .{version}), .data = version });
    try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "tree-{s}/run.exe", .{version}), .data = "run" });
    var manifest_text: std.ArrayList(u8) = .empty;
    try manifest_text.print(a, "let v = \"{s}\"\ndownload \"{{site}}/many-{{v}}.zip\"\nextract\n", .{version});
    for (0..many_exes) |i| {
        try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "bin/m{d}.exe", .{i}), .data = try std.fmt.allocPrint(a, "{s} {d}", .{ version, i }) });
        try manifest_text.print(a, "install exe \"m{d}.exe\" from \"bin/m{d}.exe\"\n", .{ i, i });
    }
    try manifest_text.appendSlice(a, "install dir \"tree-{v}\"\ninstall exelink \"manyrun.exe\" -> \"tree-{v}/run.exe\"\n");
    try env.serveZip(try std.fmt.allocPrint(a, "many-{s}.zip", .{version}), entries.items);
    return manifest_text.items;
}

fn expectManyAt(env: *Env, version: []const u8) !void {
    for (0..many_exes) |i| {
        const name = try std.fmt.allocPrint(env.a(), "m{d}.exe", .{i});
        const expected = try std.fmt.allocPrint(env.a(), "{s} {d}", .{ version, i });
        try testing.expectEqualStrings(expected, try env.read(name));
    }
    try testing.expectEqualStrings(version, try env.read(try std.fmt.allocPrint(env.a(), "tree-{s}\\version.txt", .{version})));
    try testing.expect(env.exists("manyrun.exe"));
    var it = env.bin.iterate();
    var dirs: usize = 0;
    while (try it.next(testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "tree-")) dirs += 1;
    }
    try testing.expectEqual(1, dirs);
    try env.expectSettled();
}

/// Starts a command and kills it some way into making its change, returning whether
/// that left a journal for the next winbin to finish.
fn killDuringChange(env: *Env, args: []const []const u8, delay_ms: f64) !bool {
    var child = try env.spawn(args);
    defer child.kill(testing.io);
    const clock: std.Io.Clock = .awake;
    const start = clock.now(testing.io);
    var seen: ?std.Io.Timestamp = null;
    while (true) {
        const now = clock.now(testing.io);
        if (seen) |at| {
            if (@as(f64, @floatFromInt(at.durationTo(now).toNanoseconds())) / std.time.ns_per_ms >= delay_ms) break;
        } else if (env.exists(".winbin\\journal")) {
            seen = now;
        }
        // it finished before it was caught, or never got that far
        if (start.durationTo(now).toSeconds() >= 10) break;
    }
    child.kill(testing.io);
    return env.exists(".winbin\\journal");
}

test "killed while updating: the next winbin finishes it, whatever it was doing" {
    const env = try Env.init();
    defer env.deinit();
    const v1 = try serveMany(env, "1.0");
    const v2 = try serveMany(env, "2.0");
    const from = try env.manifest("many", v1);
    try (try env.install(from)).expectOk();
    try expectManyAt(env, "1.0");

    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    var caught: usize = 0;
    var version: []const u8 = "1.0";
    for (0..25) |round| {
        const going_to_v2 = std.mem.eql(u8, version, "1.0");
        version = if (going_to_v2) "2.0" else "1.0";
        _ = try env.manifest("many", if (going_to_v2) v2 else v1);
        const left_journal = try killDuringChange(env, &.{ "update", from }, random.float(f64) * 8);
        if (left_journal) caught += 1;

        // sometimes the one finishing it gets killed too
        if (left_journal and round % 3 == 0) {
            var finisher = try env.spawn(&.{"installed"});
            try testing.io.sleep(.fromNanoseconds(@intFromFloat(random.float(f64) * 4 * std.time.ns_per_ms)), .awake);
            finisher.kill(testing.io);
        }

        const listed = try env.run(&.{"installed"});
        try listed.expectOk();
        if (left_journal) {
            // it was already decided, there's nothing more to download
            try expectManyAt(env, version);
            const after = try env.update(from);
            try after.expectOut("already the latest version");
        } else {
            try (try env.update(from)).expectOk();
            try expectManyAt(env, version);
        }
    }
    // otherwise this hasn't tested what it says it has
    try testing.expect(caught >= 10);
}

test "killed while uninstalling: it's all there or all gone" {
    const env = try Env.init();
    defer env.deinit();
    const from = try env.manifest("many", try serveMany(env, "1.0"));
    try (try env.install(from)).expectOk();

    var prng: std.Random.DefaultPrng = .init(2);
    const random = prng.random();
    var caught: usize = 0;
    for (0..12) |_| {
        if (try killDuringChange(env, &.{ "uninstall", from }, random.float(f64) * 4)) caught += 1;
        try (try env.run(&.{"installed"})).expectOk();
        try env.expectSettled();
        if (try env.recordOf("many") != null) {
            try expectManyAt(env, "1.0");
            try (try env.uninstall("many")).expectOk();
        }
        try env.expectFiles("");
        try (try env.install(from)).expectOk();
    }
    try testing.expect(caught >= 5);
}

test "a journal left part way through is finished" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    const record_path = (try env.recordOf("tool")).?;
    const record_file = std.fs.path.basename(record_path);
    const old = try env.read(record_path);
    const new_record = try std.mem.replaceOwned(u8, env.a(), old, "tool-1.0", "tool-2.0");

    // the link has already moved, the new directory hasn't
    try env.bin.createDirPath(testing.io, ".winbin\\publish\\tool-2.0\\share");
    try env.write(".winbin\\publish\\tool-2.0\\share\\version.txt", "2.0");
    try env.write(".winbin\\journal", try std.mem.concat(env.a(), u8, &.{ "record-file ", record_file, "\nretire-dir tool-1.0\nrecord\n", new_record }));
    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try env.expectFiles("tool-2.0 tool.exe");
    try env.expectSettled();
    try testing.expect(std.mem.find(u8, try env.read(record_path), "installed-dir tool-2.0") != null);

    // anything taking the lock finishes it first
    try env.write(".winbin\\journal", try std.mem.concat(env.a(), u8, &.{ "record-file ", record_file, "\nremove-file tool.exe\nremove-dir tool-2.0\ndelete-record\n" }));
    try (try env.uninstall("tool")).expectError("isn't installed");
    try env.expectFiles("");
    try env.expectSettled();
}

test "a journal left part way through replacing what was in the way is finished" {
    const env = try Env.init();
    defer env.deinit();
    const data = "the exe";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const new_record = try std.fmt.allocPrint(env.a(),
        \\installed-url https://e.com/x.zip
        \\installed-hash sha256:{s}
        \\installed-exe x.exe sha256:{s}
        \\installed-dir d
        \\installed-from file:///C:/pkgs/x
        \\the manifest
        \\
    , .{ &hex, &hex });
    try env.bin.createDirPath(testing.io, ".winbin\\installed");
    // a directory where the exe goes, and a file where the directory goes
    try env.bin.createDirPath(testing.io, "x.exe\\sub");
    try env.write("d", "in the way");
    try env.bin.createDirPath(testing.io, ".winbin\\publish\\d");
    try env.write(".winbin\\publish\\d\\new.txt", "new");
    try env.write(".winbin\\publish\\x.exe", data);
    try env.write(".winbin\\journal", try std.mem.concat(env.a(), u8, &.{ "record-file x-0123456789abcdef\nrecord\n", new_record }));
    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try env.expectFiles("d x.exe");
    try testing.expectEqualStrings(data, try env.read("x.exe"));
    try testing.expectEqualStrings("new", try env.read("d\\new.txt"));
    try env.expectSettled();
}

test "what's still being deleted isn't in the way of what's next to be deleted" {
    const env = try Env.init();
    defer env.deinit();
    const data = "the exe";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const new_record = try std.fmt.allocPrint(env.a(),
        \\installed-url https://e.com/x.zip
        \\installed-hash sha256:{s}
        \\installed-dir d
        \\installed-from file:///C:/pkgs/x
        \\the manifest
        \\
    , .{&hex});
    try env.bin.createDirPath(testing.io, ".winbin\\installed");
    try env.bin.createDirPath(testing.io, "d");
    try env.write("d\\old.txt", "old");
    try env.bin.createDirPath(testing.io, ".winbin\\publish\\d");
    try env.write(".winbin\\publish\\d\\new.txt", "new");

    // an earlier d that can't be deleted yet, because something in it is running
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\d");
    try env.write(".winbin\\delete\\d\\running.exe", try env.realExe());
    const running_exe = try std.fs.path.join(env.a(), &.{ env.bin_path, ".winbin\\delete\\d\\running.exe" });
    var running = try std.process.spawn(testing.io, .{ .argv = &.{ running_exe, "-n", "60", "127.0.0.1" }, .stdout = .ignore, .stderr = .ignore, .create_no_window = false });
    var killed = false;
    defer if (!killed) running.kill(testing.io);
    try testing.io.sleep(.fromMilliseconds(300), .awake);

    try env.write(".winbin\\journal", try std.mem.concat(env.a(), u8, &.{ "record-file x-0123456789abcdef\nrecord\n", new_record }));
    const output = try env.run(&.{"installed"});
    try output.expectOut("finishing what an earlier winbin was doing");
    try testing.expectEqualStrings("", output.stderr);
    try testing.expectEqualStrings("new", try env.read("d\\new.txt"));
    try testing.expect(!env.exists("d\\old.txt"));
    try testing.expect(env.exists(".winbin\\delete\\d\\running.exe"));
    try testing.expect(!env.exists(".winbin\\journal"));

    // the next winbin after it's stopped finishes the job
    running.kill(testing.io);
    killed = true;
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "no network fails saying so, and changes nothing" {
    const env = try Env.init();
    defer env.deinit();
    try env.write("keep.exe", "keep");
    const unreachable_url = "http://127.0.0.1:1";
    const download = try env.install(try env.manifest("down", "download \"" ++ unreachable_url ++ "/x.zip\"\nextract\ninstall exe \"x.exe\"\n"));
    try download.expectError("can't connect");
    const fetched = try env.install(try env.manifest("fetched", "let r = @fetch(\"" ++ unreachable_url ++ "/x\")\nlet u = @json_value(r, \"/u\")\ndownload u\nextract\ninstall exe \"x.exe\"\n"));
    try fetched.expectError("can't connect");
    try env.expectFiles("keep.exe");
    try env.expectSettled();
    try testing.expectEqualStrings("keep", try env.read("keep.exe"));
}

/// A journal part way through replacing `d`, with what's replacing it ready to go.
fn writeJournalReplacingD(env: *Env) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("the exe", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const new_record = try std.fmt.allocPrint(env.a(),
        \\installed-url https://e.com/x.zip
        \\installed-hash sha256:{s}
        \\installed-dir d
        \\installed-from file:///C:/pkgs/x
        \\the manifest
        \\
    , .{&hex});
    try env.bin.createDirPath(testing.io, ".winbin\\installed");
    try env.bin.createDirPath(testing.io, ".winbin\\publish\\d");
    try env.write(".winbin\\publish\\d\\new.txt", "new");
    try env.write(".winbin\\journal", try std.mem.concat(env.a(), u8, &.{ "record-file x-0123456789abcdef\nrecord\n", new_record }));
}

/// Copies an exe that keeps running to `path`, and starts it.
fn startRunning(env: *Env, path: []const u8) !std.process.Child {
    try env.write(path, try env.realExe());
    const exe = try std.fs.path.join(env.a(), &.{ env.bin_path, path });
    const child = try std.process.spawn(testing.io, .{ .argv = &.{ exe, "-n", "60", "127.0.0.1" }, .stdout = .ignore, .stderr = .ignore, .create_no_window = false });
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    return child;
}

/// Something with `path` as its current directory, which stops a directory being moved.
fn startWorkingIn(env: *Env, path: []const u8) !std.process.Child {
    const cwd = try std.fs.path.join(env.a(), &.{ env.bin_path, path });
    const child = try std.process.spawn(testing.io, .{
        .argv = &.{ "C:\\Windows\\System32\\PING.EXE", "-n", "60", "127.0.0.1" },
        .cwd = .{ .path = cwd },
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = false,
    });
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    return child;
}

/// A directory outside of what winbin manages, and a junction in `path` that points to it.
fn makeJunctionToPrecious(env: *Env, path: []const u8) !void {
    try env.tmp.dir.createDirPath(testing.io, "elsewhere");
    try env.tmp.dir.writeFile(testing.io, .{ .sub_path = "elsewhere\\precious.txt", .data = "precious" });
    const target = try env.tmp.dir.realPathFileAlloc(testing.io, "elsewhere", env.a());
    const link = try std.fs.path.join(env.a(), &.{ env.bin_path, path });
    const made = try std.process.run(env.a(), testing.io, .{ .argv = &.{ "cmd", "/c", "mklink", "/J", link, target }, .create_no_window = false });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, made.term);
}

fn expectPreciousIsThere(env: *Env) !void {
    try testing.expectEqualStrings("precious", try env.tmp.dir.readFileAlloc(testing.io, "elsewhere\\precious.txt", env.a(), .unlimited));
}

test "deleting: a name that's taken goes to .1, then .2, whichever is free" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, "d");
    try env.write("d\\old.txt", "old");
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\d");
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\d.1");
    var first = try startRunning(env, ".winbin\\delete\\d\\running.exe");
    defer first.kill(testing.io);
    var second = try startRunning(env, ".winbin\\delete\\d.1\\running.exe");
    defer second.kill(testing.io);
    try writeJournalReplacingD(env);

    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try testing.expectEqualStrings("new", try env.read("d\\new.txt"));
    try testing.expect(!env.exists("d\\old.txt"));
    try testing.expect(!env.exists(".winbin\\journal"));
}

test "deleting: a name that only differs by case is still taken" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, "d");
    try env.write("d\\old.txt", "old");
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\D");
    var running = try startRunning(env, ".winbin\\delete\\D\\running.exe");
    defer running.kill(testing.io);
    try writeJournalReplacingD(env);

    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try testing.expectEqualStrings("new", try env.read("d\\new.txt"));
    try testing.expect(env.exists(".winbin\\delete\\D\\running.exe"));
}

test "deleting: what's left from before is cleaned up by the next winbin" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\d\\a\\b\\c\\d\\e\\f");
    try env.write(".winbin\\delete\\d\\a\\b\\c\\d\\e\\f\\deep.txt", "deep");
    try env.write(".winbin\\delete\\file.exe", "file");
    try env.write(".winbin\\delete\\file.exe.1", "file");
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "deleting: it doesn't follow a junction out of what's being deleted" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\d");
    try makeJunctionToPrecious(env, ".winbin\\delete\\d\\link");
    try (try env.run(&.{"installed"})).expectOk();
    try expectPreciousIsThere(env);
    try env.expectSettled();
}

test "deleting: a junction directly in the delete directory isn't followed" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, ".winbin\\delete");
    try makeJunctionToPrecious(env, ".winbin\\delete\\link");
    try (try env.run(&.{"installed"})).expectOk();
    try expectPreciousIsThere(env);
    try env.expectSettled();
}

test "deleting: the delete directory itself being a junction isn't followed" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, ".winbin");
    try makeJunctionToPrecious(env, ".winbin\\delete");
    try (try env.run(&.{"installed"})).expectOk();
    try expectPreciousIsThere(env);
}

test "deleting: a file where the delete directory goes doesn't get in the way" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, ".winbin");
    try env.write(".winbin\\delete", "a file");
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();

    try env.write(".winbin\\delete", "a file");
    try env.bin.createDirPath(testing.io, "d");
    try writeJournalReplacingD(env);
    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try testing.expectEqualStrings("new", try env.read("d\\new.txt"));
    try env.expectSettled();
}

test "deleting: a read-only file doesn't stop anything" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\d");
    try env.write(".winbin\\delete\\d\\readonly.txt", "readonly");
    const path = try std.fs.path.join(env.a(), &.{ env.bin_path, ".winbin\\delete\\d\\readonly.txt" });
    try attrib(env, "+r", path);
    defer attrib(env, "-r", path) catch {};
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "deleting: a journal finished twice, already moved or not, ends up the same" {
    const env = try Env.init();
    defer env.deinit();

    // what's being replaced has already been moved out of the way
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\d");
    try env.write(".winbin\\delete\\d\\old.txt", "old");
    try writeJournalReplacingD(env);
    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try testing.expectEqualStrings("new", try env.read("d\\new.txt"));
    try env.expectSettled();

    // and the new one has already been moved into place
    try env.bin.createDirPath(testing.io, ".winbin\\delete\\d");
    try env.write(".winbin\\delete\\d\\old.txt", "old");
    try writeJournalReplacingD(env);
    try env.bin.deleteTree(testing.io, ".winbin\\publish\\d");
    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try testing.expectEqualStrings("new", try env.read("d\\new.txt"));
    try env.expectSettled();
}

test "deleting: uninstalling doesn't follow a junction in a package's directory" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    try makeJunctionToPrecious(env, "tool-1.0\\link");
    try (try env.uninstall("tool")).expectOk();
    try expectPreciousIsThere(env);
    try env.expectFiles("");
    try env.expectSettled();
}

test "deleting: updating doesn't follow a junction in the old version's directory" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try serveTool(env, "2.0");
    const from = try toolManifest(env, "1.0");
    try (try env.install(from)).expectOk();
    try makeJunctionToPrecious(env, "tool-1.0\\link");
    _ = try toolManifest(env, "2.0");
    try (try env.update(from)).expectOk();
    try expectPreciousIsThere(env);
    try env.expectFiles("tool-2.0 tool.exe");
    try env.expectSettled();
}

test "deleting: replacing a directory doesn't follow a junction in it" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, "d");
    try makeJunctionToPrecious(env, "d\\link");
    try writeJournalReplacingD(env);
    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try expectPreciousIsThere(env);
    try testing.expectEqualStrings("new", try env.read("d\\new.txt"));
    try env.expectSettled();
}

test "deleting: uninstalling what's already gone is fine" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    try env.bin.deleteTree(testing.io, "tool-1.0");
    try env.bin.deleteFile(testing.io, "tool.exe");
    try (try env.uninstall("tool")).expectOk();
    try env.expectFiles("");
    try env.expectSettled();
}

test "deleting: uninstalling a read-only exe" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try (try env.install(try env.manifest("one", exeText("one")))).expectOk();
    const path = try std.fs.path.join(env.a(), &.{ env.bin_path, "one.exe" });
    try attrib(env, "+r", path);
    defer attrib(env, "-r", path) catch {};
    try (try env.uninstall("one")).expectOk();
    try env.expectFiles("");
    try env.expectSettled();
}

test "deleting: a read-only file in a package's directory" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    const path = try std.fs.path.join(env.a(), &.{ env.bin_path, "tool-1.0\\share\\version.txt" });
    try attrib(env, "+r", path);
    defer attrib(env, "-r", path) catch {};
    try (try env.uninstall("tool")).expectOk();
    try env.expectFiles("");
    try env.expectSettled();
}

test "deleting: uninstalling with a program running in the package's directory finishes once it stops" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    var running = try startRunning(env, "tool-1.0\\running.exe");
    var killed = false;
    defer if (!killed) running.kill(testing.io);

    const output = try env.uninstall("tool");
    try output.expectOut("uninstalled tool");
    try testing.expectEqualStrings("", output.stderr);
    try testing.expect(!env.exists(".winbin\\journal"));
    try env.expectFiles("");

    // it isn't installed any more, and nothing's stuck
    const listed = try env.run(&.{"installed"});
    try listed.expectOk();
    try testing.expectEqualStrings("", listed.stdout);

    running.kill(testing.io);
    killed = true;
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectFiles("");
    try env.expectSettled();
}

test "deleting: uninstalling a directory something's working in finishes once it stops" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    var running = try startWorkingIn(env, "tool-1.0");
    var killed = false;
    defer if (!killed) running.kill(testing.io);

    const output = try env.uninstall("tool");
    try output.expectOut("uninstalled tool");
    try testing.expect(std.mem.find(u8, output.stderr, "is something in it running?") != null);
    try testing.expect(!env.exists(".winbin\\journal"));
    try testing.expect(env.exists(".winbin\\deferred-cleanup\\tool-1.0"));

    // nothing's stuck, and trying again isn't worth mentioning
    const listed = try env.run(&.{"installed"});
    try listed.expectOk();
    try testing.expectEqualStrings("", listed.stderr);
    try testing.expect(env.exists("tool-1.0\\share\\version.txt"));

    running.kill(testing.io);
    killed = true;
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectFiles("");
    try env.expectSettled();
}

test "uninstalling a running exe moves it aside until it's stopped" {
    const env = try Env.init();
    defer env.deinit();
    const real = try env.realExe();
    try env.serveZip("real.zip", &.{.{ .name = "own.exe", .data = real }});
    try (try env.install(try env.manifest("own", "download \"{site}/real.zip\"\nextract\ninstall exe \"own.exe\"\n"))).expectOk();
    const own_exe = try std.fs.path.join(env.a(), &.{ env.bin_path, "own.exe" });
    var running = try std.process.spawn(testing.io, .{ .argv = &.{ own_exe, "-n", "60", "127.0.0.1" }, .stdout = .ignore, .stderr = .ignore, .create_no_window = false });
    var killed = false;
    defer if (!killed) running.kill(testing.io);
    try testing.io.sleep(.fromMilliseconds(300), .awake);

    const output = try env.uninstall("own");
    try output.expectOut("uninstalled own");
    try testing.expectEqualStrings("", output.stderr);
    try env.expectFiles("");
    try testing.expect(env.exists(".winbin\\delete\\own.exe"));
    try testing.expect(!env.exists(".winbin\\journal"));

    running.kill(testing.io);
    killed = true;
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "updating an exe that's running twice keeps both old ones out of the way" {
    const env = try Env.init();
    defer env.deinit();
    const real = try env.realExe();
    const text = "download \"{site}/real.zip\"\nextract\ninstall exe \"own.exe\"\n";
    try env.serveZip("real.zip", &.{.{ .name = "own.exe", .data = real }});
    const from = try env.manifest("own", text);
    try (try env.install(from)).expectOk();
    const own_exe = try std.fs.path.join(env.a(), &.{ env.bin_path, "own.exe" });
    const argv: []const []const u8 = &.{ own_exe, "-n", "60", "127.0.0.1" };

    var first = try std.process.spawn(testing.io, .{ .argv = argv, .stdout = .ignore, .stderr = .ignore, .create_no_window = false });
    var first_killed = false;
    defer if (!first_killed) first.kill(testing.io);
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    _ = try env.manifest("own", text ++ "\n");
    try (try env.update(from)).expectOk();

    var second = try std.process.spawn(testing.io, .{ .argv = argv, .stdout = .ignore, .stderr = .ignore, .create_no_window = false });
    var second_killed = false;
    defer if (!second_killed) second.kill(testing.io);
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    _ = try env.manifest("own", text ++ "\n\n");
    try (try env.update(from)).expectOk();

    try testing.expect(env.exists(".winbin\\delete\\own.exe"));
    try testing.expect(env.exists(".winbin\\delete\\own.exe.1"));
    try testing.expect(env.exists("own.exe"));

    first.kill(testing.io);
    first_killed = true;
    second.kill(testing.io);
    second_killed = true;
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
    try env.expectFiles("own.exe");
}

test "a directory with something running in it is replaced, and it keeps running" {
    const env = try Env.init();
    defer env.deinit();
    const text = "download \"{site}/dir.zip\"\nextract\ninstall dir \"d\"\n";
    try env.serveZip("dir.zip", &.{.{ .name = "d/a.txt", .data = "one" }});
    const from = try env.manifest("dir", text);
    try (try env.install(from)).expectOk();
    var running = try startRunning(env, "d\\running.exe");
    var killed = false;
    defer if (!killed) running.kill(testing.io);

    try env.serveZip("dir.zip", &.{.{ .name = "d/a.txt", .data = "two" }});
    _ = try env.manifest("dir", text ++ "\n");
    try (try env.update(from)).expectOk();
    try testing.expectEqualStrings("two", try env.read("d\\a.txt"));
    try testing.expect(!env.exists("d\\running.exe"));
    try testing.expect(env.exists(".winbin\\delete\\d\\running.exe"));
    try testing.expect(!env.exists(".winbin\\journal"));

    // it's still running, so it can't be deleted yet
    try (try env.run(&.{"installed"})).expectOk();
    try testing.expect(env.exists(".winbin\\delete\\d\\running.exe"));

    running.kill(testing.io);
    killed = true;
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "a directory something's working in fails before anything changes" {
    const env = try Env.init();
    defer env.deinit();
    const text = "download \"{site}/dir.zip\"\nextract\ninstall dir \"d\"\n";
    try env.serveZip("dir.zip", &.{.{ .name = "d/a.txt", .data = "one" }});
    const from = try env.manifest("dir", text);
    try (try env.install(from)).expectOk();

    var running = try startWorkingIn(env, "d");
    var killed = false;
    defer if (!killed) running.kill(testing.io);

    try env.serveZip("dir.zip", &.{.{ .name = "d/a.txt", .data = "two" }});
    _ = try env.manifest("dir", text ++ "\n");
    const output = try env.update(from);
    try output.expectError("(is something in it running?)");
    try testing.expectEqualStrings("one", try env.read("d\\a.txt"));
    try testing.expect(!env.exists(".winbin\\journal"));
    try env.expectSettled();

    // nothing's stuck, the rest still works
    try (try env.run(&.{"installed"})).expectOk();

    running.kill(testing.io);
    killed = true;
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    try (try env.update(from)).expectOk();
    try testing.expectEqualStrings("two", try env.read("d\\a.txt"));
    try env.expectSettled();
}

test "a journal finishes replacing a running exe" {
    const env = try Env.init();
    defer env.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("the exe", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const new_record = try std.fmt.allocPrint(env.a(),
        \\installed-url https://e.com/x.zip
        \\installed-hash sha256:{s}
        \\installed-exe x.exe sha256:{s}
        \\installed-from file:///C:/pkgs/x
        \\the manifest
        \\
    , .{ &hex, &hex });
    try env.bin.createDirPath(testing.io, ".winbin\\installed");
    var running = try startRunning(env, "x.exe");
    var killed = false;
    defer if (!killed) running.kill(testing.io);
    try env.bin.createDirPath(testing.io, ".winbin\\publish");
    try env.write(".winbin\\publish\\x.exe", "the exe");
    try env.write(".winbin\\journal", try std.mem.concat(env.a(), u8, &.{ "record-file x-0123456789abcdef\nrecord\n", new_record }));

    try (try env.run(&.{"installed"})).expectOut("finishing what an earlier winbin was doing");
    try testing.expectEqualStrings("the exe", try env.read("x.exe"));
    try testing.expect(!env.exists(".winbin\\journal"));
    try testing.expect(env.exists(".winbin\\delete\\x.exe"));

    running.kill(testing.io);
    killed = true;
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "winbin updates itself like any other package" {
    const env = try Env.init();
    defer env.deinit();
    const original = try env.read("winbin.exe");
    const one = try std.mem.concat(env.a(), u8, &.{ original, "one" });
    const two = try std.mem.concat(env.a(), u8, &.{ original, "two" });
    const text = "download \"{site}/winbin.zip\"\nextract\ninstall exe \"winbin.exe\"\ninstall pdb \"winbin.pdb\"\n";
    try env.serveZip("winbin.zip", &.{ .{ .name = "winbin.exe", .data = one }, .{ .name = "winbin.pdb", .data = "pdb one" } });
    const from = try env.manifest("winbin", text);

    // not installed by winbin yet, so it's asked about
    try (try env.run(&.{ "install", "--non-interactive", from })).expectError(non_interactive_message);
    var asking = try startAsking(env, from);
    const installed = try asking.answer("y\n");
    try installed.expectOut("installed winbin");
    try testing.expectEqualStrings(one, try env.read("winbin.exe"));
    try testing.expect(!env.exists("winbin.pdb"));

    // and the new one runs, cleans up after the old one, and knows it's installed
    const listed = try env.run(&.{"installed"});
    try listed.expectOk();
    try testing.expect(std.mem.find(u8, listed.stdout, "winbin") != null);
    try env.expectSettled();
    try (try env.install(from)).expectOut("is already installed");

    // an update isn't asked about, and takes effect the same way
    try env.serveZip("winbin.zip", &.{ .{ .name = "winbin.exe", .data = two }, .{ .name = "winbin.pdb", .data = "pdb two" } });
    _ = try env.manifest("winbin", text ++ "\n");
    const updated = try env.run(&.{ "update", "--non-interactive", from });
    try updated.expectOut("reinstalled winbin");
    try testing.expectEqualStrings(two, try env.read("winbin.exe"));
    try (try env.run(&.{"--version"})).expectOk();
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();

    // a PDB comes along like any other package's
    try (try env.run(&.{ "install", "--pdbs", from })).expectOut("reinstalled winbin");
    try testing.expectEqualStrings("pdb two", try env.read("winbin.pdb"));
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectSettled();
}

test "deleting: updating with a program running in the old version's directory" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try serveTool(env, "2.0");
    const from = try toolManifest(env, "1.0");
    try (try env.install(from)).expectOk();
    var running = try startRunning(env, "tool-1.0\\running.exe");
    var killed = false;
    defer if (!killed) running.kill(testing.io);

    _ = try toolManifest(env, "2.0");
    const output = try env.update(from);
    try output.expectOk();
    try testing.expectEqualStrings("", output.stderr);
    try env.expectFiles("tool-2.0 tool.exe");
    try testing.expect(!env.exists(".winbin\\journal"));
    try testing.expect(env.exists(".winbin\\delete\\tool-1.0\\running.exe"));

    running.kill(testing.io);
    killed = true;
    const finished = try env.run(&.{"installed"});
    try finished.expectOk();
    try testing.expectEqualStrings("", finished.stderr);
    try env.expectSettled();
}

test "deleting: updating with something working in the old version's directory" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try serveTool(env, "2.0");
    const from = try toolManifest(env, "1.0");
    try (try env.install(from)).expectOk();
    var running = try startWorkingIn(env, "tool-1.0");
    var killed = false;
    defer if (!killed) running.kill(testing.io);

    _ = try toolManifest(env, "2.0");
    const output = try env.update(from);
    try output.expectOk();
    try testing.expect(std.mem.find(u8, output.stderr, "couldn't delete") != null);
    try testing.expect(env.exists("tool-2.0\\share\\version.txt"));
    try testing.expect(!env.exists(".winbin\\journal"));
    try testing.expect(env.exists(".winbin\\deferred-cleanup\\tool-1.0"));

    // trying again while it's in use doesn't change anything, or say anything
    const again = try env.run(&.{"installed"});
    try again.expectOk();
    try testing.expectEqualStrings("", again.stderr);
    try testing.expect(env.exists("tool-1.0\\share\\version.txt"));
    try testing.expect(env.exists(".winbin\\deferred-cleanup\\tool-1.0"));

    running.kill(testing.io);
    killed = true;
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    const finished = try env.run(&.{"installed"});
    try finished.expectOk();
    try testing.expectEqualStrings("", finished.stderr);
    try env.expectFiles("tool-2.0 tool.exe");
    try env.expectSettled();
}

fn writeDeferred(env: *Env, name: []const u8) !void {
    try env.bin.createDirPath(testing.io, ".winbin\\deferred-cleanup");
    try env.write(try std.fmt.allocPrint(env.a(), ".winbin\\deferred-cleanup\\{s}", .{name}), "");
}

test "deferred cleanup: an exe, a directory, and what's already gone" {
    const env = try Env.init();
    defer env.deinit();
    try env.write("old.exe", "old");
    try env.bin.createDirPath(testing.io, "old-1.0\\sub");
    try env.write("old-1.0\\sub\\file.txt", "file");
    try env.write("other.exe", "other");
    try writeDeferred(env, "old.exe");
    try writeDeferred(env, "old-1.0");
    try writeDeferred(env, "gone-1.0");
    try (try env.run(&.{"installed"})).expectOk();
    try env.expectFiles("other.exe");
    try env.expectSettled();
}

test "deferred cleanup: installed again since, it's left alone and forgotten" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try (try env.install(try toolManifest(env, "1.0"))).expectOk();
    try writeDeferred(env, "tool-1.0");
    try (try env.run(&.{"installed"})).expectOut("tool");
    try testing.expect(env.exists("tool-1.0\\share\\version.txt"));
    try env.expectSettled();

    // Windows ignores case, so a record's name still counts spelled differently
    try writeDeferred(env, "TOOL-1.0");
    try (try env.run(&.{"installed"})).expectOut("tool");
    try testing.expect(env.exists("tool-1.0\\share\\version.txt"));
    try env.expectSettled();
}

test "deferred cleanup: a record that can't be read could be the one that wants it" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, ".winbin\\installed");
    try env.write(".winbin\\installed\\broken-0123456789abcdef", "not a record");
    try env.bin.createDirPath(testing.io, "keep-1.0");
    try env.write("keep-1.0\\file.txt", "file");
    try writeDeferred(env, "keep-1.0");
    try (try env.run(&.{"installed"})).expectOk();
    try testing.expect(env.exists("keep-1.0\\file.txt"));
    try testing.expect(env.exists(".winbin\\deferred-cleanup\\keep-1.0"));

    // once it's been dealt with, it goes
    try env.bin.deleteFile(testing.io, ".winbin\\installed\\broken-0123456789abcdef");
    try (try env.run(&.{"installed"})).expectOk();
    try testing.expect(!env.exists("keep-1.0"));
    try env.expectSettled();
}

test "deferred cleanup: a name that can't be installed can't point at anything" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, "a b");
    try env.write("a b\\file.txt", "file");
    try writeDeferred(env, "a b");
    try writeDeferred(env, ".winbin");
    const output = try env.run(&.{"installed"});
    try output.expectOk();
    try testing.expect(std.mem.find(u8, output.stderr, "nothing winbin installs could have that name") != null);
    try testing.expect(env.exists("a b\\file.txt"));
    try testing.expect(env.exists(".winbin\\installed"));
    try testing.expect(env.exists(".winbin\\deferred-cleanup\\a b"));
}

test "deferred cleanup: winbin itself isn't deleted by a note, it's running" {
    const env = try Env.init();
    defer env.deinit();
    const original = try env.read("winbin.exe");
    try writeDeferred(env, "winbin.exe");
    const output = try env.run(&.{"installed"});
    try output.expectOk();
    try testing.expectEqualStrings(original, try env.read("winbin.exe"));
    try testing.expect(env.exists(".winbin\\deferred-cleanup\\winbin.exe"));
}

test "deferred cleanup: a junction goes, and what it points to stays" {
    const env = try Env.init();
    defer env.deinit();
    try makeJunctionToPrecious(env, "old-1.0");
    try writeDeferred(env, "old-1.0");
    try (try env.run(&.{"installed"})).expectOk();
    try expectPreciousIsThere(env);
    try testing.expect(!env.exists("old-1.0"));
    try env.expectSettled();
}

test "deferred cleanup: a read-only file doesn't stop it" {
    const env = try Env.init();
    defer env.deinit();
    try env.bin.createDirPath(testing.io, "old-1.0");
    try env.write("old-1.0\\readonly.txt", "readonly");
    const path = try std.fs.path.join(env.a(), &.{ env.bin_path, "old-1.0\\readonly.txt" });
    try attrib(env, "+r", path);
    defer attrib(env, "-r", path) catch {};
    try writeDeferred(env, "old-1.0");
    try (try env.run(&.{"installed"})).expectOk();
    try testing.expect(!env.exists("old-1.0"));
    try env.expectSettled();
}

test "deferred cleanup: uninstalling the package doesn't disturb a note for its old version" {
    const env = try Env.init();
    defer env.deinit();
    try serveTool(env, "1.0");
    try serveTool(env, "2.0");
    const from = try toolManifest(env, "1.0");
    try (try env.install(from)).expectOk();
    var running = try startWorkingIn(env, "tool-1.0");
    var killed = false;
    defer if (!killed) running.kill(testing.io);
    _ = try toolManifest(env, "2.0");
    try (try env.update(from)).expectOk();
    try testing.expect(env.exists(".winbin\\deferred-cleanup\\tool-1.0"));

    running.kill(testing.io);
    killed = true;
    try testing.io.sleep(.fromMilliseconds(300), .awake);
    try (try env.uninstall("tool")).expectOk();
    try env.expectFiles("");
    try env.expectSettled();
}

test "deleting: an abandoned run's directory doesn't follow a junction" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    try env.bin.createDirPath(testing.io, ".winbin\\tmp\\0123456789abcdef01234567");
    try env.write(".winbin\\tmp\\0123456789abcdef01234567.lock", "");
    try makeJunctionToPrecious(env, ".winbin\\tmp\\0123456789abcdef01234567\\link");
    try (try env.install(try env.manifest("one", exeText("one")))).expectOk();
    try expectPreciousIsThere(env);
    try testing.expect(!env.exists(".winbin\\tmp\\0123456789abcdef01234567"));
}

test "a bad journal stops everything rather than guessing" {
    const env = try Env.init();
    defer env.deinit();
    try env.write(".winbin\\..\\keep.exe", "keep");
    try env.bin.createDirPath(testing.io, ".winbin");
    try env.write(".winbin\\journal", "record-file x\nremove-file ../keep.exe\ndelete-record\n");
    try (try env.run(&.{"installed"})).expectError("isn't valid");
    try testing.expectEqualStrings("keep", try env.read("keep.exe"));
}

test "what a dead process left in tmp is cleaned up, and a live one's isn't" {
    const env = try Env.init();
    defer env.deinit();
    try env.serveZip("flat.zip", &flat_entries);
    const from = try env.manifest("flat", "download \"{site}/flat.zip\"\nextract\ndiscard \"data.txt\"\ninstall exe \"tool.exe\"\n");

    // as a process that died leaves it: its lock is free
    try env.bin.createDirPath(testing.io, ".winbin\\tmp\\dead\\staging");
    try env.write(".winbin\\tmp\\dead\\staging\\file.txt", "x");
    try env.write(".winbin\\tmp\\dead.lock", "");

    // as a live one has it: its lock is held
    try env.bin.createDirPath(testing.io, ".winbin\\tmp\\live\\staging");
    try env.write(".winbin\\tmp\\live\\staging\\file.txt", "x");
    const held = try env.bin.createFile(testing.io, ".winbin\\tmp\\live.lock", .{});
    try testing.expect(try held.tryLock(testing.io, .exclusive));

    try (try env.install(from)).expectOk();
    try testing.expect(!env.exists(".winbin\\tmp\\dead"));
    try testing.expect(!env.exists(".winbin\\tmp\\dead.lock"));
    try testing.expect(env.exists(".winbin\\tmp\\live\\staging\\file.txt"));

    held.close(testing.io);
    try env.bin.deleteFile(testing.io, "tool.exe");
    try (try env.install(from)).expectOk();
    try testing.expect(!env.exists(".winbin\\tmp\\live"));
    try testing.expectEqual(0, try env.tmpCount());
}

test "killed while downloading: a later run cleans up, and waiters take over" {
    const env = try Env.init();
    defer env.deinit();
    const from = try env.manifest("many", try serveMany(env, "1.0"));

    // wait for it to have a directory of its own, then kill it
    var child = try env.spawn(&.{ "install", from });
    const clock: std.Io.Clock = .awake;
    const start = clock.now(testing.io);
    while ((try env.tmpCount()) == 0 and start.durationTo(clock.now(testing.io)).toSeconds() < 10) {}
    child.kill(testing.io);

    try (try env.install(from)).expectOk();
    try testing.expectEqual(0, try env.tmpCount());
    try expectManyAt(env, "1.0");
}

const std = @import("std");
const paths = @import("paths");
const testing = std.testing;
