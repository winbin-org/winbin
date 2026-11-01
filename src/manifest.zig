//! Parsing and validating package manifests, the format is in MANIFEST.md.

pub const arch_names = [_][]const u8{ "x86_64", "aarch64", "x86" };

pub const Diagnostic = struct {
    /// 0 when the message is about the manifest as a whole
    line: u32 = 0,
    message: []const u8 = "",
    /// A word winbin doesn't know, which a newer winbin might. It goes after the
    /// message, which is about what kind of word it is.
    unknown: []const u8 = "",
};

/// A value in a manifest: a variable, or text that can have {name}s in it.
pub const Expr = union(enum) {
    variable: []const u8,
    /// what's between the quotes, escapes and all
    string: []const u8,
};

const Token = union(enum) {
    word: []const u8,
    /// what's between the quotes
    string: []const u8,
    /// the name after the @
    builtin: []const u8,
    lparen,
    rparen,
    comma,
    equals,
    arrow,
    end,
    invalid,
};

const Tokenizer = struct {
    rest: []const u8,

    fn next(self: *Tokenizer) Token {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");
        if (self.rest.len == 0) return .end;
        switch (self.rest[0]) {
            '(' => return self.single(.lparen),
            ')' => return self.single(.rparen),
            ',' => return self.single(.comma),
            '=' => return self.single(.equals),
            '-' => {
                if (!std.mem.startsWith(u8, self.rest, "->")) return .invalid;
                self.rest = self.rest[2..];
                return .arrow;
            },
            '"' => return self.string(),
            '@' => {
                self.rest = self.rest[1..];
                const name = self.word();
                return if (name.len == 0) .invalid else .{ .builtin = name };
            },
            else => {
                const name = self.word();
                return if (name.len == 0) .invalid else .{ .word = name };
            },
        }
    }

    fn single(self: *Tokenizer, token: Token) Token {
        self.rest = self.rest[1..];
        return token;
    }

    fn word(self: *Tokenizer) []const u8 {
        var end: usize = 0;
        while (end < self.rest.len) : (end += 1) switch (self.rest[end]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
            else => break,
        };
        defer self.rest = self.rest[end..];
        return self.rest[0..end];
    }

    /// \" and \\ are the only escapes.
    fn string(self: *Tokenizer) Token {
        var i: usize = 1;
        while (i < self.rest.len) : (i += 1) switch (self.rest[i]) {
            '"' => {
                defer self.rest = self.rest[i + 1 ..];
                return .{ .string = self.rest[1..i] };
            },
            '\\' => {
                i += 1;
                if (i == self.rest.len or (self.rest[i] != '"' and self.rest[i] != '\\')) return .invalid;
            },
            else => {},
        };
        return .invalid;
    }
};

pub const Line = struct {
    /// trimmed
    text: []const u8,
    number: u32,
};

pub const LineIterator = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    number: u32 = 0,

    pub fn init(text: []const u8) LineIterator {
        return .{ .it = std.mem.splitScalar(u8, text, '\n') };
    }

    pub fn next(self: *LineIterator) ?Line {
        while (self.it.next()) |raw| {
            self.number += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            return .{ .text = line, .number = self.number };
        }
        return null;
    }
};

/// How a variable gets its value, the right side of `let NAME = ...`.
pub const Value = union(enum) {
    /// what's between the parentheses
    map_arch: []const u8,
    fetch: Expr,
    fetch_redirect: Expr,
    match_text: Read,
    json_value: Read,
    json_keys: Keys,
    /// the variable with the list
    newest: []const u8,
    expr: Expr,

    /// A function of a variable: then a pattern or a path, as a string.
    pub const Read = struct { source: []const u8, arg: []const u8 };
    pub const Keys = struct { source: []const u8, path: []const u8, except: ?[]const u8 };
};

/// `install exe` and `install dir`: DEST [from SOURCE]
pub const Install = struct { dest: Expr, from: ?Expr };

pub const Statement = union(enum) {
    let: struct { name: []const u8, value: Value },
    download: Expr,
    verify: Expr,
    extract,
    discard: Expr,
    install_exe: Install,
    install_dir: Install,
    install_exelink: struct { dest: Expr, target: Expr },
};

const ParseError = error{Invalid};

fn parseExpr(token: Token) ?Expr {
    return switch (token) {
        .word => |name| .{ .variable = name },
        .string => |raw| .{ .string = raw },
        else => null,
    };
}

fn expectEnd(tokens: *Tokenizer, n: u32, diag: *Diagnostic) ParseError!void {
    if (tokens.next() != .end) return fail(diag, n, "there's something unexpected at the end of this line");
}

fn parseStatement(line: Line, diag: *Diagnostic) ParseError!Statement {
    const n = line.number;
    var tokens: Tokenizer = .{ .rest = line.text };
    const key = switch (tokens.next()) {
        .word => |word| word,
        else => return fail(diag, n, "a line starts with 'let' or a word like 'download'"),
    };
    if (eql(key, "let")) return parseLet(&tokens, n, diag);
    if (eql(key, "download") or eql(key, "verify") or eql(key, "discard")) {
        const expr = parseExpr(tokens.next()) orelse
            return fail(diag, n, "expected a variable or a \"quoted value\" after this word");
        try expectEnd(&tokens, n, diag);
        return if (eql(key, "download"))
            .{ .download = expr }
        else if (eql(key, "verify"))
            .{ .verify = expr }
        else
            .{ .discard = expr };
    }
    if (eql(key, "extract")) {
        try expectEnd(&tokens, n, diag);
        return .extract;
    }
    if (eql(key, "install")) return parseInstall(&tokens, n, diag);
    return failUnknown(diag, n, "unknown line", key);
}

fn parseLet(tokens: *Tokenizer, n: u32, diag: *Diagnostic) ParseError!Statement {
    const name = switch (tokens.next()) {
        .word => |word| word,
        else => return fail(diag, n, "expected 'let NAME = ...'"),
    };
    if (tokens.next() != .equals) return fail(diag, n, "expected 'let NAME = ...'");
    const value: Value = switch (tokens.next()) {
        .builtin => |builtin| try parseBuiltin(builtin, tokens, n, diag),
        .word => |word| .{ .expr = .{ .variable = word } },
        .string => |raw| .{ .expr = .{ .string = raw } },
        else => return fail(diag, n, "expected a value after '=': a \"quoted value\", a variable, or an @builtin"),
    };
    try expectEnd(tokens, n, diag);
    return .{ .let = .{ .name = name, .value = value } };
}

fn parseBuiltin(builtin: []const u8, tokens: *Tokenizer, n: u32, diag: *Diagnostic) ParseError!Value {
    const known = eql(builtin, "map_arch") or eql(builtin, "fetch") or eql(builtin, "fetch_redirect") or
        eql(builtin, "match_text") or eql(builtin, "json_value") or eql(builtin, "json_keys") or eql(builtin, "newest");
    if (!known) return failUnknown(diag, n, "unknown builtin", builtin);
    if (tokens.next() != .lparen) return fail(diag, n, "expected '(' after this builtin");
    if (eql(builtin, "map_arch")) return .{ .map_arch = try mapArchArgs(tokens, n, diag) };
    if (eql(builtin, "fetch") or eql(builtin, "fetch_redirect")) {
        const url = parseExpr(tokens.next()) orelse return fail(diag, n, "expected a URL, a variable or a \"quoted value\"");
        try expectClose(tokens, n, diag);
        return if (eql(builtin, "fetch")) .{ .fetch = url } else .{ .fetch_redirect = url };
    }
    const source = switch (tokens.next()) {
        .word => |word| word,
        else => return fail(diag, n, "expected a variable as the first argument"),
    };
    if (eql(builtin, "newest")) {
        if (tokens.next() != .comma) return fail(diag, n, "expected '@newest(LIST, @compare_version)'");
        const compare = switch (tokens.next()) {
            .builtin => |word| word,
            else => return fail(diag, n, "expected '@newest(LIST, @compare_version)'"),
        };
        if (!eql(compare, "compare_version")) return failUnknown(diag, n, "unknown comparer", compare);
        try expectClose(tokens, n, diag);
        return .{ .newest = source };
    }
    if (tokens.next() != .comma) return fail(diag, n, "expected a \"quoted\" second argument");
    const arg = switch (tokens.next()) {
        .string => |raw| raw,
        else => return fail(diag, n, "expected a \"quoted\" second argument"),
    };
    if (eql(builtin, "match_text") or eql(builtin, "json_value")) {
        try expectClose(tokens, n, diag);
        const read: Value.Read = .{ .source = source, .arg = arg };
        return if (eql(builtin, "match_text")) .{ .match_text = read } else .{ .json_value = read };
    }
    var except: ?[]const u8 = null;
    switch (tokens.next()) {
        .rparen => {},
        .comma => {
            const named = tokens.next();
            const is_except = named == .word and eql(named.word, "except");
            if (!is_except or tokens.next() != .equals) return fail(diag, n, "expected 'except=\"KEY\"'");
            except = switch (tokens.next()) {
                .string => |raw| raw,
                else => return fail(diag, n, "expected 'except=\"KEY\"'"),
            };
            try expectClose(tokens, n, diag);
        },
        else => return fail(diag, n, "expected ')' or ', except=\"KEY\"'"),
    }
    return .{ .json_keys = .{ .source = source, .path = arg, .except = except } };
}

