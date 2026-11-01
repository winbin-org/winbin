//! Getting a package ready to go next to winbin.exe: downloading it, extracting it, and
//! carrying out its `discard` and `install` lines. All of it happens in a `Run`'s
//! directory, so nothing next to winbin.exe has changed if it fails.

const exelink_template = @embedFile("exelink_template");

fn download(arena: std.mem.Allocator, root: store.Root, url: []const u8, path: []const u8) [record.hash_len]u8 {
    main.print("downloading {s}\n", .{url});
    const response: http.Response = .get(arena, url, .follow);
    defer response.close();
    if (response.status != 200) main.fatal("GET {s}: HTTP {d}", .{ url, response.status });

    const file = root.dir.createFile(main.io, path, .{}) catch |e|
        main.fatal("create '{s}\\{s}': {t}", .{ root.path, path, e });
    defer file.close(main.io);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = response.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        file.writeStreamingAll(main.io, buf[0..n]) catch |e|
            main.fatal("write '{s}\\{s}': {t}", .{ root.path, path, e });
    }
    // it might go on to be installed as it is
    root.syncFile(file, path);
    return store.finishHash(&hasher);
}

/// Hex can be in either case. A package with no hash to expect matches anything.
pub fn hashMatches(expected: ?[]const u8, actual: []const u8) bool {
    return if (expected) |e| std.ascii.eqlIgnoreCase(e, actual) else true;
}

pub fn fetchDownload(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, package: []const u8, url: []const u8, expected: ?[]const u8, extract: bool) [record.hash_len]u8 {
    const path = std.fmt.allocPrint(arena, "{s}\\download", .{run.dir}) catch |e| main.oom(e);
    defer arena.free(path);
    const hash = download(arena, root, url, path);
    // before anything looks inside it
    if (!hashMatches(expected, &hash))
        main.fatal("{s}: the download from {s} has the wrong hash, expected {s}, got {s}", .{ package, url, expected.?, &hash });
    if (extract) {
        extractArchive(arena, root, run, package, url, path);
        root.dir.deleteFile(main.io, path) catch |e| main.fatal("delete '{s}\\{s}': {t}", .{ root.path, path, e });
    } else {
        const name = manifest.urlName(url);
        if (name.len == 0 or !manifest.isSafePath(name) or std.mem.findAny(u8, name, "/\\") != null)
            main.fatal("{s}: can't name the download after its URL, {s}", .{ package, url });
        const staged = stagedPath(arena, run, name);
        defer arena.free(staged);
        root.rename(path, staged);
    }
    return hash;
}

/// Extracts the whole archive to staging, syncing each file while it's still open:
/// opening them all again afterwards takes far longer. Paths are from the network,
/// and std.zip only rejects `..` and a leading slash: not on Windows' drives and
/// streams, so each one is checked here.
fn extractArchive(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, package: []const u8, url: []const u8, zip_path: []const u8) void {
    const zip_file = root.dir.openFile(main.io, zip_path, .{}) catch |e|
        main.fatal("open '{s}\\{s}': {t}", .{ root.path, zip_path, e });
    defer zip_file.close(main.io);
    var read_buf: [4096]u8 = undefined;
    var reader = zip_file.reader(main.io, &read_buf);

    const tree = root.dir.openDir(main.io, run.staging, .{}) catch |e|
        main.fatal("open '{s}\\{s}': {t}", .{ root.path, run.staging, e });
    defer tree.close(main.io);

    const options: std.zip.ExtractOptions = .{ .allow_backslashes = true };
    var it = std.zip.Iterator.init(&reader) catch |e| main.fatal("read zip {s}: {t}", .{ url, e });
    while (it.next() catch |e| main.fatal("read zip {s}: {t}", .{ url, e })) |entry| {
        const filename_buf = arena.alloc(u8, entry.filename_len) catch |e| main.oom(e);
        defer arena.free(filename_buf);
        const entry_name = entry.getFilename(&reader, filename_buf, options) catch |e|
            main.fatal("read zip {s}: {t}", .{ url, e });
        const trimmed = std.mem.trimEnd(u8, entry_name, "/");
        if (!manifest.isSafePath(trimmed))
            main.fatal("{s}: {s} has a path that isn't safe to extract: '{s}'", .{ package, url, entry_name });
        if (trimmed.len != entry_name.len) {
            if (entry.uncompressed_size != 0) main.fatal("{s}: {s} has a directory with contents: '{s}'", .{ package, url, entry_name });
            tree.createDirPath(main.io, trimmed) catch |e| main.fatal("extract '{s}' from {s}: {t}", .{ entry_name, url, e });
            continue;
        }
        if (std.fs.path.dirname(entry_name)) |parent| tree.createDirPath(main.io, parent) catch |e|
            main.fatal("extract '{s}' from {s}: {t}", .{ entry_name, url, e });
        const out = tree.createFile(main.io, entry_name, .{ .exclusive = true }) catch |e|
            main.fatal("extract '{s}' from {s}: {t}", .{ entry_name, url, e });
        defer out.close(main.io);
        var write_buf: [4096]u8 = undefined;
        var writer = out.writer(main.io, &write_buf);
        entry.extractTo(&reader, &writer.interface) catch |e| switch (e) {
            error.WriteFailed => main.fatal("extract '{s}' from {s}: {t}", .{ entry_name, url, writer.err.? }),
            else => main.fatal("extract '{s}' from {s}: {t}", .{ entry_name, url, e }),
        };
        writer.interface.flush() catch main.fatal("extract '{s}' from {s}: {t}", .{ entry_name, url, writer.err.? });
        out.sync(main.io) catch |e| main.fatal("sync '{s}' from {s}: {t}", .{ entry_name, url, e });
    }
}

