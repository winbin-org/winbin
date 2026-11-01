# The `.winbin` directory

Everything winbin keeps about a directory it installs to is in `DIR\.winbin`. `DIR` is the winbin
directory: where winbin.exe is, or what `--dir` or `WINBIN_DIR` says. Nothing outside `DIR` is read
or written, and there's no registry key and no per-user state.

Different winbins can use the same `DIR`: at the same time, and one after another, including a newer
one after an older one and the other way round. So this is a protocol between them, and each part
below says what every winbin has to agree on.

Records and journals start with the version of this document they're written to, which is 1. A
winbin that finds a later version leaves that file alone and says a newer winbin wrote it.

A winbin writes the lowest version that can say what it's writing: a later one only for a record or
journal that uses something the earlier ones don't have. Then going back to an older winbin only
loses the packages that needed the newer one.

```
DIR\.winbin\lock                   held to read or change what's installed
DIR\.winbin\installed\RECORD       one install record per installed package
DIR\.winbin\journal                a change that's been decided and may not be finished
DIR\.winbin\journal.new            the journal while it's being written
DIR\.winbin\publish\               what a change is about to move into DIR
DIR\.winbin\delete\                what's been moved out of DIR, deleted as soon as it can be
DIR\.winbin\deferred-cleanup\NAME  NAME in DIR should be deleted, and couldn't be yet
DIR\.winbin\tmp\ID.lock            held by a winbin that's downloading
DIR\.winbin\tmp\ID\                what that winbin has downloaded and extracted
```

All text is bytes with `\n` line ends, no `\r`, no BOM.

## Names

Everything a package installs is a single name directly in `DIR`, never a path. A NAME starts with
a letter or digit and has only letters, digits, `.`, `_` and `-`. Windows ignores case, so names are
compared ignoring ASCII case.

What a package installs also can't have a name Windows would treat as something else: it doesn't end in `.`, and what's
before its first `.` isn't `con`, `prn`, `aux`, `nul`, or `com` or `lpt` and a digit, in any case.

- **PACKAGE:** a NAME with no uppercase letters. It isn't installed, so that's all.
- **EXE:** a NAME ending `.exe`.
- **PDB:** a NAME ending `.pdb`.
- **FILE:** any NAME.
- **DIRNAME:** any NAME.
- **HASH:** `sha256:` and 64 hex digits.
- **URL:** `https://` or `http://`, then `HOST` or `HOST:PORT`, then a `/` and anything after it. No spaces or
  control bytes, and no user or IPv6 address in the host.

## `lock`

An empty file. A winbin takes an exclusive lock on it, the kind that's released when its handle is
closed or its process dies, before it reads or changes `installed`, `journal`, `publish`, `delete` or
`deferred-cleanup`, or installs to or deletes from `DIR`. It's never deleted, another winbin could be
waiting on it. It isn't held while downloading or extracting, or while waiting for an answer.

Whoever takes the lock first does this, before anything else:

1. If there's a `journal`, carry it out. See below.
2. If there isn't, delete `publish` and what can be deleted of `delete`: without a journal nothing
   has been done with them.
3. Go through `deferred-cleanup`.

## `installed\RECORD`

A package is identified by the URL of its manifest. RECORD is `PACKAGE-ID`, where PACKAGE is the
last part of that URL and ID is the first 8 bytes of the SHA-256 of the URL, as 16 lowercase hex
digits. For a package in the registry the URL is `https://winbin-org.github.io/pkg/PACKAGE`.

```
winbin-record 1
installed-url URL
installed-hash HASH
installed-exe EXE HASH
installed-exelink EXE
installed-hardlink FILE HASH
installed-dir DIRNAME
installed-pdb PDB
installed-from MANIFEST-URL
the manifest, to the end of the file
```

- The version, `installed-url` and `installed-hash` come first, in that order: where the package was downloaded
  from, and the hash of what that served.
- Then any number of entries, in any order, one per name the package put in `DIR`. An `installed-exe`
  and an `installed-hardlink` have the hash of that file as it was installed.
- Then `installed-from`, which has to be the URL the record's file name was made from. It can be a
  `file:///` URL.
- Everything after that line is the manifest it was installed from, byte for byte. It's only ever
  compared with the manifest as it is now, never parsed, and it can contain anything, a line
  starting `installed-` included.

