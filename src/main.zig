pub const std_options: std.Options = .{
    .io_vtable = .threaded,
    .enable_segfault_handler = false,
    .allow_stack_tracing = @import("builtin").mode == .debug,
};
pub const panic = crash.panic;

var threaded: std.Io.Threaded = .init_single_threaded;
pub const io = threaded.io();

const registry_host = "winbin-org.github.io";
const registry_url = "https://" ++ registry_host ++ "/";
const pkgs_url = registry_url ++ "pkg/";
const names_url = registry_url ++ "names";

const usage =
    \\usage:
    \\  winbin install NAME|URL...    install packages that aren't already ('i' for short)
    \\  winbin update NAME|URL...     update installed packages to the latest version
    \\  winbin uninstall NAME|URL...  remove installed packages
    \\  winbin available              print the packages you can install
    \\  winbin installed              print the installed packages
    \\  winbin --version              print winbin's version
    \\
    \\A package is the URL of its manifest:
    \\  NAME  a package in the registry, at
++ " " ++ pkgs_url ++ "NAME\n" ++
    \\  URL   a package anywhere else, starts with https://, http:// or file:///
    \\        a file needs its absolute path, like file:///C:/pkgs/foo
    \\Update and uninstall a package with the same NAME or URL you installed it with.
    \\
    \\Packages are installed next to winbin.exe, in {s}. Add it to your PATH to use them.
    \\
;

pub fn main(init: std.process.Init.Minimal) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    crash.install();
    main2(init, arena_state.allocator());
}

pub fn main2(init: std.process.Init.Minimal, arena: std.mem.Allocator) void {
    var args = init.args.iterateAllocator(arena) catch |e| oom(e);
    defer args.deinit();
    _ = args.skip();
    const command = args.next() orelse {
        const exe_dir_path = exeDirPath(arena);
        std.debug.print(usage, .{exe_dir_path});
        arena.free(exe_dir_path);
        std.process.exit(1);
    };
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        const exe_dir_path = exeDirPath(arena);
        defer arena.free(exe_dir_path);
        print(usage, .{exe_dir_path});
    } else if (std.mem.eql(u8, command, "--version")) {
        print("{s}\n", .{@embedFile("version")});
    } else if (std.mem.eql(u8, command, "install") or std.mem.eql(u8, command, "i")) {
        checkPackageArgs("install", init, arena);
        const exe_dir_path = exeDirPath(arena);
        defer arena.free(exe_dir_path);
        const root: store.Root = .open(exe_dir_path);
        defer root.close();
        forEachPackage(init, arena, root, installIfNeeded);
    } else if (std.mem.eql(u8, command, "update")) {
        checkPackageArgs("update", init, arena);
        const exe_dir_path = exeDirPath(arena);
        defer arena.free(exe_dir_path);
        const root: store.Root = .open(exe_dir_path);
        defer root.close();
        forEachPackage(init, arena, root, checkInstalled);
        forEachPackage(init, arena, root, installOrUpdate);
    } else if (std.mem.eql(u8, command, "uninstall")) {
        checkPackageArgs("uninstall", init, arena);
        const exe_dir_path = exeDirPath(arena);
        defer arena.free(exe_dir_path);
        const root: store.Root = .open(exe_dir_path);
        defer root.close();
        forEachPackage(init, arena, root, checkInstalled);
        forEachPackage(init, arena, root, uninstall);
    } else if (std.mem.eql(u8, command, "available")) {
        if (args.next() != null) fatal("'available' takes no arguments", .{});
        const names = fetchNames(arena);
        defer arena.free(names);
        print("{s}", .{names});
    } else if (std.mem.eql(u8, command, "installed")) {
        if (args.next() != null) fatal("'installed' takes no arguments", .{});
        const exe_dir_path = exeDirPath(arena);
        defer arena.free(exe_dir_path);
        const root: store.Root = .open(exe_dir_path);
        defer root.close();
        printInstalled(arena, root);
    } else fatal("unknown command '{s}', --help lists them", .{command});
}

