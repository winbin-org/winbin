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
    \\  winbin install [--pdbs] NAME|URL... [--end-pdbs] NAME|URL...
    \\                                install packages that aren't already ('i' for short),
    \\                                with the PDBs of those between --pdbs and --end-pdbs
    \\  winbin update NAME|URL...     update installed packages to the latest version
    \\  winbin uninstall NAME|URL...  remove installed packages
    \\  winbin available              print the packages you can install
    \\  winbin installed              print the installed packages
    \\  winbin --version              print winbin's version
    \\  winbin --dir DIR COMMAND...   any of the above, with packages in DIR
    \\
    \\install, update and uninstall also take --non-interactive, which fails whenever winbin
    \\would need to ask you something.
    \\
    \\A package is the URL of its manifest:
    \\  NAME  a package in the registry, at
++ " " ++ pkgs_url ++ "NAME\n" ++
    \\  URL   a package anywhere else, starts with https://, http:// or file:///
    \\        a file needs its absolute path, like file:///C:/pkgs/foo
    \\Update and uninstall a package with the same NAME or URL you installed it with.
    \\
    \\Packages are installed next to winbin.exe. To install them somewhere else, give
    \\--dir DIR before the command, or set the WINBIN_DIR environment variable.
    \\Right now they go in {s}. Add it to your PATH to use them.
    \\
;

pub fn main(init: std.process.Init.Minimal) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    crash.install();
    main2(init, arena_state.allocator());
}

pub fn main2(init: std.process.Init.Minimal, arena: std.mem.Allocator) void {
    if (builtin.cpu.arch != .aarch64) exitIfEmulated();
    var args = init.args.iterateAllocator(arena) catch |e| oom(e);
    defer args.deinit();
    _ = args.skip();
    var dir_arg: ?[]const u8 = null;
    var command = args.next() orelse failUsage(init, arena, null);
    if (std.mem.eql(u8, command, dir_flag)) {
        dir_arg = args.next() orelse errExit("'" ++ dir_flag ++ "' needs a directory after it", .{});
        command = args.next() orelse failUsage(init, arena, dir_arg);
    }
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        const root_path = rootPath(init, arena, dir_arg);
        defer arena.free(root_path.path);
        print(usage, .{root_path.path});
    } else if (std.mem.eql(u8, command, "--version")) {
        print("{s}\n", .{@embedFile("version")});
    } else if (std.mem.eql(u8, command, "install") or std.mem.eql(u8, command, "i")) {
        checkPackageArgs("install", init, arena);
        const root_path = rootPath(init, arena, dir_arg);
        defer arena.free(root_path.path);
        const root: store.Root = .open(root_path.path, root_path.chosen_by);
        defer root.close();
        forEachPackage("install", init, arena, root, installIfNeeded);
    } else if (std.mem.eql(u8, command, "update")) {
        checkPackageArgs("update", init, arena);
        const root_path = rootPath(init, arena, dir_arg);
        defer arena.free(root_path.path);
        const root: store.Root = .open(root_path.path, root_path.chosen_by);
        defer root.close();
        forEachPackage("update", init, arena, root, checkInstalled);
        forEachPackage("update", init, arena, root, installOrUpdate);
    } else if (std.mem.eql(u8, command, "uninstall")) {
        checkPackageArgs("uninstall", init, arena);
        const root_path = rootPath(init, arena, dir_arg);
        defer arena.free(root_path.path);
        const root: store.Root = .open(root_path.path, root_path.chosen_by);
        defer root.close();
        forEachPackage("uninstall", init, arena, root, checkInstalled);
        forEachPackage("uninstall", init, arena, root, uninstall);
    } else if (std.mem.eql(u8, command, "available")) {
        if (args.next() != null) errExit("'available' takes no arguments", .{});
        const names = fetchNames(arena);
        defer arena.free(names);
        print("{s}", .{names});
    } else if (std.mem.eql(u8, command, "installed")) {
        if (args.next() != null) errExit("'installed' takes no arguments", .{});
        const root_path = rootPath(init, arena, dir_arg);
        defer arena.free(root_path.path);
        const root: store.Root = .open(root_path.path, root_path.chosen_by);
        defer root.close();
        printInstalled(arena, root);
    } else errExit("unknown command '{s}', --help lists them", .{command});
}

