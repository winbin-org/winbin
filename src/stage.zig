//! Getting a package ready to go in the winbin directory: downloading it, extracting it,
//! and carrying out its `discard` and `install` lines. All of it happens in a `Run`'s
//! directory, so nothing a package has installed has changed if it fails.

const exelink_template = @embedFile("exelink_template");

fn download(arena: std.mem.Allocator, winhttp: *const http.WinHttp, root: store.Root, url: []const u8, path: []const u8) [record.hash_len]u8 {
    main.print("downloading {s}\n", .{url});
    const response: http.Response = .get(winhttp, arena, url, .follow);
    defer response.close();
    if (response.status != 200) main.errExit("GET {s}: HTTP {d}", .{ url, response.status });

    const file = root.dir.createFile(main.io, path, .{}) catch |e|
        main.errExit("create '{s}\\{s}': {t}", .{ root.path, path, e });
    defer file.close(main.io);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = response.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        file.writeStreamingAll(main.io, buf[0..n]) catch |e|
            main.errExit("write '{s}\\{s}': {t}", .{ root.path, path, e });
    }
    // it might go on to be installed as it is
    root.syncFile(file, path);
    return store.finishHash(&hasher);
}

/// Hex can be in either case. A package with no hash to expect matches anything.
pub fn hashMatches(expected: ?[]const u8, actual: []const u8) bool {
    return if (expected) |e| std.ascii.eqlIgnoreCase(e, actual) else true;
}

pub fn fetchDownload(arena: std.mem.Allocator, winhttp: *const http.WinHttp, root: store.Root, run: *const store.Run, package: []const u8, url: []const u8, expected: ?[]const u8, extract: bool) [record.hash_len]u8 {
    const path = std.fmt.allocPrint(arena, "{s}\\download", .{run.dir}) catch |e| oom(e);
    defer arena.free(path);
    const hash = download(arena, winhttp, root, url, path);
    // before anything looks inside it
    if (!hashMatches(expected, &hash))
        main.errExit("{s}: the download from {s} has the wrong hash, expected {s}, got {s}", .{ package, url, expected.?, &hash });
    if (extract) {
        extractArchive(root, run, package, url, path);
        root.dir.deleteFile(main.io, path) catch |e| main.errExit("delete '{s}\\{s}': {t}", .{ root.path, path, e });
    } else {
        const name = manifest.urlName(url);
        if (name.len == 0 or !manifest.isSafePath(name) or std.mem.findAny(u8, name, "/\\") != null)
            main.errExit("{s}: can't name the download after its URL, {s}", .{ package, url });
        const staged = stagedPath(arena, run, name);
        defer arena.free(staged);
        root.rename(path, staged);
    }
    return hash;
}

/// Extracts the whole archive to staging, a zip or a tar.gz, going by how the file
/// starts rather than its URL. Each file is synced while it's still open: opening
/// them all again afterwards takes far longer.
fn extractArchive(root: store.Root, run: *const store.Run, package: []const u8, url: []const u8, archive_path: []const u8) void {
    const archive = root.dir.openFile(main.io, archive_path, .{}) catch |e|
        main.errExit("open '{s}\\{s}': {t}", .{ root.path, archive_path, e });
    defer archive.close(main.io);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = archive.reader(main.io, &read_buf);

    const tree = root.dir.openDir(main.io, run.staging, .{}) catch |e|
        main.errExit("open '{s}\\{s}': {t}", .{ root.path, run.staging, e });
    defer tree.close(main.io);

    const start = reader.interface.peek(2) catch |e| switch (e) {
        error.EndOfStream => main.errExit("{s}: {s} is too short to be a zip or a tar.gz", .{ package, url }),
        error.ReadFailed => main.errExit("read '{s}\\{s}': {t}", .{ root.path, archive_path, reader.err.? }),
    };
    if (std.mem.eql(u8, start, "PK")) return extractZip(tree, &reader, package, url);
    if (std.mem.eql(u8, start, "\x1f\x8b")) return extractTarGz(tree, &reader, package, url);
    main.errExit("{s}: {s} isn't a zip or a tar.gz, it starts with {x}", .{ package, url, start });
}

