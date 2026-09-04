import Foundation

/// Measures the startup volume and the well-known directories that quietly
/// accumulate gigabytes, and clears the ones that are safe to clear.
///
/// Everything this class removes goes to the Trash. That keeps mistakes
/// recoverable, but it also means space is not reclaimed until the Trash is
/// emptied — the UI says so explicitly rather than reporting a phantom win.
final class StorageScanner: ObservableObject {

    @Published private(set) var volume = VolumeInfo()
    @Published private(set) var targets: [CleanupTarget] = []
    @Published private(set) var isScanning = false

    private let work = DispatchQueue(label: "com.macmanager.storage", qos: .userInitiated)
    /// Measurement fans out, so it needs a concurrent queue — dispatching the
    /// groups onto the serial `work` queue would run them one at a time.
    private let measure = DispatchQueue(label: "com.macmanager.storage.measure",
                                        qos: .userInitiated, attributes: .concurrent)

    // MARK: - Target catalogue

    private static func catalogue() -> [CleanupTarget] {
        let home = NSHomeDirectory()

        func t(_ name: String, _ detail: String, _ path: String, _ safety: CleanupTarget.Safety) -> CleanupTarget {
            return CleanupTarget(name: name, detail: detail, path: path, safety: safety)
        }

        return [
            // ---- Regenerated automatically; clearing costs only a rebuild ----
            t("Application caches",
              "Rebuilt automatically the next time each app runs.",
              "\(home)/Library/Caches", .safe),

            t("Application logs",
              "Diagnostic logs written by installed apps.",
              "\(home)/Library/Logs", .safe),

            t("Crash reports",
              "Reports from apps that quit unexpectedly.",
              "\(home)/Library/Application Support/CrashReporter", .safe),

            t("Saved application state",
              "Window positions and reopened documents. Rebuilt on next launch.",
              "\(home)/Library/Saved Application State", .safe),

            t("Hidden tool cache (~/.cache)",
              "Shared cache folder used by many command-line tools.",
              "\(home)/.cache", .safe),

            t("Xcode derived data",
              "Build intermediates. Xcode regenerates them on the next build.",
              "\(home)/Library/Developer/Xcode/DerivedData", .safe),

            t("iOS device support",
              "Debug symbols per iOS version. Re-downloaded when needed.",
              "\(home)/Library/Developer/Xcode/iOS DeviceSupport", .safe),

            t("Xcode cache",
              "Xcode's own cache directory.",
              "\(home)/Library/Caches/com.apple.dt.Xcode", .safe),

            t("Simulator caches",
              "Cached simulator runtime data.",
              "\(home)/Library/Developer/CoreSimulator/Caches", .safe),

            t("npm cache",
              "Downloaded packages. npm refetches anything it needs.",
              "\(home)/.npm/_cacache", .safe),

            t("Yarn cache",
              "Downloaded packages, refetched on demand.",
              "\(home)/Library/Caches/Yarn", .safe),

            t("pnpm store",
              "Content-addressed package store, refetched on demand.",
              "\(home)/Library/pnpm/store", .safe),

            t("Bun cache",
              "Downloaded packages, refetched on demand.",
              "\(home)/.bun/install/cache", .safe),

            t("Homebrew cache",
              "Downloaded bottles and formula archives.",
              "\(home)/Library/Caches/Homebrew", .safe),

            t("pip cache",
              "Downloaded Python wheels.",
              "\(home)/Library/Caches/pip", .safe),

            t("Go build cache",
              "Compiled build artefacts, regenerated on the next build.",
              "\(home)/Library/Caches/go-build", .safe),

            t("Gradle caches",
              "Downloaded dependencies and build outputs.",
              "\(home)/.gradle/caches", .safe),

            t("Cargo registry cache",
              "Downloaded crate archives.",
              "\(home)/.cargo/registry/cache", .safe),

            t("CocoaPods repos",
              "Cloned podspec repositories, re-clonable.",
              "\(home)/.cocoapods/repos", .safe),

            // ---- Real data behind them: shown, never preselected ----
            t("Containers",
              "Sandboxed data for every app you run. Often the largest folder in Library.",
              "\(home)/Library/Containers", .review),

            t("Application Support",
              "Where apps keep your actual data. Big, and mostly worth keeping.",
              "\(home)/Library/Application Support", .review),

            t("Group Containers",
              "Data shared between related apps and their extensions.",
              "\(home)/Library/Group Containers", .review),

            t("iCloud Drive (local copies)",
              "Locally downloaded copies of your iCloud files.",
              "\(home)/Library/Mobile Documents", .review),

            t("Ollama models",
              "Downloaded language models. Large, and re-downloadable.",
              "\(home)/.ollama/models", .review),

            t("Docker data",
              "Docker's virtual machine disk image. Usually many gigabytes.",
              "\(home)/Library/Containers/com.docker.docker/Data", .review),

            t("Android SDK",
              "Downloaded Android platforms, system images and build tools.",
              "\(home)/Library/Android/sdk", .review),

            t("Go module cache",
              "Downloaded Go modules.",
              "\(home)/go/pkg/mod", .review),

            t("Maven repository",
              "Downloaded Java dependencies.",
              "\(home)/.m2/repository", .review),

            t("Temporary files",
              "Your per-user temp folder. Apps use it while running.",
              NSTemporaryDirectory(), .review),

            t("Xcode archives",
              "Signed builds you may still need to distribute.",
              "\(home)/Library/Developer/Xcode/Archives", .review),

            t("Simulator devices",
              "Installed simulator runtimes and their data.",
              "\(home)/Library/Developer/CoreSimulator/Devices", .review),

            t("iOS device backups",
              "Full backups of iPhones and iPads. Irreplaceable if not synced.",
              "\(home)/Library/Application Support/MobileSync/Backup", .review),

            t("Downloads",
              "Everything you have downloaded. Worth a look before clearing.",
              "\(home)/Downloads", .review),

            t("Mail downloads",
              "Attachments saved out of Mail.",
              "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", .review),
        ]
    }

