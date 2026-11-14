import Foundation

enum HealthSeverity: Int, Comparable {
    case ok = 0, info, warning, critical

    static func < (lhs: HealthSeverity, rhs: HealthSeverity) -> Bool { return lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .ok: return "Healthy"
        case .info: return "Worth knowing"
        case .warning: return "Needs attention"
        case .critical: return "Act now"
        }
    }

    var icon: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }
}

enum HealthCategory: String, CaseIterable, Identifiable {
    case security = "Security"
    case hardware = "Hardware"
    case software = "Software"
    case startup = "Startup"
    case network = "Ports"
    case cleanup = "Cleanup"

    var id: String { return rawValue }

    var icon: String {
        switch self {
        case .security: return "lock.shield"
        case .hardware: return "cpu"
        case .software: return "app.badge"
        case .startup: return "power"
        case .network: return "network"
        case .cleanup: return "sparkles"
        }
    }
}

/// A startup file to take out of service, and the launchd job that goes with it.
struct QuarantineItem {
    let path: String
    /// launchd label to stop before moving the file, when there is one.
    let label: String?
    /// True for /Library items, which run for every user and need an administrator.
    let isSystem: Bool
}

/// What a fix button does.
enum FixAction {
    case openURL(String)
    case navigate(Section)
    case quitProcesses([Int32])
    case quarantine([QuarantineItem])
    case trash([String])
    case reclaimCaches
    case reveal(String)
}

struct HealthFix: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    /// Shown in a confirmation before anything is changed. Nil means the
    /// button only opens or shows something, so no confirmation is needed.
    let confirmation: String?
    let action: FixAction
    var destructive: Bool = false
}

/// One result of the health check: what was found, why it matters, how to fix
/// it by hand, and — where it is safe — a button that does it.
struct HealthFinding: Identifiable {
    let id: String
    let category: HealthCategory
    let severity: HealthSeverity
    let title: String
    let summary: String
    /// Why this matters, in plain words.
    let why: String
    /// Numbered instructions for doing it by hand.
    let steps: [String]
    /// A Terminal command for people who prefer one, with a Copy button.
    var command: String? = nil
    /// The specific things found — paths, process names, counts.
    var evidence: [String] = []
    var fixes: [HealthFix] = []
}