/// Paths are from the network, and std.zip only rejects `..` and a leading slash: not
/// on Windows' drives and streams, so each one is checked here.
fn extractZip(tree: std.Io.Dir, reader: *std.Io.File.Reader, package: []const u8, url: []const u8) void {
    const options: std.zip.ExtractOptions = .{ .allow_backslashes = true };
    var it = std.zip.Iterator.init(reader) catch |e| main.errExit("read zip {s}: {t}", .{ url, e });
    // a zip's name length is 16 bits
    var filename_buf: [std.math.maxInt(u16)]u8 = undefined;
    while (it.next() catch |e| main.errExit("read zip {s}: {t}", .{ url, e })) |entry| {
        const entry_name = entry.getFilename(reader, &filename_buf, options) catch |e|
            main.errExit("read zip {s}: {t}", .{ url, e });
        const trimmed = std.mem.trimEnd(u8, entry_name, "/");
        if (!manifest.isSafePath(trimmed))
            main.errExit("{s}: {s} has a path that isn't safe to extract: '{s}'", .{ package, url, entry_name });
        if (trimmed.len != entry_name.len) {
            if (entry.uncompressed_size != 0) main.errExit("{s}: {s} has a directory with contents: '{s}'", .{ package, url, entry_name });
            tree.createDirPath(main.io, trimmed) catch |e| main.errExit("extract '{s}' from {s}: {t}", .{ entry_name, url, e });
            continue;
        }
        if (std.fs.path.dirname(entry_name)) |parent| tree.createDirPath(main.io, parent) catch |e|
            main.errExit("extract '{s}' from {s}: {t}", .{ entry_name, url, e });
        const out = tree.createFile(main.io, entry_name, .{ .exclusive = true }) catch |e|
            main.errExit("extract '{s}' from {s}: {t}", .{ entry_name, url, e });
        defer out.close(main.io);
        var write_buf: [4096]u8 = undefined;
        var writer = out.writer(main.io, &write_buf);
        entry.extractTo(reader, &writer.interface) catch |e| switch (e) {
            error.WriteFailed => main.errExit("extract '{s}' from {s}: {t}", .{ entry_name, url, writer.err.? }),
            else => main.errExit("extract '{s}' from {s}: {t}", .{ entry_name, url, e }),
        };
        writer.interface.flush() catch main.errExit("extract '{s}' from {s}: {t}", .{ entry_name, url, writer.err.? });
        out.sync(main.io) catch |e| main.errExit("sync '{s}' from {s}: {t}", .{ entry_name, url, e });
    }
}