fn expectClose(tokens: *Tokenizer, n: u32, diag: *Diagnostic) ParseError!void {
    if (tokens.next() != .rparen) return fail(diag, n, "expected ')'");
}

/// Goes past the closing parenthesis, returning what's before it.
fn mapArchArgs(tokens: *Tokenizer, n: u32, diag: *Diagnostic) ParseError![]const u8 {
    const start = tokens.rest;
    while (true) {
        const before = tokens.rest;
        switch (tokens.next()) {
            .rparen => return start[0 .. start.len - before.len],
            .end, .invalid => return fail(diag, n, "expected ')'"),
            else => {},
        }
    }
}

fn parseInstall(tokens: *Tokenizer, n: u32, diag: *Diagnostic) ParseError!Statement {
    const kind = switch (tokens.next()) {
        .word => |word| word,
        else => return fail(diag, n, "expected 'install exe', 'install dir' or 'install exelink'"),
    };
    if (!eql(kind, "exe") and !eql(kind, "dir") and !eql(kind, "exelink"))
        return failUnknown(diag, n, "unknown kind of install", kind);
    const dest = parseExpr(tokens.next()) orelse
        return fail(diag, n, "expected what to install as, a \"quoted name\" or a variable");
    if (eql(kind, "exelink")) {
        if (tokens.next() != .arrow) return fail(diag, n, "expected 'install exelink NAME -> PATH'");
        const target = parseExpr(tokens.next()) orelse return fail(diag, n, "expected 'install exelink NAME -> PATH'");
        try expectEnd(tokens, n, diag);
        return .{ .install_exelink = .{ .dest = dest, .target = target } };
    }
    var from: ?Expr = null;
    switch (tokens.next()) {
        .end => {},
        .word => |word| {
            if (!eql(word, "from")) return fail(diag, n, "expected 'from' or the end of the line");
            from = parseExpr(tokens.next()) orelse return fail(diag, n, "expected a path after 'from'");
            try expectEnd(tokens, n, diag);
        },
        else => return fail(diag, n, "expected 'from' or the end of the line"),
    }
    const install: Install = .{ .dest = dest, .from = from };
    return if (eql(kind, "exe")) .{ .install_exe = install } else .{ .install_dir = install };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The statements of a validated manifest.
pub const StatementIterator = struct {
    lines: LineIterator,

    pub const Numbered = struct { statement: Statement, number: u32 };

    pub fn next(self: *StatementIterator) ?Numbered {
        const line = self.lines.next() orelse return null;
        var diag: Diagnostic = .{};
        return .{ .statement = parseStatement(line, &diag) catch unreachable, .number = line.number };
    }
};

pub fn statements(text: []const u8) StatementIterator {
    return .{ .lines = .init(text) };
}

/// What @map_arch's arguments give for `arch`, null if they don't list it. The
/// manifest has been validated.
pub fn mapArch(args: []const u8, arch: []const u8) ?[]const u8 {
    var tokens: Tokenizer = .{ .rest = args };
    while (true) {
        const key = tokens.next().word;
        _ = tokens.next();
        const value = tokens.next().string;
        if (eql(key, arch)) return value;
        if (tokens.next() == .end) return null;
    }
}

/// Checks everything that can be checked without the network, so a mistake
/// fails for whoever tests the manifest on any arch.
pub fn validate(text: []const u8, diag: *Diagnostic) error{Invalid}!void {
    var defined: Defined = .{};
    var lines: LineIterator = .init(text);
    var has_line = false;
    var has_lookup = false;
    var has_download = false;
    var has_verify = false;
    var has_extract = false;
    var has_dir = false;
    var has_install = false;
    while (lines.next()) |line| {
        const n = line.number;
        has_line = true;
        switch (try parseStatement(line, diag)) {
            .let => |let| {
                if (has_download) return fail(diag, n, "'let' must come before 'download'");
                try checkNewVariable(let.name, &defined, n, diag);
                var kind: Defined.Kind = .value;
                switch (let.value) {
                    .map_arch => |args| {
                        // so an unsupported arch fails before any network access
                        if (has_lookup) return fail(diag, n, "'@map_arch' must come before any requests");
                        try checkMapArch(args, n, diag);
                    },
                    .fetch => |url| {
                        try checkExpr(url, &defined, n, diag);
                        has_lookup = true;
                        kind = .response;
                    },
                    .fetch_redirect => |url| {
                        try checkExpr(url, &defined, n, diag);
                        has_lookup = true;
                    },
                    .match_text => |read| {
                        // text can be a response, or a value like a tag from JSON
                        const index = defined.find(read.source) orelse
                            return fail(diag, n, "reads a variable that isn't set yet");
                        if (defined.kinds[index] == .list) return fail(diag, n, "a list can only be read by @newest");
                        defined.read[index] = true;
                        try checkPattern(read.arg, &defined, n, diag);
                    },
                    .json_value => |read| {
                        try checkRead(read.source, .response, "can only read a variable set by @fetch", &defined, n, diag);
                        try checkPath(read.arg, .no_any_key, &defined, n, diag);
                    },
                    .json_keys => |keys| {
                        try checkRead(keys.source, .response, "can only read a variable set by @fetch", &defined, n, diag);
                        try checkPath(keys.path, .one_any_key, &defined, n, diag);
                        kind = .list;
                    },
                    .newest => |source| try checkRead(source, .list, "@newest needs a list from @json_keys", &defined, n, diag),
                    .expr => |expr| try checkExpr(expr, &defined, n, diag),
                }
                defined.add(let.name, kind, n);
            },
            .download => |url| {
                if (has_download) return fail(diag, n, "duplicate 'download'");
                try checkExpr(url, &defined, n, diag);
                has_download = true;
            },
            .verify => |hash| {
                if (!has_download) return fail(diag, n, "'verify' needs a 'download' before it");
                if (has_extract or has_install) return fail(diag, n, "'verify' must come before 'extract' and 'install'");
                if (has_verify) return fail(diag, n, "duplicate 'verify'");
                try checkExpr(hash, &defined, n, diag);
                if (knownString(hash)) |raw| if (!isHash(raw)) return fail(diag, n, "expected \"sha256:\" and 64 hex digits");
                has_verify = true;
            },
            .extract => {
                if (!has_download) return fail(diag, n, "'extract' needs a 'download' before it");
                if (has_install) return fail(diag, n, "'extract' must come before 'install'");
                if (has_extract) return fail(diag, n, "duplicate 'extract'");
                has_extract = true;
            },
            .discard => |path| {
                if (!has_extract) return fail(diag, n, "'discard' needs an 'extract' before it");
                if (has_install) return fail(diag, n, "'discard' must come before 'install'");
                try checkExpr(path, &defined, n, diag);
                if (knownString(path)) |raw| if (!isSafePath(raw)) return fail(diag, n, "'discard' needs a relative path that stays in the archive");
            },
            .install_exe => |install| {
                if (!has_download) return fail(diag, n, "'install' needs a 'download' before it");
                try checkExpr(install.dest, &defined, n, diag);
                if (knownString(install.dest)) |raw| if (!isExeName(raw))
                    return fail(diag, n, "an exe is installed as a plain NAME.exe that isn't winbin.exe");
                try checkFrom(install, false, &defined, n, diag);
                has_install = true;
            },
            .install_dir => |install| {
                if (!has_extract) return fail(diag, n, "'install dir' needs an 'extract' before it");
                try checkExpr(install.dest, &defined, n, diag);
                if (knownString(install.dest)) |raw| if (!isDirName(raw))
                    return fail(diag, n, "a directory is installed as a plain name that isn't winbin.exe");
                try checkFrom(install, true, &defined, n, diag);
                has_dir = true;
                has_install = true;
            },
            .install_exelink => |link| {
                if (!has_dir) return fail(diag, n, "'install exelink' needs an 'install dir' before it");
                try checkExpr(link.dest, &defined, n, diag);
                if (knownString(link.dest)) |raw| if (!isExeName(raw))
                    return fail(diag, n, "an exelink is installed as a plain NAME.exe that isn't winbin.exe");
                try checkExpr(link.target, &defined, n, diag);
                if (knownString(link.target)) |raw| if (!isLinkTarget(raw))
                    return fail(diag, n, "'install exelink' needs a path into an installed directory, like \"dir/foo.exe\"");
                has_install = true;
            },
        }
    }
    if (!has_line) return fail(diag, 0, "it's empty");
    if (!has_download) return fail(diag, 0, "it has no 'download'");
    if (!has_install) return fail(diag, 0, "it doesn't install anything");
    if (defined.unread()) |n| return fail(diag, n, "nothing reads this");
}

/// A string with no variables can be checked now, others once they're known.
fn knownString(expr: Expr) ?[]const u8 {
    return switch (expr) {
        .string => |raw| if (std.mem.findAny(u8, raw, "{\\") == null) raw else null,
        .variable => null,
    };
}

fn checkFrom(install: Install, is_dir: bool, defined: *const Defined, n: u32, diag: *Diagnostic) error{Invalid}!void {
    const from = install.from orelse return;
    try checkExpr(from, defined, n, diag);
    if (knownString(from)) |raw| {
        if (!isSafePath(raw) and !(is_dir and eql(raw, ".")))
            return fail(diag, n, "'from' needs a relative path that stays in the archive");
    }
    if (from == .string and install.dest == .string and eql(from.string, install.dest.string))
        return fail(diag, n, "leave out 'from' when it's the same as the name");
}

const Defined = struct {
    names: [max_vars][]const u8 = undefined,
    kinds: [max_vars]Kind = undefined,
    lines: [max_vars]u32 = undefined,
    read: [max_vars]bool = undefined,
    len: usize = 0,

    const Kind = enum { value, response, list };

    fn find(self: *const Defined, name: []const u8) ?usize {
        for (self.names[0..self.len], 0..) |n, i| if (eql(n, name)) return i;
        return null;
    }

    /// Validation rejects too many before calling this.
    fn add(self: *Defined, name: []const u8, kind: Kind, line: u32) void {
        self.names[self.len] = name;
        self.kinds[self.len] = kind;
        self.lines[self.len] = line;
        self.read[self.len] = false;
        self.len += 1;
    }

    /// The line of a request or a list nothing uses. A value can go unused, like
    /// an @map_arch that's only there to say which arches a package supports.
    fn unread(self: *const Defined) ?u32 {
        for (self.kinds[0..self.len], self.read[0..self.len], self.lines[0..self.len]) |kind, read, line| {
            if (kind != .value and !read) return line;
        }
        return null;
    }
};

fn checkNewVariable(name: []const u8, defined: *const Defined, n: u32, diag: *Diagnostic) error{Invalid}!void {
    if (!isVariableName(name)) return fail(diag, n, "invalid variable name");
    if (defined.find(name) != null) return fail(diag, n, "this variable is already set");
    if (defined.len == max_vars) return fail(diag, n, "too many variables");
}

fn checkRead(source: []const u8, kind: Defined.Kind, message: []const u8, defined: *Defined, n: u32, diag: *Diagnostic) error{Invalid}!void {
    const index = defined.find(source) orelse return fail(diag, n, "reads a variable that isn't set yet");
    if (defined.kinds[index] != kind) return fail(diag, n, message);
    defined.read[index] = true;
}

fn checkExpr(expr: Expr, defined: *const Defined, n: u32, diag: *Diagnostic) error{Invalid}!void {
    switch (expr) {
        .variable => |name| try checkVariable(name, defined, n, diag),
        .string => |raw| try checkDefined(raw, defined, n, diag),
    }
}

fn checkPath(path: []const u8, any_key: enum { no_any_key, one_any_key }, defined: *const Defined, n: u32, diag: *Diagnostic) error{Invalid}!void {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/')
        return fail(diag, n, "a path starts with / and has parts between slashes, like \"/a/b\"");
    var parts: PathIterator = .init(path);
    var count: usize = 0;
    var any_keys: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > max_path_segments) return fail(diag, n, "the path has too many parts");
        switch (parsePathPart(part) orelse return fail(diag, n, "a path part is empty, or isn't [FIELD=VALUE]")) {
            .any_key => any_keys += 1,
            .key => |key| try checkDefined(key, defined, n, diag),
            .select => |select| {
                if (std.mem.findAny(u8, select.field, " \t{") != null)
                    return fail(diag, n, "the FIELD of [FIELD=VALUE] has to be a plain name");
                try checkDefined(select.value, defined, n, diag);
            },
        }
    }
    switch (any_key) {
        .no_any_key => if (any_keys != 0) return fail(diag, n, "@json_value reads one value, it can't have {*} in its path"),
        .one_any_key => if (any_keys != 1) return fail(diag, n, "@json_keys needs exactly one {*} as a part of its path"),
    }
}