pub fn print(comptime fmt_string: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    stdout.interface.print(fmt_string, args) catch fatal("write stdout: {t}", .{stdout.err.?});
    stdout.interface.flush() catch fatal("write stdout: {t}", .{stdout.err.?});
}

pub fn warn(comptime fmt_string: []const u8, args: anytype) void {
    std.debug.print("winbin: warning: " ++ fmt_string ++ "\n", args);
}

pub fn fatal(comptime fmt_string: []const u8, args: anytype) noreturn {
    std.debug.print("winbin: error: " ++ fmt_string ++ "\n", args);
    std.process.exit(1);
}

pub fn oom(err: error{OutOfMemory}) noreturn {
    fatal("{t}", .{err});
}

/// `noinline` so the path buffer leaves the stack on return.
noinline fn exeDirPath(arena: std.mem.Allocator) []const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.process.executableDirPath(io, &buf) catch |e|
        fatal("find the directory winbin.exe is in: {t}", .{e});
    return arena.dupe(u8, buf[0..len]) catch |e| oom(e);
}

const Source = struct {
    name: []const u8,
    kind: enum { registry, url },
    url: []const u8,
    /// The name of its install record, which can't be the URL itself.
    record_file: []const u8,

    fn init(arena: std.mem.Allocator, name: []const u8, kind: @FieldType(Source, "kind"), url: []const u8) Source {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
        const hex = std.fmt.bytesToHex(digest[0..8].*, .lower);
        const record_file = std.fmt.allocPrint(arena, "{s}-{s}", .{ name, &hex }) catch |e| oom(e);
        return .{ .name = name, .kind = kind, .url = url, .record_file = record_file };
    }

    fn deinit(self: *const Source, arena: std.mem.Allocator) void {
        arena.free(self.record_file);
        if (self.kind == .registry) arena.free(self.url);
    }

    /// What errors call it: whichever the user typed.
    fn given(self: *const Source) []const u8 {
        return if (self.kind == .registry) self.name else self.url;
    }

    fn readRecord(self: *const Source, arena: std.mem.Allocator, root: store.Root) ?record.Record {
        return root.readRecord(arena, self.record_file, self.url, self.given());
    }

    fn failNotInstalled(self: *const Source) noreturn {
        fatal("'{s}' isn't installed, 'winbin installed' lists what is", .{self.given()});
    }
};

/// What comes after the command, which `iterateAllocator` can be asked for again and
/// again, so there's no need to keep any of it.
fn packageArgs(init: std.process.Init.Minimal, arena: std.mem.Allocator) std.process.Args.Iterator {
    var args = init.args.iterateAllocator(arena) catch |e| oom(e);
    _ = args.skip();
    _ = args.skip();
    return args;
}

/// All of them before anything else, so a typo in the last one fails before anything's
/// changed.
fn checkPackageArgs(comptime command: []const u8, init: std.process.Init.Minimal, arena: std.mem.Allocator) void {
    var args = packageArgs(init, arena);
    defer args.deinit();
    var count: usize = 0;
    while (args.next()) |arg| : (count += 1) {
        checkArg(arg);
        var earlier = packageArgs(init, arena);
        defer earlier.deinit();
        for (0..count) |_| {
            if (std.mem.eql(u8, earlier.next().?, arg)) fatal("'{s}' is given more than once", .{arg});
        }
    }
    if (count == 0) fatal("expected '" ++ command ++ " NAME|URL...'", .{});
}

fn forEachPackage(
    init: std.process.Init.Minimal,
    arena: std.mem.Allocator,
    root: store.Root,
    comptime action: fn (std.mem.Allocator, store.Root, *const Source) void,
) void {
    var args = packageArgs(init, arena);
    defer args.deinit();
    while (args.next()) |arg| {
        const source = parseSource(arg, arena);
        defer source.deinit(arena);
        action(arena, root, &source);
    }
}

