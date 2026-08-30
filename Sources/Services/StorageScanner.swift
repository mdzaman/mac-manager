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
    @Published private(set) var homeBreakdown: [CleanupTarget] = []
    @Published private(set) var isScanningHome = false

    private let work = DispatchQueue(label: "com.macmanager.storage", qos: .userInitiated)

    // MARK: - Target catalogue

    private static func catalogue() -> [CleanupTarget] {
        let home = NSHomeDirectory()

        func t(_ name: String, _ detail: String, _ path: String, _ safety: CleanupTarget.Safety) -> CleanupTarget {
            return CleanupTarget(name: name, detail: detail, path: path, safety: safety)
        }

        return [
            t("Application caches",
              "Rebuilt automatically the next time each app runs.",
              "\(home)/Library/Caches", .safe),

            t("Application logs",
              "Diagnostic logs written by installed apps.",
              "\(home)/Library/Logs", .safe),

            t("Crash reports",
              "Reports from apps that quit unexpectedly.",
              "\(home)/Library/Application Support/CrashReporter", .safe),

            t("Xcode derived data",
              "Build intermediates. Xcode regenerates them on the next build.",
              "\(home)/Library/Developer/Xcode/DerivedData", .safe),

            t("iOS device support",
              "Debug symbols per iOS version. Re-downloaded when needed.",
              "\(home)/Library/Developer/Xcode/iOS DeviceSupport", .safe),

            t("Simulator caches",
              "Cached simulator runtime data.",
              "\(home)/Library/Developer/CoreSimulator/Caches", .safe),

            t("npm cache",
              "Downloaded packages. npm refetches anything it needs.",
              "\(home)/.npm/_cacache", .safe),

            t("Yarn cache",
              "Downloaded packages, refetched on demand.",
              "\(home)/Library/Caches/Yarn", .safe),

            t("Homebrew cache",
              "Downloaded bottles and formula archives.",
              "\(home)/Library/Caches/Homebrew", .safe),

            t("pip cache",
              "Downloaded Python wheels.",
              "\(home)/Library/Caches/pip", .safe),

            t("Gradle caches",
              "Downloaded dependencies and build outputs.",
              "\(home)/.gradle/caches", .safe),

            t("Cargo registry cache",
              "Downloaded crate archives.",
              "\(home)/.cargo/registry/cache", .safe),

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

        let catalogue = StorageScanner.catalogue()
        let existing = catalogue.filter { FileManager.default.fileExists(atPath: $0.path) }
        targets = existing
        volume = StorageScanner.readVolume()

        work.async {
            // One target at a time so the list fills in progressively; a cold
            // cache directory can take a second or two on its own.
            for target in existing {
                let bytes = AppScanner.size(of: target.path)
                DispatchQueue.main.async {
                    if let index = self.targets.firstIndex(where: { $0.path == target.path }) {
                        self.targets[index].sizeBytes = bytes
                        self.targets[index].scanned = true
                    }
                }
            }

            let trash = AppScanner.size(of: StorageScanner.trashPath)
            DispatchQueue.main.async {
                self.trashBytes = trash
                self.isScanning = false
            }
        }
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

    // MARK: - Home folder breakdown

    /// On demand only — a full walk of the home folder is slow and there is no
    /// reason to pay for it unless the user asks.
    func scanHomeFolder() {
        if isScanningHome { return }
        isScanningHome = true
        homeBreakdown = []

        work.async {
            let home = NSHomeDirectory()
            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(atPath: home)) ?? []
            let paths = entries
                .filter { !$0.hasPrefix(".") }
                .map { home + "/" + $0 }

            var results: [CleanupTarget] = []
            for path in paths {
                let bytes = AppScanner.size(of: path)
                var target = CleanupTarget(name: (path as NSString).lastPathComponent,
                                           detail: "",
                                           path: path,
                                           safety: .review)
                target.sizeBytes = bytes
                target.scanned = true
                results.append(target)

                let sorted = results.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
                DispatchQueue.main.async { self.homeBreakdown = sorted }
            }

            DispatchQueue.main.async { self.isScanningHome = false }
        }
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
