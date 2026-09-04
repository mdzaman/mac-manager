import SwiftUI

/// Answers "what is growing?" two ways: by comparing folder measurements
/// against their previous values, and by finding large files changed recently.
///
/// The second works immediately; the first needs a baseline, so it stays empty
/// until a folder has been measured twice.
struct GrowthView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var days: Int = 7
    @State private var minimumMB: Int = 50
    @State private var rootPath: String = NSHomeDirectory()

    var body: some View {
        let p = Palette(scheme)
        let movements = SnapshotStore.shared.movements()
        let grew = movements.filter { $0.isGrowth }
        let shrank = movements.filter { !$0.isGrowth }

        return Page(title: "Growth",
                    subtitle: Section.growth.blurb,
                    trailing: {
            Button(action: { self.state.storage.explore(self.state.storage.explorePath) }) {
                Text("Re-measure current folder")
            }
        }) {
            summary(p: p, grew: grew, shrank: shrank)
            recentChanges(p: p)
            movementCard(p: p, title: "Grew", rows: grew, growth: true)
            movementCard(p: p, title: "Shrank", rows: shrank, growth: false)
            explainer(p: p)
        }
        .onAppear {
            if state.storage.recentFiles.isEmpty && !state.storage.isScanningRecent {
                state.storage.scanRecentChanges(root: rootPath, days: days, minimumMB: minimumMB)
            }
        }
    }

    // MARK: - Summary

    private func summary(p: Palette, grew: [GrowthRow], shrank: [GrowthRow]) -> some View {
        let net = grew.reduce(0) { $0 + $1.changeBytes } + shrank.reduce(0) { $0 + $1.changeBytes }
        let baseline = SnapshotStore.shared.earliestBaseline

        return Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Net change", value: Fmt.signedBytes(net),
                         detail: baseline == nil ? "no baseline yet" : "across tracked folders",
                         accent: net > 0 ? p.critical : (net < 0 ? p.good : nil))
                Divider().frame(height: 40)
                StatTile(label: "Folders growing", value: "\(grew.count)",
                         detail: grew.isEmpty ? "nothing growing" : "measured twice or more",
                         accent: grew.isEmpty ? nil : p.serious)
                Divider().frame(height: 40)
                StatTile(label: "Folders shrinking", value: "\(shrank.count)",
                         detail: shrank.isEmpty ? "nothing shrinking" : "your cleanup, working",
                         accent: shrank.isEmpty ? nil : p.good)
                Divider().frame(height: 40)
                StatTile(label: "Tracked", value: "\(SnapshotStore.shared.trackedFolderCount)",
                         detail: baseline == nil ? "visit Explore to start" : "since \(Fmt.date(baseline))")
            }
        }
    }

    // MARK: - Recent changes

    private func recentChanges(p: Palette) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files changed recently")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(p.textPrimary)
                    Text("Works with no history at all — this is what to check when space keeps disappearing.")
                        .font(.system(size: 11))
                        .foregroundColor(p.textSecondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Picker("", selection: $days) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 190)

                Picker("", selection: $minimumMB) {
                    Text("10 MB+").tag(10)
                    Text("50 MB+").tag(50)
                    Text("500 MB+").tag(500)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 190)

                Button(action: {
                    self.state.storage.scanRecentChanges(root: self.rootPath,
                                                         days: self.days,
                                                         minimumMB: self.minimumMB)
                }) {
                    Text(state.storage.isScanningRecent ? "Scanning…" : "Scan")
                }
                .disabled(state.storage.isScanningRecent)
                Spacer()
            }

            HStack(spacing: 7) {
                ForEach(ExploreShortcut.all) { shortcut in
                    Button(action: { self.rootPath = shortcut.path }) {
                        Text(shortcut.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(self.rootPath == shortcut.path ? .white : p.series1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                            .fill(self.rootPath == shortcut.path
                                                    ? p.series1 : p.series1.opacity(0.12)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }

            Divider()

            if state.storage.isScanningRecent {
                LoadingRow(text: "Searching for recently changed files…")
            } else if let note = state.storage.recentNote {
                Text(note).font(.system(size: 12)).foregroundColor(p.textSecondary)
                    .padding(.vertical, 6)
            } else if state.storage.recentFiles.isEmpty {
                Text("Pick a folder and a time window, then Scan.")
                    .font(.system(size: 12)).foregroundColor(p.textMuted)
                    .padding(.vertical, 6)
            } else {
                let files = Array(state.storage.recentFiles.prefix(40))
                let total = state.storage.recentFiles.reduce(0) { $0 + $1.sizeBytes }
                Text("\(state.storage.recentFiles.count) files · \(Fmt.bytes(total)) changed in the last \(days) days")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(p.textPrimary)

                ForEach(files) { file in
                    HStack(spacing: 9) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10)).foregroundColor(p.series1).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name)
                                .font(.system(size: 12)).foregroundColor(p.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            Text(file.displayFolder)
                                .font(.system(size: 10)).foregroundColor(p.textMuted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.relative(file.modified))
                            .font(.system(size: 10)).foregroundColor(p.textSecondary)
                            .frame(width: 92, alignment: .trailing)
                        Text(Fmt.bytes(file.sizeBytes))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(p.textPrimary)
                            .frame(width: 76, alignment: .trailing)
                        Button(action: { StorageScanner.reveal(file.path) }) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundColor(p.textMuted)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Movements

    private func movementCard(p: Palette, title: String, rows: [GrowthRow], growth: Bool) -> some View {
        let shown = Array(rows.prefix(15))
        let tint = growth ? p.serious : p.good
        let largest = max(1, rows.map { abs($0.changeBytes) }.max() ?? 1)

        return Card(padding: 0, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: growth ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(p.textPrimary)
                Text(growth ? "since the previous measurement" : "space you have won back")
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)

            Divider()

            if shown.isEmpty {
                Text(growth
                        ? "Nothing has grown yet. Measure a folder in Explore twice and changes appear here."
                        : "Nothing has shrunk yet.")
                    .font(.system(size: 12)).foregroundColor(p.textMuted)
                    .padding(14)
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                    GrowthRowView(row: row, striped: index % 2 == 1, largest: largest, tint: tint,
                                  onOpen: {
                                      self.state.storage.explore(row.path)
                                      self.state.section = .explore
                                  })
                    if index < shown.count - 1 { Divider().padding(.leading, 14) }
                }
            }
        }
    }

    private func explainer(p: Palette) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("How this works")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("Every folder you measure in Explore is recorded, and the next measurement is compared against it — so the comparison only exists for folders you have visited at least twice. Nothing is measured in the background; the app never runs when you are not looking at it. The recent-files scan above needs no history and is the faster answer when space is disappearing right now.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct GrowthRowView: View {
    @Environment(\.colorScheme) private var scheme
    let row: GrowthRow
    let striped: Bool
    let largest: Int64
    let tint: Color
    let onOpen: () -> Void

    var body: some View {
        let p = Palette(scheme)
        let share = Double(abs(row.changeBytes)) / Double(max(largest, 1))

        return HStack(spacing: 10) {
            Image(systemName: row.isGrowth ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 13)).foregroundColor(p.textPrimary)
                        .lineLimit(1)
                    Text(row.displayPath)
                        .font(.system(size: 10)).foregroundColor(p.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(p.track).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(tint)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, share))), height: 6)
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(width: 84, height: 18)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.signedBytes(row.changeBytes))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(p.textPrimary)
                Text(Fmt.signedPercent(row.changeFraction))
                    .font(.system(size: 9)).foregroundColor(p.textSecondary)
            }
            .frame(width: 92, alignment: .trailing)

            Text(Fmt.bytes(row.currentBytes))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(p.textSecondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(striped ? p.track.opacity(0.28) : Color.clear)
    }
}