fn installIfNeeded(arena: std.mem.Allocator, root: store.Root, source: *const Source) void {
    if (!isInstalled(arena, root, source)) installOrUpdate(arena, root, source);
}

/// `arg` has been through `checkArg`.
fn parseSource(arg: []const u8, arena: std.mem.Allocator) Source {
    if (manifest.urlScheme(arg) != null) return .init(arena, manifest.urlName(arg), .url, arg);
    const url = std.fmt.allocPrint(arena, pkgs_url ++ "{s}", .{arg}) catch |e| oom(e);
    return .init(arena, arg, .registry, url);
}

fn checkArg(arg: []const u8) void {
    if (manifest.urlScheme(arg) != null) return checkUrlArg(arg);
    if (std.mem.findAny(u8, arg, "/\\") != null)
        fatal("'{s}' isn't a package name or a URL, a file needs its absolute path as a URL, like file:///C:/pkgs/foo", .{arg});
    if (!manifest.isPackageName(arg)) fatal("invalid package name '{s}': lowercase letters, digits, '.', '_' and '-' only", .{arg});
}

fn checkUrlArg(url: []const u8) void {
    const scheme = manifest.urlScheme(url).?;
    if (std.mem.eql(u8, scheme, "file")) {
        if (!std.mem.startsWith(u8, url, "file:///")) failFileUrl(url);
    } else {
        if (!std.mem.eql(u8, scheme, "https") and !std.mem.eql(u8, scheme, "http"))
            fatal("unsupported URL scheme '{s}' in '{s}', expected https://, http:// or file://", .{ scheme, url });
        if (afterRegistryHost(url)) |after_host| {
            if (registryName(after_host)) |registry_name|
                fatal("'{s}' is in the registry, use its name instead: {s}", .{ url, registry_name });
            fatal("'{s}' is in the registry, use the package's name instead", .{url});
        }
        if (!manifest.isUrl(url)) fatal("invalid URL '{s}', expected {s}://HOST/PATH", .{ url, scheme });
    }
    const name = manifest.urlName(url);
    if (!manifest.isPackageName(name)) fatal("'{s}' gives the package name '{s}', which isn't valid: lowercase letters, digits, '.', '_' and '-' only", .{ url, name });
}

/// What follows the host if it's the registry's. A host ignores case and can be written
/// with a user, a port or a trailing dot, so these all have to count or they'd be a
/// second copy of the same package.
fn afterRegistryHost(url: []const u8) ?[]const u8 {
    const after_scheme = url[std.mem.find(u8, url, "://").? + "://".len ..];
    const end = std.mem.findAny(u8, after_scheme, "/?#") orelse after_scheme.len;
    const authority = after_scheme[0..end];
    const after_user = authority[if (std.mem.findScalarLast(u8, authority, '@')) |at| at + 1 else 0..];
    const host = after_user[0 .. std.mem.findScalar(u8, after_user, ':') orelse after_user.len];
    if (!std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, host, "."), registry_host)) return null;
    return after_scheme[end..];
}

/// The package `after_host` is the manifest of, if it's one.
fn registryName(after_host: []const u8) ?[]const u8 {
    const pkg = "/pkg/";
    if (!std.ascii.startsWithIgnoreCase(after_host, pkg)) return null;
    const after = after_host[pkg.len..];
    const name = after[0 .. std.mem.findAny(u8, after, "/?#") orelse after.len];
    return if (manifest.isPackageName(name)) name else null;
}

/// What the commands call a package, from where its record says it was installed from.
fn packageArg(from: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, from, pkgs_url)) from[pkgs_url.len..] else from;
}

fn failFileUrl(url: []const u8) noreturn {
    fatal("invalid URL '{s}', a file needs its absolute path, like file:///C:/pkgs/foo", .{url});
}

fn checkInstalled(arena: std.mem.Allocator, root: store.Root, source: *const Source) void {
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    const installed = source.readRecord(arena, root) orelse source.failNotInstalled();
    installed.deinit(arena);
}

