import AppKit
import Foundation

/// Finds installed applications, measures them, locates the support files they
/// leave behind, and removes both — always to the Trash, never with `rm`.
final class AppScanner: ObservableObject {

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var isMeasuring: Bool = false
    @Published private(set) var lastError: String?

    private let work = DispatchQueue(label: "com.macmanager.appscanner", qos: .userInitiated)

    private static let searchRoots: [(String, InstalledApp.Location)] = [
        ("/Applications", .applications),
        (NSHomeDirectory() + "/Applications", .userApplications),
        ("/System/Applications", .system),
    ]

    // MARK: - Scanning

    func refresh() {
        if isScanning { return }
        isScanning = true
        lastError = nil

        work.async {
            let found = AppScanner.enumerateApps()
            DispatchQueue.main.async {
                self.apps = found
                self.isScanning = false
                self.loadLastUsedDates()
                self.measureSizes()
            }
        }
    }

    private static func enumerateApps() -> [InstalledApp] {
        let fm = FileManager.default
        var results: [InstalledApp] = []
        var seen = Set<String>()

        for (root, location) in searchRoots {
            var candidates: [String] = []
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }

            for entry in entries.sorted() {
                let full = root + "/" + entry
                if entry.hasSuffix(".app") {
                    candidates.append(full)
                } else {
                    // One level down catches /Applications/Utilities and the
                    // folders vendors like to nest their suites in.
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue,
                       let nested = try? fm.contentsOfDirectory(atPath: full) {
                        for sub in nested.sorted() where sub.hasSuffix(".app") {
                            candidates.append(full + "/" + sub)
                        }
                    }
                }
            }

            for path in candidates {
                if seen.contains(path) { continue }
                seen.insert(path)
                if let app = readBundle(at: path, location: location) {
                    results.append(app)
                }
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func readBundle(at path: String, location: InstalledApp.Location) -> InstalledApp? {
        let infoPath = path + "/Contents/Info.plist"
        let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any]

        let fallbackName = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")

        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? fallbackName

        let bundleID = (info?["CFBundleIdentifier"] as? String) ?? ""

        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? "—"

        // Prefer the folder name: it is what the user sees in Finder, and some
        // bundles carry an internal CFBundleName nobody recognises.
        let display = fallbackName.isEmpty ? name : fallbackName

        return InstalledApp(path: path,
                            name: display,
                            bundleID: bundleID,
                            version: version,
                            location: location,
                            sizeBytes: nil,
                            lastUsed: nil)
    }

    // MARK: - Sizes

    /// `du` on ~70 bundles takes several seconds, so it runs in chunks and the
    /// table fills in as results arrive rather than blocking on the whole set.
    private func measureSizes() {
        let targets = apps.filter { $0.location != .system }.map { $0.path }
        if targets.isEmpty { return }

        isMeasuring = true
        work.async {
            let chunkSize = 6
            var index = 0
            while index < targets.count {
                let chunk = Array(targets[index ..< min(index + chunkSize, targets.count)])
                let sizes = AppScanner.diskUsage(paths: chunk)
                DispatchQueue.main.async {
                    self.applySizes(sizes)
                }
                index += chunkSize
            }
            DispatchQueue.main.async { self.isMeasuring = false }
        }
    }

    private func applySizes(_ sizes: [String: Int64]) {
        guard !sizes.isEmpty else { return }
        for i in apps.indices {
            if let bytes = sizes[apps[i].path] {
                apps[i].sizeBytes = bytes
            }
        }
    }

    /// Runs `du -sk` and maps each reported path back to its input.
    static func diskUsage(paths: [String]) -> [String: Int64] {
        if paths.isEmpty { return [:] }
        let result = Shell.run("/usr/bin/du", ["-sk"] + paths)
        var sizes: [String: Int64] = [:]

        for line in result.out.nonEmptyLines {
            // Format: "<kilobytes>\t<path>" — the path may contain spaces.
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let kb = Int64(line[line.startIndex ..< tab].trimmingCharacters(in: .whitespaces)) ?? 0
            let path = String(line[line.index(after: tab)...])
            sizes[path] = kb * 1024
        }
        return sizes
    }

    /// Size of a single path. Returns 0 when the path does not exist.
    static func size(of path: String) -> Int64 {
        if !FileManager.default.fileExists(atPath: path) { return 0 }
        return diskUsage(paths: [path])[path] ?? 0
    }

    // MARK: - Last used

    /// Spotlight records the last launch date, which is the signal that makes
    /// "should this still be installed?" answerable.
    private func loadLastUsedDates() {
        let targets = apps.map { $0.path }
        if targets.isEmpty { return }

        work.async {
            var dates: [String: Date] = [:]
            let chunkSize = 40
            var index = 0
            while index < targets.count {
                let chunk = Array(targets[index ..< min(index + chunkSize, targets.count)])
                dates.merge(AppScanner.lastUsedDates(paths: chunk)) { a, _ in a }
                index += chunkSize
            }
            DispatchQueue.main.async {
                for i in self.apps.indices {
                    if let date = dates[self.apps[i].path] {
                        self.apps[i].lastUsed = date
                    }
                }
            }
        }
    }

    private static let mdlsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func lastUsedDates(paths: [String]) -> [String: Date] {
        let result = Shell.run("/usr/bin/mdls",
                               ["-name", "kMDItemPath", "-name", "kMDItemLastUsedDate"] + paths)

        var dates: [String: Date] = [:]
        var pendingDate: Date?

        for line in result.out.nonEmptyLines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            if key == "kMDItemLastUsedDate" {
                pendingDate = value == "(null)" ? nil : mdlsDateFormatter.date(from: value)
            } else if key == "kMDItemPath" {
                // Spotlight reports the firmlinked path; normalise it back.
                var path = value
                let dataPrefix = "/System/Volumes/Data"
                if path.hasPrefix(dataPrefix) { path = String(path.dropFirst(dataPrefix.count)) }
                if let date = pendingDate { dates[path] = date }
                pendingDate = nil
            }
        }
        return dates
    }

