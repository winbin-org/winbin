//! The winbin directory and everything that keeps it consistent: other winbins
//! running at the same time, and any of them dying at any moment, power loss included.
//!
//! - Each run works in its own directory in `.winbin\tmp`, holding a lock file next to
//!   it for as long as it's alive. One whose lock can be taken was left by a process
//!   that died, so it's safe to delete.
//! - `.winbin\lock` is held to read or change what's installed, and not while
//!   downloading. It's never deleted, another process could be waiting on it.
//! - A change gets everything onto the disk, then writes a journal saying what it's
//!   about to do, then does it. If there's a journal, whoever takes the lock next finishes
//!   that first, going forward from the start: what's already done gets skipped.

const installed_dir = ".winbin\\installed";
const tmp_dir = ".winbin\\tmp";
const lock_path = ".winbin\\lock";
const journal_path = ".winbin\\journal";
/// What a package is about to put next to winbin.exe, once it's all been synced.
pub const publish_dir = ".winbin\\publish";
/// What's been moved out of the way of what's replacing it, to be deleted as soon as it can
/// be. Something still in use stays until a later run.
const delete_dir = ".winbin\\delete";
/// An entry for anything next to winbin.exe that should be cleaned up but has failed so far,
/// which every winbin tries again. It's an empty file with that name.
const deferred_cleanup_dir = ".winbin\\deferred-cleanup";

