# Mac Manager

A local macOS app for managing what is installed on your Mac, what is using its
memory, where its disk space went, and which ports are open.

Native SwiftUI. No dependencies, no package manager, no network access, no
background agent. It reads the same system tools you would run by hand
(`lsof`, `ps`, `du`, `vm_stat`, `sysctl`, `mdls`) and puts them behind one window.

## Build and run

```bash
./build.sh && open "build/Mac Manager.app"
```

To keep it in your Applications folder:

```bash
cp -R "build/Mac Manager.app" /Applications/
```

Requires the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

## The four tabs

**Overview** — memory, storage, app count and open ports at a glance, plus large
apps you have not opened in over six months.

**Applications** — everything in `/Applications` and `~/Applications` with its
version, size, and the date you last opened it. Sort by size to find what is
costing you, or by last opened to find what you have forgotten about. Removing an
app also finds the support files it scattered through your Library folders, which
a plain drag-to-Trash leaves behind — often far larger than the app itself.

**Memory** — a live breakdown of app memory, wired, compressed and cached, with
processes grouped by the app that owns them, so a browser reads as one row
instead of forty. Quit asks nicely; Force Quit does not.

**Storage** — disk capacity, plus the directories that quietly accumulate
gigabytes: caches, logs, Xcode derived data, package-manager downloads. Each is
labelled *Safe to clear* or *Review first*. There is also an on-demand
measurement of every top-level folder in your home directory.

**Ports** — every TCP port in the LISTEN state, which process owns it, and
whether it is reachable from your network or only from this Mac.

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
Tools/MakeIcon.swift       app icon, drawn in code
build.sh                   compile, bundle, sign
```

## License

MIT — see [LICENSE](LICENSE).