fn failUsage(init: std.process.Init.Minimal, arena: std.mem.Allocator, dir_arg: ?[]const u8) noreturn {
    const root_path = rootPath(init, arena, dir_arg);
    std.debug.print(usage, .{root_path.path});
    arena.free(root_path.path);
    std.process.exit(1);
}

/// Windows on ARM64 runs the x86_64 and x86 winbin emulated, where it would install
/// packages for the wrong architecture. IsWow64Process2 gives the machine's own
/// architecture even to an emulated process.
fn exitIfEmulated() void {
    var process: win32.IMAGE_FILE_MACHINE = undefined;
    var native: win32.IMAGE_FILE_MACHINE = undefined;
    if (0 == win32.IsWow64Process2(win32.GetCurrentProcess(), &process, &native))
        errExit("IsWow64Process2 failed, error={f}", .{win32.GetLastError()});
    if (native != .ARM64) return;
    errExit("this is the {t} winbin, but this PC is ARM64. Install the ARM64 winbin by running this in PowerShell: irm https://winbin-org.github.io/install.ps1 | iex", .{builtin.cpu.arch});
}

pub fn print(comptime fmt_string: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    stdout.interface.print(fmt_string, args) catch errExit("write stdout: {t}", .{stdout.err.?});
    stdout.interface.flush() catch errExit("write stdout: {t}", .{stdout.err.?});
}

pub fn warn(comptime fmt_string: []const u8, args: anytype) void {
    std.debug.print("winbin: warning: " ++ fmt_string ++ "\n", args);
}

pub fn errExit(comptime fmt_string: []const u8, args: anytype) noreturn {
    std.debug.print("winbin: error: " ++ fmt_string ++ "\n", args);
    std.process.exit(1);
}

fn oom(err: error{OutOfMemory}) noreturn {
    errExit("{t}", .{err});
}

/// `noinline` so the path buffer leaves the stack on return.
noinline fn exeDirPath(arena: std.mem.Allocator) []const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.process.executableDirPath(io, &buf) catch |e|
        errExit("find the directory winbin.exe is in: {t}", .{e});
    return arena.dupe(u8, buf[0..len]) catch |e| oom(e);
}

const RootPath = struct {
    path: []const u8,
    chosen_by: store.Root.ChosenBy,
};

const dir_flag = "--dir";
const dir_variable = "WINBIN_DIR";

/// Where packages go: what `--dir` or `WINBIN_DIR` says, or else next to winbin.exe.
fn rootPath(init: std.process.Init.Minimal, arena: std.mem.Allocator, dir_arg: ?[]const u8) RootPath {
    const variable = init.environ.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral(dir_variable)) orelse {
        const arg = dir_arg orelse return .{ .path = exeDirPath(arena), .chosen_by = .exe_dir };
        if (!std.fs.path.isAbsolute(arg)) errExit("'" ++ dir_flag ++ " {s}' has to be an absolute path", .{arg});
        return .{ .path = arena.dupe(u8, arg) catch |e| oom(e), .chosen_by = .cmdline };
    };
    const path = std.unicode.wtf16LeToWtf8Alloc(arena, variable) catch |e| oom(e);
    if (dir_arg) |arg|
        errExit("'" ++ dir_flag ++ " {s}' was given, but " ++ dir_variable ++ " is also set, to '{s}', only one of them can say where packages go", .{ arg, path });
    if (!std.fs.path.isAbsolute(path)) errExit(dir_variable ++ " is '{s}', it has to be an absolute path", .{path});
    return .{ .path = path, .chosen_by = .env };
}

