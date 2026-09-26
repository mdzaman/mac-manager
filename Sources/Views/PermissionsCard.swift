import SwiftUI

/// Explains what macOS is blocking and opens the right pane to fix it.
///
/// There is no API to grant Full Disk Access — an app that could grant itself
/// the thing that protects the user from apps would be no protection at all. So
/// this does the next best thing: names what is blocked, says what it costs,
/// opens the exact settings pane, and reveals the app so it can be dragged in.
struct PermissionsCard: View {
    @Environment(\.colorScheme) private var scheme

    @ObservedObject var permissions: Permissions
    /// Shown even when everything is granted, for a settings-style listing.
    var alwaysShow: Bool = false

    @State private var showSteps = false

    var body: some View {
        let p = Palette(scheme)

        return Group {
            if !permissions.hasFullDiskAccess || alwaysShow {
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: permissions.hasFullDiskAccess
                                ? "checkmark.shield.fill" : "lock.trianglebadge.exclamationmark.fill")
                            .font(.system(size: 18))
                            .foregroundColor(permissions.hasFullDiskAccess ? p.good : p.serious)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(permissions.hasFullDiskAccess
                                    ? "Full Disk Access granted"
                                    : "Full Disk Access needed")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(p.textPrimary)

                            Text(permissions.explanation)
                                .font(.system(size: 11))
                                .foregroundColor(p.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if !permissions.blockedSample.isEmpty {
                                Text("Currently blocked: " +
                                     permissions.blockedSample.prefix(5).joined(separator: ", ") +
                                     (permissions.blockedSample.count > 5 ? "…" : ""))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(p.textMuted)
                                    .lineLimit(2)
                            }
                        }

                        Spacer()

                        VStack(spacing: 6) {
                            if !permissions.hasFullDiskAccess {
                                Button(action: {
                                    Permissions.open(.fullDisk)
                                    self.showSteps = true
                                }) {
                                    Text("Grant access")
                                }
                                Button("Re-check") { self.permissions.refresh() }
                            } else {
                                Button("Re-check") { self.permissions.refresh() }
                            }
                        }
                    }

                    if showSteps && !permissions.hasFullDiskAccess {
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text("In the window that just opened")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(p.textPrimary)
                            stepRow(p: p, number: 1, text: "Click the + button in the Full Disk Access list.")
                            stepRow(p: p, number: 2, text: "Choose Mac Manager. The button below reveals it in Finder if you cannot find it.")
                            stepRow(p: p, number: 3, text: "Switch it on, then come back and press Re-check.")

                            HStack(spacing: 8) {
                                Button("Show Mac Manager in Finder") { Permissions.revealApp() }
                                Button("Open settings again") { Permissions.open(.fullDisk) }
                                Spacer()
                            }
                            .padding(.top, 2)

                            Text("macOS may ask you to quit and reopen Mac Manager before the change takes effect.")
                                .font(.system(size: 10))
                                .foregroundColor(p.textMuted)
                        }
                    }
                }
            }
        }
    }

    private func stepRow(p: Palette, number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(p.series1))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
