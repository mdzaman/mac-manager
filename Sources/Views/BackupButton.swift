import SwiftUI

/// A moving gradient, used while a backup is in flight.
///
/// A static bar at 4% looks identical to a frozen one. Continuous motion is the
/// signal that work is still happening, independent of whether the number has
/// moved recently — which matters when one large file takes minutes.
struct ShimmerBar: View {
    @Environment(\.colorScheme) private var scheme

    var fraction: Double
    var height: CGFloat = 12
    var animated: Bool = true

    @State private var phase: CGFloat = -1

    var body: some View {
        let p = Palette(scheme)
        // Ordered categorical hues rather than an arbitrary rainbow, so the bar
        // belongs to the same palette as every chart in the app.
        let colors = [p.series1, p.series3, p.series1, p.series4, p.series1]

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(p.track)

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(LinearGradient(gradient: Gradient(colors: colors),
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * CGFloat(max(0, min(1, fraction)))))
                    .overlay(
                        // A brighter band travelling left to right over the fill.
                        LinearGradient(gradient: Gradient(colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(self.animated ? 0.45 : 0),
                            Color.white.opacity(0),
                        ]), startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.4)
                            .offset(x: self.phase * geo.size.width)
                            .clipped()
                    )
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))
            }
            .frame(height: geo.size.height, alignment: .center)
        }
        .frame(height: height)
        .onAppear {
            guard animated else { return }
            withAnimation(Animation.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.2
            }
        }
    }
}

/// The primary action of the Backup tab.
///
/// Three states in one control, because the question the user is asking is
/// always the same — "is it running, and when did it last work?" — and the
/// answer belongs on the button itself rather than somewhere else on screen.
struct BackupButton: View {
    @Environment(\.colorScheme) private var scheme

    let isRunning: Bool
    let progress: Double
    let historyLabel: String?
    let copiedFiles: Int
    let totalFiles: Int
    let enabled: Bool
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        let p = Palette(scheme)

        return Button(action: action) {
            HStack(spacing: 12) {
                icon(p: p)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.85))
                            .lineLimit(1)
                    }

                    if isRunning {
                        ShimmerBar(fraction: progress, height: 6)
                            .frame(width: 220)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                if isRunning {
                    Text(Fmt.percent(progress))
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(background(p: p))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
    }

    private var title: String {
        if isRunning { return "Backup in progress…" }
        if let label = historyLabel { return "Backup (\(label))" }
        return "Backup"
    }

    private var subtitle: String? {
        if isRunning {
            return totalFiles > 0
                ? "\(copiedFiles) of \(totalFiles) files copied"
                : "\(copiedFiles) files copied"
        }
        if historyLabel == nil { return "Nothing has been backed up yet" }
        return "Copies new and changed files. Nothing on the drive is deleted."
    }

    private func icon(p: Palette) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.22)).frame(width: 34, height: 34)
            Image(systemName: isRunning ? "arrow.triangle.2.circlepath" : "externaldrive.fill.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .rotationEffect(.degrees(isRunning && pulse ? 360 : 0))
        }
        .onAppear {
            guard isRunning else { return }
            withAnimation(Animation.linear(duration: 2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }

    private func background(p: Palette) -> some View {
        // Running is the eye-catching state; idle stays a calm single hue so
        // the animation means something when it appears.
        let colors: [Color] = isRunning
            ? [p.series1, p.series3, p.series4]
            : [p.series1, p.series1.opacity(0.82)]

        return LinearGradient(gradient: Gradient(colors: colors),
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