    // MARK: - Leftovers

    /// Support files an app scatters through the Library folders. Matching is
    /// deliberately conservative: bundle-identifier prefixes, plus exact
    /// folder-name matches, so a removal never catches an unrelated app.
    static func findLeftovers(for app: InstalledApp, completion: @escaping ([LeftoverItem]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var candidates: [(String, String)] = []  // (path, category)
            let home = NSHomeDirectory()
            let bundleID = app.bundleID
            let name = app.name

            func addExact(_ path: String, _ category: String) {
                candidates.append((path, category))
            }

            /// Adds every entry in `dir` whose name starts with one of `prefixes`.
            func addMatching(dir: String, prefixes: [String], category: String) {
                let usable = prefixes.filter { $0.count >= 3 }
                if usable.isEmpty { return }
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
                for entry in entries {
                    for prefix in usable where entry.lowercased().hasPrefix(prefix.lowercased()) {
                        candidates.append((dir + "/" + entry, category))
                        break
                    }
                }
            }

            // Identifier-keyed locations — an exact-prefix match is safe here.
            if !bundleID.isEmpty {
                addExact("\(home)/Library/Containers/\(bundleID)", "Container")
                addExact("\(home)/Library/Application Support/\(bundleID)", "Application Support")
                addExact("\(home)/Library/Caches/\(bundleID)", "Cache")
                addExact("\(home)/Library/WebKit/\(bundleID)", "Web data")
                addExact("\(home)/Library/Application Scripts/\(bundleID)", "Scripts")
                addExact("\(home)/Library/Saved Application State/\(bundleID).savedState", "Window state")

                addMatching(dir: "\(home)/Library/Preferences",
                            prefixes: [bundleID], category: "Preferences")
                addMatching(dir: "\(home)/Library/Preferences/ByHost",
                            prefixes: [bundleID], category: "Preferences")
                addMatching(dir: "\(home)/Library/HTTPStorages",
                            prefixes: [bundleID], category: "Web data")
                addMatching(dir: "\(home)/Library/Cookies",
                            prefixes: [bundleID], category: "Cookies")
                addMatching(dir: "\(home)/Library/LaunchAgents",
                            prefixes: [bundleID], category: "Login item")
                addMatching(dir: "\(home)/Library/Group Containers",
                            prefixes: [bundleID], category: "Group container")

                // Machine-wide locations. These usually need an administrator,
                // which the Finder fallback prompts for.
                addMatching(dir: "/Library/LaunchAgents", prefixes: [bundleID], category: "Login item")
                addMatching(dir: "/Library/LaunchDaemons", prefixes: [bundleID], category: "Background service")
                addMatching(dir: "/Library/PrivilegedHelperTools", prefixes: [bundleID], category: "Helper tool")
                addMatching(dir: "/Library/Preferences", prefixes: [bundleID], category: "Preferences")
            }

            // Name-keyed locations. Only an exact folder-name match qualifies —
            // a prefix match on a short name like "Notes" would over-collect.
            if name.count >= 3 {
                addExact("\(home)/Library/Application Support/\(name)", "Application Support")
                addExact("\(home)/Library/Caches/\(name)", "Cache")
                addExact("\(home)/Library/Logs/\(name)", "Logs")
                addExact("/Library/Application Support/\(name)", "Application Support")
                addExact("/Library/Logs/\(name)", "Logs")
            }

            // Keep only what exists, de-duplicated, then measure.
            let fm = FileManager.default
            var uniquePaths: [String: String] = [:]
            for (path, category) in candidates where fm.fileExists(atPath: path) {
                if uniquePaths[path] == nil { uniquePaths[path] = category }
            }

            let paths = Array(uniquePaths.keys)
            let sizes = diskUsage(paths: paths)

            let items = uniquePaths.map { path, category -> LeftoverItem in
                return LeftoverItem(path: path,
                                    category: category,
                                    sizeBytes: sizes[path] ?? 0,
                                    selected: true)
            }.sorted { $0.sizeBytes > $1.sizeBytes }

            DispatchQueue.main.async { completion(items) }
        }
    }

