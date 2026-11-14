import Foundation

/// One thing that starts with the Mac.
struct StartupEntry: Identifiable {
    var id: String { return path ?? ("btm:" + label) }

    enum Kind: String {
        case userAgent = "Your account"
        case systemAgent = "All users"
        case daemon = "System service"
        case loginItem = "Login item"
    }

    let label: String
    let displayName: String
    let kind: Kind
    /// The launchd property list, for agents and daemons.
    let path: String?
    let program: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    var disabled: Bool
    var pid: Int32?
    var memoryBytes: Int64 = 0
    /// The program it would launch no longer exists.
    let broken: Bool
    /// The installed app this belongs to, when that can be told.
    let appPath: String?
    let developer: String?

    var isRunning: Bool { return pid != nil }
    var needsAdmin: Bool { return kind == .daemon }
    var isManagedBySystem: Bool { return kind == .loginItem }

    /// launchd keeps these alive: quit them and they come straight back.
    var schedule: String {
        if kind == .loginItem { return "Opens at login" }
        if keepAlive { return "Always running" }
        if runAtLoad { return "Starts at login" }
        return "Starts on demand"
    }

    var vendor: String {
        let parts = label.components(separatedBy: ".")
        return parts.count >= 2 ? parts[1].capitalized : label
    }

    /// The launchd domain the job lives in.
    func domain(uid: uid_t) -> String {
        return kind == .daemon ? "system" : "gui/\(uid)"
    }
}

/// Lists everything that starts with the Mac and turns items off, back on, or
/// removes them.
///
/// Three separate actions, because they are three different commitments:
/// **Disable** stops the job and tells launchd not to load it again — the file
/// stays put and Enable reverses it exactly. **Remove** moves the file to
/// quarantine. **Uninstall** hands over to the app uninstaller, which takes the
/// app and all its support files, startup items included.
final class StartupManager: ObservableObject {