/// How to update the winbin that's running. It's a package next to itself, so that's
/// without anything saying packages go somewhere else, and it's an install if it has no
/// record there yet.
const UpdateWinbin = struct {
    root: store.Root,
    recorded: bool,

    fn init(arena: std.mem.Allocator, root: store.Root) UpdateWinbin {
        const exe_dir_path = exeDirPath(arena);
        defer arena.free(exe_dir_path);
        const winbin = parseSource("winbin", arena);
        defer winbin.deinit(arena);
        const record_path = std.fs.path.join(arena, &.{ exe_dir_path, store.installed_dir, winbin.record_file }) catch |e| oom(e);
        defer arena.free(record_path);
        std.Io.Dir.cwd().access(io, record_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return .{ .root = root, .recorded = false },
            else => errExit("check '{s}': {t}", .{ record_path, e }),
        };
        return .{ .root = root, .recorded = true };
    }

    pub fn format(self: UpdateWinbin, w: *std.Io.Writer) error{WriteFailed}!void {
        const command = if (self.recorded) "winbin update winbin" else "winbin install winbin";
        switch (self.root.chosen_by) {
            .exe_dir => try w.print("to update winbin, run: {s}", .{command}),
            .env => try w.print(dir_variable ++ " is set to '{s}', to update winbin, unset it and run: {s}", .{ self.root.path, command }),
            .cmdline => try w.print("to update winbin, run it without " ++ dir_flag ++ ": {s}", .{command}),
        }
    }
};

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
        errExit("'{s}' isn't installed, 'winbin installed' lists what is", .{self.given()});
    }
};

/// What comes after the command, which `iterateAllocator` can be asked for again and
/// again, so there's no need to keep any of it.
fn packageArgs(init: std.process.Init.Minimal, arena: std.mem.Allocator) std.process.Args.Iterator {
    var args = init.args.iterateAllocator(arena) catch |e| oom(e);
    _ = args.skip();
    if (std.mem.eql(u8, args.next().?, dir_flag)) {
        _ = args.skip();
        _ = args.skip();
    }
    return args;
}

/// All of them before anything else, so a typo in the last one fails before anything's
/// changed.
fn checkPackageArgs(comptime command: []const u8, init: std.process.Init.Minimal, arena: std.mem.Allocator) void {
    var args = packageArgs(init, arena);
    defer args.deinit();
    var count: usize = 0;
    var position: usize = 0;
    var with_pdbs = false;
    while (args.next()) |arg| : (position += 1) {
        if (std.mem.eql(u8, arg, non_interactive_flag)) continue;
        if (isPdbFlag(command, arg, &with_pdbs)) continue;
        count += 1;
        checkArg(arg);
        var earlier = packageArgs(init, arena);
        defer earlier.deinit();
        for (0..position) |_| {
            if (std.mem.eql(u8, earlier.next().?, arg)) errExit("'{s}' is given more than once", .{arg});
        }
    }
    if (count == 0) errExit("expected '" ++ command ++ " NAME|URL...'", .{});
}

const non_interactive_flag = "--non-interactive";

/// What a command's options say about one package.
const Options = struct {
    with_pdbs: bool,
    non_interactive: bool,
};

/// Only `install` has these. `update` keeps what a package was installed with.
fn isPdbFlag(comptime command: []const u8, arg: []const u8, with_pdbs: *bool) bool {
    if (comptime !std.mem.eql(u8, command, "install")) return false;
    if (std.mem.eql(u8, arg, "--pdbs")) {
        if (with_pdbs.*) errExit("'--pdbs' is given again before '--end-pdbs'", .{});
        with_pdbs.* = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--end-pdbs")) {
        if (!with_pdbs.*) errExit("'--end-pdbs' needs a '--pdbs' before it", .{});
        with_pdbs.* = false;
        return true;
    }
    return false;
}

fn forEachPackage(
    comptime command: []const u8,
    init: std.process.Init.Minimal,
    arena: std.mem.Allocator,
    root: store.Root,
    comptime action: fn (std.mem.Allocator, store.Root, *const Source, Options) void,
) void {
    var options: Options = .{ .with_pdbs = false, .non_interactive = false };
    {
        var args = packageArgs(init, arena);
        defer args.deinit();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, non_interactive_flag)) options.non_interactive = true;
        }
    }
    var args = packageArgs(init, arena);
    defer args.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, non_interactive_flag)) continue;
        if (isPdbFlag(command, arg, &options.with_pdbs)) continue;
        const source = parseSource(arg, arena);
        defer source.deinit(arena);
        action(arena, root, &source, options);
    }
}

