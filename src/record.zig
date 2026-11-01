//! The two files winbin keeps about what's installed, as plain text. Nothing here
//! touches the disk.
//!
//! An install record is what a package has next to winbin.exe: the URL it was
//! downloaded from and the hash of what that served, which is how `update` tells if
//! there's anything new, what it put there, the URL of its manifest which is what
//! identifies the package, and the manifest so `update` can tell if it changed. That
//! manifest is only ever compared, never read: a newer winbin might not understand
//! it, and that shouldn't stop it from uninstalling the package.
//!
//! A journal is a change that's about to be made. It's written before the change
//! starts, so if the change doesn't finish, the next winbin can.

/// `sha256:` and the digest in hex.
pub const hash_len = "sha256:".len + 2 * std.crypto.hash.sha2.Sha256.digest_length;

pub const Entry = union(enum) {
    exe: struct { name: []const u8, hash: []const u8 },
    exelink: []const u8,
    dir: []const u8,
    pdb: []const u8,

    pub fn name(self: Entry) []const u8 {
        return switch (self) {
            .exe => |exe| exe.name,
            .exelink, .dir, .pdb => |n| n,
        };
    }
};

const url_prefix = "installed-url ";
const hash_prefix = "installed-hash ";
const exe_prefix = "installed-exe ";
const exelink_prefix = "installed-exelink ";
const dir_prefix = "installed-dir ";
const pdb_prefix = "installed-pdb ";
const from_prefix = "installed-from ";

/// Null if it isn't one, or isn't valid: uninstalling deletes what these name, so
/// they can't name anything else.
pub fn parseEntry(line: []const u8) ?Entry {
    if (std.mem.startsWith(u8, line, exe_prefix)) {
        const rest = line[exe_prefix.len..];
        const space = std.mem.findScalar(u8, rest, ' ') orelse return null;
        const name = rest[0..space];
        const hash = rest[space + 1 ..];
        return if (manifest.isExeName(name) and manifest.isHash(hash)) .{ .exe = .{ .name = name, .hash = hash } } else null;
    }
    if (std.mem.startsWith(u8, line, exelink_prefix)) {
        const name = line[exelink_prefix.len..];
        return if (manifest.isExeName(name)) .{ .exelink = name } else null;
    }
    if (std.mem.startsWith(u8, line, dir_prefix)) {
        const name = line[dir_prefix.len..];
        return if (manifest.isDirName(name)) .{ .dir = name } else null;
    }
    if (std.mem.startsWith(u8, line, pdb_prefix)) {
        const name = line[pdb_prefix.len..];
        return if (manifest.isPdbName(name)) .{ .pdb = name } else null;
    }
    return null;
}

/// The entries of a valid record.
pub const EntryIterator = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *EntryIterator) ?Entry {
        while (self.it.next()) |line| {
            if (line.len != 0) return parseEntry(line).?;
        }
        return null;
    }
};

pub const Record = struct {
    text: []const u8,
    url: []const u8,
    hash: []const u8,
    entries_text: []const u8,
    from: []const u8,
    manifest: []const u8,

    pub const Error = error{ BadStart, BadEntry, BadSource, BadUrl, BadHash };

    pub fn parse(text: []const u8) Error!Record {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const url_line = lines.next().?;
        const hash_line = lines.next() orelse "";
        if (!std.mem.startsWith(u8, url_line, url_prefix) or !std.mem.startsWith(u8, hash_line, hash_prefix)) return error.BadStart;
        const entries_start = lines.index orelse text.len;
        var from_line = lines.next() orelse "";
        while (!std.mem.startsWith(u8, from_line, from_prefix)) : (from_line = lines.next() orelse "") {
            if (parseEntry(from_line) == null) return error.BadEntry;
        }
        const record: Record = .{
            .text = text,
            .url = url_line[url_prefix.len..],
            .hash = hash_line[hash_prefix.len..],
            .entries_text = text[entries_start .. @intFromPtr(from_line.ptr) - @intFromPtr(text.ptr)],
            .from = from_line[from_prefix.len..],
            .manifest = lines.rest(),
        };
        if (manifest.urlScheme(record.from) == null) return error.BadSource;
        if (!manifest.isUrl(record.url)) return error.BadUrl;
        if (!manifest.isHash(record.hash)) return error.BadHash;
        return record;
    }

    /// For one parsed from text that `allocator` allocated, which is all it points to.
    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }

    pub fn entries(self: Record) EntryIterator {
        return .{ .it = std.mem.splitScalar(u8, self.entries_text, '\n') };
    }

    pub fn hasPdb(self: Record) bool {
        var it = self.entries();
        while (it.next()) |entry| {
            if (entry == .pdb) return true;
        }
        return false;
    }

    /// Whether it has this name, whatever kind of thing it is. Windows ignores case.
    pub fn has(self: Record, name: []const u8) bool {
        var it = self.entries();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name(), name)) return true;
        }
        return false;
    }
};