    /// The Trash is measured but never emptied by this app — reclaiming that
    /// space is a permanent deletion, so it stays the user's own action in
    /// Finder.
    static var trashPath: String { return NSHomeDirectory() + "/.Trash" }

    @Published private(set) var trashBytes: Int64 = 0

    // MARK: - Scanning

    func refresh() {
        if isScanning { return }
        isScanning = true

        let existing = StorageScanner.catalogue()
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        targets = existing
        volume = StorageScanner.readVolume()

        // Measuring 34 folders with one `du -s` each would walk shared parents
        // over and over — and ~/Library alone takes minutes. Targets sharing a
        // parent are measured together with a single `du -d 1` on that parent,
        // which walks it once and returns every child's total.
        var byParent: [String: [CleanupTarget]] = [:]
        for target in existing {
            let parent = (target.path as NSString).deletingLastPathComponent
            byParent[parent, default: []].append(target)
        }

        let group = DispatchGroup()
        // du is I/O bound, so a few in flight helps; more just thrashes.
        let slots = DispatchSemaphore(value: 3)

        for (parent, members) in byParent {
            group.enter()
            measure.async {
                // Wait here, not before dispatching: blocking on the semaphore
                // from the caller would stall the main thread.
                slots.wait()
                var measured: [String: Int64] = [:]

                if members.count > 1 {
                    let sizes = StorageScanner.directoryChildSizes(of: parent)
                    for member in members {
                        measured[member.path] = sizes[(member.path as NSString).lastPathComponent] ?? 0
                    }
                } else if let only = members.first {
                    measured[only.path] = AppScanner.size(of: only.path)
                }

                DispatchQueue.main.async {
                    for (path, bytes) in measured {
                        if let index = self.targets.firstIndex(where: { $0.path == path }) {
                            self.targets[index].sizeBytes = bytes
                            self.targets[index].scanned = true
                        }
                    }
                }
                slots.signal()
                group.leave()
            }
        }

        work.async {
            let trash = AppScanner.size(of: StorageScanner.trashPath)
            DispatchQueue.main.async { self.trashBytes = trash }
        }

        group.notify(queue: .main) { self.isScanning = false }
    }

