import Foundation

/// Durable, corruption-resistant storage for everything the app remembers
/// between launches.
///
/// Three defences, because the app writes state while a backup is running and
/// a Mac can lose power, sleep, or have its drive yanked at any moment:
///
/// 1. **Atomic replace.** Every write goes to a temporary file and is renamed
///    into place, so a reader sees either the whole old file or the whole new
///    one — never a half-written mixture.
/// 2. **A previous-good copy.** The prior version is kept as `.bak` before each
///    replace, so a file that decodes but is wrong is still recoverable.
/// 3. **Validated loads.** Anything that fails to decode falls back to the
///    backup, and if that fails too the file is quarantined rather than
///    crashing or silently returning nothing.
enum StateStore {

    struct LoadResult<T> {
        let value: T?
        let recoveredFromBackup: Bool
        let problem: String?
    }

    struct FileHealth: Identifiable {
        var id: String { return name }
        let name: String
        let exists: Bool
        let sizeBytes: Int64
        let modified: Date?
        let hasBackup: Bool
        let readable: Bool
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("MacManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ name: String) -> URL { return directory.appendingPathComponent(name) }
    private static func backupURL(_ name: String) -> URL { return url(name + ".bak") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: - Writing

    @discardableResult
    static func save<T: Encodable>(_ value: T, as name: String) -> Bool {
        guard let data = try? encoder.encode(value) else { return false }

        let target = url(name)
        let fm = FileManager.default

        // Keep the last good copy before overwriting it.
        if fm.fileExists(atPath: target.path) {
            let backup = backupURL(name)
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: target, to: backup)
        }

        // `.atomic` writes to a temporary file and renames, so a crash midway
        // leaves the previous file intact rather than a truncated one.
        do {
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Reading

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> LoadResult<T> {
        let target = url(name)
        let fm = FileManager.default

        if !fm.fileExists(atPath: target.path) {
            return LoadResult(value: nil, recoveredFromBackup: false, problem: nil)
        }

        if let data = try? Data(contentsOf: target),
           let decoded = try? decoder.decode(type, from: data) {
            return LoadResult(value: decoded, recoveredFromBackup: false, problem: nil)
        }

        // The live file is unreadable — fall back to the previous good copy.
        let backup = backupURL(name)
        if fm.fileExists(atPath: backup.path),
           let data = try? Data(contentsOf: backup),
           let decoded = try? decoder.decode(type, from: data) {
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: backup, to: target)
            return LoadResult(value: decoded, recoveredFromBackup: true,
                              problem: "\(name) was damaged and has been restored from the last good copy.")
        }

        // Neither is usable. Move the bad file aside rather than deleting it,
        // and rather than looping on it at every launch.
        let quarantine = url(name + ".corrupt-" + String(Int(Date().timeIntervalSince1970)))
        try? fm.moveItem(at: target, to: quarantine)
        return LoadResult(value: nil, recoveredFromBackup: false,
                          problem: "\(name) could not be read and was set aside. Starting fresh.")
    }

    // MARK: - Maintenance

    static func health() -> [FileHealth] {
        let fm = FileManager.default
        let names = ["history.json", "index.json", "exclusions.json",
                     "last-organize.json", "backup-job.json"]

        return names.map { name in
            let target = url(name)
            let attributes = try? fm.attributesOfItem(atPath: target.path)
            let exists = fm.fileExists(atPath: target.path)
            var readable = false
            if exists, let data = try? Data(contentsOf: target) {
                readable = (try? JSONSerialization.jsonObject(with: data)) != nil
            }
            return FileHealth(
                name: name,
                exists: exists,
                sizeBytes: Int64((attributes?[.size] as? Int) ?? 0),
                modified: attributes?[.modificationDate] as? Date,
                hasBackup: fm.fileExists(atPath: backupURL(name).path),
                readable: readable)
        }
    }

    static func reset(_ name: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: url(name))
        try? fm.removeItem(at: backupURL(name))
    }

    /// Quarantined files from previous failures, so they can be cleared out.
    static func quarantinedFiles() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.filter { $0.contains(".corrupt-") }.sorted()
    }

    static func clearQuarantine() {
        for name in quarantinedFiles() {
            try? FileManager.default.removeItem(at: url(name))
        }
    }
}
