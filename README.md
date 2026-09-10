# Mac Manager

A local macOS app for managing what is installed on your Mac, what is using its
memory, where its disk space went, and which ports are open.

Native SwiftUI. No dependencies, no package manager, no network access, no
background agent. It reads the same system tools you would run by hand
(`lsof`, `ps`, `du`, `vm_stat`, `sysctl`, `mdls`) and puts them behind one window.

![Overview](docs/screenshots/overview.png)

## Build and run

```bash
./build.sh && open "build/Mac Manager.app"
```

To keep it in your Applications folder:

```bash
cp -R "build/Mac Manager.app" /Applications/
```

Requires the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

### Growth

**What changed, where, and when — drillable to the file, for any period.**

Most disk tools show what is *big*. This shows what *grew*, attributed down the
tree. Pick a folder and a window — 24 hours, 7 days, 30 days, 90 days, a year, or
any date you choose — and it lists which subfolder the growth landed in, then
lets you open that subfolder and see the same breakdown one level deeper, all the
way to the individual files.

It needs no prior snapshot and no background agent. Every file records when it
was created and when it was last written, so growth over any period is read
straight off the disk. A file created inside the window counts as **Added**; one
created earlier but rewritten inside it counts as **Updated** — which separates
real growth from an application merely touching its own files. On the machine
this was built on, a 30-day window over Application Support showed 24.24 GB
added against 740 MB updated, so almost all of it was genuinely new.

One pass collects the changed files; every level of drill-down is grouped from
that list, so navigating deeper is instant however large the tree.

The one thing timestamps cannot show is deletion — a removed file leaves nothing
behind to read a date from. Measured snapshots cover that, and are kept alongside
as *Folders that shrank*.

### Ports

Every TCP port in the LISTEN state, which process owns it, and whether it is
reachable from your network or only from this Mac.

![Ports](docs/screenshots/ports.png)

## File tabs

### Find

Search your files by meaning as well as by name, and tag them.

Scoring is hybrid on purpose. Meaning alone is not trustworthy on short
filenames — asked for "work slides" a pure embedding search ranked a holiday
photo above an actual presentation — so keyword matching against names, folders,
tags and file kind carries most of the weight, and semantic similarity fills the
gaps a keyword misses. Asking for "spreadsheet budget" surfaces a `.csv` with
neither word in its name.

The embedding model is Apple's, running on this Mac. Nothing is uploaded.

Vectors are quantized to Int8 — 512 bytes per file rather than 4 KB. Measured
against full precision the worst cosine error is 0.006, far too small to change
a ranking, and it takes a 43,000-file index from ~170 MB of memory to 22 MB.
Embedding runs across all cores at roughly 1,600 files/sec, so that index builds
in about 40 seconds. The default limit is 250,000 files and is adjustable in the
tab; search works lexically while embedding is still running.

Tags are real macOS Finder tags, written to the `_kMDItemUserTags` extended
attribute — so tags set here appear in Finder's sidebar, and tags set in Finder
appear here.

### Organize

Sorts loose files in a folder into a structure — by type, by type and year, or
by year and month.

Nothing moves until you have seen the complete plan and approved it. Existing
subfolders are left alone, because they usually reflect a structure you already
chose. Nothing is ever overwritten: a name that is already taken gets a numbered
suffix. Every run records where each file came from, so **Undo** puts them all
back and removes the folders it created.

### Backup

Mirrors chosen folders to an external drive using rsync.

- **Never deletes.** `--delete` is not used, so removing a file on your Mac never
  removes it from the backup.
- **Always previewable.** A dry run lists exactly what would be copied first.
- **Versioned.** Replaced files move into a timestamped folder rather than being
  overwritten, so previous versions stay recoverable.
- **Reports progress in detail.** Live file count, bytes copied against the
  total, current file, transfer rate and estimated time, plus a per-folder
  comparison of what is on this Mac against what is on the drive. Progress is
  measured in bytes rather than files, because one file can be a gigabyte and
  the next a kilobyte.
- **Skips build junk.** On the machine this was built on, excluding
  `node_modules` and friends took one folder from **679,767 files to 60,752**,
  and the scan from 44 seconds to 3.
