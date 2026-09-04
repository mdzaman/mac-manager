import Foundation

// MARK: - Applications

struct InstalledApp: Identifiable, Equatable {
    var id: String { return path }

    let path: String
    let name: String
    let bundleID: String
    let version: String
    let location: Location
    var sizeBytes: Int64?
    var lastUsed: Date?

    enum Location: String {
        case applications = "Applications"
        case userApplications = "User Applications"
        case system = "System"

        /// System apps ship with macOS and are protected by SIP — the app
        /// surfaces them for context but never offers to remove them.
        var removable: Bool { return self != .system }
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        return lhs.path == rhs.path
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.lastUsed == rhs.lastUsed
    }
}

/// A support file left behind by an app — caches, preferences, containers.
struct LeftoverItem: Identifiable {
    var id: String { return path }

    let path: String
    let category: String
    var sizeBytes: Int64
    var selected: Bool = true

    var displayPath: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Memory

struct MemorySnapshot {
    var totalBytes: Int64 = 0
    var appBytes: Int64 = 0
    var wiredBytes: Int64 = 0
    var compressedBytes: Int64 = 0
    var cachedBytes: Int64 = 0
    var freeBytes: Int64 = 0
    var swapUsedBytes: Int64 = 0
    var swapTotalBytes: Int64 = 0
    var pressureLevel: Pressure = .normal

    /// What Activity Monitor calls "Memory Used".
    var usedBytes: Int64 { return appBytes + wiredBytes + compressedBytes }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    enum Pressure: Int {
        case normal = 1
        case warning = 2
        case critical = 4

        var label: String {
            switch self {
            case .normal: return "Normal"
            case .warning: return "Under pressure"
            case .critical: return "Critical"
            }
        }
    }
}

struct RunningProcess: Identifiable, Equatable {
    var id: Int32 { return pid }

    let pid: Int32
    let name: String
    let path: String
    let memoryBytes: Int64
    let cpuPercent: Double

    /// Helper processes are noise on their own; grouping them under the parent
    /// app is what makes the list readable.
    var isHelper: Bool {
        return name.contains("Helper") || name.contains("(Renderer)")
            || name.contains("(GPU)") || name.contains("(Plugin)")
    }
}

/// Processes belonging to one app, collapsed into a single row.
struct ProcessGroup: Identifiable {
    var id: String { return name }

    let name: String
    let iconPath: String?
    var members: [RunningProcess]

    var memoryBytes: Int64 { return members.reduce(0) { $0 + $1.memoryBytes } }
    var cpuPercent: Double { return members.reduce(0) { $0 + $1.cpuPercent } }
    var pids: [Int32] { return members.map { $0.pid } }
}

// MARK: - Storage

struct VolumeInfo {
    var totalBytes: Int64 = 0
    var availableBytes: Int64 = 0
    var usedBytes: Int64 { return max(0, totalBytes - availableBytes) }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

/// A directory the app knows how to measure and (sometimes) clear.
struct CleanupTarget: Identifiable {
    var id: String { return path }

    let name: String
    let detail: String
    let path: String
    let safety: Safety
    var sizeBytes: Int64?
    var scanned: Bool = false

    enum Safety {
        /// Regenerated automatically; clearing costs nothing but a rebuild.
        case safe
        /// May hold data worth keeping — the app shows it but never preselects it.
        case review

        var label: String {
            switch self {
            case .safe: return "Safe to clear"
            case .review: return "Review first"
            }
        }
    }

    var displayPath: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Ports

struct PortEntry: Identifiable {
    var id: String { return "\(pid)-\(networkProtocol)-\(address)-\(port)" }

    let port: Int
    let networkProtocol: String
    let address: String
    let pid: Int32
    let processName: String
    let user: String

    /// Bound to all interfaces means reachable from the local network.
    var isExposed: Bool {
        return address == "*" || address == "0.0.0.0" || address == "::"
    }

    var scopeLabel: String { return isExposed ? "All interfaces" : "Localhost only" }

    /// Best-effort name for well-known ports, so the list means something
    /// without having to look each one up.
    var serviceHint: String? {
        switch port {
        case 22: return "SSH"
        case 80: return "HTTP"
        case 443: return "HTTPS"
        case 445: return "SMB file sharing"
        case 631: return "CUPS printing"
        case 3000: return "Dev server"
        case 3306: return "MySQL"
        case 5000: return "Dev server"
        case 5432: return "PostgreSQL"
        case 5900: return "Screen Sharing"
        case 6379: return "Redis"
        case 7000: return "AirPlay Receiver"
        case 8000, 8080, 8081: return "Dev server"
        case 9000: return "Dev server"
        case 27017: return "MongoDB"
        default: return nil
        }
    }
}

// MARK: - Explorer

/// One entry in the disk explorer: a file or folder with its measured size.
///
/// Unlike Finder, the explorer lists dot-prefixed names and items carrying the
/// hidden flag — those are exactly the ones that hide large caches.
struct ExploreEntry: Identifiable {
    var id: String { return path }

    let path: String
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    var sizeBytes: Int64
    /// Folders are listed immediately and measured afterwards, because `du`
    /// has to walk the whole subtree before it can report a total.
    var measured: Bool
    /// Change since this folder was last measured, when there is a baseline.
    var deltaBytes: Int64? = nil
    var deltaSince: Date? = nil

    var displayPath: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// A place worth jumping straight to. `~/Library` is the headline case: Finder
/// hides it, and it is usually the largest thing in a home folder.
struct ExploreShortcut: Identifiable {
    var id: String { return path }

    let label: String
    let icon: String
    let path: String

    static var all: [ExploreShortcut] {
        let home = NSHomeDirectory()
        return [
            ExploreShortcut(label: "Home", icon: "house", path: home),
            ExploreShortcut(label: "Library", icon: "eye.slash", path: home + "/Library"),
            ExploreShortcut(label: "Containers", icon: "shippingbox",
                            path: home + "/Library/Containers"),
            ExploreShortcut(label: "App Support", icon: "gearshape",
                            path: home + "/Library/Application Support"),
            ExploreShortcut(label: "Caches", icon: "clock.arrow.circlepath",
                            path: home + "/Library/Caches"),
            ExploreShortcut(label: "Developer", icon: "hammer",
                            path: home + "/Library/Developer"),
            ExploreShortcut(label: "Temp files", icon: "tray",
                            path: NSTemporaryDirectory()),
        ]
    }
}

// MARK: - Growth

/// A folder that changed size between two measurements.
struct GrowthRow: Identifiable {
    var id: String { return path }

    let path: String
    let currentBytes: Int64
    let previousBytes: Int64
    let measuredAt: Date
    let baselineAt: Date

    var changeBytes: Int64 { return currentBytes - previousBytes }
    var isGrowth: Bool { return changeBytes > 0 }

    var name: String { return (path as NSString).lastPathComponent }

    var displayPath: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Percentage change, or nil when there was nothing there to grow from.
    var changeFraction: Double? {
        guard previousBytes > 0 else { return nil }
        return Double(changeBytes) / Double(previousBytes)
    }
}

/// A file changed recently — the direct answer to "what is growing right now",
/// available without any prior snapshot.
struct RecentFile: Identifiable {
    var id: String { return path }

    let path: String
    let sizeBytes: Int64
    let modified: Date

    var name: String { return (path as NSString).lastPathComponent }

    var folder: String {
        return (path as NSString).deletingLastPathComponent
    }

    var displayFolder: String {
        let home = NSHomeDirectory()
        let dir = folder
        if dir.hasPrefix(home) { return "~" + dir.dropFirst(home.count) }
        return dir
    }
}