fn loadManifest(arena: std.mem.Allocator, source: *const Source) []const u8 {
    if (!std.mem.startsWith(u8, source.url, "file:///")) return fetchManifest(arena, source);
    const path = (manifest.filePath(source.url, arena) catch |e| oom(e)) orelse failFileUrl(source.url);
    defer arena.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e|
        fatal("read manifest '{s}': {t}", .{ source.url, e });
}

fn fetchManifest(arena: std.mem.Allocator, source: *const Source) []const u8 {
    const url = source.url;
    const response: http.Response = .get(arena, url, .follow);
    defer response.close();
    if (response.status == 404 and source.kind == .registry)
        fatal("no package named '{s}' ({s})", .{ source.name, url });
    if (response.status != 200) fatal("GET {s}: HTTP {d}", .{ url, response.status });
    return http.readBody(&response, arena);
}

fn isInstalled(arena: std.mem.Allocator, root: store.Root, source: *const Source) bool {
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    const installed = source.readRecord(arena, root) orelse return false;
    defer installed.deinit(arena);
    root.checkExesUnchanged(source.given(), installed);
    if (root.missingEntry(installed)) |missing| {
        print("{s} is missing, installing {s} again\n", .{ missing, source.name });
        return false;
    }
    print("{s} is already installed\n", .{source.given()});
    return true;
}

fn fetchNames(arena: std.mem.Allocator) []const u8 {
    const response: http.Response = .get(arena, names_url, .follow);
    defer response.close();
    if (response.status != 200) fatal("GET {s}: HTTP {d}", .{ names_url, response.status });
    const text = http.readBody(&response, arena);
    var diag: manifest.Diagnostic = .{};
    _ = manifest.parseNames(text, &diag) catch
        fatal("{s}, line {d}: {s}", .{ names_url, diag.line, diag.message });
    return text;
}

fn installOrUpdate(arena: std.mem.Allocator, root: store.Root, source: *const Source) void {
    const name = source.name;
    const text = loadManifest(arena, source);
    defer arena.free(text);
    validateManifest(source.given(), text);
    var inputs: gather.Gather = .init(source.given(), arena);
    defer inputs.deinit();
    const resolved = inputs.resolve(text);
    defer resolved.deinit(arena);

    const approved = approved: {
        const lock: store.Lock = .acquire(root, arena);
        defer lock.release();
        const old = source.readRecord(arena, root);
        defer if (old) |o| o.deinit(arena);
        if (isCurrent(root, source, resolved, text, old)) return;
        break :approved findInTheWay(arena, root, source, &inputs, text, old);
    };
    defer freeNames(arena, approved);
    // Not holding the lock: whoever answers can take as long as they like.
    if (approved.len != 0) askToReplace(root, source, approved);

    const run: store.Run = .begin(arena, root);
    const hash = stage.fetchDownload(arena, root, &run, source.given(), resolved.url, resolved.hash, resolved.extract);
    stage.carryOut(arena, root, &run, &inputs, text, resolved.url);

    // Another process may have changed things while this one was downloading.
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    const old = source.readRecord(arena, root);
    defer if (old) |o| o.deinit(arena);
    if (isCurrent(root, source, resolved, text, old)) {
        run.end(arena, root);
        return;
    }
    const now_in_the_way = findInTheWay(arena, root, source, &inputs, text, old);
    defer freeNames(arena, now_in_the_way);
    for (now_in_the_way) |in_the_way| {
        for (approved) |a| {
            if (std.ascii.eqlIgnoreCase(a, in_the_way)) break;
        } else fatal("'{s}\\{s}' has appeared since {s} started installing, run this again to decide about it", .{ root.path, in_the_way, source.given() });
    }
    const new_record = buildRecord(arena, root, &run, &inputs, text, resolved.url, &hash, source.url);
    defer arena.free(new_record);
    const journal = buildUpdateJournal(arena, source, &inputs, text, old, new_record);
    defer arena.free(journal);
    root.rename(run.out, store.publish_dir);
    lock.apply(arena, root, journal);
    run.end(arena, root);

    if (old) |o| {
        if (std.mem.eql(u8, o.url, resolved.url))
            print("reinstalled {s}\n", .{name})
        else
            print("updated {s}\n", .{name});
    } else print("installed {s}\n", .{name});
}