fn installIfNeeded(arena: std.mem.Allocator, root: store.Root, source: *const Source, options: Options) void {
    if (!isInstalled(arena, root, source, options.with_pdbs)) installOrUpdate(arena, root, source, options);
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
        errExit("'{s}' isn't a package name or a URL, a file needs its absolute path as a URL, like file:///C:/pkgs/foo", .{arg});
    if (!manifest.isPackageName(arg)) errExit("invalid package name '{s}': lowercase letters, digits, '.', '_' and '-' only", .{arg});
}

fn checkUrlArg(url: []const u8) void {
    const scheme = manifest.urlScheme(url).?;
    if (std.mem.eql(u8, scheme, "file")) {
        if (!std.mem.startsWith(u8, url, "file:///")) failFileUrl(url);
    } else {
        if (!std.mem.eql(u8, scheme, "https") and !std.mem.eql(u8, scheme, "http"))
            errExit("unsupported URL scheme '{s}' in '{s}', expected https://, http:// or file://", .{ scheme, url });
        if (afterRegistryHost(url)) |after_host| {
            if (registryName(after_host)) |registry_name|
                errExit("'{s}' is in the registry, use its name instead: {s}", .{ url, registry_name });
            errExit("'{s}' is in the registry, use the package's name instead", .{url});
        }
        if (!manifest.isUrl(url)) errExit("invalid URL '{s}', expected {s}://HOST/PATH", .{ url, scheme });
    }
    const name = manifest.urlName(url);
    if (!manifest.isPackageName(name)) errExit("'{s}' gives the package name '{s}', which isn't valid: lowercase letters, digits, '.', '_' and '-' only", .{ url, name });
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
    errExit("invalid URL '{s}', a file needs its absolute path, like file:///C:/pkgs/foo", .{url});
}

fn checkInstalled(arena: std.mem.Allocator, root: store.Root, source: *const Source, _: Options) void {
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    const installed = source.readRecord(arena, root) orelse source.failNotInstalled();
    installed.deinit(arena);
}

fn loadWinHttp() http.WinHttp {
    var err: Error = undefined;
    return http.WinHttp.load(&err) catch |e| switch (e) {
        error.Error => errExit("{f}", .{err}),
    };
}

fn loadManifest(arena: std.mem.Allocator, winhttp: *const http.WinHttp, source: *const Source) []const u8 {
    if (!std.mem.startsWith(u8, source.url, "file:///")) return fetchManifest(arena, winhttp, source);
    const path = (manifest.filePath(source.url, arena) catch |e| oom(e)) orelse failFileUrl(source.url);
    defer arena.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e|
        errExit("read manifest '{s}': {t}", .{ source.url, e });
}

fn fetchManifest(arena: std.mem.Allocator, winhttp: *const http.WinHttp, source: *const Source) []const u8 {
    const url = source.url;
    const response: http.Response = .get(winhttp, arena, url, .follow);
    defer response.close();
    if (response.status == 404 and source.kind == .registry)
        errExit("no package named '{s}' ({s})", .{ source.name, url });
    if (response.status != 200) errExit("GET {s}: HTTP {d}", .{ url, response.status });
    return http.readBody(&response, arena);
}

fn isInstalled(arena: std.mem.Allocator, root: store.Root, source: *const Source, with_pdbs: bool) bool {
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    const installed = source.readRecord(arena, root) orelse return false;
    defer installed.deinit(arena);
    root.checkExesUnchanged(source.given(), installed);
    if (root.missingEntry(installed)) |missing| {
        print("{s} is missing, installing {s} again\n", .{ missing, source.name });
        return false;
    }
    // only the manifest can say whether it has any
    if (with_pdbs and !installed.hasPdb()) return false;
    print("{s} is already installed\n", .{source.given()});
    return true;
}