What it's used for:

- **Is it installed, and is it current:** the record exists, and the URL, hash and manifest are what
  they'd be now.
- **What to remove:** an uninstall, or an update that no longer installs a name, deletes exactly the
  entries. That's why an entry can only be a name in `DIR`.
- **Whose a name is:** a package can't install a name that's an entry in another package's record.
- **Was it changed:** an exe or hardlink whose hash isn't the record's was replaced by something
  else, and winbin won't overwrite or delete it.

A record is written under `RECORD.new`, synced, and renamed to `RECORD`, only while carrying out a
journal.

## `journal`

A change to `DIR`, to one package. It's written to `journal.new`, synced, and renamed to `journal`.
From the rename on, the change is going to happen: whoever holds the lock carries it out from the
start, skipping what's already been done, until the last step, which deletes the journal.

```
winbin-journal 1
install RECORD
an install record, to the end of the file
```

or

```
winbin-journal 1
uninstall RECORD
```

An `install` is also how a package is updated. Nothing else is written down: what has to go is
whatever the package's record in `installed` has that the new one doesn't, which for an `uninstall`
is all of it.

Carrying it out, in this order:

1. For an `install`: for each entry of the new record whose name is in `publish`, move what's in
   `DIR` under that name into `delete`, then move it from `publish` into `DIR`.
2. For each entry of `installed\RECORD` as it is now that the new record doesn't have: delete it. A
   file that's in use is moved into `delete`. A directory is moved into `delete`, or gets an entry
   in `deferred-cleanup` if it can't be.
3. For an `install`, write the new record as `installed\RECORD`. For an `uninstall`, delete it.
4. Delete `publish`, what can be deleted of `delete`, and then `journal`.

The record is only replaced in step 3, so starting again before then finds the same things to
delete, and starting again after it finds none.

## `publish\`

What a change is about to put in `DIR`, under the names it will have there. It's moved here, already
synced, before the journal is renamed into place. It only means anything while there's a journal.

## `delete\`

What's been moved out of `DIR`. A running exe can be renamed but not deleted, so this is how one is
replaced. Something moved here keeps its name, or gets `.1`, `.2` and so on after it if that's taken.
Every winbin holding the lock deletes what it can of it and says nothing about the rest.

## `deferred-cleanup\NAME`

An empty file. It says the directory or file `NAME` in `DIR` should be deleted and couldn't be,
usually because a program in it was running. Every winbin holding the lock goes through them:

- `NAME` isn't a DIRNAME: warn and leave the note.
- `NAME` is gone from `DIR`: delete the note.
- A record has `NAME` as an entry, so it's been installed again since: delete the note.
- A record couldn't be read, so there's no telling: leave both.
- Otherwise delete it. A directory is moved into `delete`. If that fails, leave the note.

## `tmp\`

A winbin that's downloading makes `ID.lock`, takes an exclusive lock on it for as long as it's alive,
and works in the directory `ID`. ID is 24 random hex digits. Nothing here is covered by `lock`.

An `ID.lock` that can be locked was left by a winbin that died. Whoever finds one deletes the
directory `ID` and then the lock file, still holding the lock. What's inside `ID` is that winbin's
own business and isn't part of this.

## What a winbin does with a file it can't use

- **A record or journal with a later version:** it isn't damaged, a newer winbin wrote it. For a
  record, commands on that package fail, and for other packages it's skipped with a warning. For a
  journal, every command fails. Both say to use that winbin, or to run the install script on `DIR`,
  which brings the newest winbin with it: that finishes the journal and updates the winbin there.
- **A record that was skipped, for either reason:** a package that would replace something in `DIR`
  that no readable record has is refused instead of being asked about, since it could be that
  package's.
- **A record that isn't valid:** for that package, every command fails and says to delete the
  record and what it installed. For other packages it's skipped with a warning, so its names aren't
  protected from them.
- **A journal that isn't valid:** every command fails until it's deleted by hand. Carrying out a
  damaged one could delete the wrong thing.
- **Anything else in `.winbin`, or in `installed`, `tmp` or `deferred-cleanup`, that isn't described
  here:** a file in `installed` is read as a record. A directory in `installed` fails every command.
  Other names directly in `.winbin` are never looked at.
