import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var confirmClear: CleanupTarget?
    @State private var lastResult: String?

    var body: some View {
        let p = Palette(scheme)
        let vol = state.storage.volume
        let safe = state.storage.targets.filter { $0.safety == .safe }
        let review = state.storage.targets.filter { $0.safety == .review }

        return Page(title: "Storage",
                    subtitle: Section.storage.blurb,
                    trailing: {
            Button(action: { self.state.storage.refresh() }) {
                Text(state.storage.isScanning ? "Measuring…" : "Re-measure")
            }
            .disabled(state.storage.isScanning)
        }) {
            capacityCard(p: p, vol: vol)

            if let result = lastResult {
                noticeCard(p: p, result: result)
            }

            targetsCard(p: p,
                        title: "Safe to clear",
                        note: "These rebuild themselves. Clearing them costs nothing but a slower first launch.",
                        targets: safe)

            targetsCard(p: p,
                        title: "Review before clearing",
                        note: "These may hold data you want. Nothing here is preselected — open each one first.",
                        targets: review)

            trashCard(p: p)
            homeCard(p: p)
        }
        .alert(item: $confirmClear) { target in
            Alert(title: Text("Clear \(target.name)?"),
                  message: Text("The contents of \(target.displayPath) — \(Fmt.bytes(target.sizeBytes)) — will be moved to the Trash. The folder itself stays, and nothing is deleted until you empty the Trash."),
                  primaryButton: .destructive(Text("Move to Trash")) { self.clear(target) },
                  secondaryButton: .cancel())
        }
    }

    // MARK: - Cards

    private func capacityCard(p: Palette, vol: VolumeInfo) -> some View {
        let fraction = vol.usedFraction
        return Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Free space", value: Fmt.gb(vol.availableBytes),
                         detail: "of \(Fmt.gb(vol.totalBytes)) total")
                Divider().frame(height: 40)
                StatTile(label: "In use", value: Fmt.gb(vol.usedBytes),
                         detail: Fmt.percent(fraction) + " of the disk")
                Divider().frame(height: 40)
                StatTile(label: "Safe to reclaim", value: Fmt.bytes(state.storage.reclaimableBytes),
                         detail: state.storage.isScanning ? "still measuring…" : "caches and build leftovers",
                         accent: state.storage.reclaimableBytes > 1_000_000_000 ? p.good : nil)
            }

            CapacityBar(fraction: fraction, height: 12)

            HStack(spacing: 5) {
                Image(systemName: p.capacityIcon(fraction))
                    .font(.system(size: 11))
                    .foregroundColor(p.capacityColor(fraction))
                Text(p.capacityLabel(fraction))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textPrimary)
                Text("· macOS keeps a reserve, so the free figure matches Finder rather than raw block counts.")
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)
            }
        }
    }

    private func noticeCard(p: Palette, result: String) -> some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundColor(p.good)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(p.textPrimary)
                    Text("The space comes back when you empty the Trash.")
                        .font(.system(size: 11))
                        .foregroundColor(p.textSecondary)
                }
                Spacer()
                Button("Open Trash") { StorageScanner.revealTrashInFinder() }
                Button(action: { self.lastResult = nil }) {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func targetsCard(p: Palette, title: String, note: String, targets: [CleanupTarget]) -> some View {
        Card(padding: 0, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(p.textPrimary)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 10)

            Divider()

            if targets.isEmpty {
                Text("Nothing here on this Mac.")
                    .font(.system(size: 12))
                    .foregroundColor(p.textMuted)
                    .padding(14)
            } else {
                ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                    TargetRow(target: target,
                              striped: index % 2 == 1,
                              onClear: { self.confirmClear = target },
                              onReveal: { StorageScanner.reveal(target.path) })
                    if index < targets.count - 1 { Divider().padding(.leading, 14) }
                }
            }
        }
    }

    /// The Trash is reported but never emptied here: emptying it is a permanent
    /// deletion, and that stays a deliberate action the user takes in Finder.
    private func trashCard(p: Palette) -> some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundColor(p.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash · \(Fmt.bytes(state.storage.trashBytes))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(p.textPrimary)
                    Text("Emptying the Trash permanently deletes files, so Mac Manager leaves that to you in Finder.")
                        .font(.system(size: 11))
                        .foregroundColor(p.textSecondary)
                }
                Spacer()
                Button("Open Trash in Finder") { StorageScanner.revealTrashInFinder() }
            }
        }
    }

    private func homeCard(p: Palette) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where the rest of your space went")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(p.textPrimary)
                    Text("Measures every top-level folder in your home directory. Takes a minute or two.")
                        .font(.system(size: 11))
                        .foregroundColor(p.textSecondary)
                }
                Spacer()
                Button(action: { self.state.storage.scanHomeFolder() }) {
                    Text(state.storage.isScanningHome ? "Measuring…" : "Measure home folder")
                }
                .disabled(state.storage.isScanningHome)
            }

            if !state.storage.homeBreakdown.isEmpty {
                Divider()
                let maxBytes = state.storage.homeBreakdown.map { $0.sizeBytes ?? 0 }.max() ?? 1
                ForEach(state.storage.homeBreakdown) { item in
                    HStack(spacing: 10) {
                        Text(item.name)
                            .font(.system(size: 12))
                            .foregroundColor(p.textPrimary)
                            .frame(width: 160, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(p.track).frame(height: 8)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(p.series1)
                                    .frame(width: max(2, geo.size.width * CGFloat(Double(item.sizeBytes ?? 0) / Double(max(maxBytes, 1)))),
                                           height: 8)
                            }
                            .frame(height: geo.size.height, alignment: .center)
                        }
                        .frame(height: 16)
                        Text(Fmt.bytes(item.sizeBytes))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(p.textPrimary)
                            .frame(width: 74, alignment: .trailing)
                        Button(action: { StorageScanner.reveal(item.path) }) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundColor(p.textMuted)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Actions

    private func clear(_ target: CleanupTarget) {
        StorageScanner.clearContents(of: target.path) { moved, failures in
            if failures.isEmpty {
                self.lastResult = "Moved \(moved) items from \(target.name) to the Trash."
            } else {
                self.lastResult = "Moved \(moved) items from \(target.name); \(failures.count) were in use and stayed put."
            }
            self.state.storage.refresh()
        }
    }
}

struct TargetRow: View {
    @Environment(\.colorScheme) private var scheme
    let target: CleanupTarget
    let striped: Bool
    let onClear: () -> Void
    let onReveal: () -> Void

    var body: some View {
        let p = Palette(scheme)
        let safe = target.safety == .safe

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(target.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(p.textPrimary)
                    Text(target.safety.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(safe ? p.good : p.serious)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                                        .fill((safe ? p.good : p.serious).opacity(0.14)))
                }
                Text(target.detail)
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)
                    .lineLimit(1)
                Text(target.displayPath)
                    .font(.system(size: 10))
                    .foregroundColor(p.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if target.scanned {
                Text(Fmt.bytes(target.sizeBytes))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(p.textPrimary)
                    .frame(width: 84, alignment: .trailing)
            } else {
                ProgressView().scaleEffect(0.4).frame(width: 84, alignment: .trailing)
            }

            HStack(spacing: 5) {
                Button(action: onReveal) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundColor(p.textMuted)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Show in Finder")

                RowButton(title: safe ? "Clear" : "Review",
                          icon: safe ? "trash" : "eye",
                          destructive: safe,
                          action: safe ? onClear : onReveal)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(striped ? p.track.opacity(0.28) : Color.clear)
    }
}