pub fn describe(err: Record.Error) []const u8 {
    return switch (err) {
        error.BadStart => "it doesn't start with a URL and a hash",
        error.BadEntry => "it has a line that isn't something it installed",
        error.BadSource => "the URL of its manifest isn't valid",
        error.BadUrl => "its URL isn't valid",
        error.BadHash => "its hash isn't valid",
    };
}

pub fn writeStart(w: *std.Io.Writer, url: []const u8, hash: []const u8) std.Io.Writer.Error!void {
    try w.print(url_prefix ++ "{s}\n" ++ hash_prefix ++ "{s}\n", .{ url, hash });
}

pub fn writeEntry(w: *std.Io.Writer, entry: Entry) std.Io.Writer.Error!void {
    switch (entry) {
        .exe => |exe| try w.print(exe_prefix ++ "{s} {s}\n", .{ exe.name, exe.hash }),
        .exelink => |name| try w.print(exelink_prefix ++ "{s}\n", .{name}),
        .dir => |name| try w.print(dir_prefix ++ "{s}\n", .{name}),
        .pdb => |name| try w.print(pdb_prefix ++ "{s}\n", .{name}),
    }
}

pub fn writeEnd(w: *std.Io.Writer, from: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try w.print(from_prefix ++ "{s}\n{s}", .{ from, text });
}

pub const Action = union(enum) {
    remove_file: []const u8,
    /// An old version's directory: failing to delete it is tried again by later winbins.
    retire_dir: []const u8,
    /// A directory being uninstalled, which has to go.
    remove_dir: []const u8,
};

const record_file_prefix = "record-file ";
const remove_file_prefix = "remove-file ";
const retire_dir_prefix = "retire-dir ";
const remove_dir_prefix = "remove-dir ";
const record_line = "record";
const delete_record_line = "delete-record";

fn parseAction(line: []const u8) ?Action {
    if (std.mem.startsWith(u8, line, remove_file_prefix)) {
        const name = line[remove_file_prefix.len..];
        return if (manifest.isExeName(name) or manifest.isPdbName(name)) .{ .remove_file = name } else null;
    }
    if (std.mem.startsWith(u8, line, retire_dir_prefix)) {
        const name = line[retire_dir_prefix.len..];
        return if (manifest.isDirName(name)) .{ .retire_dir = name } else null;
    }
    if (std.mem.startsWith(u8, line, remove_dir_prefix)) {
        const name = line[remove_dir_prefix.len..];
        return if (manifest.isDirName(name)) .{ .remove_dir = name } else null;
    }
    return null;
}

pub const ActionIterator = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *ActionIterator) ?Action {
        while (self.it.next()) |line| {
            if (line.len != 0) return parseAction(line).?;
        }
        return null;
    }
};

pub const Journal = struct {
    record_file: []const u8,
    actions_text: []const u8,
    /// The package's new record, null if the package is going away.
    record: ?Record,
    record_text: []const u8,

    pub const Error = error{ BadRecordFile, BadAction, CutShort, BadRecord };

    pub fn parse(text: []const u8) Error!Journal {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const file_line = lines.next().?;
        if (!std.mem.startsWith(u8, file_line, record_file_prefix)) return error.BadRecordFile;
        const record_file = file_line[record_file_prefix.len..];
        if (!manifest.isPackageName(record_file)) return error.BadRecordFile;
        const actions_start = lines.index orelse return error.CutShort;
        var actions_end = actions_start;
        while (lines.next()) |line| {
            // what's after the last \n, with no line saying what happens to the record
            if (line.len == 0 and lines.index == null) return error.CutShort;
            if (std.mem.eql(u8, line, delete_record_line))
                return .{ .record_file = record_file, .actions_text = text[actions_start..actions_end], .record = null, .record_text = "" };
            if (std.mem.eql(u8, line, record_line)) {
                const record_text = lines.rest();
                return .{
                    .record_file = record_file,
                    .actions_text = text[actions_start..actions_end],
                    .record = Record.parse(record_text) catch return error.BadRecord,
                    .record_text = record_text,
                };
            }
            if (parseAction(line) == null) return error.BadAction;
            actions_end = lines.index orelse return error.CutShort;
        }
        return error.CutShort;
    }

    pub fn actions(self: Journal) ActionIterator {
        return .{ .it = std.mem.splitScalar(u8, self.actions_text, '\n') };
    }
};

