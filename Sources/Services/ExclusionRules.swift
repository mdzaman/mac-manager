import Foundation

/// One thing to leave out of scans, backups and organisation.
struct ExclusionRule: Codable, Identifiable, Equatable {
    var id: String { return pattern }

    let pattern: String
    var enabled: Bool
    let note: String
    let group: String

    static func == (lhs: ExclusionRule, rhs: ExclusionRule) -> Bool {
        return lhs.pattern == rhs.pattern && lhs.enabled == rhs.enabled
    }
}

/// Shared exclusion list, applied everywhere the app touches files.
///
/// One list rather than three: a folder not worth backing up is rarely worth
/// indexing or organising either, and keeping separate lists in sync by hand is
/// how they drift apart.
final class ExclusionRules: ObservableObject {

    @Published var rules: [ExclusionRule] = [] {
        didSet { save() }
    }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("MacManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("exclusions.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([ExclusionRule].self, from: data),
           !saved.isEmpty {
            rules = saved
        } else {
            rules = ExclusionRules.recommended
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Recommendations

    /// Sensible defaults. The ones that are off by default are judgement calls
    /// rather than obvious wins, so they are presented rather than assumed.
    static var recommended: [ExclusionRule] {
        func r(_ pattern: String, _ note: String, _ group: String, _ on: Bool = true) -> ExclusionRule {
            return ExclusionRule(pattern: pattern, enabled: on, note: note, group: group)
        }

        return [
            // Rebuilt from a lockfile in seconds; can be 100,000 files each.
            r("node_modules", "JavaScript packages, reinstalled with one command", "Build output"),
            r("__pycache__", "Compiled Python bytecode", "Build output"),
            r(".venv", "Python virtual environment", "Build output"),
            r("venv", "Python virtual environment", "Build output"),
            r("DerivedData", "Xcode build intermediates", "Build output"),
            r("Pods", "CocoaPods dependencies, restored by pod install", "Build output"),
            r("target", "Rust and Java build output", "Build output"),
            r(".gradle", "Gradle build cache", "Build output"),
            r(".next", "Next.js build output", "Build output"),
            r("dist", "Bundled build output", "Build output", false),
            r("build", "Build output — off by default, some projects keep real files here",
              "Build output", false),

            // Metadata macOS and Windows scatter everywhere.
            r(".DS_Store", "Finder folder settings", "System junk"),
            r("Thumbs.db", "Windows thumbnail cache", "System junk"),
            r("desktop.ini", "Windows folder settings", "System junk"),
            r(".Spotlight-V100", "Spotlight index", "System junk"),
            r(".fseventsd", "Filesystem event log", "System junk"),
            r(".Trashes", "Per-volume trash", "System junk"),

            r(".cache", "Generic cache folder", "Caches"),
            r(".pytest_cache", "pytest cache", "Caches"),
            r(".terraform", "Downloaded Terraform providers", "Caches"),
            r("*.log", "Log files", "Caches", false),
            r("*.tmp", "Temporary files", "Caches"),

            // Off by default: a repo's history is usually worth keeping.
            r(".git", "Git history — off by default, it is your version history",
              "Version control", false),
            r(".svn", "Subversion metadata", "Version control", false),

            // Off by default: large but often irreplaceable.
            r("*.iso", "Disc images", "Large media", false),
            r("*.dmg", "Disk images, usually re-downloadable", "Large media", false),
            r("*.vmdk", "Virtual machine disks", "Large media", false),
        ]
    }

    func restoreRecommended() { rules = ExclusionRules.recommended }

    func add(pattern: String, note: String = "Added by you") {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return }
        if rules.contains(where: { $0.pattern == trimmed }) { return }
        rules.append(ExclusionRule(pattern: trimmed, enabled: true, note: note, group: "Yours"))
    }

    func remove(_ rule: ExclusionRule) {
        rules.removeAll { $0.pattern == rule.pattern }
    }

    func setEnabled(_ enabled: Bool, for rule: ExclusionRule) {
        guard let index = rules.firstIndex(where: { $0.pattern == rule.pattern }) else { return }
        rules[index].enabled = enabled
    }

    // MARK: - Matching

    var activePatterns: [String] { return rules.filter { $0.enabled }.map { $0.pattern } }

    var activeCount: Int { return activePatterns.count }

    var groups: [String] {
        var seen: [String] = []
        for rule in rules where !seen.contains(rule.group) { seen.append(rule.group) }
        return seen
    }

    /// True when a file or folder should be left alone.
    ///
    /// Three pattern shapes, matching what rsync accepts so the same list can be
    /// handed straight to it: `*.ext` matches an extension, a pattern
    /// containing `/` matches anywhere in the path, anything else matches a
    /// whole path component.
    func excludes(name: String, path: String) -> Bool {
        for pattern in activePatterns {
            if pattern.hasPrefix("*.") {
                let ext = String(pattern.dropFirst(2)).lowercased()
                if (name as NSString).pathExtension.lowercased() == ext { return true }
            } else if pattern.contains("/") {
                if path.contains(pattern) { return true }
            } else if name == pattern {
                return true
            }
        }
        return false
    }

    /// The same rules as rsync arguments.
    var rsyncArguments: [String] {
        return activePatterns.map { "--exclude=\($0)" }
    }
}
