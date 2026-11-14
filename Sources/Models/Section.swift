import Foundation

/// The app's tabs.
enum Section: String, CaseIterable, Identifiable {
    case dashboard = "Overview"
    case health = "Health"
    case startup = "Startup"
    case apps = "Applications"
    case memory = "Memory"
    case storage = "Storage"
    case explore = "Explore"
    case growth = "Growth"
    case ports = "Ports"
    case find = "Find"
    case organize = "Organize"
    case backup = "Backup"
    case duplicates = "Duplicates"

    var id: String { return rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge"
        case .health: return "stethoscope"
        case .startup: return "power"
        case .apps: return "square.grid.2x2"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .explore: return "eye.slash"
        case .growth: return "chart.line.uptrend.xyaxis"
        case .ports: return "network"
        case .find: return "sparkle.magnifyingglass"
        case .organize: return "folder.badge.gearshape"
        case .backup: return "externaldrive.badge.timemachine"
        case .duplicates: return "doc.on.doc"
        }
    }

    /// Which sidebar group this belongs to.
    var group: String {
        switch self {
        case .find, .organize, .backup, .duplicates: return "Files"
        default: return "System"
        }
    }

    var blurb: String {
        switch self {
        case .dashboard: return "How this Mac is doing right now."
        case .startup: return "Everything that starts with this Mac — disable it, remove it, or uninstall the app behind it."
        case .health: return "Diagnose hardware, software, startup, port and security problems — with the fix."
        case .apps: return "Everything installed, what it costs you, and how to remove it cleanly."
        case .memory: return "What is using your memory, grouped by app."
        case .storage: return "Where your disk space went, and what is safe to reclaim."
        case .explore: return "Drill into any folder — including the hidden ones Finder will not show you."
        case .growth: return "What changed, where, and when — drillable to the file, for any period."
        case .find: return "Search your files by meaning as well as by name, and tag them."
        case .organize: return "Sort a messy folder into a structure — previewed first, undoable after."
        case .backup: return "Mirror your folders to an external drive, keeping old versions."
        case .duplicates: return "Identical copies, and files sharing a name but not their contents."
        case .ports: return "Which programs are listening for network connections."
        }
    }
}
