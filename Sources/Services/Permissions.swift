import AppKit
import Foundation

/// What macOS is currently letting this app do, and how to ask for more.
///
/// These grants cannot be given programmatically — by design, only the user can
/// turn them on in System Settings, and an app that could grant itself Full Disk
/// Access would make the whole protection pointless. What the app can do is say
/// precisely what is missing, what it costs, and open the exact pane.
final class Permissions: ObservableObject {

    @Published private(set) var hasFullDiskAccess = false
    @Published private(set) var blockedSample: [String] = []
    @Published private(set) var lastChecked: Date?

    /// Paths only readable with Full Disk Access. If any can be read, the grant
    /// is in place; probing several avoids a false negative from one of them
    /// simply not existing on a given Mac.
    private static let probes: [String] = [
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Cookies",
        NSHomeDirectory() + "/Library/Mail",
    ]

    init() { refresh() }

    func refresh() {
        var granted = false
        var existed = false

        for path in Permissions.probes {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            existed = true
            if FileHandle(forReadingAtPath: path) != nil {
                granted = true
                break
            }
            // A directory has no file handle; listing it is the equivalent test.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                granted = true
                break
            }
        }

        // With no probe present at all, assume granted rather than nagging.
        hasFullDiskAccess = granted || !existed
        lastChecked = Date()
        blockedSample = hasFullDiskAccess ? [] : Permissions.protectedEntries(
            in: NSHomeDirectory() + "/Library/Caches", limit: 8)
    }

    /// Entries inside a folder that cannot currently be read.
    static func protectedEntries(in folder: String, limit: Int = .max) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var blocked: [String] = []

        for name in names.sorted() {
            let path = folder + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if (try? FileManager.default.contentsOfDirectory(atPath: path)) == nil {
                    blocked.append(name)
                }
            }
            if blocked.count >= limit { break }
        }
        return blocked
    }

    /// True when this specific path can be read right now.
    static func isReadable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
        return FileManager.default.isReadableFile(atPath: path)
    }

    // MARK: - Asking

    enum Pane: String {
        case fullDisk = "Privacy_AllFiles"
        case automation = "Privacy_Automation"
        case files = "Privacy_FilesAndFolders"

        var title: String {
            switch self {
            case .fullDisk: return "Full Disk Access"
            case .automation: return "Automation"
            case .files: return "Files and Folders"
            }
        }
    }

    /// Opens the exact System Settings pane. macOS will not let an app grant
    /// itself the switch, so this is as close to one click as exists.
    static func open(_ pane: Pane) {
        Shell.run("/usr/bin/open",
                  ["x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"])
    }

    /// Reveals the built app so it can be dragged into the settings list, which
    /// is the step people most often get stuck on.
    static func revealApp() {
        let path = Bundle.main.bundlePath
        Shell.run("/usr/bin/open", ["-R", path])
    }

    var explanation: String {
        return hasFullDiskAccess
            ? "Mac Manager can read every folder it needs."
            : "Without Full Disk Access, protected folders — your Photos library, Mail, Safari data and some caches — are invisible to scans and missing from backups."
    }
}