pub fn writeJournalStart(w: *std.Io.Writer, record_file: []const u8) std.Io.Writer.Error!void {
    try w.print(record_file_prefix ++ "{s}\n", .{record_file});
}

pub fn writeAction(w: *std.Io.Writer, action: Action) std.Io.Writer.Error!void {
    switch (action) {
        .remove_file => |name| try w.print(remove_file_prefix ++ "{s}\n", .{name}),
        .retire_dir => |name| try w.print(retire_dir_prefix ++ "{s}\n", .{name}),
        .remove_dir => |name| try w.print(remove_dir_prefix ++ "{s}\n", .{name}),
    }
}

pub fn writeJournalRecord(w: *std.Io.Writer, record_text: []const u8) std.Io.Writer.Error!void {
    try w.print(record_line ++ "\n{s}", .{record_text});
}

pub fn writeJournalDeleteRecord(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(delete_record_line ++ "\n");
}

const hash_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const hash_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn sampleRecord(w: *std.Io.Writer) !void {
    try writeStart(w, "https://e.com/a.zip", hash_a);
    try writeEntry(w, .{ .exe = .{ .name = "a.exe", .hash = hash_b } });
    try writeEntry(w, .{ .exelink = "b.exe" });
    try writeEntry(w, .{ .dir = "c-1.0" });
    try writeEnd(w, "file:///C:/pkg/a", "the manifest\nsecond line, installed-from x\n");
}

test "a record round trips" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try sampleRecord(&w);

    const record = try Record.parse(w.buffered());
    try testing.expectEqualStrings("https://e.com/a.zip", record.url);
    try testing.expectEqualStrings(hash_a, record.hash);
    try testing.expectEqualStrings("file:///C:/pkg/a", record.from);
    // whatever the manifest says, it's only the manifest
    try testing.expectEqualStrings("the manifest\nsecond line, installed-from x\n", record.manifest);

    var it = record.entries();
    const exe = it.next().?.exe;
    try testing.expectEqualStrings("a.exe", exe.name);
    try testing.expectEqualStrings(hash_b, exe.hash);
    try testing.expectEqualStrings("b.exe", it.next().?.exelink);
    try testing.expectEqualStrings("c-1.0", it.next().?.dir);
    try testing.expectEqual(null, it.next());

    try testing.expect(record.has("a.exe"));
    try testing.expect(record.has("A.EXE"));
    try testing.expect(record.has("c-1.0"));
    try testing.expect(!record.has("d.exe"));
}

test "a record with nothing in it" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStart(&w, "https://e.com/a.zip", hash_a);
    try writeEnd(&w, "https://e.com/m", "");
    var it = (try Record.parse(w.buffered())).entries();
    try testing.expectEqual(null, it.next());
}

test "a bad record is an error, not a crash" {
    const url = url_prefix ++ "https://e.com/a\n";
    const hash = hash_prefix ++ hash_a ++ "\n";
    try testing.expectError(error.BadStart, Record.parse(""));
    try testing.expectError(error.BadStart, Record.parse("\x00\x00\x00\x00"));
    try testing.expectError(error.BadStart, Record.parse(url));
    try testing.expectError(error.BadEntry, Record.parse(url ++ hash));
    try testing.expectError(error.BadEntry, Record.parse(url ++ hash ++ "what\n"));
    try testing.expectError(error.BadEntry, Record.parse(url ++ hash ++ "\x00\x00"));
    try testing.expectError(error.BadSource, Record.parse(url ++ hash ++ from_prefix ++ "\n"));
    try testing.expectError(error.BadSource, Record.parse(url ++ hash ++ from_prefix ++ "C:\\pkg\\a\n"));
    const from = from_prefix ++ "https://e.com/m\n";
    try testing.expectError(error.BadUrl, Record.parse(url_prefix ++ "nope\n" ++ hash ++ from));
    try testing.expectError(error.BadHash, Record.parse(url ++ hash_prefix ++ "nope\n" ++ from));
}

