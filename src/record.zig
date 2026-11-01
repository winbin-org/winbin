//! The two files winbin keeps about what's installed, as plain text, which DOTWINBIN.md
//! specifies. Nothing here touches the disk.
//!
//! An install record is what a package has in the winbin directory: the URL it was
//! downloaded from and the hash of what that served, which is how `update` tells if
//! there's anything new, what it put there, the URL of its manifest which is what
//! identifies the package, and the manifest so `update` can tell if it changed. That
//! manifest is only ever compared, never read, so uninstalling a package never depends
//! on being able to read its manifest.
//!
//! A journal is a change that's about to be made to one package. It's written before
//! the change starts, so if the change doesn't finish, the next winbin can.

/// `sha256:` and the digest in hex.
pub const hash_len = "sha256:".len + 2 * std.crypto.hash.sha2.Sha256.digest_length;

pub const Entry = union(enum) {
    exe: Hashed,
    exelink: []const u8,
    hardlink: Hashed,
    dir: []const u8,
    pdb: []const u8,

    pub const Hashed = struct { name: []const u8, hash: []const u8 };

    pub fn name(self: Entry) []const u8 {
        return switch (self) {
            .exe, .hardlink => |hashed| hashed.name,
            .exelink, .dir, .pdb => |n| n,
        };
    }
};

/// The first line of each file, with the version of DOTWINBIN.md it's written to.
const record_version_prefix = "winbin-record ";
const journal_version_prefix = "winbin-journal ";
const version = "1";

/// `Newer` for a version after this winbin's, which only a newer winbin writes.
fn checkVersion(line: []const u8, prefix: []const u8) error{ BadStart, Newer }!void {
    if (!std.mem.startsWith(u8, line, prefix)) return error.BadStart;
    if (manifest.isLaterVersion(line[prefix.len..])) return error.Newer;
    if (!std.mem.eql(u8, line[prefix.len..], version)) return error.BadStart;
}

const url_prefix = "installed-url ";
const hash_prefix = "installed-hash ";
const exe_prefix = "installed-exe ";
const exelink_prefix = "installed-exelink ";
const hardlink_prefix = "installed-hardlink ";
const dir_prefix = "installed-dir ";
const pdb_prefix = "installed-pdb ";
const from_prefix = "installed-from ";