fn checkMapArch(args: []const u8, n: u32, diag: *Diagnostic) error{Invalid}!void {
    const expected = "expected CANONICAL=\"SPELLING\", like x86_64=\"amd64\"";
    var seen: [arch_names.len]bool = @splat(false);
    var tokens: Tokenizer = .{ .rest = args };
    while (true) {
        const key = switch (tokens.next()) {
            .word => |word| word,
            else => return fail(diag, n, expected),
        };
        if (tokens.next() != .equals) return fail(diag, n, expected);
        const value = switch (tokens.next()) {
            .string => |raw| raw,
            else => return fail(diag, n, expected),
        };
        const index = for (arch_names, 0..) |name, i| {
            if (eql(name, key)) break i;
        } else return fail(diag, n, "unknown arch, expected x86_64, aarch64 or x86");
        if (seen[index]) return fail(diag, n, "duplicate arch");
        seen[index] = true;
        if (!isName(value)) return fail(diag, n, "invalid arch spelling");
        switch (tokens.next()) {
            .end => return,
            .comma => {},
            else => return fail(diag, n, expected),
        }
    }
}

fn isVariableName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

fn checkDefined(template: []const u8, defined: *const Defined, n: u32, diag: *Diagnostic) error{Invalid}!void {
    var segments: SegmentIterator = .{ .rest = template };
    while (segments.next()) |segment| switch (segment) {
        .literal => {},
        .variable => |name| try checkVariable(name, defined, n, diag),
        .capture => return fail(diag, n, "{*} is only for patterns, or a whole part of a @json_keys path"),
    };
}

fn checkVariable(name: []const u8, defined: *const Defined, n: u32, diag: *Diagnostic) error{Invalid}!void {
    const index = defined.find(name) orelse return fail(diag, n, "uses a variable that isn't set yet");
    switch (defined.kinds[index]) {
        .value => {},
        .response => return fail(diag, n, "a fetched response isn't a value, read it with @json_value or @match_text"),
        .list => return fail(diag, n, "a list isn't a value, pick from it with @newest"),
    }
}

fn checkPattern(pattern: []const u8, defined: *const Defined, n: u32, diag: *Diagnostic) error{Invalid}!void {
    var segments: SegmentIterator = .{ .rest = pattern };
    var captures: usize = 0;
    while (segments.next()) |segment| switch (segment) {
        .literal => {},
        .variable => |name| try checkVariable(name, defined, n, diag),
        .capture => captures += 1,
    };
    if (captures != 1) return fail(diag, n, "a pattern needs exactly one {*}");
}

const Segment = union(enum) { literal: []const u8, variable: []const u8, capture };

/// Splits a string at its {name}s and {*}s, and takes care of its escapes. A { that
/// doesn't start one is literal, so JSON like `"a": {` can be in a pattern.
const SegmentIterator = struct {
    rest: []const u8,

    fn next(self: *SegmentIterator) ?Segment {
        if (self.rest.len == 0) return null;
        if (std.mem.startsWith(u8, self.rest, "{*}")) {
            self.rest = self.rest[3..];
            return .capture;
        }
        if (variableAt(self.rest)) |name| {
            self.rest = self.rest[name.len + 2 ..];
            return .{ .variable = name };
        }
        // the character after a backslash is itself, and already in the text
        if (self.rest[0] == '\\') {
            defer self.rest = self.rest[2..];
            return .{ .literal = self.rest[1..2] };
        }
        var end: usize = 1;
        while (end < self.rest.len and self.rest[end] != '\\' and
            !std.mem.startsWith(u8, self.rest[end..], "{*}") and
            variableAt(self.rest[end..]) == null) end += 1;
        defer self.rest = self.rest[end..];
        return .{ .literal = self.rest[0..end] };
    }
};

fn variableAt(s: []const u8) ?[]const u8 {
    if (s.len < 3 or s[0] != '{' or !std.ascii.isLower(s[1])) return null;
    for (s[1..], 1..) |c, i| switch (c) {
        '}' => return s[1..i],
        'a'...'z', '0'...'9', '_' => {},
        else => return null,
    };
    return null;
}

pub const max_vars = 16;

pub const Vars = struct {
    names: [max_vars][]const u8 = undefined,
    values: [max_vars][]const u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const Vars, name: []const u8) ?[]const u8 {
        for (self.names[0..self.len], self.values[0..self.len]) |n, v| {
            if (eql(n, name)) return v;
        }
        return null;
    }

    /// The value has to last as long as this does.
    pub fn set(self: *Vars, name: []const u8, value: []const u8) void {
        self.values[self.len] = value;
        self.names[self.len] = name;
        self.len += 1;
    }
};

/// Replaces each {name} in `template` with its value.
pub fn expand(template: []const u8, vars: *const Vars, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var segments: SegmentIterator = .{ .rest = template };
    while (segments.next()) |segment| {
        const part = switch (segment) {
            .literal => |s| s,
            // validation requires it to be set by here
            .variable => |name| vars.get(name).?,
            // validation only allows these in patterns and paths, this is to show one
            .capture => "{*}",
        };
        try out.appendSlice(arena, part);
    }
    return out.toOwnedSlice(arena);
}

