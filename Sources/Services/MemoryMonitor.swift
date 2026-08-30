import Foundation

/// Live memory statistics plus the process list, grouped so that a browser's
/// forty helper processes read as one row instead of forty.
final class MemoryMonitor: ObservableObject {

    @Published private(set) var snapshot = MemorySnapshot()
    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var processCount: Int = 0

    private let work = DispatchQueue(label: "com.macmanager.memory", qos: .userInitiated)
    private var timer: Timer?
    private var refreshing = false

    // MARK: - Lifecycle

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        if refreshing { return }
        refreshing = true

        work.async {
            let snap = MemoryMonitor.readSnapshot()
            let procs = MemoryMonitor.readProcesses()
            let grouped = MemoryMonitor.group(procs)

            DispatchQueue.main.async {
                self.snapshot = snap
                self.groups = grouped
                self.processCount = procs.count
                self.refreshing = false
            }
        }
    }

    // MARK: - vm_stat

    static func readSnapshot() -> MemorySnapshot {
        var snap = MemorySnapshot()
        snap.totalBytes = Shell.sysctlInt("hw.memsize")

        let output = Shell.run("/usr/bin/vm_stat", []).out
        var pageSize: Int64 = 4096
        var counts: [String: Int64] = [:]

        for line in output.nonEmptyLines {
            if line.hasPrefix("Mach Virtual Memory Statistics") {
                // "... (page size of 16384 bytes)"
                if let range = line.range(of: "page size of ") {
                    let rest = line[range.upperBound...]
                    let digits = rest.prefix { $0.isNumber }
                    pageSize = Int64(digits) ?? 4096
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex ..< colon])
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ".", with: "")
            counts[key] = Int64(value) ?? 0
        }

        func pages(_ key: String) -> Int64 { return (counts[key] ?? 0) * pageSize }

        // Mirrors how Activity Monitor breaks memory down.
        let anonymous = pages("Anonymous pages")
        let purgeable = pages("Pages purgeable")
        snap.appBytes = max(0, anonymous - purgeable)
        snap.wiredBytes = pages("Pages wired down")
        snap.compressedBytes = pages("Pages occupied by compressor")
        snap.cachedBytes = pages("File-backed pages") + purgeable
        snap.freeBytes = pages("Pages free") + pages("Pages speculative")

        // Swap
        let swap = Shell.sysctl("vm.swapusage")
        snap.swapTotalBytes = parseSwapField(swap, "total")
        snap.swapUsedBytes = parseSwapField(swap, "used")

        let level = Int(Shell.sysctl("kern.memorystatus_vm_pressure_level")) ?? 1
        snap.pressureLevel = MemorySnapshot.Pressure(rawValue: level) ?? .normal

        return snap
    }

    /// Parses "total = 12288.00M  used = 10723.69M  free = 1564.31M".
    private static func parseSwapField(_ text: String, _ field: String) -> Int64 {
        guard let range = text.range(of: "\(field) = ") else { return 0 }
        let rest = text[range.upperBound...]
        let token = rest.prefix { !$0.isWhitespace }
        let unit = token.last
        let number = Double(token.dropLast()) ?? 0
        switch unit {
        case "K": return Int64(number * 1024)
        case "M": return Int64(number * 1024 * 1024)
        case "G": return Int64(number * 1024 * 1024 * 1024)
        default: return Int64(Double(token) ?? 0)
        }
    }

    // MARK: - Processes

    static func readProcesses() -> [RunningProcess] {
        // COMM is last because it contains spaces; everything before it is
        // fixed-width enough to split on whitespace.
        let output = Shell.run("/bin/ps", ["-Ao", "pid,rss,pcpu,comm", "-m"]).out
        var results: [RunningProcess] = []

        for (index, line) in output.components(separatedBy: .newlines).enumerated() {
            if index == 0 { continue }  // header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let fields = trimmed.whitespaceFields
            if fields.count < 4 { continue }
            guard let pid = Int32(fields[0]),
                  let rssKB = Int64(fields[1]),
                  let cpu = Double(fields[2]) else { continue }

            // Rejoin everything after the first three columns.
            let path = fields[3...].joined(separator: " ")
            if pid == 0 { continue }

            results.append(RunningProcess(pid: pid,
                                          name: (path as NSString).lastPathComponent,
                                          path: path,
                                          memoryBytes: rssKB * 1024,
                                          cpuPercent: cpu))
        }
        return results
    }

    /// Collapses helper processes into the app bundle that owns them.
    static func group(_ processes: [RunningProcess]) -> [ProcessGroup] {
        var buckets: [String: ProcessGroup] = [:]

        for proc in processes {
            let (name, iconPath) = owningApp(for: proc.path)
            if var existing = buckets[name] {
                existing.members.append(proc)
                buckets[name] = existing
            } else {
                buckets[name] = ProcessGroup(name: name, iconPath: iconPath, members: [proc])
            }
        }

        return buckets.values.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    /// Walks a process path back to the outermost `.app` bundle, so
    /// "Chrome Helper (Renderer)" is attributed to "Google Chrome".
    private static func owningApp(for path: String) -> (String, String?) {
        let components = path.components(separatedBy: "/")
        for (index, component) in components.enumerated() where component.hasSuffix(".app") {
            let bundlePath = components[0 ... index].joined(separator: "/")
            let name = component.replacingOccurrences(of: ".app", with: "")
            return (name, bundlePath)
        }
        return ((path as NSString).lastPathComponent, nil)
    }

    // MARK: - Actions

    /// Asks the processes to quit (SIGTERM). Work in progress gets a chance to
    /// be saved, unlike a force quit.
    static func quit(pids: [Int32]) {
        for pid in pids { kill(pid, SIGTERM) }
    }

    /// Last resort — the process dies immediately and loses unsaved work.
    static func forceQuit(pids: [Int32]) {
        for pid in pids { kill(pid, SIGKILL) }
    }
}