- **Carries tags.** NTFS and exFAT drives cannot store extended attributes, so
  tags would be silently lost on copy. They are written alongside the backup as
  `tags.json` instead.

**Interruptions are expected, not exceptional.** A run is journalled to disk as
it proceeds, so a backup cut short — the drive unplugged, the Mac asleep or shut
down, the app quit — is picked up where it stopped rather than started over.
Folders that finished are skipped; within a folder rsync skips files that already
match; `--partial` keeps a half-written file so it continues rather than
restarting. Unplugging the drive stops the transfer immediately rather than
letting rsync write into a mount point that is no longer there, and reconnecting
it offers to carry on.

**State survives corruption.** Everything the app remembers is written
atomically with the previous good version kept alongside. A crash mid-write
leaves the old file intact rather than a truncated one; a file that will not
decode is restored from its backup automatically; and if both are unreadable the
bad file is set aside rather than deleted, and the app starts fresh instead of
failing at launch. The Backup tab lists every state file and whether it reads
cleanly.

It is a mirror with history, not a Time Machine replacement — it does not
snapshot your whole system, and a drive that lives next to your Mac is not
protection against fire or theft.

## Exclusions

One list, shared by search indexing, backups and duplicate scans — a folder not
worth backing up is rarely worth indexing either, and separate lists drift apart.

Recommended defaults cover build output (`node_modules`, `DerivedData`, `Pods`,
virtual environments), system junk (`.DS_Store`, `Thumbs.db`, `.Spotlight-V100`)
and caches. Judgement calls ship switched **off** rather than assumed: `.git` is
your version history, `build` and `dist` sometimes hold real files, and disk
images are large but often irreplaceable.

Patterns follow rsync's own syntax, so the same list is handed straight to it. A
bare name matches any file or folder called that, `*.ext` matches an extension,
and anything containing a slash matches part of a path.

## How removal works

**Nothing is ever deleted. Everything goes to the Trash.**

That is a deliberate trade, and it has one consequence worth stating plainly:
*moving 4 GB of caches to the Trash does not free 4 GB until you empty the Trash.*
The app says so at every point where it matters, and gives you a button to open
the Trash in Finder. It will not empty the Trash for you — that is a permanent
deletion, and it stays your decision.

Before anything moves, you see the exact list of files with their sizes and can
uncheck any of them.

### How leftover files are matched

Conservatively, on purpose:

- **Bundle identifier prefix** in the folders keyed by identifier
  (`~/Library/Containers`, `Caches`, `Preferences`, `HTTPStorages`,
  `Group Containers`, `LaunchAgents`, and the machine-wide equivalents).
- **Exact folder-name match** in the few places keyed by app name
  (`~/Library/Application Support`, `Caches`, `Logs`).

Anything ambiguous is left out rather than guessed at. A missed leftover file
costs a few megabytes; a wrong match costs you data.

## Permissions

- **Administrator password** — only if you remove something owned by root. The
  app hands the move to Finder, which asks you directly. It never runs `sudo`.
- **Automation (Finder)** — same case, prompted once by macOS.
- **Full Disk Access** — optional. Without it a few protected paths report as
  empty. Grant it in System Settings › Privacy & Security if you want those
  measured.

## Known limits

- `lsof` only reports processes your account can see, so ports owned by root or
  another user are not listed. The Ports tab says this on screen.
- System apps in `/System/Applications` are shown for context but marked
  Protected — they are on the sealed system volume and cannot be removed.
- Sizes come from `du`, which measures actual blocks used. Apps sharing files
  through hard links can read smaller than expected.
- The app is signed ad-hoc, not notarised. It is built from source on your own
  machine, so Gatekeeper does not quarantine it.

## Layout

```
Sources/
  MacManagerApp.swift      app shell, sidebar, shared state
  Support/                 shell wrapper, formatters, design system
  Models/                  data types
  Services/                AppScanner, MemoryMonitor, StorageScanner, PortScanner
  Views/                   one file per tab, plus the uninstall sheet
                           (ExploreView is the hidden-file browser)
Tools/MakeIcon.swift       app icon, drawn in code
build.sh                   compile, bundle, sign
```

## License

MIT — see [LICENSE](LICENSE).