pub const Root = struct {
    path: []const u8,
    dir: std.Io.Dir,

    pub fn open(path: []const u8) Root {
        return .{
            .path = path,
            .dir = std.Io.Dir.cwd().openDir(main.io, path, .{}) catch |e| main.fatal("open '{s}': {t}", .{ path, e }),
        };
    }

    pub fn close(self: Root) void {
        self.dir.close(main.io);
    }

    pub fn exists(self: Root, path: []const u8) bool {
        self.dir.access(main.io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => main.fatal("check '{s}\\{s}': {t}", .{ self.path, path, e }),
        };
        return true;
    }

    pub fn kind(self: Root, path: []const u8) ?std.Io.File.Kind {
        const stat = self.dir.statFile(main.io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => main.fatal("check '{s}\\{s}': {t}", .{ self.path, path, e }),
        };
        return stat.kind;
    }

    pub fn createDirPath(self: Root, path: []const u8) void {
        self.dir.createDirPath(main.io, path) catch |e| main.fatal("create '{s}\\{s}': {t}", .{ self.path, path, e });
    }

    pub fn deleteTreeWarn(self: Root, path: []const u8) void {
        self.dir.deleteTree(main.io, path) catch |e|
            main.warn("couldn't delete '{s}\\{s}': {t} (is something in it running?)", .{ self.path, path, e });
    }

    /// Something else having a file open, like an antivirus scanning it, fails with
    /// AccessDenied, so that's treated as temporary for a bounded time.
    pub fn rename(self: Root, from: []const u8, to: []const u8) void {
        var delay_ms: i64 = 1;
        var total_ms: i64 = 0;
        while (true) {
            self.dir.rename(from, self.dir, to, main.io) catch |e| switch (e) {
                error.AccessDenied, error.PermissionDenied => {
                    if (total_ms < 2000) {
                        main.io.sleep(.fromMilliseconds(delay_ms), .awake) catch |sleep_err| main.fatal("sleep: {t}", .{sleep_err});
                        total_ms += delay_ms;
                        delay_ms = @min(delay_ms * 2, 100);
                        continue;
                    }
                    main.fatal("move '{s}\\{s}' to '{s}\\{s}': {t} (is it, or something in it, running?)", .{ self.path, from, self.path, to, e });
                },
                else => main.fatal("move '{s}\\{s}' to '{s}\\{s}': {t}", .{ self.path, from, self.path, to, e }),
            };
            return;
        }
    }

    pub fn hashFile(self: Root, path: []const u8) ?[record.hash_len]u8 {
        const file = self.dir.openFile(main.io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => main.fatal("open '{s}\\{s}': {t}", .{ self.path, path, e }),
        };
        defer file.close(main.io);
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(main.io, &read_buf);
        var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
        while (true) {
            const chunk = reader.interface.peekGreedy(1) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => main.fatal("read '{s}\\{s}': {t}", .{ self.path, path, reader.err.? }),
            };
            hasher.update(chunk);
            reader.interface.toss(chunk.len);
        }
        return finishHash(&hasher);
    }

    /// Without syncing a rename can reach the disk before what it renames, leaving
    /// empty or zero-filled files after a power loss.
    pub fn syncFile(self: Root, file: std.Io.File, path: []const u8) void {
        file.sync(main.io) catch |e| main.fatal("sync '{s}\\{s}': {t}", .{ self.path, path, e });
    }

    /// A file that's either all there or not there at all, even after a power loss.
    /// Only call this holding the lock, it writes through a fixed name.
    fn writeDurable(self: Root, arena: std.mem.Allocator, path: []const u8, bytes: []const u8) void {
        const tmp = std.fmt.allocPrint(arena, "{s}.new", .{path}) catch |e| main.oom(e);
        defer arena.free(tmp);
        const file = self.dir.createFile(main.io, tmp, .{}) catch |e|
            main.fatal("create '{s}\\{s}': {t}", .{ self.path, tmp, e });
        {
            defer file.close(main.io);
            file.writeStreamingAll(main.io, bytes) catch |e| main.fatal("write '{s}\\{s}': {t}", .{ self.path, tmp, e });
            self.syncFile(file, tmp);
        }
        self.rename(tmp, path);
    }

    fn recordPath(arena: std.mem.Allocator, name: []const u8) []const u8 {
        return std.fmt.allocPrint(arena, installed_dir ++ "\\{s}", .{name}) catch |e| main.oom(e);
    }

    /// `given` is what to call the package in errors.
    pub fn readRecord(self: Root, arena: std.mem.Allocator, file: []const u8, url: []const u8, given: []const u8) ?record.Record {
        const path = recordPath(arena, file);
        defer arena.free(path);
        const text = self.dir.readFileAlloc(main.io, path, arena, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => main.fatal("read '{s}\\{s}': {t}", .{ self.path, path, e }),
        };
        const installed = record.Record.parse(text) catch |e|
            main.fatal("the installed record of {s} is invalid: {s}. To reinstall it, delete '{s}\\{s}' and whatever it installed next to winbin.exe", .{ given, record.describe(e), self.path, path });
        if (!std.mem.eql(u8, installed.from, url))
            main.fatal("'{s}\\{s}' should be the record of {s}, but it's of {s}", .{ self.path, path, url, installed.from });
        return installed;
    }

    /// Fails if an exe isn't the file that was installed. These sit under a fixed name
    /// in a shared directory, so something else can have replaced one, and it isn't
    /// winbin's to overwrite or delete then. A missing one is fine, it can't be lost.
    /// Links and directories aren't checked: they aren't the program itself, or have
    /// a version in their name.
    pub fn checkExesUnchanged(self: Root, name: []const u8, installed: record.Record) void {
        var entries = installed.entries();
        while (entries.next()) |entry| {
            const exe = switch (entry) {
                .exe => |exe| exe,
                else => continue,
            };
            const actual = self.hashFile(exe.name) orelse continue;
            if (!std.mem.eql(u8, exe.hash, &actual))
                main.fatal("'{s}\\{s}' isn't the file {s} installed, it was changed or replaced (expected {s}, got {s}). If you don't need it, delete it and 'winbin install {s}' puts it back", .{ self.path, exe.name, name, exe.hash, &actual, name });
        }
    }

    pub fn missingEntry(self: Root, installed: record.Record) ?[]const u8 {
        var entries = installed.entries();
        while (entries.next()) |entry| {
            if (!self.exists(entry.name())) return entry.name();
        }
        return null;
    }

    /// Fails now if something can't be moved out of the way, before anything has changed:
    /// a directory can't be while something in it is running. The only real test is doing
    /// it, so it's moved aside and back. Only call this holding the lock.
    pub fn checkReplaceable(self: Root, arena: std.mem.Allocator, name: []const u8) void {
        if (self.kind(name) == null) return;
        const to_delete = freeDeletePath(arena, self, name);
        defer arena.free(to_delete);
        prepareDeleteDir(self);
        self.renameForDelete(arena, name, to_delete) catch |e| {
            self.dir.deleteDir(main.io, delete_dir) catch {};
            main.fatal("replace '{s}\\{s}': {t} (is something in it running?)", .{ self.path, name, e });
        };
        self.renameForDelete(arena, to_delete, name) catch |e|
            main.fatal("move '{s}\\{s}' back to '{s}\\{s}': {t}", .{ self.path, to_delete, self.path, name, e });
        self.dir.deleteDir(main.io, delete_dir) catch {};
    }

    /// Unlike `std`'s rename, this only asks for what a rename needs. `std` asks for write
    /// access too, which is refused for an exe that's running.
    fn renameForDelete(self: Root, arena: std.mem.Allocator, from: []const u8, to: []const u8) error{ OutOfMemory, InvalidWtf8, RenameFailed }!void {
        const windows = std.os.windows;
        const from_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, from);
        defer arena.free(from_w);
        const to_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, to);
        defer arena.free(to_w);

        const attributes: windows.OBJECT.ATTRIBUTES = .{
            .RootDirectory = self.dir.handle,
            .Attributes = .{},
            .ObjectName = @constCast(&windows.UNICODE_STRING.init(from_w)),
            .SecurityDescriptor = null,
        };
        var handle: windows.HANDLE = undefined;
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        if (windows.ntdll.NtCreateFile(
            &handle,
            .{ .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true } },
            &attributes,
            &io_status_block,
            null,
            .{ .NORMAL = true },
            .{ .READ = true, .WRITE = true, .DELETE = true },
            .OPEN,
            .{ .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true },
            null,
            0,
        ) != .SUCCESS) return error.RenameFailed;
        defer windows.CloseHandle(handle);

        const info = try arena.create(windows.FILE.RENAME_INFORMATION);
        defer arena.destroy(info);
        info.Flags = .{};
        info.RootDirectory = self.dir.handle;
        info.FileNameLength = @intCast(to_w.len * @sizeOf(u16));
        @memcpy(info.FileName[0..to_w.len], to_w);
        const buffer = info.toBuffer();
        if (windows.ntdll.NtSetInformationFile(handle, &io_status_block, buffer.ptr, @intCast(buffer.len), .Rename) != .SUCCESS)
            return error.RenameFailed;
    }

    /// Out of the way, and deleted as soon as it can be, which can't be yet if it's running.
    fn moveToDelete(self: Root, arena: std.mem.Allocator, name: []const u8) void {
        const to_delete = freeDeletePath(arena, self, name);
        defer arena.free(to_delete);
        prepareDeleteDir(self);
        self.renameForDelete(arena, name, to_delete) catch |e|
            main.fatal("move '{s}\\{s}' to '{s}\\{s}': {t} (is something in it running? winbin finishes this next time it runs)", .{ self.path, name, self.path, to_delete, e });
    }

    /// Whether it's been moved to be deleted, or is already gone.
    fn tryMoveToDelete(self: Root, arena: std.mem.Allocator, name: []const u8) bool {
        if (self.kind(name) == null) return true;
        const to_delete = freeDeletePath(arena, self, name);
        defer arena.free(to_delete);
        prepareDeleteDir(self);
        self.renameForDelete(arena, name, to_delete) catch return false;
        return true;
    }

    /// For something that doesn't matter having been deleted yet.
    fn deleteOrDefer(self: Root, arena: std.mem.Allocator, name: []const u8) void {
        if (self.tryMoveToDelete(arena, name)) return;
        main.warn("couldn't delete '{s}\\{s}' (is something in it running? winbin finishes this once it's stopped)", .{ self.path, name });
        deferCleanup(arena, self, name);
    }

    /// Something in it being in use isn't worth saying, it's what it's for.
    fn cleanDeleteDir(self: Root) void {
        self.dir.deleteTree(main.io, delete_dir) catch |e| switch (e) {
            error.AccessDenied, error.PermissionDenied, error.FileBusy => {},
            else => main.warn("couldn't delete '{s}\\{s}': {t}", .{ self.path, delete_dir, e }),
        };
    }

    /// Only call this holding the lock.
    pub fn installedIterator(self: Root, arena: std.mem.Allocator) InstalledIterator {
        const dir = self.dir.openDir(main.io, installed_dir, .{ .iterate = true }) catch |e|
            main.fatal("open '{s}\\{s}': {t}", .{ self.path, installed_dir, e });
        return .{ .root = self, .dir = dir, .it = dir.iterate(), .arena = arena };
    }
};