    // MARK: - Removal

    /// True when the app currently has a running process.
    static func isRunning(_ app: InstalledApp) -> Bool {
        for running in NSWorkspace.shared.runningApplications {
            if !app.bundleID.isEmpty, running.bundleIdentifier == app.bundleID { return true }
            if let url = running.bundleURL, url.path == app.path { return true }
        }
        return false
    }

    /// Asks the app to quit. Returns false if it is not running.
    @discardableResult
    static func quit(_ app: InstalledApp) -> Bool {
        var quitAny = false
        for running in NSWorkspace.shared.runningApplications {
            let matchesID = !app.bundleID.isEmpty && running.bundleIdentifier == app.bundleID
            let matchesPath = running.bundleURL?.path == app.path
            if matchesID || matchesPath {
                running.terminate()
                quitAny = true
            }
        }
        return quitAny
    }

    /// Moves paths to the Trash. Nothing here deletes: everything stays
    /// recoverable until the user empties the Trash themselves.
    /// Returns the paths that could not be moved, with the reason.
    static func moveToTrash(paths: [String], completion: @escaping ([(String, String)]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [(String, String)] = []

            for path in paths {
                let url = URL(fileURLWithPath: path)
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    // Root-owned items need an administrator. Finder asks for
                    // the password itself and still moves the item to the Trash.
                    let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    let script = "tell application \"Finder\" to delete POSIX file \"\(escaped)\""
                    let fallback = Shell.osascript(script)
                    if !fallback.ok {
                        failures.append((path, error.localizedDescription))
                    }
                }
            }

            DispatchQueue.main.async { completion(failures) }
        }
    }

    func removeFromList(paths: Set<String>) {
        apps.removeAll { paths.contains($0.path) }
    }
}

/// App icons are cheap to fetch but not free; caching keeps scrolling smooth.
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        cache[path] = image
        return image
    }
}