/// Whether there's nothing to do, printing so if there isn't.
fn isCurrent(root: store.Root, source: *const Source, resolved: gather.Resolved, text: []const u8, old: ?record.Record) bool {
    const o = old orelse return false;
    root.checkExesUnchanged(source.given(), o);
    // A changed manifest reinstalls even with the same URL: it can install
    // different files. So does a new hash: the file at the URL was replaced.
    if (std.mem.eql(u8, o.url, resolved.url) and stage.hashMatches(resolved.hash, o.hash) and std.mem.eql(u8, o.manifest, text) and root.missingEntry(o) == null) {
        print("{s} is already the latest version\n", .{source.name});
        return true;
    }
    return false;
}

/// The names this would replace that no package installed. Fails on one that another
/// package did, even if it's missing: that package would delete it when uninstalled.
/// Also fails on an exe that can't be replaced because it's running.
fn findInTheWay(arena: std.mem.Allocator, root: store.Root, source: *const Source, inputs: *const gather.Gather, text: []const u8, old: ?record.Record) []const []const u8 {
    var in_the_way: std.ArrayList([]const u8) = .empty;
    var installs = inputs.installs(text);
    while (installs.next()) |install| {
        defer arena.free(install.name);
        const ours = old != null and old.?.has(install.name);
        if (!ours) if (ownerOf(arena, root, install.name)) |owner|
            fatal("{s} can't install '{s}', it belongs to {s}, uninstall that first", .{ source.given(), install.name, packageArg(owner.from) });
        const kind = root.kind(install.name) orelse continue;
        if (kind == .file) root.checkReplaceable(install.name);
        if (!ours) {
            const name = arena.dupe(u8, install.name) catch |e| oom(e);
            in_the_way.append(arena, name) catch |e| oom(e);
        }
    }
    return in_the_way.toOwnedSlice(arena) catch |e| oom(e);
}

fn freeNames(arena: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| arena.free(name);
    arena.free(names);
}

/// The question goes to stderr so that it's still seen with stdout redirected.
fn askToReplace(root: store.Root, source: *const Source, names: []const []const u8) void {
    std.debug.print("winbin didn't install these, and {s} would replace them:\n", .{source.given()});
    for (names) |name| {
        const suffix = if (root.kind(name) == .directory) "\\ and everything in it" else "";
        std.debug.print("  {s}\\{s}{s}\n", .{ root.path, name, suffix });
    }
    std.debug.print("They can't be restored. Replace them? [y/N] ", .{});

    var buf: [256]u8 = undefined;
    const line = readLine(&buf) orelse fatal("there's no one to answer, nothing was changed. To replace them, answer y on stdin", .{});
    const answer = std.mem.trim(u8, line, " \t\r");
    if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes")) {
        std.debug.print("winbin: user cancelled install\n", .{});
        std.process.exit(1);
    }
}

/// A byte at a time: reading any further could take the next package's answer.
fn readLine(buf: []u8) ?[]const u8 {
    var len: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.Io.File.stdin().readStreaming(io, &.{&byte}) catch |e| switch (e) {
            error.EndOfStream => return if (len == 0) null else buf[0..len],
            else => fatal("read stdin: {t}", .{e}),
        };
        if (n == 0) continue;
        if (byte[0] == '\n') return buf[0..len];
        if (len == buf.len) fatal("that isn't y or n, nothing was changed", .{});
        buf[len] = byte[0];
        len += 1;
    }
}

/// The record of the package that has this name, for the caller to free.
fn ownerOf(arena: std.mem.Allocator, root: store.Root, name: []const u8) ?record.Record {
    var installed = root.installedIterator(arena);
    defer installed.close();
    while (installed.next()) |r| {
        if (r.has(name)) return r;
        r.deinit(arena);
    }
    return null;
}