pub const InstalledIterator = struct {
    root: Root,
    dir: std.Io.Dir,
    it: std.Io.Dir.Iterator,
    arena: std.mem.Allocator,
    /// Whether there's been a record that couldn't be read, and was warned about.
    skipped_invalid: bool = false,

    pub fn next(self: *InstalledIterator) ?record.Record {
        while (self.it.next(main.io) catch |e| main.fatal("read '{s}\\{s}': {t}", .{ self.root.path, installed_dir, e })) |entry| {
            const text = self.dir.readFileAlloc(main.io, entry.name, self.arena, .unlimited) catch |e|
                main.fatal("read '{s}\\{s}\\{s}': {t}", .{ self.root.path, installed_dir, entry.name, e });
            return record.Record.parse(text) catch |e| {
                main.warn("'{s}\\{s}\\{s}' is invalid: {s}", .{ self.root.path, installed_dir, entry.name, record.describe(e) });
                self.arena.free(text);
                self.skipped_invalid = true;
                continue;
            };
        }
        return null;
    }

    pub fn close(self: *InstalledIterator) void {
        self.dir.close(main.io);
    }
};

pub fn finishHash(hasher: *std.crypto.hash.sha2.Sha256) [record.hash_len]u8 {
    var out: [record.hash_len]u8 = undefined;
    const hex = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    _ = std.fmt.bufPrint(&out, "sha256:{s}", .{&hex}) catch unreachable;
    return out;
}