pub fn eval(expr: Expr, vars: *const Vars, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    return switch (expr) {
        .variable => |name| arena.dupe(u8, vars.get(name).?),
        .string => |raw| expand(raw, vars, arena),
    };
}

pub const OneMatch = union(enum) {
    none,
    one: []const u8,
    /// what the first two matches captured
    several: [2][]const u8,
};

/// What `pattern` captures in `text`, which it has to match exactly once: taking
/// the first of several would depend on the order of a page that can change.
/// Matches don't overlap.
pub fn matchOne(pattern: []const u8, text: []const u8, vars: *const Vars) OneMatch {
    var found: ?[]const u8 = null;
    var capture: []const u8 = undefined;
    var start: usize = 0;
    while (start <= text.len) {
        const end = matchAt(pattern, text, start, vars, &capture) orelse {
            start += 1;
            continue;
        };
        if (found) |first| return .{ .several = .{ first, capture } };
        found = capture;
        start = end;
    }
    return if (found) |one| .{ .one = one } else .none;
}

/// Where a match starting exactly at `start` ends, null if there isn't one.
fn matchAt(pattern: []const u8, text: []const u8, start: usize, vars: *const Vars, capture: *[]const u8) ?usize {
    var pos = start;
    var segments: SegmentIterator = .{ .rest = pattern };
    while (segments.next()) |segment| switch (segment) {
        .literal => |literal| {
            if (!std.mem.startsWith(u8, text[pos..], literal)) return null;
            pos += literal.len;
        },
        .variable => |name| {
            const value = vars.get(name).?;
            if (!std.mem.startsWith(u8, text[pos..], value)) return null;
            pos += value.len;
        },
        .capture => {
            // it ends at the text after it or the end of the line
            const line_end = std.mem.findScalarPos(u8, text, pos, '\n') orelse text.len;
            const line = std.mem.trimEnd(u8, text[pos..line_end], "\r");
            var after = segments;
            const len = if (after.next()) |next_segment| blk: {
                const literal = switch (next_segment) {
                    .literal => |s| s,
                    .variable => |name| vars.get(name).?,
                    // validation requires exactly one
                    .capture => unreachable,
                };
                break :blk std.mem.find(u8, line, literal) orelse return null;
            } else line.len;
            if (len == 0) return null;
            capture.* = text[pos..][0..len];
            pos += len;
        },
    };
    return pos;
}

/// A directory next to winbin.exe. It can come from the network, so it can't name
/// anything else, like a path out of there.
pub fn isDirName(name: []const u8) bool {
    return isName(name) and isSafePath(name) and !std.ascii.eqlIgnoreCase(name, "winbin.exe");
}

/// A path into an installed directory: it can't just be an exe next to the link.
pub fn isLinkTarget(path: []const u8) bool {
    return isSafePath(path) and std.mem.findAny(u8, path, "/\\") != null;
}

/// A relative path that stays where it starts on Windows, for paths from the
/// network: in a zip or a manifest. Being strict about this is the point, a drive
/// like `C:/x` or a stream like `a:b` isn't caught by rejecting `..`, and Windows
/// ignores a trailing `.` or space, so `.. ` can mean `..`.
pub fn isSafePath(path: []const u8) bool {
    var parts = std.mem.splitAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0 or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
        for (part) |c| switch (c) {
            0...0x1f, ':', '*', '?', '"', '<', '>', '|' => return false,
            else => {},
        };
        const base = part[0 .. std.mem.findScalar(u8, part, '.') orelse part.len];
        const trimmed = std.mem.trimEnd(u8, base, " ");
        for ([_][]const u8{ "con", "prn", "aux", "nul" }) |device| {
            if (std.ascii.eqlIgnoreCase(trimmed, device)) return false;
        }
        if (trimmed.len == 4 and std.ascii.isDigit(trimmed[3]) and
            (std.ascii.eqlIgnoreCase(trimmed[0..3], "com") or std.ascii.eqlIgnoreCase(trimmed[0..3], "lpt"))) return false;
    }
    return true;
}

/// Dot separated numbers, what `compareVersions` can compare.
pub fn isVersion(s: []const u8) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Part by part, as numbers of any size. A missing part counts as 0, so 1.2 and
/// 1.2.0 are equal.
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    var a_parts = std.mem.splitScalar(u8, a, '.');
    var b_parts = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = a_parts.next();
        const b_part = b_parts.next();
        if (a_part == null and b_part == null) return .eq;
        const a_digits = std.mem.trimStart(u8, a_part orelse "", "0");
        const b_digits = std.mem.trimStart(u8, b_part orelse "", "0");
        const order = std.math.order(a_digits.len, b_digits.len);
        if (order != .eq) return order;
        const digits = std.mem.order(u8, a_digits, b_digits);
        if (digits != .eq) return digits;
    }
}

/// The only hash there is so far: `sha256:` and 64 hex digits.
pub fn isHash(s: []const u8) bool {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, s, prefix) or s.len != prefix.len + 64) return false;
    for (s[prefix.len..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

const max_path_segments = 16;

/// Splits a JSON path at its slashes. A `[FIELD=VALUE]` is one part, whatever's
/// in VALUE. Each part is from a validated path.
const PathIterator = struct {
    rest: []const u8,

    fn init(path: []const u8) PathIterator {
        return .{ .rest = path[1..] };
    }

    fn next(self: *PathIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const end = if (self.rest[0] == '[')
            if (std.mem.find(u8, self.rest, "]/")) |close| close + 1 else self.rest.len
        else
            std.mem.findScalar(u8, self.rest, '/') orelse self.rest.len;
        defer self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else "";
        return self.rest[0..end];
    }
};

/// Null if it isn't any kind of segment. Its strings aren't expanded yet.
fn parsePathPart(part: []const u8) ?json.Segment {
    if (part.len == 0) return null;
    if (eql(part, "{*}")) return .any_key;
    if (part[0] != '[') return .{ .key = part };
    if (part[part.len - 1] != ']') return null;
    const eq = std.mem.findScalar(u8, part, '=') orelse return null;
    if (eq == 1) return null;
    return .{ .select = .{ .field = part[1..eq], .value = part[eq + 1 .. part.len - 1] } };
}

/// A validated path with each {name} replaced by its value. That's done after
/// splitting it, so a slash in a value can't change what the path means.
pub fn expandPath(path: []const u8, vars: *const Vars, arena: std.mem.Allocator) error{OutOfMemory}![]const json.Segment {
    var segments: std.ArrayList(json.Segment) = .empty;
    errdefer {
        freePath(segments.items, arena);
        segments.deinit(arena);
    }
    var parts: PathIterator = .init(path);
    while (parts.next()) |part| {
        try segments.append(arena, switch (parsePathPart(part).?) {
            .any_key => .any_key,
            .key => |key| .{ .key = try expand(key, vars, arena) },
            .select => |select| .{ .select = .{ .field = select.field, .value = try expand(select.value, vars, arena) } },
        });
    }
    return segments.toOwnedSlice(arena);
}

pub fn freePath(segments: []const json.Segment, arena: std.mem.Allocator) void {
    for (segments) |segment| switch (segment) {
        .any_key => {},
        .key => |key| arena.free(key),
        .select => |select| arena.free(select.value),
    };
    arena.free(segments);
}

/// Validates the `names` file, returning how many packages it lists: each line
/// is a package name terminated by \n, sorted bytewise, and nothing else. An
/// empty file lists no packages.
pub fn parseNames(text: []const u8, diag: *Diagnostic) error{Invalid}!u32 {
    if (text.len == 0) return 0;
    var count: u32 = 0;
    var previous: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |name| {
        const number = count + 1;
        // what follows the last \n: empty, unless the last line isn't terminated
        if (it.index == null) {
            if (name.len != 0) return fail(diag, number, "the last line has no newline");
            return count;
        }
        if (!isPackageName(name)) return fail(diag, number, "invalid package name");
        if (previous) |p| if (!std.mem.lessThan(u8, p, name))
            return fail(diag, number, "out of order or duplicate");
        previous = name;
        count = number;
    }
    unreachable;
}

fn fail(diag: *Diagnostic, line: u32, message: []const u8) error{Invalid} {
    diag.* = .{ .line = line, .message = message };
    return error.Invalid;
}

fn failUnknown(diag: *Diagnostic, line: u32, message: []const u8, word: []const u8) error{Invalid} {
    diag.* = .{ .line = line, .message = message, .unknown = word };
    return error.Invalid;
}

/// A file directly next to winbin.exe, it comes from the network so it can't
/// name anything else. winbin.exe is the package manager's own.
pub fn isExeName(exe: []const u8) bool {
    if (!std.mem.endsWith(u8, exe, ".exe") or !isName(exe[0 .. exe.len - ".exe".len])) return false;
    return !std.ascii.eqlIgnoreCase(exe, "winbin.exe");
}

/// A package name is a file name on Windows, which ignores case, and a URL path
/// segment, which doesn't. Lowercase only, so `Foo` and `foo` can't collide.
pub fn isPackageName(name: []const u8) bool {
    if (!isName(name)) return false;
    for (name) |c| if (std.ascii.isUpper(c)) return false;
    return true;
}

/// Becomes a file name and maybe a URL path segment. Starts alphanumeric, so
/// never "." or "..".
fn isName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// The SCHEME if `s` starts with SCHEME://, which is what makes it a URL.
pub fn urlScheme(s: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < s.len) : (end += 1) switch (s[end]) {
        'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => {},
        else => break,
    };
    if (end == 0) return null;
    return if (std.mem.startsWith(u8, s[end..], "://")) s[0..end] else null;
}

/// The last part of a valid URL's path, without a query or fragment. It can be
/// empty, and isn't validated.
pub fn urlName(url: []const u8) []const u8 {
    const after_scheme = url[std.mem.find(u8, url, "://").? + "://".len ..];
    const end = std.mem.findAny(u8, after_scheme, "?#") orelse after_scheme.len;
    const path = after_scheme[0..end];
    return path[std.mem.findScalarLast(u8, path, '/').? + 1 ..];
}

/// URLs can come from captures, so they're checked after expanding. A valid one
/// has a host and a path.
pub fn isUrl(s: []const u8) bool {
    const scheme_len: usize = if (std.mem.startsWith(u8, s, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, s, "http://"))
        "http://".len
    else
        return false;
    for (s) |c| if (c <= ' ' or c == 0x7f) return false;
    const after_scheme = s[scheme_len..];
    const slash = std.mem.findScalar(u8, after_scheme, '/') orelse return false;
    return slash != 0;
}

/// The Windows path a file:// URL names. Null unless it's an absolute path, and only one
/// way of writing it: the URL is what identifies a package.
pub fn filePath(url: []const u8, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    const prefix = "file:///";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const encoded = url[prefix.len..];
    for (encoded) |c| switch (c) {
        0...' ', 0x7f, '\\', '?', '#' => return null,
        else => {},
    };
    const buf = try arena.dupe(u8, encoded);
    // it decodes to the end of the buffer
    const decoded = std.Uri.percentDecodeInPlace(buf);
    std.mem.copyForwards(u8, buf, decoded);
    const path = buf[0..decoded.len];
    if (path.len < 4 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '/' or
        std.mem.findScalar(u8, path, '\\') != null or !isSafePath(path[3..]))
    {
        arena.free(buf);
        return null;
    }
    std.mem.replaceScalar(u8, path, '/', '\\');
    return try arena.realloc(buf, path.len);
}

fn expectValid(text: []const u8) !void {
    var diag: Diagnostic = .{};
    validate(text, &diag) catch |e| {
        std.debug.print("line {d}: {s} {s}\n", .{ diag.line, diag.message, diag.unknown });
        return e;
    };
}

fn expectInvalid(text: []const u8, line: u32, message: []const u8) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(error.Invalid, validate(text, &diag));
    try testing.expectEqualStrings(message, diag.message);
    try testing.expectEqual(line, diag.line);
}