test "a pdb is an entry like any other, and is only ever a NAME.pdb" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStart(&w, "https://e.com/a.zip", hash_a);
    try writeEntry(&w, .{ .exe = .{ .name = "a.exe", .hash = hash_b } });
    try writeEntry(&w, .{ .pdb = "a.pdb" });
    try writeEnd(&w, "file:///C:/pkg/a", "the manifest\n");
    const record = try Record.parse(w.buffered());
    try testing.expect(record.hasPdb());
    try testing.expect(record.has("a.pdb"));

    var without_buf: [1024]u8 = undefined;
    var without: std.Io.Writer = .fixed(&without_buf);
    try writeStart(&without, "https://e.com/a.zip", hash_a);
    try writeEntry(&without, .{ .exe = .{ .name = "a.exe", .hash = hash_b } });
    try writeEnd(&without, "file:///C:/pkg/a", "the manifest\n");
    try testing.expect(!(try Record.parse(without.buffered())).hasPdb());

    try testing.expectEqual(null, parseEntry("installed-pdb a"));
    try testing.expectEqual(null, parseEntry("installed-pdb a.exe"));
    try testing.expectEqual(null, parseEntry("installed-pdb ../a.pdb"));
    try testing.expectEqual(null, parseEntry("installed-pdb sub/a.pdb"));
}

test "entries can't name anything but what's next to winbin.exe" {
    try testing.expectEqual(null, parseEntry("installed-exe a.exe"));
    try testing.expectEqual(null, parseEntry("installed-exe a.exe sha256:abc"));
    try testing.expectEqual(null, parseEntry("installed-exe ../a.exe " ++ hash_a));
    try testing.expectEqual(null, parseEntry("installed-exelink ../a.exe"));
    try testing.expectEqual(null, parseEntry("installed-dir .."));
    try testing.expectEqual(null, parseEntry("installed-dir ../x"));
    try testing.expectEqual(null, parseEntry("installed-dir C:"));
    try testing.expectEqual(null, parseEntry("installed-dir "));
    try testing.expectEqual(null, parseEntry("installed-from a"));
}

test "an update journal round trips" {
    var record_buf: [1024]u8 = undefined;
    var record_w: std.Io.Writer = .fixed(&record_buf);
    try sampleRecord(&record_w);

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJournalStart(&w, "foo");
    try writeAction(&w, .{ .remove_file = "old.exe" });
    try writeAction(&w, .{ .retire_dir = "foo-1.0" });
    try writeJournalRecord(&w, record_w.buffered());

    const journal = try Journal.parse(w.buffered());
    try testing.expectEqualStrings("foo", journal.record_file);
    try testing.expectEqualStrings(record_w.buffered(), journal.record_text);
    try testing.expectEqualStrings("https://e.com/a.zip", journal.record.?.url);
    var it = journal.actions();
    try testing.expectEqualStrings("old.exe", it.next().?.remove_file);
    try testing.expectEqualStrings("foo-1.0", it.next().?.retire_dir);
    try testing.expectEqual(null, it.next());
}

test "an uninstall journal round trips" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJournalStart(&w, "foo");
    try writeAction(&w, .{ .remove_file = "a.exe" });
    try writeAction(&w, .{ .remove_dir = "foo-1.0" });
    try writeJournalDeleteRecord(&w);

    const journal = try Journal.parse(w.buffered());
    try testing.expectEqual(null, journal.record);
    var it = journal.actions();
    try testing.expectEqualStrings("a.exe", it.next().?.remove_file);
    try testing.expectEqualStrings("foo-1.0", it.next().?.remove_dir);
    try testing.expectEqual(null, it.next());
}

test "a bad journal is an error, and can't name anything to delete elsewhere" {
    try testing.expectError(error.BadRecordFile, Journal.parse(""));
    try testing.expectError(error.BadRecordFile, Journal.parse("what\n"));
    try testing.expectError(error.BadRecordFile, Journal.parse("record-file ../x\ndelete-record\n"));
    try testing.expectError(error.CutShort, Journal.parse("record-file a"));
    try testing.expectError(error.CutShort, Journal.parse("record-file a\n"));
    try testing.expectError(error.CutShort, Journal.parse("record-file a\nremove-file a.exe\n"));
    try testing.expectError(error.BadAction, Journal.parse("record-file a\nremove-file ../a.exe\ndelete-record\n"));
    try testing.expectError(error.BadAction, Journal.parse("record-file a\nremove-file ../a.pdb\ndelete-record\n"));
    try testing.expectError(error.BadAction, Journal.parse("record-file a\nremove-dir ..\ndelete-record\n"));
    try testing.expectError(error.BadAction, Journal.parse("record-file a\nretire-dir C:\ndelete-record\n"));
    try testing.expectError(error.BadAction, Journal.parse("record-file a\nother\ndelete-record\n"));
    try testing.expectError(error.BadRecord, Journal.parse("record-file a\nrecord\nnot a record\n"));
}

const std = @import("std");
const manifest = @import("manifest.zig");
const testing = std.testing;