/// Holds whoever else is reading or changing what's installed off until it's released,
/// which also happens if the process dies.
pub const Lock = struct {
    file: std.Io.File,

    /// Finishes anything an earlier process didn't.
    pub fn acquire(root: Root, arena: std.mem.Allocator) Lock {
        root.createDirPath(installed_dir);
        const file = createOrOpen(root, lock_path);
        const locked = file.tryLock(main.io, .exclusive) catch |e| main.fatal("lock '{s}\\{s}': {t}", .{ root.path, lock_path, e });
        if (!locked) {
            main.print("waiting for another winbin to finish\n", .{});
            file.lock(main.io, .exclusive) catch |e| main.fatal("lock '{s}\\{s}': {t}", .{ root.path, lock_path, e });
        }
        if (root.dir.readFileAlloc(main.io, journal_path, arena, .unlimited)) |text| {
            defer arena.free(text);
            main.print("finishing what an earlier winbin was doing\n", .{});
            carryOut(arena, root, text);
        } else |e| switch (e) {
            error.FileNotFound => {
                // Without a journal nothing's been done with these yet.
                root.deleteTreeWarn(publish_dir);
                root.cleanDeleteDir();
            },
            else => main.fatal("read '{s}\\{s}': {t}", .{ root.path, journal_path, e }),
        }
        retryDeferredCleanup(arena, root);
        return .{ .file = file };
    }

    pub fn release(self: Lock) void {
        self.file.close(main.io);
    }

    /// Makes a change, which is complete even if this process dies once it's started.
    pub fn apply(self: Lock, arena: std.mem.Allocator, root: Root, journal_text: []const u8) void {
        _ = self; // only someone holding the lock can do this
        root.writeDurable(arena, journal_path, journal_text);
        carryOut(arena, root, journal_text);
    }
};