const hyperfine =
    \\let arch = @map_arch(x86_64="x86_64", aarch64="aarch64", x86="i686")
    \\let release = @fetch("https://api.github.com/repos/sharkdp/hyperfine/releases/latest")
    \\let tag = @json_value(release, "/tag_name")
    \\let asset = "hyperfine-{tag}-{arch}-pc-windows-msvc"
    \\let url = @json_value(release, "/assets/[name={asset}.zip]/browser_download_url")
    \\let digest = @json_value(release, "/assets/[name={asset}.zip]/digest")
    \\
    \\download url
    \\verify digest
    \\extract
    \\discard "{asset}/README.md"
    \\discard "{asset}/autocomplete"
    \\install exe "hyperfine.exe" from "{asset}/hyperfine.exe"
    \\
;

const zig_manifest =
    \\# a comment
    \\let arch = @map_arch(x86_64="x86_64", aarch64="aarch64", x86="x86")
    \\let index = @fetch("https://ziglang.org/download/index.json")
    \\let versions = @json_keys(index, "/{*}/{arch}-windows/tarball", except="master")
    \\let version = @newest(versions, @compare_version)
    \\let tarball = @json_value(index, "/{version}/{arch}-windows/tarball")
    \\let shasum = @json_value(index, "/{version}/{arch}-windows/shasum")
    \\
    \\download tarball
    \\verify "sha256:{shasum}"
    \\extract
    \\install dir "zig-{version}" from "zig-{arch}-windows-{version}"
    \\install exelink "zig.exe" -> "zig-{version}/zig.exe"
    \\
;

test "validate accepts real manifests" {
    try expectValid(hyperfine);
    try expectValid(zig_manifest);
    // the whole archive, and a variable as a source
    try expectValid(
        \\let v = "1"
        \\download "https://e.com/a.zip"
        \\extract
        \\install dir "a-{v}" from "."
        \\install exelink "a.exe" -> "a-{v}/a.exe"
    );
    try expectValid(
        \\let asset = "a"
        \\download "https://e.com/a.zip"
        \\extract
        \\install dir "b" from asset
        \\install dir asset
        \\install exelink "a.exe" -> "b/a.exe"
    );
    // a download that's the exe itself has nothing to extract
    try expectValid(
        \\download "https://e.com/jq-windows-amd64.exe"
        \\install exe "jq.exe" from "jq-windows-amd64.exe"
    );
}

test "statements" {
    var it = statements(zig_manifest);
    try testing.expectEqualStrings("arch", it.next().?.statement.let.name);
    for (0..5) |_| _ = it.next().?;
    const download = it.next().?;
    try testing.expectEqualStrings("tarball", download.statement.download.variable);
    try testing.expectEqual(9, download.number);
    try testing.expectEqualStrings("sha256:{shasum}", it.next().?.statement.verify.string);
    try testing.expectEqual(.extract, std.meta.activeTag(it.next().?.statement));
    const dir = it.next().?.statement.install_dir;
    try testing.expectEqualStrings("zig-{version}", dir.dest.string);
    try testing.expectEqualStrings("zig-{arch}-windows-{version}", dir.from.?.string);
    const link = it.next().?.statement.install_exelink;
    try testing.expectEqualStrings("zig.exe", link.dest.string);
    try testing.expectEqualStrings("zig-{version}/zig.exe", link.target.string);
    try testing.expectEqual(null, it.next());
}

test "mapArch" {
    const args = "x86_64=\"win\", aarch64=\"winarm64\"";
    try testing.expectEqualStrings("win", mapArch(args, "x86_64").?);
    try testing.expectEqualStrings("winarm64", mapArch(args, "aarch64").?);
    try testing.expectEqual(null, mapArch(args, "x86"));
}

test "a value can hold anything the syntax uses" {
    const text =
        \\let page = @fetch("https://e.com/a")
        \\let a = @match_text(page, "a, (b) = # -> @c {*} d ")
        \\let b = @match_text(page, "<meta content=\"{*}\">")
        \\let c = "back\\slash"
        \\download "https://e.com/a.zip"
        \\install exe "a.exe"
    ;
    try expectValid(text);
    var it = statements(text);
    _ = it.next().?;
    try testing.expectEqualStrings("a, (b) = # -> @c {*} d ", it.next().?.statement.let.value.match_text.arg);
    const pattern = it.next().?.statement.let.value.match_text.arg;
    var vars: Vars = .{};
    try testing.expectEqualStrings("1.2", matchOne(pattern, "x <meta content=\"1.2\"> y", &vars).one);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("back\\slash", try eval(it.next().?.statement.let.value.expr, &vars, arena.allocator()));
}

test "a variable can be named like a word in the format" {
    try expectValid(
        \\let install = "1"
        \\let download = "2"
        \\let from = "3"
        \\download "https://e.com/{install}{download}{from}.zip"
        \\install exe "a.exe" from from
    );
}

test "an unknown word could be from a newer winbin" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.Invalid, validate("let a = @frobnicate(\"x\")\n", &diag));
    try testing.expectEqualStrings("frobnicate", diag.unknown);
    try testing.expectEqualStrings("unknown builtin", diag.message);
    diag = .{};
    try testing.expectError(error.Invalid, validate("mirror \"x\"\n", &diag));
    try testing.expectEqualStrings("mirror", diag.unknown);
    try testing.expectEqualStrings("unknown line", diag.message);
    diag = .{};
    try testing.expectError(error.Invalid, validate("install link \"x\"\n", &diag));
    try testing.expectEqualStrings("link", diag.unknown);
    diag = .{};
    try testing.expectError(error.Invalid, validate("let l = @fetch(\"https://e.com/\")\nlet a = @newest(l, @compare_date)\n", &diag));
    try testing.expectEqualStrings("compare_date", diag.unknown);
}

