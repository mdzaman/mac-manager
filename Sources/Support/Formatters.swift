import Foundation

enum Fmt {

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// "1.2 GB" — matches how Finder reports sizes.
    static func bytes(_ value: Int64?) -> String {
        guard let value = value else { return "—" }
        if value <= 0 { return "0 KB" }
        return byteFormatter.string(fromByteCount: value)
    }

    /// Compact form for big headline numbers: "12.3 GB".
    static func gb(_ value: Int64) -> String {
        let g = Double(value) / 1_000_000_000.0
        if g >= 100 { return String(format: "%.0f GB", g) }
        if g >= 10 { return String(format: "%.1f GB", g) }
        return String(format: "%.2f GB", g)
    }

    static func percent(_ fraction: Double) -> String {
        return String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func date(_ value: Date?) -> String {
        guard let value = value else { return "Never" }
        return dateFormatter.string(from: value)
    }

    /// "3 days ago" / "8 months ago" — the useful signal when deciding whether
    /// an app still earns its disk space.
    static func relative(_ value: Date?) -> String {
        guard let value = value else { return "Never opened" }
        let seconds = Date().timeIntervalSince(value)
        if seconds < 0 { return "Just now" }
        let days = Int(seconds / 86_400)
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...30: return "\(days) days ago"
        case 31...364:
            let months = max(1, days / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        default:
            let years = max(1, days / 365)
            return years == 1 ? "Over a year ago" : "\(years) years ago"
        }
    }
}