/// std.tar takes any path, so each one is checked here, and only files and directories
/// are extracted: a link could point outside staging.
fn extractTarGz(tree: std.Io.Dir, reader: *std.Io.File.Reader, package: []const u8, url: []const u8) void {
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
    var name_buf: [4096]u8 = undefined;
    var link_buf: [4096]u8 = undefined;
    var it: std.tar.Iterator = .init(&decompress.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (it.next() catch |e| failTarRead(&decompress, reader, url, e)) |entry| {
        // `tar -C dir .` has "./" as an entry, and in front of every other one
        var name = std.mem.trimEnd(u8, entry.name, "/");
        while (std.mem.startsWith(u8, name, "./")) name = std.mem.trimStart(u8, name["./".len..], "/");
        if (entry.kind == .directory and (name.len == 0 or std.mem.eql(u8, name, "."))) continue;
        if (!manifest.isSafePath(name))
            main.errExit("{s}: {s} has a path that isn't safe to extract: '{s}'", .{ package, url, entry.name });
        switch (entry.kind) {
            .directory => tree.createDirPath(main.io, name) catch |e| main.errExit("extract '{s}' from {s}: {t}", .{ entry.name, url, e }),
            .sym_link => main.errExit("{s}: {s} has a link, '{s}' -> '{s}', and winbin only extracts files and directories", .{ package, url, entry.name, entry.link_name }),
            .file => {
                if (std.fs.path.dirname(name)) |parent| tree.createDirPath(main.io, parent) catch |e|
                    main.errExit("extract '{s}' from {s}: {t}", .{ entry.name, url, e });
                const out = tree.createFile(main.io, name, .{ .exclusive = true }) catch |e|
                    main.errExit("extract '{s}' from {s}: {t}", .{ entry.name, url, e });
                defer out.close(main.io);
                var write_buf: [64 * 1024]u8 = undefined;
                var writer = out.writer(main.io, &write_buf);
                it.streamRemaining(entry, &writer.interface) catch |e| switch (e) {
                    error.WriteFailed => main.errExit("extract '{s}' from {s}: {t}", .{ entry.name, url, writer.err.? }),
                    else => failTarRead(&decompress, reader, url, e),
                };
                writer.interface.flush() catch main.errExit("extract '{s}' from {s}: {t}", .{ entry.name, url, writer.err.? });
                out.sync(main.io) catch |e| main.errExit("sync '{s}' from {s}: {t}", .{ entry.name, url, e });
            },
        }
    }
}

/// ReadFailed hides the real error, which is in the decompressor, or the file under it.
fn failTarRead(decompress: *const std.compress.flate.Decompress, reader: *const std.Io.File.Reader, url: []const u8, err: anyerror) noreturn {
    if (err != error.ReadFailed) main.errExit("read tar {s}: {t}", .{ url, err });
    const gz_err = decompress.err.?;
    if (gz_err == error.ReadFailed) main.errExit("read {s}: {t}", .{ url, reader.err.? });
    main.errExit("read gzip {s}: {t}", .{ url, gz_err });
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
                    main.errExit("{s}, line {d}: can't discard '{s}', it isn't in the archive", .{ package, line, path });
                root.dir.deleteTree(main.io, staged) catch |e| main.errExit("delete '{s}\\{s}': {t}", .{ root.path, staged, e });
            },
            .unwrapdir => |expr| {
                const path = inputs.evalArchivePath(line, expr);
                defer arena.free(path);
                unwrapDir(arena, root, run, package, line, path);
            },
            .install_exe => |install| {
                const name = inputs.evalExeName(line, install.dest);
                defer arena.free(name);
                const staged = stagedSource(arena, root, run, inputs, line, install, name, .exe);
                defer arena.free(staged);
                const out = outPath(arena, root, run, package, line, name);
                defer arena.free(out);
                root.rename(staged, out);
            },
            .install_hardlink => |link| {
                const name = inputs.evalFileName(line, link.dest);
                defer arena.free(name);
                const target = inputs.evalArchivePath(line, link.target);
                defer arena.free(target);
                const existing = std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.out, target }) catch |e| oom(e);
                defer arena.free(existing);
                const kind = root.kind(existing) orelse
                    main.errExit("{s}, line {d}: 'install hardlink \"{s}\"' links to '{s}', which nothing before it installs", .{ package, line, name, target });
                if (kind == .directory) main.errExit("{s}, line {d}: 'install hardlink \"{s}\"' links to '{s}', which is a directory", .{ package, line, name, target });
                const out = outPath(arena, root, run, package, line, name);
                defer arena.free(out);
                hardLink(arena, root, existing, out);
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
                const staged = stagedSource(arena, root, run, inputs, line, install, name, .dir);
                defer arena.free(staged);
                root.rename(staged, out);
            },
            .install_exelink => |link| writeLink(arena, root, run, inputs, line, link.dest, link.target),
            .install_pdb => |install| {
                const name = inputs.evalPdbName(line, install.dest);
                defer arena.free(name);
                checkPdbHasExe(arena, inputs, text, line, name);
                const staged = stagedSource(arena, root, run, inputs, line, install, name, .pdb);
                defer arena.free(staged);
                if (inputs.with_pdbs) {
                    const out = outPath(arena, root, run, package, line, name);
                    defer arena.free(out);
                    root.rename(staged, out);
                } else root.dir.deleteFile(main.io, staged) catch |e| main.errExit("delete '{s}\\{s}': {t}", .{ root.path, staged, e });
            },
            else => {},
        }
    }
    checkNothingLeft(arena, root, run, package, url);
}

/// Moves what's in a directory up into its parent, and removes it. It's moved aside
/// first, since it can have something in it with its own name.
fn unwrapDir(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, package: []const u8, line: u32, path: []const u8) void {
    const staged = stagedPath(arena, run, path);
    defer arena.free(staged);
    const kind = root.kind(staged) orelse
        main.errExit("{s}, line {d}: can't unwrapdir '{s}', it isn't in the archive", .{ package, line, path });
    if (kind != .directory) main.errExit("{s}, line {d}: can't unwrapdir '{s}', it's a file", .{ package, line, path });
    const aside = std.fmt.allocPrint(arena, "{s}\\unwrapdir", .{run.dir}) catch |e| oom(e);
    defer arena.free(aside);
    root.rename(staged, aside);
    const parent = std.fs.path.dirname(staged).?;
    moveContents(arena, root, package, line, path, aside, parent, "");
    root.dir.deleteDir(main.io, aside) catch |e| main.errExit("delete '{s}\\{s}': {t}", .{ root.path, aside, e });
}

