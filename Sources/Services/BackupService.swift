import Foundation

/// Mirrors folders to an external drive, keeping previous versions of anything
/// it replaces.
///
/// Built on rsync, which is already on every Mac. Three deliberate choices:
///
/// - **Never delete.** `--delete` is not used, so removing a file locally never
///   removes it from the backup. The drive accumulates; it does not mirror
///   destruction.
/// - **Always previewable.** Every run can be a dry run first, listing exactly
///   what would be copied and what would be replaced.
/// - **Versioned.** `--backup-dir` moves each replaced file into a timestamped
///   folder, so previous versions stay recoverable instead of being overwritten.
final class BackupService: ObservableObject {

    @Published private(set) var volumes: [BackupVolume] = []
    @Published private(set) var changes: [BackupChange] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRunning = false
    @Published private(set) var log: [String] = []
    @Published private(set) var lastRun: Date?
    @Published private(set) var summary: String?
    /// Totals across every source — `changes` is truncated for display.
    @Published private(set) var pendingNew = 0
    @Published private(set) var pendingUpdated = 0

    @Published var sources: [String] = BackupService.defaultSources
    @Published var destinationVolume: String?
    @Published var keepVersions: Bool = true
    @Published var skipBuildFolders: Bool = true

    /// Regenerable build output. One `node_modules` can hold a hundred
    /// thousand files, which would dominate a backup while being worthless in
    /// it — the folder is rebuilt from a lockfile in seconds.
    static let buildJunk = ["node_modules", "__pycache__", ".venv", "venv",
                            "DerivedData", ".next", ".nuxt", "dist", ".cache",
                            ".gradle", ".DS_Store", "*.pyc", ".pytest_cache",
                            ".terraform", "Pods"]

    private let work = DispatchQueue(label: "com.macmanager.backup", qos: .userInitiated)

    static var defaultSources: [String] {
        let home = NSHomeDirectory()
        return ["Documents", "Desktop", "Pictures"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Everything lands under one folder so the drive stays usable for other
    /// things.
    static let backupFolderName = "MacManager Backup"

    // MARK: - Volumes

    func refreshVolumes() {
        work.async {
            let found = BackupService.mountedVolumes()
            DispatchQueue.main.async {
                self.volumes = found
                if self.destinationVolume == nil {
                    // Prefer a removable drive — that is what "external" means.
                    self.destinationVolume = found.first(where: { $0.isRemovable })?.path
                        ?? found.first?.path
                }
            }
        }
    }

    static func mountedVolumes() -> [BackupVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeIsRemovableKey,
                                      .volumeIsInternalKey, .volumeIsReadOnlyKey]

        guard let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]) else { return [] }

        var found: [BackupVolume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsReadOnly == true { continue }

            let isInternal = values.volumeIsInternal ?? true
            let removable = (values.volumeIsRemovable ?? false) || !isInternal

            found.append(BackupVolume(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
                isRemovable: removable,
                fileSystem: BackupService.fileSystem(of: url.path)))
        }