    @Published private(set) var entries: [StartupEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private let work = DispatchQueue(label: "com.macmanager.startup", qos: .userInitiated)

    // MARK: - Loading

    func refresh(apps: [InstalledApp]) {
        if isLoading { return }
        isLoading = true

        work.async {
            // Launch items are quick to read. Login items come from a system
            // tool that takes about five seconds, so the list appears first
            // and they are added when it answers.
            let launch = StartupManager.gather(apps: apps, includeLoginItems: false)
            DispatchQueue.main.async { self.entries = launch }

            let all = StartupManager.gather(apps: apps, includeLoginItems: true)
            DispatchQueue.main.async {
                self.entries = all
                self.isLoading = false
            }
        }
    }

    static func gather(apps: [InstalledApp], includeLoginItems: Bool = true) -> [StartupEntry] {
        let uid = getuid()
        let disabledUser = disabledLabels(domain: "gui/\(uid)")
        let disabledSystem = disabledLabels(domain: "system")
        let userJobs = loadedUserJobs()
        let systemJobs = loadedSystemJobs()
        let memory = residentMemory()

        var entries: [StartupEntry] = []
        var coveredPaths = Set<String>()

        for item in HealthScanner.launchItems() {
            let kind: StartupEntry.Kind = item.path.contains("/LaunchDaemons/") ? .daemon
                : (item.isSystem ? .systemAgent : .userAgent)

            var pid: Int32?
            if kind == .daemon {
                pid = systemJobs[item.label]
            } else if let listed = userJobs[item.label] {
                pid = listed
            }

            let disabled = (kind == .daemon ? disabledSystem : disabledUser).contains(item.label)
            coveredPaths.insert(item.path)

            entries.append(StartupEntry(
                label: item.label,
                displayName: readableName(label: item.label, program: item.program),
                kind: kind,
                path: item.path,
                program: item.program,
                runAtLoad: item.runAtLoad,
                keepAlive: item.keepAlive,
                disabled: disabled,
                pid: pid,
                memoryBytes: pid.flatMap { memory[$0] } ?? 0,
                broken: item.programMissing,
                appPath: owningApp(label: item.label, program: item.program, apps: apps),
                developer: nil))
        }

        // Apps that open at login and helpers registered by apps themselves.
        // macOS manages these in System Settings; they have no plist to edit.
        for record in (includeLoginItems ? loginItemRecords(uid: uid) : []) {
            guard let url = record["URL"], url.hasPrefix("file://") else { continue }
            let path = (URL(string: url)?.path ?? url).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fullPath = "/" + path
            if coveredPaths.contains(fullPath) { continue }

            let name = record["Name"] ?? (fullPath as NSString).lastPathComponent
            let disposition = record["Disposition"] ?? ""
            let exists = FileManager.default.fileExists(atPath: fullPath)
            let app = appBundle(containing: fullPath)

            entries.append(StartupEntry(
                label: record["Bundle Identifier"] ?? record["Identifier"] ?? name,
                displayName: name,
                kind: .loginItem,
                path: nil,
                program: fullPath,
                runAtLoad: true,
                keepAlive: false,
                disabled: disposition.contains("disabled"),
                pid: nil,
                broken: !exists || fullPath.contains("/.Trash/"),
                appPath: exists ? app : nil,
                developer: record["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 }))
        }

        return entries.sorted { lhs, rhs in
            if lhs.broken != rhs.broken { return lhs.broken }
            if lhs.keepAlive != rhs.keepAlive { return lhs.keepAlive }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Labels launchd has been told not to load. Lines read `"label" => disabled`.
    static func disabledLabels(domain: String) -> Set<String> {
        let output = Shell.run("/bin/launchctl", ["print-disabled", domain]).out
        return parseDisabled(output)
    }

    static func parseDisabled(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.components(separatedBy: .newlines) where line.contains("=> disabled") {
            let parts = line.components(separatedBy: "\"")
            if parts.count >= 2 { labels.insert(parts[1]) }
        }
        return labels
    }

    /// `launchctl list` prints PID, last exit status and label for the user's session.
    static func loadedUserJobs() -> [String: Int32?] {
        let output = Shell.run("/bin/launchctl", ["list"]).out
        var jobs: [String: Int32?] = [:]
        for (index, line) in output.components(separatedBy: .newlines).enumerated() {
            if index == 0 { continue }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3 else { continue }
            jobs[fields[2]] = Int32(fields[0])
        }
        return jobs
    }

    /// One call for every system service, instead of one per daemon. Lines in
    /// the services block read: PID, last exit status, label.
    static func loadedSystemJobs() -> [String: Int32] {
        let output = Shell.run("/bin/launchctl", ["print", "system"]).out
        var jobs: [String: Int32] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.whitespaceFields
            if fields.count == 3, let pid = Int32(fields[0]), pid > 0, fields[2].contains(".") {
                jobs[fields[2]] = pid
            }
        }
        return jobs
    }

    static func residentMemory() -> [Int32: Int64] {
        let output = Shell.run("/bin/ps", ["-Ao", "pid,rss"]).out
        var map: [Int32: Int64] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.whitespaceFields
            if fields.count == 2, let pid = Int32(fields[0]), let kb = Int64(fields[1]) { map[pid] = kb * 1024 }
        }
        return map
    }

    /// Background-task records for one user, as key/value dictionaries, keeping
    /// only apps and login items — agents and daemons are read from their plists.
    static func loginItemRecords(uid: uid_t) -> [[String: String]] {
        let output = Shell.run("/usr/bin/sfltool", ["dumpbtm"]).out
        return parseLoginItems(output, uid: uid)
    }

    static func parseLoginItems(_ output: String, uid: uid_t) -> [[String: String]] {
        var records: [[String: String]] = []
        var current: [String: String] = [:]
        var inSection = false

        func flush() {
            let type = current["Type"] ?? ""
            if inSection, type.hasPrefix("app") || type.hasPrefix("login item") { records.append(current) }
            current = [:]
        }

        for line in output.components(separatedBy: .newlines) {
            if line.contains("Records for UID") {
                flush()
                inSection = line.contains("UID \(uid) ")
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") && trimmed.hasSuffix(":") { flush(); continue }
            guard let colon = trimmed.range(of: ": ") else { continue }
            current[String(trimmed[trimmed.startIndex ..< colon.lowerBound])] = String(trimmed[colon.upperBound...])
        }
        flush()
        return records
    }

    // MARK: - Naming and ownership

    /// The outermost .app a path sits inside, if any.
    static func appBundle(containing path: String) -> String? {
        let components = path.components(separatedBy: "/")
        for (index, component) in components.enumerated() where component.hasSuffix(".app") {
            return components[0 ... index].joined(separator: "/")
        }
        return nil
    }

    /// Which installed app a startup item belongs to. Decided by the program's
    /// own location first; by bundle identifier only when exactly one app can
    /// match, so an updater is never pinned on the wrong app from a vendor
    /// that ships several.
    static func owningApp(label: String, program: String?, apps: [InstalledApp]) -> String? {
        if let program = program, let bundle = appBundle(containing: program),
           FileManager.default.fileExists(atPath: bundle), !bundle.hasPrefix("/System/") {
            return bundle
        }
        let removable = apps.filter { $0.location.removable && !$0.bundleID.isEmpty }
        if let exact = removable.first(where: { label.hasPrefix($0.bundleID) }) { return exact.path }

        let parts = label.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        let vendor = parts[0] + "." + parts[1] + "."
        let sameVendor = removable.filter { $0.bundleID.hasPrefix(vendor) }
        return sameVendor.count == 1 ? sameVendor[0].path : nil
    }

    static func readableName(label: String, program: String?) -> String {
        if let program = program, let bundle = appBundle(containing: program) {
            return (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                + " — " + label.components(separatedBy: ".").suffix(2).joined(separator: ".")
        }
        return label
    }

    // MARK: - Actions

    static func disableScript(_ entry: StartupEntry, uid: uid_t = getuid()) -> String {
        let target = entry.domain(uid: uid) + "/" + HealthScanner.shellQuote(entry.label)
        return "launchctl bootout \(target) 2>/dev/null; launchctl disable \(target)"
    }

    static func enableScript(_ entry: StartupEntry, uid: uid_t = getuid()) -> String {
        let domain = entry.domain(uid: uid)
        let target = domain + "/" + HealthScanner.shellQuote(entry.label)
        var script = "launchctl enable \(target)"
        if let path = entry.path {
            script += "; launchctl bootstrap \(domain) \(HealthScanner.shellQuote(path)) 2>/dev/null || true"
        }
        return script
    }

    /// Stops the job now and tells launchd not to load it again. The file is
    /// untouched, so Enable puts everything back exactly as it was.
    func disable(_ entry: StartupEntry, apps: [InstalledApp]) {
        run(StartupManager.disableScript(entry), admin: entry.needsAdmin,
            prompt: "Mac Manager needs your password to disable a system service.",
            success: "Disabled \(entry.displayName). It will not start again until you enable it.", apps: apps)
    }

    func enable(_ entry: StartupEntry, apps: [InstalledApp]) {
        run(StartupManager.enableScript(entry), admin: entry.needsAdmin,
            prompt: "Mac Manager needs your password to enable a system service.",
            success: "Enabled \(entry.displayName).", apps: apps)
    }

    /// Stops the jobs and moves their files to quarantine.
    func remove(_ targets: [StartupEntry], apps: [InstalledApp]) {
        let items = targets.compactMap { entry -> QuarantineItem? in
            guard let path = entry.path else { return nil }
            return QuarantineItem(path: path, label: entry.label, isSystem: entry.kind != .userAgent)
        }
        if items.isEmpty { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let destination = HealthScanner.quarantineRoot + "/" + formatter.string(from: Date())
        run(HealthScanner.quarantineScript(items: items, destination: destination),
            admin: HealthScanner.needsAdministrator(items),
            prompt: "Mac Manager needs your password to remove startup items.",
            success: "Moved \(items.count) startup item\(items.count == 1 ? "" : "s") to quarantine. Nothing was deleted.",
            apps: apps)
    }

    private func run(_ script: String, admin: Bool, prompt: String, success: String, apps: [InstalledApp]) {
        work.async {
            let result = HealthScanner.runScript(script, admin: admin, prompt: prompt)
            DispatchQueue.main.async {
                let cancelled = result.err.contains("User canceled") || result.err.contains("-128")
                self.message = cancelled ? "Cancelled — nothing was changed." : success
                self.refresh(apps: apps)
            }
        }
    }

    // MARK: - Summaries

    var alwaysRunning: [StartupEntry] { return entries.filter { $0.keepAlive && !$0.disabled && !$0.broken } }
    var leftovers: [StartupEntry] { return entries.filter { $0.broken } }
    var disabledEntries: [StartupEntry] { return entries.filter { $0.disabled } }
    var backgroundMemory: Int64 { return entries.reduce(0) { $0 + $1.memoryBytes } }
}
