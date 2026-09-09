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

    /// Per-folder state on both sides, and live progress during a run.
    @Published private(set) var sourceStates: [BackupSourceState] = []
    @Published private(set) var currentFile: String?
    @Published private(set) var copiedFiles = 0
    @Published private(set) var copiedBytes: Int64 = 0
    @Published private(set) var totalPendingBytes: Int64 = 0
    @Published private(set) var startedAt: Date?

    /// Overall fraction copied, by bytes — file counts mislead when one file is
    /// a gigabyte and the next is a kilobyte.
    var progress: Double {
        guard totalPendingBytes > 0 else { return 0 }
        return min(1, Double(copiedBytes) / Double(totalPendingBytes))
    }

    var bytesPerSecond: Double {
        guard let started = startedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(started)
        return elapsed > 0.5 ? Double(copiedBytes) / elapsed : 0
    }

    var estimatedRemaining: TimeInterval? {
        let rate = bytesPerSecond
        guard rate > 0, totalPendingBytes > copiedBytes else { return nil }
        return Double(totalPendingBytes - copiedBytes) / rate
    }

    @Published var sources: [String] = BackupService.defaultSources
    @Published var destinationVolume: String?
    @Published var keepVersions: Bool = true
    @Published var skipBuildFolders: Bool = true

    /// Shared exclusion list; when absent the built-in defaults apply.
    var exclusions: ExclusionRules?

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
    ///
    /// `--out-format` makes rsync report each file's byte length, so the totals
    /// are exact rather than estimated from a file count.
    func preview() {
        guard let volume = selectedVolume else { return }
        if isScanning || isRunning { return }

        isScanning = true
        changes = []
        summary = nil
        copiedFiles = 0
        copiedBytes = 0
        currentFile = nil

        sourceStates = sources.map {
            BackupSourceState(sourcePath: $0, name: ($0 as NSString).lastPathComponent,
                              status: .measuring)
        }

        let sourceList = sources
        let patterns = exclusions?.activePatterns

        work.async {
            var all: [BackupChange] = []
            var totalNew = 0
            var totalUpdated = 0
            var totalBytes: Int64 = 0

            for source in sourceList {
                let destination = BackupService.destinationRoot(volume: volume, source: source)
                let result = Shell.run("/usr/bin/rsync",
                                       BackupService.arguments(source: source,
                                                               destination: destination,
                                                               dryRun: true,
                                                               versionsFolder: nil,
                                                               skipBuildJunk: self.skipBuildFolders,
                                                               patterns: patterns))
                let parsed = BackupService.parseTransfers(result.out,
                                                          prefix: (source as NSString).lastPathComponent)
                all.append(contentsOf: parsed.changes)
                totalNew += parsed.newCount
                totalUpdated += parsed.updatedCount
                totalBytes += parsed.bytes

                DispatchQueue.main.async {
                    if let index = self.sourceStates.firstIndex(where: { $0.sourcePath == source }) {
                        self.sourceStates[index].pendingFiles = parsed.newCount + parsed.updatedCount
                        self.sourceStates[index].pendingBytes = parsed.bytes
                        self.sourceStates[index].status =
                            (parsed.newCount + parsed.updatedCount) == 0 ? .done : .ready
                    }
                }

                // Both sides, so the numbers can be compared at a glance.
                let targetBytes = AppScanner.size(of: destination)
                let targetFiles = BackupService.countFiles(in: destination)
                let sourceBytes = AppScanner.size(of: source)
                let sourceFiles = BackupService.countFiles(in: source)

                DispatchQueue.main.async {
                    if let index = self.sourceStates.firstIndex(where: { $0.sourcePath == source }) {
                        self.sourceStates[index].targetBytes = targetBytes
                        self.sourceStates[index].targetFiles = targetFiles
                        self.sourceStates[index].sourceBytes = sourceBytes
                        self.sourceStates[index].sourceFiles = sourceFiles
                    }
                }
            }

            DispatchQueue.main.async {
                self.changes = all
                self.pendingNew = totalNew
                self.pendingUpdated = totalUpdated
                self.totalPendingBytes = totalBytes
                self.isScanning = false
                let total = totalNew + totalUpdated
                self.summary = total == 0
                    ? "Everything is already backed up — nothing to copy."
                    : "\(totalNew) new and \(totalUpdated) changed files to copy — \(Fmt.bytes(totalBytes))."
            }
        }
    }

    static func countFiles(in path: String) -> Int {
        if !FileManager.default.fileExists(atPath: path) { return 0 }
        let result = Shell.sh("find \(BackupService.quote(path)) -type f 2>/dev/null | wc -l")
        return Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func quote(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Running

    /// Runs the backup, reporting each file as rsync copies it.
    ///
    /// Sources are handled one after another rather than in parallel: they
    /// share one drive, and competing for it would be slower as well as making
    /// progress meaningless.
    func run(completion: @escaping (Bool) -> Void) {
        guard let volume = selectedVolume else { completion(false); return }
        if isRunning { return }

        isRunning = true
        log = []
        summary = nil
        copiedFiles = 0
        copiedBytes = 0
        currentFile = nil
        startedAt = Date()

        for index in sourceStates.indices {
            sourceStates[index].copiedFiles = 0
            sourceStates[index].copiedBytes = 0
        }

        let sourceList = sources
        let versioned = keepVersions
        let skipJunk = skipBuildFolders
        let patterns = exclusions?.activePatterns
        let stamp = BackupService.timestamp()

        work.async {
            var ok = true

            for source in sourceList {
                let name = (source as NSString).lastPathComponent
                let destination = BackupService.destinationRoot(volume: volume, source: source)
                let versionsFolder = versioned
                    ? volume.path + "/" + BackupService.backupFolderName + "/_versions/"
                        + stamp + "/" + name
                    : nil

                DispatchQueue.main.async {
                    self.log.append("Backing up \(name)…")
                    if let index = self.sourceStates.firstIndex(where: { $0.sourcePath == source }) {
                        self.sourceStates[index].status = .running
                    }
                }

                // Each source runs to completion before the next starts, so the
                // semaphore turns the async stream back into a sequence.
                let finished = DispatchSemaphore(value: 0)

                Shell.stream("/usr/bin/rsync",
                             BackupService.arguments(source: source,
                                                     destination: destination,
                                                     dryRun: false,
                                                     versionsFolder: versionsFolder,
                                                     skipBuildJunk: skipJunk,
                                                     patterns: patterns),
                             onLine: { line in
                                 guard let parsed = BackupService.parseTransferLine(line),
                                       parsed.isFile else { return }
                                 DispatchQueue.main.async {
                                     self.currentFile = name + "/" + parsed.path
                                     self.copiedFiles += 1
                                     self.copiedBytes += parsed.bytes
                                     if let index = self.sourceStates.firstIndex(where: { $0.sourcePath == source }) {
                                         self.sourceStates[index].copiedFiles += 1
                                         self.sourceStates[index].copiedBytes += parsed.bytes
                                     }
                                 }
                             },
                             completion: { status, errorText in
                                 DispatchQueue.main.async {
                                     if let index = self.sourceStates.firstIndex(where: { $0.sourcePath == source }) {
                                         self.sourceStates[index].status = status == 0 ? .done : .failed
                                     }
                                     if status == 0 {
                                         self.log.append("  \(name) done")
                                     } else {
                                         ok = false
                                         let message = errorText.nonEmptyLines.first
                                             ?? "rsync exited \(status)"
                                         self.log.append("  ⚠︎ \(name): \(message)")
                                     }
                                 }
                                 finished.signal()
                             })

                finished.wait()
            }

            let tagCount = self.writeTagSidecar(volume: volume, sources: sourceList)

            DispatchQueue.main.async {
                self.isRunning = false
                self.lastRun = Date()
                self.currentFile = nil
                self.log.append("Saved tags for \(tagCount) files to tags.json")
                self.summary = ok
                    ? "Backed up \(self.copiedFiles) files — \(Fmt.bytes(self.copiedBytes))."
                    : "Finished with errors — see the log."
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
                                  skipBuildJunk: Bool = true,
                                  patterns: [String]? = nil) -> [String] {
        var args = ["-rlt", "--out-format=%i|%l|%n"]
        if dryRun { args.append("--dry-run") }
        if skipBuildJunk {
            for pattern in patterns ?? buildJunk { args.append("--exclude=\(pattern)") }
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

    /// One line of `--out-format=%i|%l|%n`: change flags, byte length, path.
    ///
    /// Parsed on the first two pipes only, since a filename may itself contain
    /// one. Only the first `displayLimit` entries are kept — a real folder can
    /// produce hundreds of thousands of lines and holding a struct per line
    /// would exhaust memory for a list nobody can read — while counts and byte
    /// totals are accumulated over every line.
    static func parseTransfers(_ output: String,
                               prefix: String,
                               displayLimit: Int = 1500) -> (changes: [BackupChange],
                                                             newCount: Int,
                                                             updatedCount: Int,
                                                             bytes: Int64) {
        var changes: [BackupChange] = []
        var newCount = 0
        var updatedCount = 0
        var bytes: Int64 = 0

        output.enumerateLines { line, _ in
            guard let first = line.firstIndex(of: "|") else { return }
            let flags = String(line[line.startIndex ..< first])
            let rest = line[line.index(after: first)...]
            guard let second = rest.firstIndex(of: "|") else { return }

            let length = Int64(rest[rest.startIndex ..< second]) ?? 0
            let path = String(rest[rest.index(after: second)...])

            if flags.count < 2 || path.isEmpty || path == "./" { return }
            if Array(flags)[1] == "d" {
                if changes.count < displayLimit {
                    changes.append(BackupChange(relativePath: prefix + "/" + path, action: .directory))
                }
                return
            }

            let action: BackupChange.Action
            if flags.contains("+") { action = .new; newCount += 1 }
            else { action = .updated; updatedCount += 1 }
            bytes += length

            if changes.count < displayLimit {
                changes.append(BackupChange(relativePath: prefix + "/" + path, action: action))
            }
        }

        return (changes, newCount, updatedCount, bytes)
    }

    /// Same line format, for a single line arriving during a live run.
    static func parseTransferLine(_ line: String) -> (isFile: Bool, bytes: Int64, path: String)? {
        guard let first = line.firstIndex(of: "|") else { return nil }
        let flags = String(line[line.startIndex ..< first])
        let rest = line[line.index(after: first)...]
        guard let second = rest.firstIndex(of: "|") else { return nil }

        let length = Int64(rest[rest.startIndex ..< second]) ?? 0
        let path = String(rest[rest.index(after: second)...])
        if flags.count < 2 || path.isEmpty || path == "./" { return nil }

        return (Array(flags)[1] != "d", length, path)
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