test "lines are rejected for what's wrong with them" {
    const quoted = "expected a variable or a \"quoted value\" after this word";
    const value = "expected a value after '=': a \"quoted value\", a variable, or an @builtin";
    try expectInvalid("", 0, "it's empty");
    try expectInvalid("# only a comment\n", 0, "it's empty");
    try expectInvalid("= 1\n", 1, "a line starts with 'let' or a word like 'download'");
    try expectInvalid("\"a\"\n", 1, "a line starts with 'let' or a word like 'download'");
    try expectInvalid("let\n", 1, "expected 'let NAME = ...'");
    try expectInvalid("let a\n", 1, "expected 'let NAME = ...'");
    try expectInvalid("let a 1\n", 1, "expected 'let NAME = ...'");
    try expectInvalid("let a =\n", 1, value);
    try expectInvalid("let a = 1.2\n", 1, "there's something unexpected at the end of this line");
    try expectInvalid("let a = \"unterminated\n", 1, value);
    try expectInvalid("let a = \"bad \\n escape\"\n", 1, value);
    try expectInvalid("let a = \"x\" y\n", 1, "there's something unexpected at the end of this line");
    try expectInvalid("let A = \"x\"\n", 1, "invalid variable name");
    try expectInvalid("let a = \"x\"\nlet a = \"y\"\n", 2, "this variable is already set");
    try expectInvalid("download\n", 1, quoted);
    try expectInvalid("download \"https://e.com/a\" x\n", 1, "there's something unexpected at the end of this line");
    try expectInvalid("extract x\n", 1, "there's something unexpected at the end of this line");
}

test "@map_arch is rejected when wrong" {
    const expected = "expected CANONICAL=\"SPELLING\", like x86_64=\"amd64\"";
    try expectInvalid("let a = @map_arch()\n", 1, expected);
    try expectInvalid("let a = @map_arch(x86_64)\n", 1, expected);
    try expectInvalid("let a = @map_arch(x86_64=win)\n", 1, expected);
    try expectInvalid("let a = @map_arch(x86=\"a\",)\n", 1, expected);
    try expectInvalid("let a = @map_arch(x86=\"a\"\n", 1, "expected ')'");
    try expectInvalid("let a = @map_arch(sparc=\"s\")\n", 1, "unknown arch, expected x86_64, aarch64 or x86");
    try expectInvalid("let a = @map_arch(x86=\"a\", x86=\"b\")\n", 1, "duplicate arch");
    try expectInvalid("let a = @map_arch(x86=\"\")\n", 1, "invalid arch spelling");
    try expectInvalid("let a = @map_arch(x86=\"a/b\")\n", 1, "invalid arch spelling");
    try expectInvalid("let r = @fetch_redirect(\"https://e.com/\")\nlet a = @map_arch(x86=\"a\")\n", 2, "'@map_arch' must come before any requests");
}

test "variables are used for what they are" {
    const head = "let index = @fetch(\"https://e.com/a\")\n";
    const tail = "download \"https://e.com/a.zip\"\ninstall exe \"a.exe\"\n";
    try expectInvalid(head ++ tail, 1, "nothing reads this");
    try expectInvalid(head ++ "let k = @json_keys(index, \"/{*}\")\n" ++ tail, 2, "nothing reads this");
    // a value going unused is fine, it's how a package says which arches it supports
    try expectValid("let arch = @map_arch(x86_64=\"a\")\n" ++ tail);
    try expectInvalid("download nope\n", 1, "uses a variable that isn't set yet");
    try expectInvalid("download \"https://e.com/{nope}\"\n", 1, "uses a variable that isn't set yet");
    try expectInvalid("download \"https://e.com/{*}\"\n", 1, "{*} is only for patterns, or a whole part of a @json_keys path");
    try expectInvalid(head ++ "download index\n", 2, "a fetched response isn't a value, read it with @json_value or @match_text");
    try expectInvalid(head ++ "let a = \"{index}\"\n", 2, "a fetched response isn't a value, read it with @json_value or @match_text");
    const keys = head ++ "let k = @json_keys(index, \"/{*}\")\n";
    try expectInvalid(keys ++ "download k\n", 3, "a list isn't a value, pick from it with @newest");
    try expectInvalid(keys ++ "let a = @match_text(k, \"{*}\")\n", 3, "a list can only be read by @newest");
    try expectInvalid(head ++ "let a = @newest(index, @compare_version)\n", 2, "@newest needs a list from @json_keys");
    try expectInvalid("let a = \"x\"\nlet b = @json_value(a, \"/x\")\n", 2, "can only read a variable set by @fetch");
    try expectInvalid("let b = @json_value(a, \"/x\")\n", 1, "reads a variable that isn't set yet");
    try expectInvalid("let b = @match_text(a, \"{*}\")\n", 1, "reads a variable that isn't set yet");
    try expectInvalid(head ++ "let a = @match_text(index, \"none\")\n", 2, "a pattern needs exactly one {*}");
    try expectInvalid(head ++ "let a = @match_text(index, \"{*}-{*}\")\n", 2, "a pattern needs exactly one {*}");
    try expectInvalid(head ++ "let a = @match_text(index, none)\n", 2, "expected a \"quoted\" second argument");
    try expectInvalid(head ++ "let a = @json_keys(index, \"/{*}\", other=\"x\")\n", 2, "expected 'except=\"KEY\"'");
    try expectInvalid(keys ++ "let a = @newest(k)\n", 3, "expected '@newest(LIST, @compare_version)'");
    try expectInvalid("let a = @fetch\n", 1, "expected '(' after this builtin");
}

test "json paths are rejected when wrong" {
    const head = "let index = @fetch(\"https://e.com/\")\n";
    const path_message = "a path starts with / and has parts between slashes, like \"/a/b\"";
    const part_message = "a path part is empty, or isn't [FIELD=VALUE]";
    try expectInvalid(head ++ "let x = @json_value(index, \"a\")\n", 2, path_message);
    try expectInvalid(head ++ "let x = @json_value(index, \"/\")\n", 2, path_message);
    try expectInvalid(head ++ "let x = @json_value(index, \"/a/\")\n", 2, path_message);
    try expectInvalid(head ++ "let x = @json_value(index, \"/a//b\")\n", 2, part_message);
    try expectInvalid(head ++ "let x = @json_value(index, \"/[a\")\n", 2, part_message);
    try expectInvalid(head ++ "let x = @json_value(index, \"/[a]/b\")\n", 2, part_message);
    try expectInvalid(head ++ "let x = @json_value(index, \"/[=a]/b\")\n", 2, part_message);
    try expectInvalid(head ++ "let x = @json_value(index, \"/[{y}=a]/b\")\n", 2, "the FIELD of [FIELD=VALUE] has to be a plain name");
    try expectInvalid(head ++ "let x = @json_value(index, \"/[a={y}]/b\")\n", 2, "uses a variable that isn't set yet");
    try expectInvalid(head ++ "let x = @json_value(index, \"/{*}/b\")\n", 2, "@json_value reads one value, it can't have {*} in its path");
    try expectInvalid(head ++ "let x = @json_value(index, \"/v{*}/b\")\n", 2, "{*} is only for patterns, or a whole part of a @json_keys path");
    try expectInvalid(head ++ "let x = @json_value(index, \"/1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/16/17\")\n", 2, "the path has too many parts");
    try expectInvalid(head ++ "let x = @json_keys(index, \"/a\")\n", 2, "@json_keys needs exactly one {*} as a part of its path");
    try expectInvalid(head ++ "let x = @json_keys(index, \"/{*}/{*}\")\n", 2, "@json_keys needs exactly one {*} as a part of its path");
}

test "the steps have to be in order" {
    const url = "download \"https://e.com/a.zip\"\n";
    const hash = "verify \"sha256:b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428\"\n";
    const exe = "install exe \"a.exe\"\n";
    try expectValid(url ++ hash ++ "extract\n" ++ "discard \"b\"\n" ++ exe);
    try expectInvalid(url ++ "let a = \"x\"\n", 2, "'let' must come before 'download'");
    try expectInvalid(url ++ url, 2, "duplicate 'download'");
    try expectInvalid(hash, 1, "'verify' needs a 'download' before it");
    try expectInvalid(url ++ hash ++ hash, 3, "duplicate 'verify'");
    try expectInvalid(url ++ "extract\n" ++ hash, 3, "'verify' must come before 'extract' and 'install'");
    try expectInvalid(url ++ exe ++ hash, 3, "'verify' must come before 'extract' and 'install'");
    try expectInvalid(url ++ "verify \"md5:abc\"\n", 2, "expected \"sha256:\" and 64 hex digits");
    try expectInvalid("extract\n", 1, "'extract' needs a 'download' before it");
    try expectInvalid(url ++ "extract\nextract\n", 3, "duplicate 'extract'");
    try expectInvalid(url ++ exe ++ "extract\n", 3, "'extract' must come before 'install'");
    try expectInvalid(url ++ "discard \"a\"\n", 2, "'discard' needs an 'extract' before it");
    try expectInvalid(url ++ "extract\n" ++ exe ++ "discard \"a\"\n", 4, "'discard' must come before 'install'");
    try expectInvalid(url ++ "extract\ndiscard \"../a\"\n", 3, "'discard' needs a relative path that stays in the archive");
    try expectInvalid(url ++ "extract\ndiscard \".\"\n", 3, "'discard' needs a relative path that stays in the archive");
    try expectInvalid(exe, 1, "'install' needs a 'download' before it");
    try expectInvalid("let a = \"x\"\n", 0, "it has no 'download'");
    try expectInvalid(url, 0, "it doesn't install anything");
    try expectInvalid(url ++ "extract\n", 0, "it doesn't install anything");
}

