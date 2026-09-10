import Foundation

/// Answers "what grew here, and where exactly" for any folder and any period.
///
/// Most disk tools show a point-in-time picture of what is big. This shows what
/// *changed*, attributed all the way down to the file, and it needs no prior
/// snapshot to do it — the filesystem already records when every file was
/// created and last written.
///
/// One walk collects only the files that changed inside the window. Drilling in
/// is then pure grouping over that list, so navigating is instant however deep
/// the tree goes.
final class GrowthExplorer: ObservableObject {

    @Published private(set) var changed: [ChangedFile] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var stage = ""
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanRoot: String = NSHomeDirectory()
    @Published private(set) var cutoff: Date = Date().addingTimeInterval(-7 * 86_400)
    @Published private(set) var note: String?

    /// Where the user has drilled to. Always at or below `scanRoot`.
    @Published private(set) var currentPath: String = NSHomeDirectory()

    @Published var window: ChangeWindow = .week
    @Published var customDate: Date = Date().addingTimeInterval(-30 * 86_400)
    /// Ignore trivia; a thousand changed 2 KB files are not where space went.
    @Published var minimumFileKB: Int = 0

    private let work = DispatchQueue(label: "com.macmanager.growth", qos: .userInitiated)

    // MARK: - Scanning

    func scan(root: String, rules: ExclusionRules?) {
        if isScanning { return }

        let since = window.cutoff(custom: customDate)
        isScanning = true
        changed = []
        scannedCount = 0
        note = nil
        scanRoot = root
        currentPath = root
        cutoff = since
        stage = "Walking \((root as NSString).lastPathComponent)…"

        let minimum = Int64(minimumFileKB) * 1024

        work.async {
            let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey,
                                          .contentModificationDateKey,
                                          .totalFileAllocatedSizeKey]
            var found: [ChangedFile] = []
            var seen = 0

            if let walker = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: keys, options: []) {

                for case let url as URL in walker {
                    let name = url.lastPathComponent
                    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

                    if values.isDirectory == true {
                        if rules?.excludes(name: name, path: url.path) == true {
                            walker.skipDescendants()
                        }
                        continue
                    }

                    seen += 1
                    if seen % 5_000 == 0 {
                        let count = seen
                        DispatchQueue.main.async { self.scannedCount = count }
                    }

                    if rules?.excludes(name: name, path: url.path) == true { continue }
                    guard let modified = values.contentModificationDate, modified >= since else { continue }

                    let size = Int64(values.totalFileAllocatedSize ?? 0)
                    if size < minimum { continue }

                    let created = values.creationDate ?? modified
                    found.append(ChangedFile(path: url.path,
                                             name: name,
                                             sizeBytes: size,
                                             created: created,
                                             modified: modified,
                                             isNew: created >= since))
                }
            }

            DispatchQueue.main.async {
                self.changed = found
                self.scannedCount = seen
                self.isScanning = false
                self.stage = ""
                self.lastScan = Date()
                if found.isEmpty {
                    self.note = "Nothing changed in this folder during that period."
                }
            }
        }
    }

    // MARK: - Drilling

    func drill(into path: String) {
        guard path.hasPrefix(scanRoot) else { return }
        currentPath = path
    }

    func drillUp() {
        if currentPath == scanRoot { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        currentPath = parent.hasPrefix(scanRoot) ? parent : scanRoot
    }

    var breadcrumbs: [(name: String, path: String)] {
        var crumbs: [(String, String)] = []
        var path = currentPath
        while path.hasPrefix(scanRoot) {
            crumbs.append(((path as NSString).lastPathComponent, path))
            if path == scanRoot { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return crumbs.reversed()
    }

    /// Change rolled up to the immediate children of wherever the user is.
    ///
    /// Each changed file is attributed to whichever child of the current folder
    /// contains it, so a folder's figure is the whole subtree beneath it.
    var childrenHere: [ChangeAggregate] {
        let prefix = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
        var buckets: [String: ChangeAggregate] = [:]

        for file in changed {
            guard file.path.hasPrefix(prefix) else { continue }
            let remainder = String(file.path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }

            let parts = remainder.components(separatedBy: "/")
            let childName = parts[0]
            let isDirectory = parts.count > 1
            let childPath = prefix + childName

            var bucket = buckets[childPath] ?? ChangeAggregate(path: childPath,
                                                               name: childName,
                                                               isDirectory: isDirectory)
            if file.isNew {
                bucket.addedBytes += file.sizeBytes
                bucket.addedCount += 1
            } else {
                bucket.updatedBytes += file.sizeBytes
                bucket.updatedCount += 1
            }
            if file.modified > bucket.lastChange { bucket.lastChange = file.modified }
            buckets[childPath] = bucket
        }

        return buckets.values.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Changed files sitting directly in the current folder.
    var filesHere: [ChangedFile] {
        let prefix = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
        return changed
            .filter { $0.path.hasPrefix(prefix)
                        && !String($0.path.dropFirst(prefix.count)).contains("/") }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Every changed file beneath the current folder, biggest first — the
    /// answer to "just show me what actually took the space".
    func biggestBeneath(limit: Int = 40) -> [ChangedFile] {
        let prefix = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
        return changed.filter { $0.path.hasPrefix(prefix) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Totals

    private var beneathCurrent: [ChangedFile] {
        let prefix = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
        return changed.filter { $0.path.hasPrefix(prefix) }
    }

    var addedBytesHere: Int64 { return beneathCurrent.filter { $0.isNew }.reduce(0) { $0 + $1.sizeBytes } }
    var updatedBytesHere: Int64 { return beneathCurrent.filter { !$0.isNew }.reduce(0) { $0 + $1.sizeBytes } }
    var addedCountHere: Int { return beneathCurrent.filter { $0.isNew }.count }
    var updatedCountHere: Int { return beneathCurrent.filter { !$0.isNew }.count }
    var totalBytesHere: Int64 { return addedBytesHere + updatedBytesHere }

    /// Change per day across the window, for a small bar chart.
    func dailyTotals(buckets: Int = 14) -> [(day: Date, bytes: Int64)] {
        let span = Date().timeIntervalSince(cutoff)
        if span <= 0 { return [] }

        let bucketSpan = span / Double(buckets)
        var totals = [Int64](repeating: 0, count: buckets)

        for file in beneathCurrent {
            let offset = file.modified.timeIntervalSince(cutoff)
            if offset < 0 { continue }
            let index = min(buckets - 1, max(0, Int(offset / bucketSpan)))
            totals[index] += file.sizeBytes
        }

        return totals.enumerated().map { index, bytes in
            (day: cutoff.addingTimeInterval(bucketSpan * Double(index) + bucketSpan / 2),
             bytes: bytes)
        }
    }

    var windowDescription: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "since \(formatter.string(from: cutoff))"
    }
}
