import AppKit
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

    /// The persisted job. Kept on disk so an interrupted run can be picked up
    /// where it stopped rather than started over.
    @Published private(set) var job: BackupJob?
    @Published private(set) var resumable: BackupJob?
    @Published private(set) var interruptionReason: String?

    /// Held so the transfer can be stopped the moment the drive disappears,
    /// instead of rsync writing into a stale mount point.
    private var activeProcess: Process?
    private var lastJournalWrite = Date.distantPast
    private var observersInstalled = false

    static let jobFileName = "backup-job.json"

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

    // MARK: - Interruption handling

    /// Call once at startup. Recovers an interrupted job and starts listening
    /// for the events that can break a backup: the drive going away, and the
    /// machine sleeping.
    func begin() {
        recoverInterruptedJob()
        installObservers()
    }

    private func recoverInterruptedJob() {
        let result = StateStore.load(BackupJob.self, from: BackupService.jobFileName)
        if let problem = result.problem { interruptionReason = problem }

        guard var saved = result.value else { return }

        if saved.status == .running {
            // Still marked running with nobody running it — the app was quit,
            // crashed, or the Mac was shut down mid-copy.
            saved.status = .interrupted
            saved.lastMessage = "The app stopped before this backup finished."
            StateStore.save(saved, as: BackupService.jobFileName)
        }

        if saved.isResumable {
            resumable = saved
            job = saved
        }
    }

    private func installObservers() {
        if observersInstalled { return }
        observersInstalled = true

        let center = NSWorkspace.shared.notificationCenter

        // Unmounting is the common case: someone unplugs the drive mid-copy.
        center.addObserver(forName: NSWorkspace.willUnmountNotification,
                           object: nil, queue: .main) { [weak self] note in
            self?.handleUnmount(note, imminent: true)
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification,
                           object: nil, queue: .main) { [weak self] note in
            self?.handleUnmount(note, imminent: false)
        }

        // A reconnected drive is the cue to offer resuming.
        center.addObserver(forName: NSWorkspace.didMountNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.refreshVolumes()
            self?.offerResumeIfDriveIsBack()
        }

        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
    }

    private func volumePath(from note: Notification) -> String? {
        if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { return url.path }
        return nil
    }

    private func handleUnmount(_ note: Notification, imminent: Bool) {
        guard let path = volumePath(from: note) else { return }
        guard var current = job, current.volumePath == path, isRunning else { return }

        // Stop immediately rather than letting rsync write into a mount point
        // that is no longer there.
        activeProcess?.terminate()
        activeProcess = nil

        current.status = .interrupted
        current.lastMessage = "The drive was disconnected during the backup."
        persist(current)

        job = current
        resumable = current
        isRunning = false
        currentFile = nil
        interruptionReason = "\(current.volumeName) was disconnected. Reconnect it and the backup can carry on from where it stopped."
        summary = "Backup interrupted — \(current.describeProgress)."
    }

    private func handleSleep() {
        guard var current = job, isRunning else { return }
        current.lastHeartbeat = Date()
        current.lastMessage = "The Mac went to sleep during this backup."
        persist(current)
        // rsync usually survives sleep; the drive vanishing is what breaks it,
        // and that arrives separately as an unmount.
    }

    private func handleWake() {
        guard let current = job, current.status == .running || current.status == .interrupted else { return }
        refreshVolumes()

        // If the drive did not come back with the machine, the run is over
        // until it is reconnected.
        if !FileManager.default.fileExists(atPath: current.volumePath) {
            var updated = current
            updated.status = .interrupted
            updated.lastMessage = "The drive was not connected after waking."
            persist(updated)
            job = updated
            resumable = updated
            isRunning = false
            interruptionReason = "\(updated.volumeName) is not connected. Reconnect it to carry on."
        }
    }

    private func offerResumeIfDriveIsBack() {
        guard let current = job ?? resumable, current.isResumable else { return }
        if FileManager.default.fileExists(atPath: current.volumePath) {
            resumable = current
            destinationVolume = current.volumePath
            interruptionReason = "\(current.volumeName) is back. \(current.describeProgress)."
        }
    }

    /// Writes the journal, throttled — a backup copying thousands of small
    /// files would otherwise spend its time writing state instead of data.
    private func persist(_ current: BackupJob, force: Bool = false) {
        if !force && Date().timeIntervalSince(lastJournalWrite) < 2.0 { return }
        lastJournalWrite = Date()
        StateStore.save(current, as: BackupService.jobFileName)
    }

    func dismissResume() {
        resumable = nil
        interruptionReason = nil
        StateStore.reset(BackupService.jobFileName)
    }

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

    /// Starts a fresh backup.
    func run(completion: @escaping (Bool) -> Void) {
        guard let volume = selectedVolume else { completion(false); return }
        if isRunning { return }

        let fresh = BackupJob(
            id: UUID().uuidString,
            startedAt: Date(),
            lastHeartbeat: Date(),
            volumePath: volume.path,
            volumeName: volume.name,
            versionStamp: BackupService.timestamp(),
            keepVersions: keepVersions,
            skipBuildFolders: skipBuildFolders,
            patterns: exclusions?.activePatterns ?? BackupService.buildJunk,
            sources: sources.map { path in
                let state = sourceStates.first { $0.sourcePath == path }
                return BackupJob.SourceProgress(
                    path: path, state: .pending, copiedFiles: 0, copiedBytes: 0,
                    pendingFiles: state?.pendingFiles ?? 0,
                    pendingBytes: state?.pendingBytes ?? 0)
            },
            status: .running,
            lastMessage: nil)

        execute(job: fresh, resuming: false, completion: completion)
    }

    /// Picks an interrupted job back up.
    ///
    /// Folders already finished are skipped entirely, and within a folder rsync
    /// skips files whose size and timestamp already match — so resuming costs a
    /// scan rather than a re-copy. `--partial` keeps a half-written file so the
    /// next run continues it instead of starting that file again.
    func resume(completion: @escaping (Bool) -> Void) {
        guard var current = resumable ?? job, current.isResumable else { completion(false); return }
        guard FileManager.default.fileExists(atPath: current.volumePath) else {
            interruptionReason = "\(current.volumeName) is not connected."
            completion(false)
            return
        }

        current.status = .running
        current.lastHeartbeat = Date()
        current.lastMessage = nil
        resumable = nil
        interruptionReason = nil

        execute(job: current, resuming: true, completion: completion)
    }

    /// Copies each remaining folder in turn, journalling as it goes.
    ///
    /// Sources run one after another rather than together: they share a single
    /// drive, so competing for it would be slower and would make progress
    /// impossible to report honestly.
    private func execute(job start: BackupJob, resuming: Bool, completion: @escaping (Bool) -> Void) {
        isRunning = true
        summary = nil
        currentFile = nil
        startedAt = Date()
        interruptionReason = nil

        var current = start
        job = current
        persist(current, force: true)

        // Resuming keeps what was already copied in the totals.
        copiedFiles = current.copiedFiles
        copiedBytes = current.copiedBytes
        totalPendingBytes = current.pendingBytes

        log = [resuming
                ? "Resuming — \(current.describeProgress)"
                : "Starting backup to \(current.volumeName)…"]

        // Rebuild the display rows so a resumed job shows its history.
        sourceStates = current.sources.map { source in
            var state = BackupSourceState(sourcePath: source.path, name: source.name)
            state.pendingFiles = source.pendingFiles
            state.pendingBytes = source.pendingBytes
            state.copiedFiles = source.copiedFiles
            state.copiedBytes = source.copiedBytes
            state.status = source.state == .done ? .done : .ready
            return state
        }

        work.async {
            var ok = true

            for (index, source) in current.sources.enumerated() {
                if source.state == .done { continue }

                // The drive can vanish between folders as easily as during one.
                if !FileManager.default.fileExists(atPath: current.volumePath) {
                    DispatchQueue.main.async {
                        current.status = .interrupted
                        current.lastMessage = "The drive disconnected."
                        self.finishInterrupted(current)
                        completion(false)
                    }
                    return
                }

                let name = source.name
                let destination = current.volumePath + "/" + BackupService.backupFolderName + "/" + name
                let versionsFolder = current.keepVersions
                    ? current.volumePath + "/" + BackupService.backupFolderName
                        + "/_versions/" + current.versionStamp + "/" + name
                    : nil

                current.sources[index].state = .running
                let snapshot = current
                DispatchQueue.main.async {
                    self.job = snapshot
                    self.log.append("Backing up \(name)…")
                    if let row = self.sourceStates.firstIndex(where: { $0.sourcePath == source.path }) {
                        self.sourceStates[row].status = .running
                    }
                }
                self.persist(current, force: true)

                let finished = DispatchSemaphore(value: 0)
                var sourceFiles = current.sources[index].copiedFiles
                var sourceBytes = current.sources[index].copiedBytes

                let process = Shell.stream(
                    "/usr/bin/rsync",
                    BackupService.arguments(source: source.path,
                                            destination: destination,
                                            dryRun: false,
                                            versionsFolder: versionsFolder,
                                            skipBuildJunk: current.skipBuildFolders,
                                            patterns: current.patterns),
                    onLine: { line in
                        guard let parsed = BackupService.parseTransferLine(line),
                              parsed.isFile else { return }
                        sourceFiles += 1
                        sourceBytes += parsed.bytes

                        DispatchQueue.main.async {
                            self.currentFile = name + "/" + parsed.path
                            self.copiedFiles += 1
                            self.copiedBytes += parsed.bytes
                            if let row = self.sourceStates.firstIndex(where: { $0.sourcePath == source.path }) {
                                self.sourceStates[row].copiedFiles = sourceFiles
                                self.sourceStates[row].copiedBytes = sourceBytes
                            }
                            current.sources[index].copiedFiles = sourceFiles
                            current.sources[index].copiedBytes = sourceBytes
                            current.lastHeartbeat = Date()
                            self.job = current
                            self.persist(current)
                        }
                    },
                    completion: { status, errorText in
                        DispatchQueue.main.async {
                            current.sources[index].state = status == 0 ? .done : .failed
                            current.sources[index].copiedFiles = sourceFiles
                            current.sources[index].copiedBytes = sourceBytes
                            current.lastHeartbeat = Date()

                            if let row = self.sourceStates.firstIndex(where: { $0.sourcePath == source.path }) {
                                self.sourceStates[row].status = status == 0 ? .done : .failed
                            }
                            if status == 0 {
                                self.log.append("  \(name) done — \(sourceFiles) files")
                            } else {
                                ok = false
                                let message = errorText.nonEmptyLines.first ?? "rsync exited \(status)"
                                self.log.append("  ⚠︎ \(name): \(message)")
                            }
                            self.job = current
                            self.persist(current, force: true)
                        }
                        finished.signal()
                    })

                DispatchQueue.main.async { self.activeProcess = process }
                finished.wait()
                DispatchQueue.main.async { self.activeProcess = nil }

                // A terminated transfer means something took the drive away.
                if !self.isRunningFlag() { return }
            }

            let tagCount = self.writeTagSidecar(volume: BackupVolume(
                name: current.volumeName, path: current.volumePath,
                totalBytes: 0, freeBytes: 0, isRemovable: true, fileSystem: ""),
                sources: current.sources.map { $0.path })

            DispatchQueue.main.async {
                current.status = ok ? .completed : .failed
                current.lastHeartbeat = Date()
                self.job = current
                self.persist(current, force: true)

                self.isRunning = false
                self.activeProcess = nil
                self.lastRun = Date()
                self.currentFile = nil
                self.resumable = nil
                self.log.append("Saved tags for \(tagCount) files to tags.json")
                self.summary = ok
                    ? "Backed up \(self.copiedFiles) files — \(Fmt.bytes(self.copiedBytes))."
                    : "Finished with errors — see the log."
                completion(ok)
            }
        }
    }

    /// Reading `isRunning` from the work queue; it is cleared on the main queue
    /// when the drive disappears.
    private func isRunningFlag() -> Bool {
        var value = false
        DispatchQueue.main.sync { value = self.isRunning }
        return value
    }

    private func finishInterrupted(_ interrupted: BackupJob) {
        var updated = interrupted
        updated.status = .interrupted
        persist(updated, force: true)
        job = updated
        resumable = updated
        isRunning = false
        activeProcess = nil
        currentFile = nil
        summary = "Backup interrupted — \(updated.describeProgress)."
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
        // --partial keeps a half-transferred file so an interrupted run continues
        // it rather than starting that file over.
        var args = ["-rlt", "--partial", "--out-format=%i|%l|%n"]
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