/// Carries out what comes after the download, in the order it's written: `discard`
/// deletes, and `install` moves. Everything in the archive has to be accounted for by
/// the end, so a new file in a release gets noticed.
pub fn carryOut(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, inputs: *const gather.Gather, text: []const u8, url: []const u8) void {
    const package = inputs.package;
    var it = manifest.statements(text);
    while (it.next()) |numbered| {
        const line = numbered.number;
        if (!inputs.applies(numbered)) continue;
        switch (numbered.statement) {
            .discard => |expr| {
                const path = inputs.evalArchivePath(line, expr);
                defer arena.free(path);
                const staged = stagedPath(arena, run, path);
                defer arena.free(staged);
                if (root.kind(staged) == null)
                    main.fatal("{s}, line {d}: can't discard '{s}', it isn't in the archive", .{ package, line, path });
                root.dir.deleteTree(main.io, staged) catch |e| main.fatal("delete '{s}\\{s}': {t}", .{ root.path, staged, e });
            },
            .install_exe => |install| {
                const name = inputs.evalExeName(line, install.dest);
                defer arena.free(name);
                const path = if (install.from) |from| inputs.evalArchivePath(line, from) else name;
                defer if (install.from != null) arena.free(path);
                checkFromDiffers(package, line, install.from != null, path, name);
                const staged = stagedPath(arena, run, path);
                defer arena.free(staged);
                const kind = root.kind(staged) orelse
                    main.fatal("{s}, line {d}: can't install '{s}', it isn't in the archive", .{ package, line, path });
                if (kind == .directory) main.fatal("{s}, line {d}: '{s}' is a directory, not an exe", .{ package, line, path });
                const out = outPath(arena, root, run, package, line, name);
                defer arena.free(out);
                root.rename(staged, out);
            },
            .install_dir => |install| {
                const name = inputs.evalDirName(line, install.dest);
                defer arena.free(name);
                const out = outPath(arena, root, run, package, line, name);
                defer arena.free(out);
                const whole = if (install.from) |from| from == .string and std.mem.eql(u8, from.string, ".") else false;
                if (whole) {
                    root.rename(run.staging, out);
                    root.createDirPath(run.staging);
                    continue;
                }
                const path = if (install.from) |from| inputs.evalArchivePath(line, from) else name;
                defer if (install.from != null) arena.free(path);
                checkFromDiffers(package, line, install.from != null, path, name);
                const staged = stagedPath(arena, run, path);
                defer arena.free(staged);
                const kind = root.kind(staged) orelse
                    main.fatal("{s}, line {d}: can't install '{s}', it isn't in the archive", .{ package, line, path });
                if (kind != .directory) main.fatal("{s}, line {d}: '{s}' is a file, not a directory", .{ package, line, path });
                root.rename(staged, out);
            },
            .install_exelink => |link| writeLink(arena, root, run, inputs, line, link.dest, link.target),
            .install_pdb => |install| {
                const name = inputs.evalPdbName(line, install.dest);
                defer arena.free(name);
                checkPdbHasExe(arena, inputs, text, line, name);
                const path = if (install.from) |from| inputs.evalArchivePath(line, from) else name;
                defer if (install.from != null) arena.free(path);
                checkFromDiffers(package, line, install.from != null, path, name);
                const staged = stagedPath(arena, run, path);
                defer arena.free(staged);
                const kind = root.kind(staged) orelse
                    main.fatal("{s}, line {d}: can't install '{s}', it isn't in the archive", .{ package, line, path });
                if (kind == .directory) main.fatal("{s}, line {d}: '{s}' is a directory, not a pdb", .{ package, line, path });
                if (inputs.with_pdbs) {
                    const out = outPath(arena, root, run, package, line, name);
                    defer arena.free(out);
                    root.rename(staged, out);
                } else root.dir.deleteFile(main.io, staged) catch |e| main.fatal("delete '{s}\\{s}': {t}", .{ root.path, staged, e });
            },
            else => {},
        }
    }
    checkNothingLeft(arena, root, run, package, url);
}