test "installs are rejected when wrong" {
    const head = "download \"https://e.com/a.zip\"\nextract\n";
    const exe_name = "an exe is installed as a plain NAME.exe that isn't winbin.exe";
    const dir_name = "a directory is installed as a plain name that isn't winbin.exe";
    const link_name = "an exelink is installed as a plain NAME.exe that isn't winbin.exe";
    const from_path = "'from' needs a relative path that stays in the archive";
    const same = "leave out 'from' when it's the same as the name";
    const link_path = "'install exelink' needs a path into an installed directory, like \"dir/foo.exe\"";
    const dir = "install dir \"d\"\n";

    try expectInvalid(head ++ "install\n", 3, "expected 'install exe', 'install dir' or 'install exelink'");
    try expectInvalid(head ++ "install exe\n", 3, "expected what to install as, a \"quoted name\" or a variable");
    try expectInvalid(head ++ "install exe \"a\"\n", 3, exe_name);
    try expectInvalid(head ++ "install exe \"sub/a.exe\"\n", 3, exe_name);
    try expectInvalid(head ++ "install exe \"..\\a.exe\"\n", 3, "expected what to install as, a \"quoted name\" or a variable");
    try expectInvalid(head ++ "install exe \".exe\"\n", 3, exe_name);
    try expectInvalid(head ++ "install exe \"WinBin.EXE\"\n", 3, exe_name);
    try expectInvalid(head ++ "install exe \"a.exe\" \"b.exe\"\n", 3, "expected 'from' or the end of the line");
    try expectInvalid(head ++ "install exe \"a.exe\" from\n", 3, "expected a path after 'from'");
    try expectInvalid(head ++ "install exe \"a.exe\" from \"a.exe\"\n", 3, same);
    try expectInvalid(head ++ "install exe \"a.exe\" from \".\"\n", 3, from_path);
    try expectInvalid(head ++ "install exe \"a.exe\" from \"../a.exe\"\n", 3, from_path);
    try expectInvalid(head ++ "install exe \"a.exe\" from \"C:/a.exe\"\n", 3, from_path);

    try expectInvalid("download \"https://e.com/a.zip\"\ninstall dir \"d\"\n", 2, "'install dir' needs an 'extract' before it");
    // the rule that everything at the top level is named
    try expectInvalid(head ++ "install dir \".\"\n", 3, dir_name);
    try expectInvalid(head ++ "install dir \"..\"\n", 3, dir_name);
    try expectInvalid(head ++ "install dir \"a/b\"\n", 3, dir_name);
    try expectInvalid(head ++ "install dir \".winbin\"\n", 3, dir_name);
    try expectInvalid(head ++ "install dir \"nul\"\n", 3, dir_name);
    try expectInvalid(head ++ "install dir \"d\" from \"d\"\n", 3, same);
    try expectInvalid(head ++ "install dir \"d\" from \"../x\"\n", 3, from_path);

    try expectInvalid(head ++ "install exelink \"a.exe\" -> \"d/a.exe\"\n", 3, "'install exelink' needs an 'install dir' before it");
    try expectInvalid(head ++ dir ++ "install exelink \"a\" -> \"d/a.exe\"\n", 4, link_name);
    try expectInvalid(head ++ dir ++ "install exelink \"winbin.exe\" -> \"d/a.exe\"\n", 4, link_name);
    try expectInvalid(head ++ dir ++ "install exelink \"a.exe\"\n", 4, "expected 'install exelink NAME -> PATH'");
    try expectInvalid(head ++ dir ++ "install exelink \"a.exe\" to \"d/a.exe\"\n", 4, "expected 'install exelink NAME -> PATH'");
    try expectInvalid(head ++ dir ++ "install exelink \"a.exe\" -> \"a.exe\"\n", 4, link_path);
    try expectInvalid(head ++ dir ++ "install exelink \"a.exe\" -> \"../a.exe\"\n", 4, link_path);
    try expectInvalid(head ++ dir ++ "install exelink \"a.exe\" -> \"C:/a.exe\"\n", 4, link_path);
    try expectInvalid(head ++ "install exe \"a.exe\" -> \"b\"\n", 3, "expected 'from' or the end of the line");
}

test "isSafePath" {
    for ([_][]const u8{
        "a",
        "a/b.exe",
        "a\\b.exe",
        "zig-x86_64-windows-0.17.0/lib/std/std.zig",
        "a b/c d.txt",
        ".hidden/file",
        "console.txt",
        "nullable",
        "com.txt",
        "com10",
        "lpt",
    }) |path| try testing.expect(isSafePath(path));
    for ([_][]const u8{
        "",
        "/a",
        "\\a",
        "a/",
        "a//b",
        "..",
        "a/../b",
        "..\\b",
        ".",
        "./a",
        // these are what checking for `..` alone misses
        "C:/evil",
        "C:evil",
        "a:b",
        "a/b:stream",
        "\\\\server\\share\\a",
        "\\\\?\\C:\\a",
        ".. /a",
        "a. /b",
        "a ",
        "a.",
        "nul",
        "NUL.txt",
        "a/con",
        "Aux.tar.gz",
        "com1",
        "LPT9.txt",
        "a\nb",
        "a*b",
        "a?b",
        "a\"b",
        "a<b",
        "a>b",
        "a|b",
    }) |path| try testing.expect(!isSafePath(path));
}

test "isHash" {
    const hex = "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428";
    try testing.expect(isHash("sha256:" ++ hex));
    try testing.expect(!isHash(hex));
    try testing.expect(!isHash("sha256:" ++ hex ++ "0"));
    try testing.expect(!isHash("sha256:z" ++ hex[1..]));
}

test "isVersion" {
    try testing.expect(isVersion("0.17.0"));
    try testing.expect(isVersion("1"));
    try testing.expect(!isVersion("master"));
    try testing.expect(!isVersion("0.18.0-rc1"));
    try testing.expect(!isVersion("v1.2"));
    try testing.expect(!isVersion("1..2"));
    try testing.expect(!isVersion("1.2."));
    try testing.expect(!isVersion(""));
}

test "compareVersions compares numbers, not text" {
    try testing.expectEqual(.gt, compareVersions("0.17.0", "0.9.1"));
    try testing.expectEqual(.lt, compareVersions("0.9.1", "0.17.0"));
    try testing.expectEqual(.gt, compareVersions("0.14.1", "0.14.0"));
    try testing.expectEqual(.gt, compareVersions("1.0.0", "0.99.99"));
    try testing.expectEqual(.eq, compareVersions("1.2.3", "1.2.3"));
    try testing.expectEqual(.eq, compareVersions("1.2", "1.2.0"));
    try testing.expectEqual(.eq, compareVersions("01.2", "1.02"));
    try testing.expectEqual(.gt, compareVersions("1.2.1", "1.2"));
    try testing.expectEqual(.lt, compareVersions("1.2", "1.2.1"));
    // bigger than any integer type
    try testing.expectEqual(.gt, compareVersions("100000000000000000000000000000000", "99999999999999999999999999999999"));
}

test "expandPath" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var vars: Vars = .{};
    vars.set("v", "0.17.0");
    // a value with a slash stays in its part
    vars.set("s", "a/b");

    var segments = try expandPath("/{v}/tarball", &vars, arena);
    try testing.expectEqualStrings("0.17.0", segments[0].key);
    try testing.expectEqualStrings("tarball", segments[1].key);

    segments = try expandPath("/{*}/x-{v}", &vars, arena);
    try testing.expectEqual(.any_key, std.meta.activeTag(segments[0]));
    try testing.expectEqualStrings("x-0.17.0", segments[1].key);

    segments = try expandPath("/{s}/c", &vars, arena);
    try testing.expectEqual(2, segments.len);
    try testing.expectEqualStrings("a/b", segments[0].key);

    segments = try expandPath("/assets/[name=x-{v}.zip]/digest", &vars, arena);
    try testing.expectEqualStrings("name", segments[1].select.field);
    try testing.expectEqualStrings("x-0.17.0.zip", segments[1].select.value);
    try testing.expectEqualStrings("digest", segments[2].key);

    // a slash in a VALUE doesn't split it, at the end too
    segments = try expandPath("/[n=a/b]/c", &vars, arena);
    try testing.expectEqualStrings("a/b", segments[0].select.value);
    segments = try expandPath("/x/[n=a/b]", &vars, arena);
    try testing.expectEqualStrings("a/b", segments[1].select.value);
}

fn testVars() Vars {
    var vars: Vars = .{};
    vars.set("arch", "amd64");
    return vars;
}

