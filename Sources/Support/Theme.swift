import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

/// Data-mark colors, stepped separately for light and dark surfaces.
/// Categorical slots are assigned in fixed order and never cycled; status
/// colors are reserved and always ship alongside a label.
struct Palette {
    let dark: Bool

    init(_ scheme: ColorScheme) { self.dark = (scheme == .dark) }

    // Categorical slots 1-4, used for the memory breakdown segments.
    var series1: Color { return dark ? Color(hex: 0x3987e5) : Color(hex: 0x2a78d6) } // blue
    var series2: Color { return dark ? Color(hex: 0xd95926) : Color(hex: 0xeb6834) } // orange
    var series3: Color { return dark ? Color(hex: 0x199e70) : Color(hex: 0x1baf7a) } // aqua
    var series4: Color { return dark ? Color(hex: 0xc98500) : Color(hex: 0xeda100) } // yellow

    func series(_ index: Int) -> Color {
        switch index {
        case 0: return series1
        case 1: return series2
        case 2: return series3
        default: return series4
        }
    }

    // Reserved status colors — never reused as a series.
    var good: Color { return Color(hex: 0x0ca30c) }
    var warning: Color { return Color(hex: 0xfab219) }
    var serious: Color { return Color(hex: 0xec835a) }
    var critical: Color { return Color(hex: 0xd03b3b) }

    /// Capacity meters read as a state, not a magnitude, so they take the
    /// status ramp. Always paired with a written label.
    func capacityColor(_ fraction: Double) -> Color {
        if fraction >= 0.90 { return critical }
        if fraction >= 0.75 { return serious }
        return good
    }

    func capacityLabel(_ fraction: Double) -> String {
        if fraction >= 0.90 { return "Critically full" }
        if fraction >= 0.75 { return "Running low" }
        return "Healthy"
    }

    func capacityIcon(_ fraction: Double) -> String {
        if fraction >= 0.90 { return "exclamationmark.triangle.fill" }
        if fraction >= 0.75 { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    // Surfaces track the system so the app looks native in both modes.
    var surface: Color { return Color(NSColor.controlBackgroundColor) }
    var cardBorder: Color { return Color(NSColor.separatorColor) }
    var track: Color { return dark ? Color(hex: 0x383835) : Color(hex: 0xe6e5e1) }
    var textPrimary: Color { return Color(NSColor.labelColor) }
    var textSecondary: Color { return Color(NSColor.secondaryLabelColor) }
    var textMuted: Color { return Color(NSColor.tertiaryLabelColor) }
}

// MARK: - Building blocks

/// Rounded surface every panel sits on.
struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 16
    var spacing: CGFloat = 12
    let content: () -> Content

    /// Table-style cards pass `padding: 0, spacing: 0` so their rows and
    /// dividers sit flush instead of floating apart.
    init(padding: CGFloat = 16,
         spacing: CGFloat = 12,
         @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        let p = Palette(scheme)
        return VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(p.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(p.cardBorder, lineWidth: 1)
            )
    }
}

/// A headline number. Not a chart — one value, read at a glance.
struct StatTile: View {
    @Environment(\.colorScheme) private var scheme
    let label: String
    let value: String
    var detail: String? = nil
    var accent: Color? = nil

    var body: some View {
        let p = Palette(scheme)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundColor(accent ?? p.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One segment of a stacked meter.
struct MeterSegment: Identifiable {
    let id = UUID()
    let label: String
    let bytes: Int64
    let color: Color
}

/// Stacked horizontal meter. Segments are separated by a 2px surface gap so
/// adjacent fills never touch, and every segment is named in the legend.
struct SegmentedMeter: View {
    @Environment(\.colorScheme) private var scheme
    let segments: [MeterSegment]
    let total: Int64
    var height: CGFloat = 14

    var body: some View {
        let p = Palette(scheme)
        return GeometryReader { geo in
            let width = geo.size.width
            let gap: CGFloat = 2
            HStack(spacing: gap) {
                ForEach(segments) { seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: self.segmentWidth(seg, full: width, gap: gap))
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
            .background(p.track)
            .clipShape(RoundedRectangle(cornerRadius: height / 2))
        }
        .frame(height: height)
    }

    private func segmentWidth(_ seg: MeterSegment, full: CGFloat, gap: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let gaps = gap * CGFloat(max(0, segments.count - 1))
        let usable = max(0, full - gaps)
        let w = usable * CGFloat(Double(seg.bytes) / Double(total))
        return max(0, w.isFinite ? w : 0)
    }
}

/// Legend entry — a color chip plus a written label and value, so identity is
/// never carried by color alone.
struct LegendItem: View {
    @Environment(\.colorScheme) private var scheme
    let color: Color
    let label: String
    let value: String

    var body: some View {
        let p = Palette(scheme)
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(p.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(p.textPrimary)
        }
    }
}

/// Single-value capacity bar with a status color and a written state.
struct CapacityBar: View {
    @Environment(\.colorScheme) private var scheme
    let fraction: Double
    var height: CGFloat = 10

    var body: some View {
        let p = Palette(scheme)
        let f = max(0, min(1, fraction))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(p.track)
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(p.capacityColor(f))
                    .frame(width: max(height, geo.size.width * CGFloat(f)))
            }
        }
        .frame(height: height)
    }
}

struct SectionTitle: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var subtitle: String? = nil

    var body: some View {
        let p = Palette(scheme)
        return VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(p.textPrimary)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(p.textSecondary)
            }
        }
    }
}

/// Plain search box — the old SDK has no `.searchable`.
struct SearchField: View {
    @Environment(\.colorScheme) private var scheme
    let placeholder: String
    @Binding var text: String

    var body: some View {
        let p = Palette(scheme)
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(p.textMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 12))
            if !text.isEmpty {
                Button(action: { self.text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(p.textMuted)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.track.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.cardBorder, lineWidth: 1))
        .frame(width: 220)
    }
}

/// Compact action button used in table rows.
struct RowButton: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let icon: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        let p = Palette(scheme)
        let tint = destructive ? p.critical : p.series1
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct LoadingRow: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    var body: some View {
        let p = Palette(scheme)
        return HStack(spacing: 8) {
            ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            Text(text).font(.system(size: 12)).foregroundColor(p.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }
}

struct EmptyState: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String
    let title: String
    let message: String

    var body: some View {
        let p = Palette(scheme)
        return VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(p.textMuted)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(p.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(p.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