fn buildRecord(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, inputs: *const gather.Gather, text: []const u8, url: []const u8, hash: []const u8, from: []const u8) []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    writeRecord(arena, &out.writer, root, run, inputs, text, url, hash, from) catch |e| switch (e) {
        error.WriteFailed => oom(error.OutOfMemory),
    };
    return out.toOwnedSlice() catch |e| oom(e);
}

fn writeRecord(arena: std.mem.Allocator, w: *std.Io.Writer, root: store.Root, run: *const store.Run, inputs: *const gather.Gather, text: []const u8, url: []const u8, hash: []const u8, from: []const u8) std.Io.Writer.Error!void {
    try record.writeStart(w, url, hash);
    var installs = inputs.installs(text);
    while (installs.next()) |install| {
        defer arena.free(install.name);
        switch (install.kind) {
            .exe => {
                const out = std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.out, install.name }) catch |e| oom(e);
                defer arena.free(out);
                const exe_hash = root.hashFile(out) orelse
                    fatal("'{s}\\{s}' is gone just after installing it", .{ root.path, out });
                try record.writeEntry(w, .{ .exe = .{ .name = install.name, .hash = &exe_hash } });
            },
            .exelink => try record.writeEntry(w, .{ .exelink = install.name }),
            .dir => try record.writeEntry(w, .{ .dir = install.name }),
        }
    }
    try record.writeEnd(w, from, text);
}

fn manifestInstalls(inputs: *const gather.Gather, text: []const u8, name: []const u8) bool {
    var installs = inputs.installs(text);
    while (installs.next()) |install| {
        defer inputs.arena.free(install.name);
        if (std.ascii.eqlIgnoreCase(install.name, name)) return true;
    }
    return false;
}

fn buildUpdateJournal(arena: std.mem.Allocator, source: *const Source, inputs: *const gather.Gather, text: []const u8, old: ?record.Record, new_record: []const u8) []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    writeUpdateJournal(&out.writer, source, inputs, text, old, new_record) catch |e| switch (e) {
        error.WriteFailed => oom(error.OutOfMemory),
    };
    return out.toOwnedSlice() catch |e| oom(e);
}

fn writeUpdateJournal(w: *std.Io.Writer, source: *const Source, inputs: *const gather.Gather, text: []const u8, old: ?record.Record, new_record: []const u8) std.Io.Writer.Error!void {
    try record.writeJournalStart(w, source.record_file);
    if (old) |o| {
        var entries = o.entries();
        while (entries.next()) |entry| {
            if (manifestInstalls(inputs, text, entry.name())) continue;
            switch (entry) {
                .exe, .exelink => try record.writeAction(w, .{ .remove_file = entry.name() }),
                .dir => |dir_name| try record.writeAction(w, .{ .retire_dir = dir_name }),
            }
        }
    }
    try record.writeJournalRecord(w, new_record);
}

fn uninstall(arena: std.mem.Allocator, root: store.Root, source: *const Source) void {
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    const installed = source.readRecord(arena, root) orelse source.failNotInstalled();
    defer installed.deinit(arena);
    root.checkExesUnchanged(source.given(), installed);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    writeUninstallJournal(&out.writer, source.record_file, installed) catch |e| switch (e) {
        error.WriteFailed => oom(error.OutOfMemory),
    };
    lock.apply(arena, root, out.written());
    print("uninstalled {s}\n", .{source.name});
}

fn writeUninstallJournal(w: *std.Io.Writer, record_file: []const u8, installed: record.Record) std.Io.Writer.Error!void {
    try record.writeJournalStart(w, record_file);
    var entries = installed.entries();
    while (entries.next()) |entry| switch (entry) {
        .exe, .exelink => try record.writeAction(w, .{ .remove_file = entry.name() }),
        .dir => |dir_name| try record.writeAction(w, .{ .remove_dir = dir_name }),
    };
    try record.writeJournalDeleteRecord(w);
}