        // External drives first — they are the point of this screen.
        return found.sorted { lhs, rhs in
            if lhs.isRemovable != rhs.isRemovable { return lhs.isRemovable }
            return lhs.name < rhs.name
        }
    }

    private static func fileSystem(of path: String) -> String {
        let output = Shell.run("/usr/sbin/diskutil", ["info", path]).out
        for line in output.nonEmptyLines where line.contains("File System Personality") {
            if let colon = line.firstIndex(of: ":") {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return "Unknown"
    }

    var selectedVolume: BackupVolume? {
        guard let path = destinationVolume else { return nil }
        return volumes.first { $0.path == path }
    }

    // MARK: - Preview

    /// Dry run: what a real backup would copy, without copying anything.
    func preview() {
        guard let volume = selectedVolume else { return }
        if isScanning || isRunning { return }

        isScanning = true
        changes = []
        summary = nil

        let sourceList = sources
        work.async {
            var all: [BackupChange] = []
            var totalNew = 0
            var totalUpdated = 0

            for source in sourceList {
                let destination = BackupService.destinationRoot(volume: volume, source: source)
                let result = Shell.run("/usr/bin/rsync",
                                       BackupService.arguments(source: source,
                                                               destination: destination,
                                                               dryRun: true,
                                                               versionsFolder: nil,
                                                               skipBuildJunk: self.skipBuildFolders))
                let parsed = BackupService.parseItemized(result.out,
                                                         prefix: (source as NSString).lastPathComponent)
                all.append(contentsOf: parsed.changes)
                totalNew += parsed.newCount
                totalUpdated += parsed.updatedCount
            }

            DispatchQueue.main.async {
                self.changes = all
                self.pendingNew = totalNew
                self.pendingUpdated = totalUpdated
                self.isScanning = false
                let total = totalNew + totalUpdated
                self.summary = total == 0
                    ? "Everything is already backed up — nothing to copy."
                    : "\(totalNew) new files, \(totalUpdated) changed files to copy."
            }
        }
    }

    // MARK: - Running

    func run(completion: @escaping (Bool) -> Void) {
        guard let volume = selectedVolume else { completion(false); return }
        if isRunning { return }

        isRunning = true
        log = []
        summary = nil

        let sourceList = sources
        let versioned = keepVersions
        let skipJunk = skipBuildFolders
        let stamp = BackupService.timestamp()

        work.async {
            var ok = true

            for source in sourceList {
                let destination = BackupService.destinationRoot(volume: volume, source: source)
                let versionsFolder = versioned
                    ? volume.path + "/" + BackupService.backupFolderName + "/_versions/" + stamp
                        + "/" + (source as NSString).lastPathComponent
                    : nil

                DispatchQueue.main.async {
                    self.log.append("Backing up \((source as NSString).lastPathComponent)…")
                }

                let result = Shell.run("/usr/bin/rsync",
                                       BackupService.arguments(source: source,
                                                               destination: destination,
                                                               dryRun: false,
                                                               versionsFolder: versionsFolder,
                                                               skipBuildJunk: skipJunk))
                if !result.ok {
                    ok = false
                    let message = result.err.nonEmptyLines.first ?? "rsync exited \(result.status)"
                    DispatchQueue.main.async { self.log.append("  ⚠︎ \(message)") }
                } else {
                    DispatchQueue.main.async { self.log.append("  done") }
                }
            }

            // The tag sidecar matters because NTFS and exFAT drop extended
            // attributes; without this the backup would silently lose tags.
            let tagCount = self.writeTagSidecar(volume: volume, sources: sourceList)

            DispatchQueue.main.async {
                self.isRunning = false
                self.lastRun = Date()
                self.log.append("Saved tags for \(tagCount) files to tags.json")
                self.summary = ok ? "Backup finished." : "Backup finished with errors — see the log."
                completion(ok)
            }
        }
    }

    private static func destinationRoot(volume: BackupVolume, source: String) -> String {
        return volume.path + "/" + backupFolderName + "/" + (source as NSString).lastPathComponent
    }

    /// `-rlt` rather than `-a`: an NTFS or exFAT drive cannot store POSIX
    /// ownership or permissions, and asking rsync to copy them there produces a
    /// stream of errors for no benefit.
    private static func arguments(source: String,
                                  destination: String,
                                  dryRun: Bool,
                                  versionsFolder: String?,
                                  skipBuildJunk: Bool = true) -> [String] {
        var args = ["-rlt", "--itemize-changes"]
        if dryRun { args.append("--dry-run") }
        if skipBuildJunk {
            for pattern in buildJunk { args.append("--exclude=\(pattern)") }
        }
        if let versionsFolder = versionsFolder {
            args.append("--backup")
            args.append("--backup-dir=\(versionsFolder)")
        }
        // Trailing slash on the source copies its contents, not the folder.
        args.append(source.hasSuffix("/") ? source : source + "/")
        args.append(destination)
        return args
    }

    /// rsync's itemized output, e.g. ">f....... notes.txt" or "cd+++++++ dir/".
    ///
    /// The flag block is not a fixed width — openrsync (shipped with macOS)
    /// writes 9 characters where GNU rsync writes 11 — so the path is taken as
    /// everything after the first space rather than from a fixed offset.
    /// Slicing at a hard-coded index silently chopped the first characters off
    /// every filename.
    ///
    /// Only the first `displayLimit` entries are kept. A real folder can
    /// produce hundreds of thousands of lines, and holding a struct for each
    /// would exhaust memory for a list nobody can read anyway; the counts are
    /// still totalled over everything.
    static func parseItemized(_ output: String,
                              prefix: String,
                              displayLimit: Int = 1500) -> (changes: [BackupChange],
                                                            newCount: Int,
                                                            updatedCount: Int) {
        var changes: [BackupChange] = []
        var newCount = 0
        var updatedCount = 0

        output.enumerateLines { line, _ in
            guard let space = line.firstIndex(of: " ") else { return }
            let flags = String(line[line.startIndex ..< space])
            let path = String(line[line.index(after: space)...])

            if flags.count < 2 || path.isEmpty || path == "./" { return }

            let isDirectory = Array(flags)[1] == "d"
            let action: BackupChange.Action
            if isDirectory {
                action = .directory
            } else if flags.contains("+") {
                action = .new
                newCount += 1
            } else {
                action = .updated
                updatedCount += 1
            }

            if changes.count < displayLimit {
                changes.append(BackupChange(relativePath: prefix + "/" + path, action: action))
            }
        }

        return (changes, newCount, updatedCount)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    // MARK: - Tag sidecar

    /// Writes every tagged file's tags next to the backup, as a plain JSON map
    /// of relative path to tags, so tagging survives a filesystem that cannot
    /// carry extended attributes.
    private func writeTagSidecar(volume: BackupVolume, sources: [String]) -> Int {
        var map: [String: [String]] = [:]
        let fm = FileManager.default

        for source in sources {
            let name = (source as NSString).lastPathComponent
            guard let walker = fm.enumerator(atPath: source) else { continue }
            for case let relative as String in walker {
                let full = source + "/" + relative
                let tags = TagStore.tags(of: full)
                if !tags.isEmpty { map[name + "/" + relative] = tags }
            }
        }

        let folder = volume.path + "/" + BackupService.backupFolderName
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(map) {
            try? data.write(to: URL(fileURLWithPath: folder + "/tags.json"), options: .atomic)
        }
        return map.count
    }

    /// Version folders already on the drive, newest first.
    func existingVersions() -> [(name: String, path: String)] {
        guard let volume = selectedVolume else { return [] }
        let root = volume.path + "/" + BackupService.backupFolderName + "/_versions"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries.sorted(by: >).map { (name: $0, path: root + "/" + $0) }
    }
}
