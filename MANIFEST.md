# Manifests

A manifest works out the versions of a package, and both how and what they install.

```text
let arch = @map_arch(x86_64="x86_64", aarch64="aarch64", x86="i686")
let release = @fetch("https://api.github.com/repos/sharkdp/hyperfine/releases/latest")
let tag = @json_value(release, "/tag_name")
let asset = "hyperfine-{tag}-{arch}-pc-windows-msvc"
let url = @json_value(release, "/assets/[name={asset}.zip]/browser_download_url")
let digest = @json_value(release, "/assets/[name={asset}.zip]/digest")

download url
verify digest
extract
discard "{asset}/CHANGELOG.md"
discard "{asset}/LICENSE-APACHE"
discard "{asset}/LICENSE-MIT"
discard "{asset}/README.md"
discard "{asset}/autocomplete"
discard "{asset}/hyperfine.1"
install exe "hyperfine.exe" from "{asset}/hyperfine.exe"
```

## Reading one

- **A line** is either a `let`, or a step like `download`. Blank lines and lines starting with `#` are
  ignored.
- **`let NAME`** sets a variable, and the name is the package's own. No name is special, including
  `arch` and `version`, which are only names most packages happen to use. winbin never looks for one.
- **`@name`** is a function built into winbin, and a package can't define its own.
- **`"quoted"`** is text, where `{name}` stands for that variable's value. A `{` that doesn't start one is
  just a `{`. The only escapes are `\"` and `\\`.
- **A bare word** is a variable, so `download url` and `download "{url}"` are the same.

An `@name` or a step that winbin doesn't know is an error that says the manifest may need a newer winbin.

The stages always come in this order, and only the first makes requests:

1. **Work out the values:** the `let` lines.
2. **Get the download:** `download`, then `verify` if there's a hash, then `extract` if it's an archive.
3. **Install:** `discard` lines, then `install` lines.

## Values

| Line | Meaning |
|------|---------|
| `let NAME = "TEXT"` | Text, which can use earlier variables |
| `let NAME = @map_arch(CANONICAL="SPELLING", ...)` | How the package spells the arch being installed. The canonical spellings are `x86_64`, `aarch64` and `x86`, and any left out are arches the package doesn't support. It comes before any requests, and it's fine for nothing to use the variable, which is how a package with one download says it only supports one arch |
| `let NAME = @fetch(URL)` | Requests a URL, which has to return 200 without redirecting, and keeps the response. It's asked once, however many lines read it |
| `let NAME = @fetch_redirect(URL)` | Requests a URL, which has to redirect, and gives the URL it redirects to |
| `let NAME = @json_value(RESPONSE, "PATH")` | The string at a path in a JSON response |
| `let NAME = @json_keys(RESPONSE, "PATH", except="KEY")` | A list of the keys where the path has `{*}` as a part, if the rest of the path is a string there. Other keys are skipped. `except` is optional, and leaves out one key |
| `let NAME = @newest(LIST, @compare_version)` | The newest in a list. `@compare_version` compares dot separated numbers, and anything else in the list is an error rather than being skipped, since it could be the real latest version. So is two entries being the same version |
| `let NAME = @match_text(VARIABLE, "PATTERN")` | What a pattern captures in a response, or in a value like a `tag` of `v1.2` |

Prefer JSON where a source has it, since `@match_text` depends on how a page happens to be written. A
response or a list can't be used as a value, and nothing reading one is an error.

### JSON paths

A path is its parts, each after a `/`. It can't have a key with a `/` in it.

| Part | Meaning |
|------|---------|
| `KEY` | The value of a key in an object |
| `[FIELD=VALUE]` | The element of an array that has this string in FIELD. Exactly one element has to match |
| `{*}` | Every key of an object, only in `@json_keys` |

It's an error if a path leads to something that isn't a string, or if a response isn't valid JSON.

### Patterns

A pattern has exactly one `{*}`, which is the value it captures. A capture can't span lines: it ends at
the text after it, or at the end of the line. A pattern has to match exactly once, and more than once
is an error, since taking the first would depend on the order of a page that can change.

### Several versions

Some sources list every release instead of saying which is the latest:

```text
let arch = @map_arch(x86_64="x86_64", aarch64="aarch64", x86="x86")
let index = @fetch("https://ziglang.org/download/index.json")
let versions = @json_keys(index, "/{*}/{arch}-windows/tarball", except="master")
let version = @newest(versions, @compare_version)
let tarball = @json_value(index, "/{version}/{arch}-windows/tarball")
let shasum = @json_value(index, "/{version}/{arch}-windows/shasum")

download tarball
verify "sha256:{shasum}"
extract
install dir "zig-{version}" from "zig-{arch}-windows-{version}"
install exelink "zig.exe" -> "zig-{version}/zig.exe"
```