test "matchOne: a redirect's version in the middle of its URL" {
    const vars = testVars();
    const url = "https://curl.se/windows/dl-8.23.0_6/curl-8.23.0_6-win64-mingw.zip";
    try testing.expectEqualStrings("8.23.0_6", matchOne("/dl-{*}/curl-", url, &vars).one);
}

test "matchOne: a capture ends at the text after it" {
    const vars = testVars();
    try testing.expectEqualStrings("2.0", matchOne("stable: {*},", "x\n  stable: 2.0,\n", &vars).one);
}

test "matchOne: a final capture ends at the end of the line" {
    const vars = testVars();
    try testing.expectEqualStrings("2.9.8", matchOne("v{*}", "v2.9.8\r\nmore", &vars).one);
}

test "matchOne: a capture can't span lines" {
    const vars = testVars();
    try testing.expectEqual(.none, std.meta.activeTag(matchOne("a{*}b", "a1\nb", &vars)));
}

test "matchOne: nothing matches" {
    const vars = testVars();
    try testing.expectEqual(.none, std.meta.activeTag(matchOne("v{*}", "nope", &vars)));
}

test "matchOne: more than one match is an error, even with the same capture" {
    const vars = testVars();
    const different = matchOne("version = '{*}'", "schema-version = '1'\nversion = '1.2'\n", &vars).several;
    try testing.expectEqualStrings("1", different[0]);
    try testing.expectEqualStrings("1.2", different[1]);
    const same = matchOne("v{*}<", "v1<\nv1<\n", &vars).several;
    try testing.expectEqualStrings("1", same[0]);
    try testing.expectEqualStrings("1", same[1]);
}

test "matchOne: a capture at the start of a pattern doesn't match once per position" {
    const vars = testVars();
    try testing.expectEqualStrings("abc", matchOne("{*}-x", "abc-x", &vars).one);
    try testing.expectEqualStrings("only line", matchOne("{*}", "only line", &vars).one);
    const lines = matchOne("{*}", "first line\nsecond", &vars).several;
    try testing.expectEqualStrings("first line", lines[0]);
    try testing.expectEqualStrings("second", lines[1]);
}

test "matchOne: a set variable stands for its value" {
    const vars = testVars();
    const page = "foo-arm64-1.0.zip foo-amd64-2.0.zip";
    try testing.expectEqualStrings("2.0", matchOne("foo-{arch}-{*}.zip", page, &vars).one);
}

test "matchOne: the literal after a capture can be a set variable" {
    const vars = testVars();
    try testing.expectEqualStrings("1.2", matchOne("v{*}{arch}", "v1.2amd64", &vars).one);
}

test "an empty capture isn't a match" {
    const vars = testVars();
    try testing.expectEqual(.none, std.meta.activeTag(matchOne("v{*}", "v", &vars)));
}

test "a brace that isn't a capture or variable is literal" {
    const vars = testVars();
    try testing.expectEqualStrings("3", matchOne("a: { v: {*} }", "a: { v: 3 }", &vars).one);
}

test "expand" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var vars = testVars();
    vars.set("version", "1.2");
    try testing.expectEqualStrings(
        "https://e.com/v1.2/foo-amd64.zip",
        try expand("https://e.com/v{version}/foo-{arch}.zip", &vars, arena.allocator()),
    );
}

test "urlScheme" {
    try testing.expectEqualStrings("https", urlScheme("https://e.com/a").?);
    try testing.expectEqualStrings("ftp", urlScheme("ftp://e.com/a").?);
    try testing.expectEqualStrings("git+ssh", urlScheme("git+ssh://e.com/a").?);
    try testing.expectEqualStrings("file", urlScheme("file:///a").?);
    try testing.expectEqual(null, urlScheme("./foo"));
    try testing.expectEqual(null, urlScheme("foo"));
    try testing.expectEqual(null, urlScheme("C:\\foo"));
    try testing.expectEqual(null, urlScheme("./a://b"));
    try testing.expectEqual(null, urlScheme("://a"));
    try testing.expectEqualStrings("1a", urlScheme("1a://b").?);
    try testing.expectEqual(null, urlScheme(""));
    try testing.expectEqual(null, urlScheme("https"));
    try testing.expectEqual(null, urlScheme("https:/a"));
    try testing.expectEqual(null, urlScheme("https:"));
}

test "isUrl" {
    try testing.expect(isUrl("https://e.com/a"));
    try testing.expect(isUrl("https://e.com/"));
    try testing.expect(isUrl("http://e.com/a"));
    try testing.expect(isUrl("http://127.0.0.1:8000/a"));
    try testing.expect(!isUrl("ftp://e.com/a"));
    try testing.expect(!isUrl("file:///a"));
    try testing.expect(!isUrl("http://e.com"));
    try testing.expect(!isUrl("https://e.com"));
    try testing.expect(!isUrl("https:///a"));
    try testing.expect(!isUrl("https://e.com/a b"));
    try testing.expect(!isUrl("https://e.com/a\nb"));
}

test "filePath" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("C:\\pkgs\\foo", (try filePath("file:///C:/pkgs/foo", arena)).?);
    try testing.expectEqualStrings("C:\\foo", (try filePath("file:///C:/foo", arena)).?);
    try testing.expectEqualStrings("C:\\a b\\foo", (try filePath("file:///C:/a%20b/foo", arena)).?);
    for ([_][]const u8{
        "https://e.com/a",
        "file://C:/foo",
        "file://host/foo",
        "file:///foo",
        "file:///pkgs/foo",
        "file:///./foo",
        "file:///C:",
        "file:///C:/",
        "file:///C:foo",
        "file:///C:\\foo",
        "file:///C:/a/../foo",
        "file:///C:/a/./foo",
        "file:///C:/a%2F..%2Ffoo",
        "file:///C:/a%5Cfoo",
        "file:///C:/a//foo",
        "file:///C:/a/",
        "file:///C:/a b",
        "file:///C:/foo?x",
        "file:///C:/foo#x",
        "file:///C:/foo:stream",
        "file:///C:/nul",
    }) |bad| {
        if (try filePath(bad, arena)) |path| {
            std.debug.print("'{s}' gave '{s}'\n", .{ bad, path });
            return error.TestUnexpectedResult;
        }
    }
}

test "urlName" {
    try testing.expectEqualStrings("foo", urlName("file:///C:/pkgs/foo"));
    try testing.expectEqualStrings("foo", urlName("https://e.com/foo"));
    try testing.expectEqualStrings("foo", urlName("http://e.com:8000/a/foo"));
    try testing.expectEqualStrings("foo", urlName("https://e.com/a/b/foo"));
    try testing.expectEqualStrings("foo", urlName("https://e.com/a/foo?x=1/y"));
    try testing.expectEqualStrings("foo", urlName("https://e.com/a/foo#x"));
    try testing.expectEqualStrings("", urlName("https://e.com/a/"));
    try testing.expectEqualStrings("", urlName("https://e.com/"));
}

test "parseNames counts valid lists" {
    var diag: Diagnostic = .{};
    try testing.expectEqual(0, try parseNames("", &diag));
    try testing.expectEqual(1, try parseNames("hyperfine\n", &diag));
    try testing.expectEqual(3, try parseNames("anyzig\nhyperfine\nninja\n", &diag));
}

fn expectBadNames(text: []const u8, line: u32, message: []const u8) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(error.Invalid, parseNames(text, &diag));
    try testing.expectEqualStrings(message, diag.message);
    try testing.expectEqual(line, diag.line);
}

test "parseNames is strict" {
    try expectBadNames("a", 1, "the last line has no newline");
    try expectBadNames("a\nb", 2, "the last line has no newline");
    try expectBadNames("a\r\n", 1, "invalid package name");
    try expectBadNames("\n", 1, "invalid package name");
    try expectBadNames("a\n\nb\n", 2, "invalid package name");
    try expectBadNames(" a\n", 1, "invalid package name");
    try expectBadNames("# comment\n", 1, "invalid package name");
    try expectBadNames("Upper\n", 1, "invalid package name");
    try expectBadNames("../evil\n", 1, "invalid package name");
    try expectBadNames("<!DOCTYPE html>\n", 1, "invalid package name");
    try expectBadNames("b\na\n", 2, "out of order or duplicate");
    try expectBadNames("a\na\n", 2, "out of order or duplicate");
}

test "isPackageName" {
    try testing.expect(isPackageName("hyperfine"));
    try testing.expect(isPackageName("7zip"));
    try testing.expect(isPackageName("a.b_c-d"));
    try testing.expect(!isPackageName("Hyperfine"));
    try testing.expect(!isPackageName(""));
    try testing.expect(!isPackageName("."));
    try testing.expect(!isPackageName(".."));
    try testing.expect(!isPackageName("-x"));
    try testing.expect(!isPackageName("a/b"));
    try testing.expect(!isPackageName("a\\b"));
    try testing.expect(!isPackageName("a b"));
    try testing.expect(!isPackageName("a?b"));
}

const std = @import("std");
const json = @import("json.zig");
const testing = std.testing;