fn createOrOpen(root: Root, path: []const u8) std.Io.File {
    if (root.dir.createFile(main.io, path, .{ .exclusive = true })) |file| {
        return file;
    } else |e| switch (e) {
        error.PathAlreadyExists => {},
        else => main.fatal("create '{s}\\{s}': {t}", .{ root.path, path, e }),
    }
    return root.dir.openFile(main.io, path, .{}) catch |e| main.fatal("open '{s}\\{s}': {t}", .{ root.path, path, e });
}

/// Going forward from the start each time: anything already done gets skipped, so it
/// doesn't matter how far an earlier attempt got.
fn carryOut(arena: std.mem.Allocator, root: Root, text: []const u8) void {
    const journal = record.Journal.parse(text) catch |e|
        main.fatal("'{s}\\{s}' isn't valid ({t}). Nothing should have left it like that, so check what's next to winbin.exe, then delete it", .{ root.path, journal_path, e });

    if (journal.record) |new_record| {
        var entries = new_record.entries();
        while (entries.next()) |entry| {
            const published = std.fmt.allocPrint(arena, publish_dir ++ "\\{s}", .{entry.name()}) catch |e| main.oom(e);
            defer arena.free(published);
            if (!root.exists(published)) continue;
            // Even a file: renaming over one fails if it's running.
            if (root.kind(entry.name()) != null) root.moveToDelete(arena, entry.name());
            root.rename(published, entry.name());
        }
    }

    var actions = journal.actions();
    while (actions.next()) |action| switch (action) {
        .remove_file => |file| root.dir.deleteFile(main.io, file) catch |e| switch (e) {
            error.FileNotFound => {},
            error.AccessDenied, error.PermissionDenied, error.FileBusy => root.moveToDelete(arena, file),
            else => main.fatal("delete '{s}\\{s}': {t}", .{ root.path, file, e }),
        },
        else => {},
    };

    const record_path = Root.recordPath(arena, journal.record_file);
    defer arena.free(record_path);
    if (journal.record != null) {
        root.writeDurable(arena, record_path, journal.record_text);
    } else root.dir.deleteFile(main.io, record_path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => main.fatal("delete '{s}\\{s}': {t}", .{ root.path, record_path, e }),
    };

    // Last: the new version is complete, so failing here only leaves files behind.
    actions = journal.actions();
    while (actions.next()) |action| switch (action) {
        .retire_dir, .remove_dir => |tree| root.deleteOrDefer(arena, tree),
        .remove_file => {},
    };
    root.deleteTreeWarn(publish_dir);
    root.cleanDeleteDir();
    root.dir.deleteFile(main.io, journal_path) catch |e| main.fatal("delete '{s}\\{s}': {t}", .{ root.path, journal_path, e });
}

fn prepareDeleteDir(root: Root) void {
    if (root.kind(delete_dir)) |kind| if (kind != .directory)
        root.dir.deleteFile(main.io, delete_dir) catch |e| main.fatal("delete '{s}\\{s}': {t}", .{ root.path, delete_dir, e });
    root.createDirPath(delete_dir);
}

fn deferCleanup(arena: std.mem.Allocator, root: Root, name: []const u8) void {
    root.createDirPath(deferred_cleanup_dir);
    const path = std.fmt.allocPrint(arena, deferred_cleanup_dir ++ "\\{s}", .{name}) catch |e| main.oom(e);
    defer arena.free(path);
    const file = root.dir.createFile(main.io, path, .{}) catch |e|
        main.fatal("create '{s}\\{s}': {t}", .{ root.path, path, e });
    defer file.close(main.io);
    root.syncFile(file, path);
}

/// Whether a record says this name is wanted, because something installed it again since it
/// was deferred. A record that can't be read could be saying so, and then there's no telling.
fn wantedByRecord(arena: std.mem.Allocator, root: Root, name: []const u8) enum { yes, no, unknown } {
    var installed = root.installedIterator(arena);
    defer installed.close();
    while (installed.next()) |r| {
        defer r.deinit(arena);
        if (r.has(name)) return .yes;
    }
    return if (installed.skipped_invalid) .unknown else .no;
}