/// Null if it isn't one, or isn't valid: uninstalling deletes what these name, so
/// they can't name anything else.
pub fn parseEntry(line: []const u8) ?Entry {
    if (std.mem.startsWith(u8, line, exe_prefix)) {
        const hashed = parseHashed(line[exe_prefix.len..]) orelse return null;
        return if (manifest.isExeName(hashed.name)) .{ .exe = hashed } else null;
    }
    if (std.mem.startsWith(u8, line, hardlink_prefix)) {
        const hashed = parseHashed(line[hardlink_prefix.len..]) orelse return null;
        return if (manifest.isFileName(hashed.name)) .{ .hardlink = hashed } else null;
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

/// NAME HASH
fn parseHashed(rest: []const u8) ?Entry.Hashed {
    const space = std.mem.findScalar(u8, rest, ' ') orelse return null;
    const hash = rest[space + 1 ..];
    if (!manifest.isHash(hash)) return null;
    return .{ .name = rest[0..space], .hash = hash };
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

    pub const Error = error{ BadStart, Newer, BadEntry, BadSource, BadUrl, BadHash };

    pub fn parse(text: []const u8) Error!Record {
        var lines = std.mem.splitScalar(u8, text, '\n');
        try checkVersion(lines.next().?, record_version_prefix);
        const url_line = lines.next() orelse "";
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
        error.BadStart => "it doesn't start with a version, a URL and a hash",
        error.Newer => "it was written by a newer winbin",
        error.BadEntry => "it has a line that isn't something it installed",
        error.BadSource => "the URL of its manifest isn't valid",
        error.BadUrl => "its URL isn't valid",
        error.BadHash => "its hash isn't valid",
    };
}

pub fn writeStart(w: *std.Io.Writer, url: []const u8, hash: []const u8) error{WriteFailed}!void {
    try w.print(record_version_prefix ++ version ++ "\n" ++ url_prefix ++ "{s}\n" ++ hash_prefix ++ "{s}\n", .{ url, hash });
}

pub fn writeEntry(w: *std.Io.Writer, entry: Entry) error{WriteFailed}!void {
    switch (entry) {
        .exe => |exe| try w.print(exe_prefix ++ "{s} {s}\n", .{ exe.name, exe.hash }),
        .exelink => |name| try w.print(exelink_prefix ++ "{s}\n", .{name}),
        .hardlink => |link| try w.print(hardlink_prefix ++ "{s} {s}\n", .{ link.name, link.hash }),
        .dir => |name| try w.print(dir_prefix ++ "{s}\n", .{name}),
        .pdb => |name| try w.print(pdb_prefix ++ "{s}\n", .{name}),
    }
}

pub fn writeEnd(w: *std.Io.Writer, from: []const u8, text: []const u8) error{WriteFailed}!void {
    try w.print(from_prefix ++ "{s}\n{s}", .{ from, text });
}

const install_prefix = "install ";
const uninstall_prefix = "uninstall ";

/// What's being done to one package. The rest is worked out from its record as it is
/// now: whatever that has and the new one doesn't is what goes.
pub const Journal = struct {
    record_file: []const u8,
    /// The package's new record, null if the package is going away.
    record: ?Record,
    record_text: []const u8,

    pub const Error = error{ BadStart, Newer, CutShort, BadOperation, BadRecord };

    pub fn parse(text: []const u8) Error!Journal {
        var lines = std.mem.splitScalar(u8, text, '\n');
        try checkVersion(lines.next().?, journal_version_prefix);
        const operation = lines.next() orelse return error.CutShort;
        if (lines.index == null) return error.CutShort;
        if (std.mem.startsWith(u8, operation, uninstall_prefix)) {
            const record_file = operation[uninstall_prefix.len..];
            if (!manifest.isPackageName(record_file) or lines.rest().len != 0) return error.BadOperation;
            return .{ .record_file = record_file, .record = null, .record_text = "" };
        }
        if (!std.mem.startsWith(u8, operation, install_prefix)) return error.BadOperation;
        const record_file = operation[install_prefix.len..];
        if (!manifest.isPackageName(record_file)) return error.BadOperation;
        const record_text = lines.rest();
        const record = Record.parse(record_text) catch |e| switch (e) {
            error.Newer => return error.Newer,
            else => return error.BadRecord,
        };
        return .{ .record_file = record_file, .record = record, .record_text = record_text };
    }
};

/// The package's new record follows, to the end of the journal.
pub fn writeJournalInstall(w: *std.Io.Writer, record_file: []const u8) error{WriteFailed}!void {
    try w.print(journal_version_prefix ++ version ++ "\n" ++ install_prefix ++ "{s}\n", .{record_file});
}

pub fn writeJournalUninstall(w: *std.Io.Writer, record_file: []const u8) error{WriteFailed}!void {
    try w.print(journal_version_prefix ++ version ++ "\n" ++ uninstall_prefix ++ "{s}\n", .{record_file});
}

const hash_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const hash_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn sampleRecord(w: *std.Io.Writer) !void {
    try writeStart(w, "https://e.com/a.zip", hash_a);
    try writeEntry(w, .{ .exe = .{ .name = "a.exe", .hash = hash_b } });
    try writeEntry(w, .{ .exelink = "b.exe" });
    try writeEntry(w, .{ .hardlink = .{ .name = "d.txt", .hash = hash_a } });
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
    const link = it.next().?.hardlink;
    try testing.expectEqualStrings("d.txt", link.name);
    try testing.expectEqualStrings(hash_a, link.hash);
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
    const v = record_version_prefix ++ version ++ "\n";
    const url = v ++ url_prefix ++ "https://e.com/a\n";
    const hash = hash_prefix ++ hash_a ++ "\n";
    try testing.expectError(error.BadStart, Record.parse(""));
    try testing.expectError(error.BadStart, Record.parse("\x00\x00\x00\x00"));
    try testing.expectError(error.BadStart, Record.parse(url_prefix ++ "https://e.com/a\n" ++ hash));
    try testing.expectError(error.BadStart, Record.parse(v));
    try testing.expectError(error.BadStart, Record.parse(url));
    try testing.expectError(error.BadEntry, Record.parse(url ++ hash));
    try testing.expectError(error.BadEntry, Record.parse(url ++ hash ++ "what\n"));
    try testing.expectError(error.BadEntry, Record.parse(url ++ hash ++ "\x00\x00"));
    try testing.expectError(error.BadSource, Record.parse(url ++ hash ++ from_prefix ++ "\n"));
    try testing.expectError(error.BadSource, Record.parse(url ++ hash ++ from_prefix ++ "C:\\pkg\\a\n"));
    const from = from_prefix ++ "https://e.com/m\n";
    try testing.expectError(error.BadUrl, Record.parse(v ++ url_prefix ++ "nope\n" ++ hash ++ from));
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

test "entries can't name anything but what's directly in the winbin directory" {
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

test "an install journal round trips" {
    var record_buf: [1024]u8 = undefined;
    var record_w: std.Io.Writer = .fixed(&record_buf);
    try sampleRecord(&record_w);

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJournalInstall(&w, "foo");
    try sampleRecord(&w);

    const journal = try Journal.parse(w.buffered());
    try testing.expectEqualStrings("foo", journal.record_file);
    try testing.expectEqualStrings(record_w.buffered(), journal.record_text);
    try testing.expectEqualStrings("https://e.com/a.zip", journal.record.?.url);
}

test "an uninstall journal round trips" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJournalUninstall(&w, "foo");
    const journal = try Journal.parse(w.buffered());
    try testing.expectEqualStrings("foo", journal.record_file);
    try testing.expectEqual(null, journal.record);
}

test "a bad journal is an error, and can't name a record anywhere else" {
    const v = journal_version_prefix ++ version ++ "\n";
    try testing.expectError(error.BadStart, Journal.parse(""));
    try testing.expectError(error.BadStart, Journal.parse("what\n"));
    try testing.expectError(error.BadStart, Journal.parse("uninstall a\n"));
    try testing.expectError(error.CutShort, Journal.parse(journal_version_prefix ++ version));
    try testing.expectError(error.CutShort, Journal.parse(v));
    try testing.expectError(error.CutShort, Journal.parse(v ++ "uninstall a"));
    try testing.expectError(error.BadOperation, Journal.parse(v ++ "uninstall ../x\n"));
    try testing.expectError(error.BadOperation, Journal.parse(v ++ "uninstall a\nmore\n"));
    try testing.expectError(error.BadOperation, Journal.parse(v ++ "install ../x\n"));
    try testing.expectError(error.BadOperation, Journal.parse(v ++ "repair a\n"));
    try testing.expectError(error.BadOperation, Journal.parse(v ++ "remove-file a.exe\n"));
    try testing.expectError(error.BadRecord, Journal.parse(v ++ "install a\nnot a record\n"));
    try testing.expectError(error.BadRecord, Journal.parse(v ++ "install a\n"));
}

test "a version after this winbin's is a newer winbin's, not damage" {
    try testing.expectError(error.Newer, Record.parse("winbin-record 2\nanything at all\n"));
    try testing.expectError(error.Newer, Record.parse("winbin-record 17"));
    try testing.expectError(error.Newer, Record.parse("winbin-record 4294967296\n"));
    try testing.expectError(error.Newer, Journal.parse("winbin-journal 99999999999999999999999999999999\n"));
    try testing.expectError(error.Newer, Journal.parse("winbin-journal 2\nrepair a\n"));
    try testing.expectError(error.Newer, Journal.parse("winbin-journal 1\ninstall a\nwinbin-record 2\nanything at all\n"));
    for ([_][]const u8{ "0", "01", "1 ", "+1", "+2", "-2", "2_0", "0x2", "1.0", "", "x" }) |bad| {
        var buf: [64]u8 = undefined;
        try testing.expectError(error.BadStart, Record.parse(try std.fmt.bufPrint(&buf, "winbin-record {s}\n", .{bad})));
        try testing.expectError(error.BadStart, Journal.parse(try std.fmt.bufPrint(&buf, "winbin-journal {s}\nuninstall a\n", .{bad})));
    }
}

// These are the bytes on disk, which every winbin there has ever been has to read. A
// change that makes one of these fail is a change to the format, see DOTWINBIN.md.

const golden_record =
    \\winbin-record 1
    \\installed-url https://e.com/a-1.0.zip
    \\installed-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    \\installed-exe a.exe sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    \\installed-exelink b.exe
    \\installed-hardlink d.txt sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    \\installed-dir c-1.0
    \\installed-pdb a.pdb
    \\installed-from https://winbin-org.github.io/pkg/a
    \\let v = "1.0"
    \\download "https://e.com/a-{v}.zip"
    \\
;

const golden_install_journal =
    \\winbin-journal 1
    \\install a-0123456789abcdef
    \\
++ golden_record;

const golden_uninstall_journal =
    \\winbin-journal 1
    \\uninstall a-0123456789abcdef
    \\
;

fn writeGoldenRecord(w: *std.Io.Writer) !void {
    try writeStart(w, "https://e.com/a-1.0.zip", hash_a);
    try writeEntry(w, .{ .exe = .{ .name = "a.exe", .hash = hash_b } });
    try writeEntry(w, .{ .exelink = "b.exe" });
    try writeEntry(w, .{ .hardlink = .{ .name = "d.txt", .hash = hash_a } });
    try writeEntry(w, .{ .dir = "c-1.0" });
    try writeEntry(w, .{ .pdb = "a.pdb" });
    try writeEnd(w, "https://winbin-org.github.io/pkg/a", "let v = \"1.0\"\ndownload \"https://e.com/a-{v}.zip\"\n");
}

test "format: a record is written as exactly these bytes, and read back from them" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeGoldenRecord(&w);
    try testing.expectEqualStrings(golden_record, w.buffered());

    const record = try Record.parse(golden_record);
    try testing.expectEqualStrings("https://e.com/a-1.0.zip", record.url);
    try testing.expectEqualStrings(hash_a, record.hash);
    try testing.expectEqualStrings("https://winbin-org.github.io/pkg/a", record.from);
    try testing.expectEqualStrings("let v = \"1.0\"\ndownload \"https://e.com/a-{v}.zip\"\n", record.manifest);
    var it = record.entries();
    try testing.expectEqualStrings("a.exe", it.next().?.exe.name);
    try testing.expectEqualStrings("b.exe", it.next().?.exelink);
    try testing.expectEqualStrings("d.txt", it.next().?.hardlink.name);
    try testing.expectEqualStrings("c-1.0", it.next().?.dir);
    try testing.expectEqualStrings("a.pdb", it.next().?.pdb);
    try testing.expectEqual(null, it.next());
}

test "format: an install journal is written as exactly these bytes, and read back from them" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJournalInstall(&w, "a-0123456789abcdef");
    try writeGoldenRecord(&w);
    try testing.expectEqualStrings(golden_install_journal, w.buffered());

    const journal = try Journal.parse(golden_install_journal);
    try testing.expectEqualStrings("a-0123456789abcdef", journal.record_file);
    try testing.expectEqualStrings(golden_record, journal.record_text);
}

test "format: an uninstall journal is written as exactly these bytes, and read back from them" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJournalUninstall(&w, "a-0123456789abcdef");
    try testing.expectEqualStrings(golden_uninstall_journal, w.buffered());

    const journal = try Journal.parse(golden_uninstall_journal);
    try testing.expectEqualStrings("a-0123456789abcdef", journal.record_file);
    try testing.expectEqual(null, journal.record);
}

test "format: these are the only entries there are" {
    for ([_][]const u8{ "installed-shortcut a.lnk", "installed-file a.txt", "installed-exe a.exe", "installed", "" }) |line| {
        try testing.expectEqual(null, parseEntry(line));
    }
}

const std = @import("std");
const manifest = @import("manifest.zig");
const testing = std.testing;