fn fetchNames(arena: std.mem.Allocator) []const u8 {
    const winhttp = loadWinHttp();
    const response: http.Response = .get(&winhttp, arena, names_url, .follow);
    defer response.close();
    if (response.status != 200) errExit("GET {s}: HTTP {d}", .{ names_url, response.status });
    const text = http.readBody(&response, arena);
    var diag: manifest.Diagnostic = .{};
    _ = manifest.parseNames(text, &diag) catch
        errExit("{s}, line {d}: {s}", .{ names_url, diag.line, diag.message });
    return text;
}

fn installOrUpdate(arena: std.mem.Allocator, root: store.Root, source: *const Source, options: Options) void {
    const name = source.name;
    const winhttp = loadWinHttp();
    const text = loadManifest(arena, &winhttp, source);
    defer arena.free(text);
    validateManifest(arena, root, source.given(), text);
    var inputs: gather.Gather = .init(source.given(), arena, &winhttp);
    defer inputs.deinit();
    const resolved = inputs.resolve(text);
    defer resolved.deinit(arena);

    const approved = approved: {
        const lock: store.Lock = .acquire(root, arena);
        defer lock.release();
        const old = source.readRecord(arena, root);
        defer if (old) |o| o.deinit(arena);
        // it stays how it was installed, unless it's being asked for
        inputs.with_pdbs = options.with_pdbs or (old != null and old.?.hasPdb());
        if (isCurrent(arena, root, source, &inputs, resolved, text, old)) return;
        break :approved findInTheWay(arena, root, source, &inputs, text, old);
    };
    defer freeNames(arena, approved);
    // Not holding the lock: whoever answers can take as long as they like.
    if (approved.len != 0) {
        askToReplace(root, source, approved, options.non_interactive);
        const lock: store.Lock = .acquire(root, arena);
        defer lock.release();
        checkAllReplaceable(arena, root, approved);
    }

    const run: store.Run = .begin(arena, root);
    const hash = stage.fetchDownload(arena, &winhttp, root, &run, source.given(), resolved.url, resolved.hash, resolved.extract);
    stage.carryOut(arena, root, &run, &inputs, text, resolved.url);

    // Another process may have changed things while this one was downloading.
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    const old = source.readRecord(arena, root);
    defer if (old) |o| o.deinit(arena);
    if (isCurrent(arena, root, source, &inputs, resolved, text, old)) {
        run.end(arena, root);
        return;
    }
    const now_in_the_way = findInTheWay(arena, root, source, &inputs, text, old);
    defer freeNames(arena, now_in_the_way);
    for (now_in_the_way) |in_the_way| {
        for (approved) |a| {
            if (std.ascii.eqlIgnoreCase(a, in_the_way)) break;
        } else errExit("'{s}\\{s}' has appeared since {s} started installing, run this again to decide about it", .{ root.path, in_the_way, source.given() });
    }
    checkAllReplaceable(arena, root, now_in_the_way);
    const journal_file = lock.createJournal(root);
    var journal_buf: [4096]u8 = undefined;
    var journal = journal_file.writer(io, &journal_buf);
    writeInstallJournal(arena, &journal.interface, root, &run, source, &inputs, text, resolved.url, &hash) catch
        errExit("write '{s}\\{s}': {t}", .{ root.path, store.new_journal_path, journal.err.? });
    root.rename(run.out, store.publish_dir);
    lock.apply(arena, root, journal_file);
    run.end(arena, root);

    if (old) |o| {
        if (std.mem.eql(u8, o.url, resolved.url))
            print("reinstalled {s}\n", .{name})
        else
            print("updated {s}\n", .{name});
    } else print("installed {s}\n", .{name});
}

/// Whether there's nothing to do, printing so if there isn't.
fn isCurrent(arena: std.mem.Allocator, root: store.Root, source: *const Source, inputs: *const gather.Gather, resolved: gather.Resolved, text: []const u8, old: ?record.Record) bool {
    const o = old orelse return false;
    if (inputs.with_pdbs and !o.hasPdb() and manifestHasPdb(arena, inputs, text)) return false;
    root.checkExesUnchanged(source.given(), o);
    // A changed manifest reinstalls even with the same URL: it can install
    // different files. So does a new hash: the file at the URL was replaced.
    if (std.mem.eql(u8, o.url, resolved.url) and stage.hashMatches(resolved.hash, o.hash) and std.mem.eql(u8, o.manifest, text) and root.missingEntry(o) == null) {
        print("{s} is already the latest version\n", .{source.name});
        return true;
    }
    return false;
}