fn retryDeferredCleanup(arena: std.mem.Allocator, root: Root) void {
    const deferred = root.dir.openDir(main.io, deferred_cleanup_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => main.fatal("open '{s}\\{s}': {t}", .{ root.path, deferred_cleanup_dir, e }),
    };
    defer deferred.close(main.io);
    var it = deferred.iterate();
    while (it.next(main.io) catch |e| main.fatal("read '{s}\\{s}': {t}", .{ root.path, deferred_cleanup_dir, e })) |entry| {
        if (!manifest.isDirName(entry.name)) {
            main.warn("ignoring '{s}\\{s}\\{s}', nothing winbin installs could have that name", .{ root.path, deferred_cleanup_dir, entry.name });
            continue;
        }
        if (root.kind(entry.name) != null) switch (wantedByRecord(arena, root, entry.name)) {
            // the note's out of date, what's there is staying
            .yes => {},
            .unknown => continue,
            // Only a directory gets moved, this can't be what makes winbin.exe disappear.
            .no => if (root.kind(entry.name) == .directory) {
                if (!root.tryMoveToDelete(arena, entry.name)) continue;
            } else root.dir.deleteTree(main.io, entry.name) catch continue,
        };
        deferred.deleteFile(main.io, entry.name) catch |e|
            main.warn("couldn't delete '{s}\\{s}\\{s}': {t}", .{ root.path, deferred_cleanup_dir, entry.name, e });
    }
    root.dir.deleteDir(main.io, deferred_cleanup_dir) catch |e| switch (e) {
        error.DirNotEmpty => {},
        else => main.warn("couldn't delete '{s}\\{s}': {t}", .{ root.path, deferred_cleanup_dir, e }),
    };
    root.cleanDeleteDir();
}

/// Where to move something that's to be deleted: its own name, or that name with `.1`, `.2`
/// and so on if something earlier is still there.
fn freeDeletePath(arena: std.mem.Allocator, root: Root, name: []const u8) []const u8 {
    const path = std.fmt.allocPrint(arena, delete_dir ++ "\\{s}", .{name}) catch |e| main.oom(e);
    if (root.kind(delete_dir) != .directory or !root.exists(path)) return path;
    arena.free(path);
    var number: usize = 1;
    while (true) : (number += 1) {
        const numbered = std.fmt.allocPrint(arena, delete_dir ++ "\\{s}.{d}", .{ name, number }) catch |e| main.oom(e);
        if (!root.exists(numbered)) return numbered;
        arena.free(numbered);
    }
}

/// This process's own directory to work in. It's cleaned up by `end`, or by the next
/// process if this one fails or dies, since nothing unwinds then.
pub const Run = struct {
    dir: []const u8,
    lock_path: []const u8,
    /// What's been downloaded, which `discard` deletes from and `install` moves from.
    staging: []const u8,
    /// What's been installed, which only moves next to winbin.exe once a manifest has
    /// run all the way through, so a failure can't leave half of a package there.
    out: []const u8,
    lock: std.Io.File,

    pub fn begin(arena: std.mem.Allocator, root: Root) Run {
        root.createDirPath(tmp_dir);
        cleanAbandonedRuns(root);
        while (true) {
            var random_bytes: [12]u8 = undefined;
            main.io.random(&random_bytes);
            const hex = std.fmt.bytesToHex(random_bytes, .lower);
            const dir = std.fmt.allocPrint(arena, tmp_dir ++ "\\{s}", .{&hex}) catch |e| main.oom(e);
            const run_lock_path = std.fmt.allocPrint(arena, "{s}.lock", .{dir}) catch |e| main.oom(e);
            const lock = root.dir.createFile(main.io, run_lock_path, .{ .exclusive = true }) catch |e| switch (e) {
                error.PathAlreadyExists => {
                    arena.free(run_lock_path);
                    arena.free(dir);
                    continue;
                },
                else => main.fatal("create '{s}\\{s}': {t}", .{ root.path, run_lock_path, e }),
            };
            // There's a window between creating and locking it where another process
            // cleaning up could lock it first. If so it gets deleted, so try a new name.
            const locked = lock.tryLock(main.io, .exclusive) catch |e| main.fatal("lock '{s}\\{s}': {t}", .{ root.path, run_lock_path, e });
            if (!locked or isDeleted(root, lock, run_lock_path)) {
                lock.close(main.io);
                arena.free(run_lock_path);
                arena.free(dir);
                continue;
            }
            const staging = std.fmt.allocPrint(arena, "{s}\\staging", .{dir}) catch |e| main.oom(e);
            const out = std.fmt.allocPrint(arena, "{s}\\out", .{dir}) catch |e| main.oom(e);
            root.createDirPath(staging);
            root.createDirPath(out);
            return .{ .dir = dir, .lock_path = run_lock_path, .staging = staging, .out = out, .lock = lock };
        }
    }

    pub fn end(self: *const Run, arena: std.mem.Allocator, root: Root) void {
        root.deleteTreeWarn(self.dir);
        // delete before closing so no other process can lock it in between
        root.dir.deleteFile(main.io, self.lock_path) catch |e|
            main.warn("couldn't delete '{s}\\{s}': {t}", .{ root.path, self.lock_path, e });
        self.lock.close(main.io);
        arena.free(self.out);
        arena.free(self.staging);
        arena.free(self.lock_path);
        arena.free(self.dir);
    }
};