/// Directories that are in both are combined, and a file that's in both is an error.
/// It takes the first entry each time, since what it moves out changes the directory.
fn moveContents(arena: std.mem.Allocator, root: store.Root, package: []const u8, line: u32, path: []const u8, from: []const u8, to: []const u8, rel: []const u8) void {
    while (true) {
        const dir = root.dir.openDir(main.io, from, .{ .iterate = true }) catch |e|
            main.errExit("open '{s}\\{s}': {t}", .{ root.path, from, e });
        defer dir.close(main.io);
        var it = dir.iterate();
        const entry = (it.next(main.io) catch |e| main.errExit("read '{s}\\{s}': {t}", .{ root.path, from, e })) orelse return;
        const src = std.fmt.allocPrint(arena, "{s}\\{s}", .{ from, entry.name }) catch |e| oom(e);
        defer arena.free(src);
        const dest = std.fmt.allocPrint(arena, "{s}\\{s}", .{ to, entry.name }) catch |e| oom(e);
        defer arena.free(dest);
        const entry_rel = if (rel.len == 0)
            arena.dupe(u8, entry.name) catch |e| oom(e)
        else
            std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name }) catch |e| oom(e);
        defer arena.free(entry_rel);
        const existing = root.kind(dest) orelse {
            root.rename(src, dest);
            continue;
        };
        if (entry.kind != .directory or existing != .directory)
            main.errExit("{s}, line {d}: can't unwrapdir '{s}', '{s}' is already in the directory it goes into", .{ package, line, path, entry_rel });
        moveContents(arena, root, package, line, path, src, dest, entry_rel);
        root.dir.deleteDir(main.io, src) catch |e| main.errExit("delete '{s}\\{s}': {t}", .{ root.path, src, e });
    }
}

/// std's hardLink isn't supported on Windows.
fn hardLink(arena: std.mem.Allocator, root: store.Root, existing: []const u8, new: []const u8) void {
    const existing_full = std.fmt.allocPrint(arena, "{s}\\{s}", .{ root.path, existing }) catch |e| oom(e);
    defer arena.free(existing_full);
    const new_full = std.fmt.allocPrint(arena, "{s}\\{s}", .{ root.path, new }) catch |e| oom(e);
    defer arena.free(new_full);
    const existing_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, existing_full) catch |e| switch (e) {
        error.OutOfMemory => oom(error.OutOfMemory),
        error.InvalidWtf8 => main.errExit("'{s}' isn't valid WTF-8", .{existing_full}),
    };
    defer arena.free(existing_w);
    const new_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, new_full) catch |e| switch (e) {
        error.OutOfMemory => oom(error.OutOfMemory),
        error.InvalidWtf8 => main.errExit("'{s}' isn't valid WTF-8", .{new_full}),
    };
    defer arena.free(new_w);
    if (win32.CreateHardLinkW(new_w, existing_w, null) == 0)
        main.errExit("hardlink '{s}' to '{s}': CreateHardLinkW failed, error={f}", .{ new_full, existing_full, win32.GetLastError() });
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
    main.errExit("{s}, line {d}: nothing installs the exe that '{s}' is for, '{s}.exe'", .{ inputs.package, line, pdb, stem });
}

/// Where what an `install` moves is in staging, for the caller to free. It's `from`, or the
/// name it's installed as.
fn stagedSource(
    arena: std.mem.Allocator,
    root: store.Root,
    run: *const store.Run,
    inputs: *const gather.Gather,
    line: u32,
    install: manifest.Install,
    name: []const u8,
    what: enum { exe, pdb, dir },
) []const u8 {
    const package = inputs.package;
    const path = if (install.from) |from| inputs.evalArchivePath(line, from) else name;
    defer if (install.from != null) arena.free(path);
    if (install.from != null and std.mem.eql(u8, path, name))
        main.errExit("{s}, line {d}: leave out 'from' when it's the same as the name, '{s}'", .{ package, line, name });
    const staged = stagedPath(arena, run, path);
    const kind = root.kind(staged) orelse
        main.errExit("{s}, line {d}: can't install '{s}', it isn't in the archive", .{ package, line, path });
    switch (what) {
        .exe => if (kind == .directory) main.errExit("{s}, line {d}: '{s}' is a directory, not an exe", .{ package, line, path }),
        .pdb => if (kind == .directory) main.errExit("{s}, line {d}: '{s}' is a directory, not a pdb", .{ package, line, path }),
        .dir => if (kind != .directory) main.errExit("{s}, line {d}: '{s}' is a file, not a directory", .{ package, line, path }),
    }
    return staged;
}