/// The names this would replace that no package installed. Fails on something of this
/// package's own that can't be replaced.
fn findInTheWay(arena: std.mem.Allocator, root: store.Root, source: *const Source, inputs: *const gather.Gather, text: []const u8, old: ?record.Record) []const []const u8 {
    const all_records_read = checkNotOwned(arena, root, source, inputs, text, old);
    var in_the_way: std.ArrayList([]const u8) = .empty;
    var installs = inputs.installs(text);
    while (installs.next()) |install| {
        defer arena.free(install.name);
        if (root.kind(install.name) == null) continue;
        if (old != null and old.?.has(install.name)) {
            root.checkReplaceable(arena, install.name);
            continue;
        }
        if (!all_records_read)
            errExit("{s} would replace '{s}\\{s}', which could belong to the package whose record couldn't be read, so it isn't being asked about", .{ source.given(), root.path, install.name });
        const name = arena.dupe(u8, install.name) catch |e| oom(e);
        in_the_way.append(arena, name) catch |e| oom(e);
    }
    return in_the_way.toOwnedSlice(arena) catch |e| oom(e);
}

/// Fails on a name another package installed, even if it's missing: that package would
/// delete it when uninstalled. False if a record couldn't be read, which was warned about.
fn checkNotOwned(arena: std.mem.Allocator, root: store.Root, source: *const Source, inputs: *const gather.Gather, text: []const u8, old: ?record.Record) bool {
    var installed = root.installedIterator(arena);
    defer installed.close();
    while (installed.next()) |r| {
        defer r.deinit(arena);
        var installs = inputs.installs(text);
        while (installs.next()) |install| {
            defer arena.free(install.name);
            if (old != null and old.?.has(install.name)) continue;
            if (r.has(install.name))
                errExit("{s} can't install '{s}', it belongs to {s}, uninstall that first", .{ source.given(), install.name, packageArg(r.from) });
        }
    }
    return !installed.skipped_invalid;
}

fn checkAllReplaceable(arena: std.mem.Allocator, root: store.Root, names: []const []const u8) void {
    for (names) |name| root.checkReplaceable(arena, name);
}

fn freeNames(arena: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| arena.free(name);
    arena.free(names);
}

/// The question goes to stderr so that it's still seen with stdout redirected.
fn askToReplace(root: store.Root, source: *const Source, names: []const []const u8, non_interactive: bool) void {
    std.debug.print("winbin didn't install these, and {s} would replace them:\n", .{source.given()});
    for (names) |name| {
        const suffix = if (root.kind(name) == .directory) "\\ and everything in it" else "";
        std.debug.print("  {s}\\{s}{s}\n", .{ root.path, name, suffix });
    }
    if (non_interactive) errExit(non_interactive_flag ++ " was given, but winbin needs to ask whether to replace them, nothing was changed", .{});
    std.debug.print("They can't be restored. Replace them? [y/N] ", .{});

    var buf: [256]u8 = undefined;
    const line = readLine(&buf) orelse errExit("there's no one to answer, nothing was changed. To replace them, answer y on stdin", .{});
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
            else => errExit("read stdin: {t}", .{e}),
        };
        if (n == 0) continue;
        if (byte[0] == '\n') return buf[0..len];
        if (len == buf.len) errExit("that isn't y or n, nothing was changed", .{});
        buf[len] = byte[0];
        len += 1;
    }
}

