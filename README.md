# winbin

A package manager for Windows command line programs.

It installs programs into the directory `winbin.exe` is in. Put that directory on your `PATH` and
every program winbin manages is available; take it off and none are. winbin never changes `PATH`
itself.

## Install

```bat
powershell -c "irm https://winbin-org.github.io/install.ps1 | iex"
```

This asks where to install: any directory on your `PATH` that you can write to, or `C:\winbin` if it isn't one
of those. There's nothing special about a location: winbin works from any directory, and installs next to itself.
It never changes your `PATH`, it only tells you how to add a directory that isn't on it. If `winbin.exe` is already
on your `PATH`, it's updated where it is.

That's for running it yourself. For a script, this longer form can take options, which the short one has no way to:

```bat
powershell -c "& ([scriptblock]::Create((irm https://winbin-org.github.io/install.ps1))) -NonInteractive C:\winbin"
```

The argument is the directory to install to, which `-NonInteractive` requires: it never asks anything. `-Pdb`
installs `winbin.pdb` as well, and an update keeps one that's already there.

There's no release to download yet, so for now build it yourself.

## Usage

```text
winbin install NAME|URL...    install packages that aren't already ('i' for short)
winbin update NAME|URL...     update installed packages to the latest version
winbin uninstall NAME|URL...  remove installed packages
winbin available              print the packages you can install
winbin installed              print the installed packages
winbin --version              print winbin's version
```

A package is the URL of its manifest, given as one of:

| Argument | Meaning |
|----------|---------|
| `NAME` | a package in the registry, at `https://winbin-org.github.io/pkg/NAME` |
| `URL` | a package anywhere else, anything starting with `SCHEME://`, only `https://`, `http://` and `file:///` are supported. A file needs its absolute path, like `file:///C:/pkgs/foo` |

A package's URL is what identifies it, so update and uninstall a package with the same `NAME` or `URL` you
installed it with. A package in the registry only goes by its name, its URL is refused, so there's only ever
one way to write it. Two packages with different URLs can't replace each other: if they install the same
thing, the second is an error until the first is uninstalled.

- `install`, `update` and `uninstall` check all their arguments first, then handle each package in turn,
  stopping at the first failure: what they've already done stays. `update` and `uninstall` also check everything
  is installed first.
- `--version` is the UTC date it was built, like `v2026_11_03`.
- `install` doesn't touch the network for a package that's already installed. If one of its exes is
  missing, it installs it again.
- `install`, `update` and `uninstall` stop if an exe installed directly was changed or replaced,
  rather than treating it as theirs. Deleting it and running `install` puts it back.
- `available` downloads the list of packages each time, and nothing else ever needs it.

## Trust

winbin installs whatever a package's host serves as its latest release, so you're trusting that host
as much as if you'd downloaded the program from it yourself. Over HTTPS that protects the download on
its way to you. A manifest can also give a hash, usually one the host publishes, and nothing is
installed if the download doesn't match. That catches a corrupted download or a file replaced after it
was published, but not a compromised host, which could change the hash too.

Installing never runs a package's code. A manifest can only make requests, write the exes it names
next to `winbin.exe`, and extract its archive into its own directory there. It can't replace what
another package installed: uninstall that package first. Before replacing anything else that's already
there, winbin asks, ahead of downloading anything. Scripts can answer with `echo y | winbin install NAME`,
and with no one to answer the install fails.

## Files

```text
DIR\winbin.exe
DIR\hyperfine.exe                  what packages install
DIR\zig.exe                        an exelink, a small exe that runs zig-0.17.0\...\zig.exe
DIR\zig-0.17.0\                    the whole archive, for a package that needs one
DIR\.winbin\installed\hyperfine-1a2b3c4d5e6f7a8b    the download URL and hash, what it installed, the manifest's URL, and the manifest
DIR\.winbin\tmp\                   downloads and extractions in progress, one directory per run
DIR\.winbin\lock                   held while changing what's installed
DIR\.winbin\journal                what a change is doing, while it's doing it
DIR\.winbin\publish\               what a change is about to put in DIR
```

Several winbins can run at once: they download and extract side by side, and take turns changing what's
installed. A change only touches `DIR` after everything it needs is on the disk and written down in the
journal, so if it's interrupted, even by a power loss, the next winbin finishes it. A failure before that
leaves the old version as it was.

## Manifests

A manifest says how to find a package's latest version, where to download it, and what to install.
[MANIFEST.md](MANIFEST.md) describes the format.

## Registry

[winbin-org.github.io](https://github.com/winbin-org/winbin-org.github.io) holds the manifests in
`pkg/`, and serves them with a generated `names` file listing them.

## Building

Needs zig 0.17.0.

```bat
zig build                 :: zig-out\bin\winbin.exe, for this machine's arch
zig build install-x86_64  :: zig-out\bin\x86_64\winbin.exe, also install-aarch64 and install-x86
zig build test
zig build release         :: run the tests, then create zig-out\winbin-ARCH.zip for each arch
```

`zig build test` has unit tests, and end-to-end tests in `test/e2e.zig` that run the real exe in a temporary
directory against a local server: installs and updates, malicious zips, several winbins at once, and killing
one in the middle of a change. None of it touches the internet. The end-to-end tests run twice: against the
real exe, and against one using `DebugAllocator`, which fails on memory that wasn't freed or was freed wrong.

A panic or crash prints a [wintrace](https://github.com/marler8997/wintrace) stack trace, which needs no PDB, so
the installer leaves it out unless asked. A release's archive has `winbin.pdb` next to `winbin.exe`, for
`wintrace-symbolize` to name a trace's frames. wintrace doesn't support x86, so a panic there only prints its message, and that exe has no PDB.

`zig build run` and `run-ARCH` work too, but the exe they run is in `.zig-cache`, so that's where
anything it installs ends up.