fn printInstalled(arena: std.mem.Allocator, root: store.Root) void {
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    var installed = root.installedIterator(arena);
    defer installed.close();
    while (installed.next()) |r| {
        defer r.deinit(arena);
        print("{s}\n", .{packageArg(r.from)});
    }
}

fn validateManifest(name: []const u8, text: []const u8) void {
    var diag: manifest.Diagnostic = .{};
    manifest.validate(text, &diag) catch {
        if (diag.line == 0) fatal("manifest of '{s}': {s}", .{ name, diag.message });
        if (diag.unknown.len != 0)
            fatal("manifest of '{s}', line {d}: {s} '{s}', this manifest may need a newer winbin (or it's misspelled)", .{ name, diag.line, diag.message, diag.unknown });
        fatal("manifest of '{s}', line {d}: {s} (this manifest may need a newer winbin)", .{ name, diag.line, diag.message });
    };
}

test "a name is short for its registry URL, and goes by its name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const url = pkgs_url ++ "hyperfine";
    const by_name = parseSource("hyperfine", arena.allocator());
    try testing.expectEqualStrings(url, by_name.url);
    try testing.expectEqualStrings("hyperfine", by_name.given());
    try testing.expectEqualStrings("hyperfine", packageArg(url));
    try testing.expectEqualStrings("https://e.com/pkg/hyperfine", packageArg("https://e.com/pkg/hyperfine"));
}

test "the registry's host is recognized however it's spelled, whatever follows it" {
    for ([_][]const u8{
        "https://winbin-org.github.io/x",
        "http://winbin-org.github.io/x",
        "https://WinBin-Org.GitHub.io/x",
        "https://winbin-org.github.io:443/x",
        "https://winbin-org.github.io./x",
        "https://me@winbin-org.github.io/x",
        "https://me:secret@winbin-org.github.io:8080/x",
    }) |url| try testing.expectEqualStrings("/x", afterRegistryHost(url).?);
    try testing.expectEqualStrings("", afterRegistryHost("https://winbin-org.github.io").?);
    try testing.expectEqualStrings("?x=1", afterRegistryHost("https://winbin-org.github.io?x=1").?);

    for ([_][]const u8{
        "https://e.com/pkg/a",
        "https://e.com/winbin-org.github.io/pkg/a",
        "https://winbin-org.github.io.e.com/pkg/a",
        "https://winbin-org.github.io@e.com/pkg/a",
        "https://notwinbin-org.github.io/pkg/a",
        "https://mirror.winbin-org.github.io/pkg/a",
    }) |url| try testing.expectEqual(null, afterRegistryHost(url));
}

test "only a package's path in the registry has a name to suggest" {
    try testing.expectEqualStrings("a", registryName("/pkg/a").?);
    try testing.expectEqualStrings("a", registryName("/PKG/a").?);
    try testing.expectEqualStrings("a", registryName("/pkg/a/more?x=1").?);
    try testing.expectEqual(null, registryName("/pkg/"));
    try testing.expectEqual(null, registryName("/pkg/A"));
    try testing.expectEqual(null, registryName("/names"));
    try testing.expectEqual(null, registryName("/other/pkg/a"));
    try testing.expectEqual(null, registryName(""));
}

test "the same last part from somewhere else is a different package" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const registry = parseSource("hyperfine", arena.allocator());
    const other = parseSource("https://e.com/hyperfine", arena.allocator());
    const file = parseSource("file:///C:/pkgs/hyperfine", arena.allocator());
    try testing.expect(!std.mem.eql(u8, registry.record_file, other.record_file));
    try testing.expect(!std.mem.eql(u8, registry.record_file, file.record_file));
    try testing.expect(!std.mem.eql(u8, other.record_file, file.record_file));
}

const std = @import("std");
const crash = @import("crash.zig");
const gather = @import("gather.zig");
const http = @import("http.zig");
const manifest = @import("manifest.zig");
const record = @import("record.zig");
const stage = @import("stage.zig");
const store = @import("store.zig");
const testing = std.testing;