fn writeRecord(arena: std.mem.Allocator, w: *std.Io.Writer, root: store.Root, run: *const store.Run, inputs: *const gather.Gather, text: []const u8, url: []const u8, hash: []const u8, from: []const u8) error{WriteFailed}!void {
    try record.writeStart(w, url, hash);
    var installs = inputs.installs(text);
    while (installs.next()) |install| {
        defer arena.free(install.name);
        switch (install.kind) {
            .exe, .hardlink => {
                const out = std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.out, install.name }) catch |e| oom(e);
                defer arena.free(out);
                const file_hash = root.hashFile(out) orelse
                    errExit("'{s}\\{s}' is gone just after installing it", .{ root.path, out });
                const hashed: record.Entry.Hashed = .{ .name = install.name, .hash = &file_hash };
                try record.writeEntry(w, if (install.kind == .exe) .{ .exe = hashed } else .{ .hardlink = hashed });
            },
            .exelink => try record.writeEntry(w, .{ .exelink = install.name }),
            .dir => try record.writeEntry(w, .{ .dir = install.name }),
            .pdb => try record.writeEntry(w, .{ .pdb = install.name }),
        }
    }
    try record.writeEnd(w, from, text);
}

fn manifestHasPdb(arena: std.mem.Allocator, inputs: *const gather.Gather, text: []const u8) bool {
    var installs = inputs.installs(text);
    while (installs.next()) |install| {
        defer arena.free(install.name);
        if (install.kind == .pdb) return true;
    }
    return false;
}

fn writeInstallJournal(arena: std.mem.Allocator, w: *std.Io.Writer, root: store.Root, run: *const store.Run, source: *const Source, inputs: *const gather.Gather, text: []const u8, url: []const u8, hash: []const u8) error{WriteFailed}!void {
    try record.writeJournalInstall(w, source.record_file);
    try writeRecord(arena, w, root, run, inputs, text, url, hash, source.url);
    try w.flush();
}

fn uninstall(arena: std.mem.Allocator, root: store.Root, source: *const Source, _: Options) void {
    const lock: store.Lock = .acquire(root, arena);
    defer lock.release();
    const installed = source.readRecord(arena, root) orelse source.failNotInstalled();
    defer installed.deinit(arena);
    root.checkExesUnchanged(source.given(), installed);

    const journal_file = lock.createJournal(root);
    var journal_buf: [4096]u8 = undefined;
    var journal = journal_file.writer(io, &journal_buf);
    writeUninstallJournal(&journal.interface, source.record_file) catch
        errExit("write '{s}\\{s}': {t}", .{ root.path, store.new_journal_path, journal.err.? });
    lock.apply(arena, root, journal_file);
    print("uninstalled {s}\n", .{source.name});
}

fn writeUninstallJournal(w: *std.Io.Writer, record_file: []const u8) error{WriteFailed}!void {
    try record.writeJournalUninstall(w, record_file);
    try w.flush();
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

fn validateManifest(arena: std.mem.Allocator, root: store.Root, name: []const u8, text: []const u8) void {
    var diag: manifest.Diagnostic = .{};
    manifest.validate(text, &diag) catch {
        if (diag.line == 0) errExit("manifest of '{s}': {s}", .{ name, diag.message });
        if (diag.newer)
            errExit("manifest of '{s}', line {d}: {s} {s}, {f}", .{ name, diag.line, diag.message, diag.unknown, UpdateWinbin.init(arena, root) });
        const update: UpdateWinbin = .init(arena, root);
        if (diag.unknown.len != 0)
            errExit("manifest of '{s}', line {d}: {s} '{s}', " ++ invalid_or_newer ++ ", {f}", .{ name, diag.line, diag.message, diag.unknown, update });
        errExit("manifest of '{s}', line {d}: {s}, " ++ invalid_or_newer ++ ", {f}", .{ name, diag.line, diag.message, update });
    };
}

const invalid_or_newer = "the manifest is either invalid or uses newer features that require a winbin update";

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
pub const crash = @import("crash.zig");
const Error = @import("Error.zig");
const win32 = @import("win32").everything;
const builtin = @import("builtin");
const gather = @import("gather.zig");
const http = @import("http.zig");
const manifest = @import("manifest.zig");
const record = @import("record.zig");
const stage = @import("stage.zig");
const store = @import("store.zig");
const testing = std.testing;