    static func readVolume() -> VolumeInfo {
        var info = VolumeInfo()
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            info.totalBytes = Int64(values.volumeTotalCapacity ?? 0)
            // The "important usage" figure is what Finder reports, because it
            // counts space macOS can purge on demand.
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                info.availableBytes = important
            } else {
                info.availableBytes = Int64(values.volumeAvailableCapacity ?? 0)
            }
        }
        return info
    }

    /// Total of everything currently marked safe — the honest "recoverable"
    /// figure, excluding anything flagged for review.
    var reclaimableBytes: Int64 {
        return targets.filter { $0.safety == .safe }
            .reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    // MARK: - Explorer

    @Published private(set) var explorePath: String = NSHomeDirectory()
    @Published private(set) var exploreEntries: [ExploreEntry] = []
    @Published private(set) var isExploring = false
    @Published private(set) var exploreNote: String?

    /// Navigating away while a slow measurement is in flight must not let the
    /// stale result overwrite the new folder's listing.
    private var exploreGeneration = 0

    func explore(_ path: String) {
        let target = (path as NSString).standardizingPath
        exploreGeneration += 1
        let generation = exploreGeneration

        explorePath = target
        exploreNote = nil
        isExploring = true

        // Phase one: list the folder immediately, sizes unknown. Waiting for
        // `du` to walk all of ~/Library before showing anything would make the
        // explorer feel broken.
        let listing = StorageScanner.listChildren(of: target)
        exploreEntries = listing
        if listing.isEmpty {
            isExploring = false
            exploreNote = "Nothing readable here. Some folders need Full Disk Access in System Settings."
            return
        }

        // Phase two: measure, record to history, then re-sort biggest first.
        work.async {
            let sizes = StorageScanner.directoryChildSizes(of: target)

            var byFullPath: [String: Int64] = [:]
            for entry in listing where entry.isDirectory {
                byFullPath[entry.path] = sizes[entry.name] ?? 0
            }
            // Recording before reading the delta means `previous` is the prior
            // visit, not this one.
            SnapshotStore.shared.record(byFullPath)

            DispatchQueue.main.async {
                guard generation == self.exploreGeneration else { return }
                var measured = listing
                for index in measured.indices where measured[index].isDirectory {
                    measured[index].sizeBytes = sizes[measured[index].name] ?? 0
                    measured[index].measured = true
                    if let change = SnapshotStore.shared.delta(for: measured[index].path) {
                        measured[index].deltaBytes = change.bytes
                        measured[index].deltaSince = change.since
                    }
                }
                self.exploreEntries = measured.sorted { $0.sizeBytes > $1.sizeBytes }
                self.isExploring = false
            }
        }
    }

    func exploreUp() {
        let parent = (explorePath as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == explorePath { return }
        explore(parent)
    }

    func refreshExplore() { explore(explorePath) }

    /// Path components as (label, path) pairs for the breadcrumb bar.
    var exploreBreadcrumbs: [(String, String)] {
        let home = NSHomeDirectory()
        var crumbs: [(String, String)] = []
        var path = explorePath

        while path != "/" && !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            crumbs.append((name, path))
            if path == home { break }
            path = (path as NSString).deletingLastPathComponent
        }
        if crumbs.isEmpty { crumbs = [("/", "/")] }
        return crumbs.reversed()
    }

    /// Lists every child including dot-prefixed names and anything carrying the
    /// hidden flag — omitting `.skipsHiddenFiles` is the whole point, since
    /// that is exactly what Finder hides.
    static func listChildren(of path: String) -> [ExploreEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey,
                                      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let url = URL(fileURLWithPath: path)

        guard let children = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: []) else { return [] }

        var entries: [ExploreEntry] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let name = child.lastPathComponent

            // A file's size is known from its metadata; only folders need du.
            var size: Int64 = 0
            if !isDirectory {
                size = Int64(values?.totalFileAllocatedSize
                                ?? values?.fileAllocatedSize ?? 0)
            }

            entries.append(ExploreEntry(path: child.path,
                                        name: name,
                                        isDirectory: isDirectory,
                                        isHidden: (values?.isHidden ?? false) || name.hasPrefix("."),
                                        sizeBytes: size,
                                        measured: !isDirectory))
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Sizes of every immediate subfolder, from a single `du -d 1` pass. One
    /// traversal for the whole folder beats one `du -s` per child.
    ///
    /// Keyed by name rather than full path: `du` echoes the path it was given,
    /// which may differ from the URL-derived path by a `/private` prefix.
    static func directoryChildSizes(of path: String) -> [String: Int64] {
        let result = Shell.run("/usr/bin/du", ["-d", "1", "-k", path])

        func resolved(_ p: String) -> String {
            return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        }
        let resolvedTarget = resolved(path)

        var sizes: [String: Int64] = [:]
        for line in result.out.nonEmptyLines {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let kilobytes = Int64(line[line.startIndex ..< tab]
                                    .trimmingCharacters(in: .whitespaces)) ?? 0
            let reported = String(line[line.index(after: tab)...])
            let name = (reported as NSString).lastPathComponent

            // du also reports the queried folder's own total. Compare with
            // symlinks resolved, since du echoes the path it was given while
            // the caller may hold the /private-resolved form (or vice versa) —
            // as happens with the temp directory.
            if resolved(reported) == resolvedTarget { continue }

            sizes[name] = kilobytes * 1024
        }
        return sizes
    }

    // MARK: - Recent changes

    @Published private(set) var recentFiles: [RecentFile] = []
    @Published private(set) var isScanningRecent = false
    @Published private(set) var recentRoot: String = NSHomeDirectory()
    @Published private(set) var recentNote: String?

    /// Finds large files modified in the last `days`. This answers "what is
    /// growing" with no prior snapshot at all, which matters the first time the
    /// app is run — history only becomes useful on the second measurement.
    func scanRecentChanges(root: String, days: Int, minimumMB: Int) {
        if isScanningRecent { return }
        isScanningRecent = true
        recentRoot = root
        recentFiles = []
        recentNote = nil

        work.async {
            let found = StorageScanner.findRecentFiles(root: root, days: days, minimumMB: minimumMB)
            DispatchQueue.main.async {
                self.recentFiles = found
                self.isScanningRecent = false
                if found.isEmpty {
                    self.recentNote = "No files over \(minimumMB) MB were modified in the last \(days) days under this folder."
                }
            }
        }
    }

    /// `find` walks metadata only — no file contents — so it is far quicker
    /// than measuring folder totals.
    static func findRecentFiles(root: String, days: Int, minimumMB: Int) -> [RecentFile] {
        let result = Shell.run("/usr/bin/find",
                               [root,
                                "-type", "f",
                                "-mtime", "-\(days)",
                                "-size", "+\(minimumMB)M"])

        var files: [RecentFile] = []
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .contentModificationDateKey]

        for path in result.out.components(separatedBy: "\n") {
            if path.isEmpty { continue }
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            files.append(RecentFile(path: path,
                                    sizeBytes: size,
                                    modified: values.contentModificationDate ?? Date()))
        }

        return files.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Clearing

    /// Moves the *contents* of a directory to the Trash, leaving the directory
    /// itself in place. Apps expect their cache folder to exist; removing the
    /// folder outright is what breaks them.
    static func clearContents(of path: String, completion: @escaping (Int, [(String, String)]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
                DispatchQueue.main.async { completion(0, [(path, "Could not read the folder.")]) }
                return
            }

            let children = entries.map { path + "/" + $0 }
            AppScanner.moveToTrash(paths: children) { failures in
                completion(children.count - failures.count, failures)
            }
        }
    }

    static func revealTrashInFinder() {
        Shell.run("/usr/bin/open", [trashPath])
    }

    static func reveal(_ path: String) {
        Shell.run("/usr/bin/open", ["-R", path])
    }
}