/// A PDB belongs to the exe of the same name, which has to be installed along with it.
fn checkPdbHasExe(arena: std.mem.Allocator, inputs: *const gather.Gather, text: []const u8, line: u32, pdb: []const u8) void {
    const stem = pdb[0 .. pdb.len - ".pdb".len];
    var installs = inputs.installs(text);
    while (installs.next()) |install| {
        defer arena.free(install.name);
        if (install.kind != .exe) continue;
        if (std.ascii.eqlIgnoreCase(install.name[0 .. install.name.len - ".exe".len], stem)) return;
    }
    main.fatal("{s}, line {d}: nothing installs the exe that '{s}' is for, '{s}.exe'", .{ inputs.package, line, pdb, stem });
}

fn checkFromDiffers(package: []const u8, line: u32, has_from: bool, path: []const u8, name: []const u8) void {
    if (has_from and std.mem.eql(u8, path, name))
        main.fatal("{s}, line {d}: leave out 'from' when it's the same as the name, '{s}'", .{ package, line, name });
}

fn stagedPath(arena: std.mem.Allocator, run: *const store.Run, path: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.staging, path }) catch |e| main.oom(e);
}

fn outPath(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, package: []const u8, line: u32, name: []const u8) []const u8 {
    const path = std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.out, name }) catch |e| main.oom(e);
    if (root.kind(path) != null)
        main.fatal("{s}, line {d}: '{s}' is installed twice", .{ package, line, name });
    return path;
}

/// Its target is relative to the link, so the whole directory can be moved, and it
/// has to be in a directory the manifest has installed.
fn writeLink(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, inputs: *const gather.Gather, line: u32, dest_expr: manifest.Expr, target_expr: manifest.Expr) void {
    const package = inputs.package;
    const name = inputs.evalExeName(line, dest_expr);
    defer arena.free(name);
    const target = inputs.eval(target_expr);
    defer arena.free(target);
    if (target.len > exelink.max_target_bytes / 2)
        main.fatal("{s}, line {d}: exelink path too long", .{ package, line });
    if (!manifest.isLinkTarget(target))
        main.fatal("{s}, line {d}: the exelink path came to '{s}', which isn't a path into an installed directory", .{ package, line, target });

    const installed = std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.out, target }) catch |e| main.oom(e);
    defer arena.free(installed);
    const kind = root.kind(installed) orelse
        main.fatal("{s}, line {d}: 'install exelink \"{s}\"' runs '{s}', which isn't in an installed directory", .{ package, line, name, target });
    if (kind == .directory) main.fatal("{s}, line {d}: 'install exelink \"{s}\"' runs '{s}', which is a directory", .{ package, line, name, target });

    const out = outPath(arena, root, run, package, line, name);
    defer arena.free(out);
    const file = root.dir.createFile(main.io, out, .{}) catch |e|
        main.fatal("create '{s}\\{s}': {t}", .{ root.path, out, e });
    defer file.close(main.io);
    var link_buf: [exelink_template.len + exelink.max_target_bytes + 1024]u8 = undefined;
    file.writeStreamingAll(main.io, exelink.create(exelink_template, target, &link_buf)) catch |e|
        main.fatal("write '{s}\\{s}': {t}", .{ root.path, out, e });
    root.syncFile(file, out);
}

/// Empty directories don't count: moving things out of a directory leaves it behind.
fn checkNothingLeft(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, package: []const u8, url: []const u8) void {
    const staging = root.dir.openDir(main.io, run.staging, .{ .iterate = true }) catch |e|
        main.fatal("open '{s}\\{s}': {t}", .{ root.path, run.staging, e });
    defer staging.close(main.io);
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(arena);
    if (findFile(arena, staging, &path)) |left|
        main.fatal("{s}: nothing installs or discards '{s}' from {s}. If it's new in this release, the manifest needs updating", .{ package, left, url });
}

fn findFile(arena: std.mem.Allocator, parent: std.Io.Dir, path: *std.ArrayList(u8)) ?[]const u8 {
    const len = path.items.len;
    var it = parent.iterate();
    while (it.next(main.io) catch |e| main.fatal("read the staging directory: {t}", .{e})) |entry| {
        path.shrinkRetainingCapacity(len);
        path.appendSlice(arena, entry.name) catch |e| main.oom(e);
        if (entry.kind != .directory) return path.items;
        const sub = parent.openDir(main.io, entry.name, .{ .iterate = true }) catch |e|
            main.fatal("open '{s}' in the staging directory: {t}", .{ path.items, e });
        defer sub.close(main.io);
        path.append(arena, '/') catch |e| main.oom(e);
        if (findFile(arena, sub, path)) |found| return found;
    }
    return null;
}

const std = @import("std");
const exelink = @import("exelink.zig");
const manifest = @import("manifest.zig");
const record = @import("record.zig");
const store = @import("store.zig");
const gather = @import("gather.zig");
const http = @import("http.zig");
const main = @import("main.zig");