Only the newest version's values get read, so an older release that's missing one doesn't matter.

## The download

| Line | Meaning |
|------|---------|
| `download URL` | Saves the file, following redirects |
| `verify "sha256:HEX"` | What the download's SHA-256 has to be, otherwise nothing is installed. It's optional |
| `extract` | Unpacks the zip, after it's been verified. Without it, the only thing to install is the download itself, named after the last part of its URL |

winbin saves the URL and the download's hash. A package is up to date as long as its manifest still gives
the same URL, and the same hash if it gives one.

The URL must be unique to that archive, and what it serves must never change, so a URL like
`.../latest/foo.zip` isn't allowed without a hash: a new release would look like nothing changed.

A hash from the same host as the download catches a corrupted download or a file replaced after it was
published. Only a hash written into the manifest also protects against the host itself.

## Installing

These run in order on the extracted files, in a temporary directory. Paths after `from` and `discard`
are relative to the top of the archive.

| Line | Meaning |
|------|---------|
| `discard PATH` | Deletes a file or a whole directory. All of these come before any `install`, and it's an error if it isn't there |
| `install exe NAME [from PATH]` | Moves one file next to `winbin.exe` as NAME, for a program that's a single exe |
| `install dir NAME [from PATH]` | Moves a directory next to `winbin.exe` as NAME, which should have the version in it. `from "."` is the whole archive, for zips with no top folder |
| `install exelink NAME -> PATH` | Creates NAME next to `winbin.exe`, a small exe that runs PATH, passing along its arguments, console and exit code. For a program that needs the files around it. PATH is relative to where NAME goes, and has to be in an installed directory |

**Everything in the archive has to be accounted for.** When a manifest ends, any file that wasn't installed
or discarded is an error, and nothing is installed. Empty directories don't count. A release that adds a
file stops installing until its manifest is updated, which is the point: it might be a DLL the exe now
needs.

**What's on the left is what lands next to `winbin.exe`**, and it's always a plain name, so nothing can go in
a subdirectory. `from` says where it comes from, and defaults to the same name at the top of the archive.
It's an error to give `from` when it's the same as the name.

Nothing next to `winbin.exe` changes until a manifest has run all the way through. A new version with a new
directory name goes beside the old one, and the old one is removed last, so a failure leaves the old
version working. Every path in the zip is checked first, and nothing is installed if any could end up
outside the temporary directory.

winbin records the hash of each `install exe`, and stops rather than overwriting or deleting one that's
been changed or replaced. An exelink can't be replaced while it's running, so updating a package that's
in use fails, with nothing changed. Its target is relative, so the folder with `winbin.exe` can be moved.

## Other examples

A redirect that says the latest version, which doesn't use up an API's rate limit:

```text
let arch = @map_arch(x86_64="win64", aarch64="win64a")
let location = @fetch_redirect("https://curl.se/windows/latest.cgi?p={arch}-mingw.zip")
let version = @match_text(location, "/dl-{*}/curl-")

download "https://curl.se/windows/dl-{version}/curl-{version}-{arch}-mingw.zip"
extract
install dir "curl-{version}" from "curl-{version}-{arch}-mingw"
install exelink "curl.exe" -> "curl-{version}/bin/curl.exe"
```

A zip with no top folder:

```text
let arch = @map_arch(x86_64="amd64", aarch64="arm64", x86="win32")
let page = @fetch("https://www.python.org/downloads/windows/")
let version = @match_text(page, "Latest Python 3 Release - Python {*}<")

download "https://www.python.org/ftp/python/{version}/python-{version}-embed-{arch}.zip"
extract
install dir "python-{version}" from "."
install exelink "python.exe" -> "python-{version}/python.exe"
```

A pinned version, with no requests at all:

```text
let arch = @map_arch(x86_64="win")
let version = "1.13.2"

download "https://github.com/ninja-build/ninja/releases/download/v{version}/ninja-{arch}.zip"
verify "sha256:07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65"
extract
install exe "ninja.exe"
```

A download that is the exe:

```text
download "https://example.com/jq-windows-amd64.exe"
install exe "jq.exe" from "jq-windows-amd64.exe"
```

## Testing a manifest

Install it from its file with `winbin install file:///C:/pkgs/foo`. After editing it, `winbin update file:///C:/pkgs/foo` reads it again.