fn isDeleted(root: Root, file: std.Io.File, path: []const u8) bool {
    var io_status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
    var info: std.os.windows.FILE.STANDARD_INFORMATION = undefined;
    const rc = std.os.windows.ntdll.NtQueryInformationFile(file.handle, &io_status_block, &info, @sizeOf(std.os.windows.FILE.STANDARD_INFORMATION), .Standard);
    if (rc != .SUCCESS) main.fatal("check '{s}\\{s}': NTSTATUS 0x{x}", .{ root.path, path, @backingInt(rc) });
    return info.DeletePending.toBool() or info.NumberOfLinks == 0;
}

/// A lock that can be taken was left by a process that died. It's only ever tried, never
/// waited on.
fn cleanAbandonedRuns(root: Root) void {
    const tmp = root.dir.openDir(main.io, tmp_dir, .{ .iterate = true }) catch |e|
        main.fatal("open '{s}\\{s}': {t}", .{ root.path, tmp_dir, e });
    defer tmp.close(main.io);
    var it = tmp.iterate();
    while (it.next(main.io) catch |e| main.fatal("read '{s}\\{s}': {t}", .{ root.path, tmp_dir, e })) |entry| {
        const lock_suffix = ".lock";
        if (!std.mem.endsWith(u8, entry.name, lock_suffix)) continue;
        const lock = tmp.openFile(main.io, entry.name, .{}) catch |e| switch (e) {
            // its owner finished or another process cleaned it up
            error.FileNotFound => continue,
            else => main.fatal("open '{s}\\{s}\\{s}': {t}", .{ root.path, tmp_dir, entry.name, e }),
        };
        defer lock.close(main.io);
        // locked means its owner is still alive
        const locked = lock.tryLock(main.io, .exclusive) catch |e| main.fatal("lock '{s}\\{s}\\{s}': {t}", .{ root.path, tmp_dir, entry.name, e });
        if (!locked) continue;
        // Failing here only leaves it for the next process, it isn't in the way.
        const run_name = entry.name[0 .. entry.name.len - lock_suffix.len];
        tmp.deleteTree(main.io, run_name) catch |e| {
            main.warn("couldn't delete '{s}\\{s}\\{s}': {t}", .{ root.path, tmp_dir, run_name, e });
            continue;
        };
        // delete while holding the lock so an owner that hasn't locked it yet sees it's gone
        tmp.deleteFile(main.io, entry.name) catch |e| switch (e) {
            error.FileNotFound => {},
            else => main.warn("couldn't delete '{s}\\{s}\\{s}': {t}", .{ root.path, tmp_dir, entry.name, e }),
        };
    }
}

const std = @import("std");
const manifest = @import("manifest.zig");
const record = @import("record.zig");
const main = @import("main.zig");