fn stagedPath(arena: std.mem.Allocator, run: *const store.Run, path: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.staging, path }) catch |e| oom(e);
}

fn outPath(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, package: []const u8, line: u32, name: []const u8) []const u8 {
    const path = std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.out, name }) catch |e| oom(e);
    if (root.kind(path) != null)
        main.errExit("{s}, line {d}: '{s}' is installed twice", .{ package, line, name });
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
        main.errExit("{s}, line {d}: exelink path too long", .{ package, line });
    if (!manifest.isLinkTarget(target))
        main.errExit("{s}, line {d}: the exelink path came to '{s}', which isn't a path into an installed directory", .{ package, line, target });

    const installed = std.fmt.allocPrint(arena, "{s}\\{s}", .{ run.out, target }) catch |e| oom(e);
    defer arena.free(installed);
    const kind = root.kind(installed) orelse
        main.errExit("{s}, line {d}: 'install exelink \"{s}\"' runs '{s}', which isn't in an installed directory", .{ package, line, name, target });
    if (kind == .directory) main.errExit("{s}, line {d}: 'install exelink \"{s}\"' runs '{s}', which is a directory", .{ package, line, name, target });

    const out = outPath(arena, root, run, package, line, name);
    defer arena.free(out);
    const file = root.dir.createFile(main.io, out, .{}) catch |e|
        main.errExit("create '{s}\\{s}': {t}", .{ root.path, out, e });
    defer file.close(main.io);
    var link_buf: [exelink_template.len + exelink.max_target_bytes + 1024]u8 = undefined;
    file.writeStreamingAll(main.io, exelink.create(exelink_template, target, &link_buf)) catch |e|
        main.errExit("write '{s}\\{s}': {t}", .{ root.path, out, e });
    root.syncFile(file, out);
}

/// Empty directories don't count: moving things out of a directory leaves it behind.
fn checkNothingLeft(arena: std.mem.Allocator, root: store.Root, run: *const store.Run, package: []const u8, url: []const u8) void {
    const staging = root.dir.openDir(main.io, run.staging, .{ .iterate = true }) catch |e|
        main.errExit("open '{s}\\{s}': {t}", .{ root.path, run.staging, e });
    defer staging.close(main.io);
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(arena);
    if (findFile(arena, staging, &path)) |left|
        main.errExit("{s}: nothing installs or discards '{s}' from {s}. If it's new in this release, the manifest needs updating", .{ package, left, url });
}

fn findFile(arena: std.mem.Allocator, parent: std.Io.Dir, path: *std.ArrayList(u8)) ?[]const u8 {
    const len = path.items.len;
    var it = parent.iterate();
    while (it.next(main.io) catch |e| main.errExit("read the staging directory: {t}", .{e})) |entry| {
        path.shrinkRetainingCapacity(len);
        path.appendSlice(arena, entry.name) catch |e| oom(e);
        if (entry.kind != .directory) return path.items;
        const sub = parent.openDir(main.io, entry.name, .{ .iterate = true }) catch |e|
            main.errExit("open '{s}' in the staging directory: {t}", .{ path.items, e });
        defer sub.close(main.io);
        path.append(arena, '/') catch |e| oom(e);
        if (findFile(arena, sub, path)) |found| return found;
    }
    return null;
}

fn oom(err: error{OutOfMemory}) noreturn {
    main.errExit("{t}", .{err});
}

const std = @import("std");
const win32 = @import("win32").everything;
const exelink = @import("exelink.zig");
const manifest = @import("manifest.zig");
const record = @import("record.zig");
const store = @import("store.zig");
const gather = @import("gather.zig");
const http = @import("http.zig");
const main = @import("main.zig");
