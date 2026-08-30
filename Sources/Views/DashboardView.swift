import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let mem = state.memory.snapshot
        let vol = state.storage.volume

        return Page(title: "Overview",
                    subtitle: Section.dashboard.blurb,
                    trailing: { EmptyView() }) {

            // Four headline numbers. Single values, so no chart — just the
            // figure and the one line of context that makes it mean something.
            Card {
                HStack(alignment: .top, spacing: 0) {
                    StatTile(label: "Memory used",
                             value: Fmt.gb(mem.usedBytes),
                             detail: "of \(Fmt.gb(mem.totalBytes)) · pressure \(mem.pressureLevel.label.lowercased())",
                             accent: mem.pressureLevel == .normal ? nil : p.critical)
                    Divider().frame(height: 44)
                    StatTile(label: "Disk free",
                             value: Fmt.gb(vol.availableBytes),
                             detail: "of \(Fmt.gb(vol.totalBytes)) total")
                    Divider().frame(height: 44)
                    StatTile(label: "Apps installed",
                             value: "\(state.appScanner.apps.filter { $0.location != .system }.count)",
                             detail: totalAppsDetail)
                    Divider().frame(height: 44)
                    StatTile(label: "Listening ports",
                             value: "\(state.ports.entries.count)",
                             detail: exposedDetail)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                memoryCard(p: p, mem: mem)
                storageCard(p: p, vol: vol)
            }

            quickWins(p: p)
        }
    }

    // MARK: - Memory

    private func memoryCard(p: Palette, mem: MemorySnapshot) -> some View {
        // A stacked meter: four parts of one whole. Each segment is named and
        // valued in the legend below, so colour never carries meaning alone.
        let segments = [
            MeterSegment(label: "App memory", bytes: mem.appBytes, color: p.series1),
            MeterSegment(label: "Wired", bytes: mem.wiredBytes, color: p.series2),
            MeterSegment(label: "Compressed", bytes: mem.compressedBytes, color: p.series3),
            MeterSegment(label: "Cached files", bytes: mem.cachedBytes, color: p.series4),
        ]

        return Card {
            HStack {
                Text("Memory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(p.textPrimary)
                Spacer()
                Text(Fmt.percent(mem.usedFraction) + " used")
                    .font(.system(size: 12))
                    .foregroundColor(p.textSecondary)
            }

            SegmentedMeter(segments: segments, total: max(mem.totalBytes, 1))

            VStack(alignment: .leading, spacing: 5) {
                ForEach(segments) { seg in
                    LegendItem(color: seg.color, label: seg.label, value: Fmt.bytes(seg.bytes))
                }
                LegendItem(color: p.track, label: "Free", value: Fmt.bytes(mem.freeBytes))
            }

            if mem.swapTotalBytes > 0 {
                Divider()
                HStack(spacing: 5) {
                    Image(systemName: mem.swapUsedBytes > mem.swapTotalBytes / 2
                            ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(mem.swapUsedBytes > mem.swapTotalBytes / 2 ? p.serious : p.good)
                    Text("Swap in use: \(Fmt.bytes(mem.swapUsedBytes)) of \(Fmt.bytes(mem.swapTotalBytes))")
                        .font(.system(size: 11))
                        .foregroundColor(p.textSecondary)
                }
            }

            Button(action: { self.state.section = .memory }) {
                Text("See what is using it →")
                    .font(.system(size: 12))
                    .foregroundColor(p.series1)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - Storage

    private func storageCard(p: Palette, vol: VolumeInfo) -> some View {
        let fraction = vol.usedFraction
        let reclaimable = state.storage.reclaimableBytes

        return Card {
            HStack {
                Text("Storage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(p.textPrimary)
                Spacer()
                Text(Fmt.percent(fraction) + " used")
                    .font(.system(size: 12))
                    .foregroundColor(p.textSecondary)
            }

            CapacityBar(fraction: fraction)

            // Status colour always ships with its icon and its word.
            HStack(spacing: 5) {
                Image(systemName: p.capacityIcon(fraction))
                    .font(.system(size: 10))
                    .foregroundColor(p.capacityColor(fraction))
                Text(p.capacityLabel(fraction))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(p.textPrimary)
                Text("· \(Fmt.bytes(vol.availableBytes)) free of \(Fmt.bytes(vol.totalBytes))")
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(state.storage.isScanning ? "Measuring caches…" : "Safe to reclaim")
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)
                Text(Fmt.bytes(reclaimable))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundColor(reclaimable > 1_000_000_000 ? p.good : p.textPrimary)
                Text("Caches and build leftovers that rebuild themselves.")
                    .font(.system(size: 11))
                    .foregroundColor(p.textMuted)
            }

            Button(action: { self.state.section = .storage }) {
                Text("Review and clear →")
                    .font(.system(size: 12))
                    .foregroundColor(p.series1)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - Quick wins

    private func quickWins(p: Palette) -> some View {
        let stale = staleApps
        return Card {
            Text("Worth a look")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(p.textPrimary)

            if state.appScanner.isScanning {
                LoadingRow(text: "Scanning applications…")
            } else if stale.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(p.good)
                    Text("Nothing obviously stale — every sizeable app has been opened recently.")
                        .font(.system(size: 12))
                        .foregroundColor(p.textSecondary)
                }
                .padding(.vertical, 6)
            } else {
                Text("Large apps you have not opened in a long time.")
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)

                ForEach(stale) { app in
                    HStack(spacing: 9) {
                        Image(nsImage: IconCache.shared.icon(for: app.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(p.textPrimary)
                            Text(Fmt.relative(app.lastUsed))
                                .font(.system(size: 10))
                                .foregroundColor(p.textSecondary)
                        }
                        Spacer()
                        Text(Fmt.bytes(app.sizeBytes))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(p.textPrimary)
                    }
                    .padding(.vertical, 3)
                }

                Button(action: { self.state.section = .apps }) {
                    Text("Manage applications →")
                        .font(.system(size: 12))
                        .foregroundColor(p.series1)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Derived

    /// Removable, over 200 MB, and either never opened or untouched for
    /// six months. Ranked by what removing it would actually give back.
    private var staleApps: [InstalledApp] {
        let cutoff = Date().addingTimeInterval(-180 * 86_400)
        return state.appScanner.apps
            .filter { $0.location.removable }
            .filter { ($0.sizeBytes ?? 0) > 200_000_000 }
            .filter { app in
                guard let used = app.lastUsed else { return true }
                return used < cutoff
            }
            .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
            .prefix(5)
            .map { $0 }
    }

    private var totalAppsDetail: String {
        let measured = state.appScanner.apps
            .filter { $0.location != .system }
            .compactMap { $0.sizeBytes }
        if state.appScanner.isMeasuring { return "measuring sizes…" }
        let total = measured.reduce(0, +)
        return total > 0 ? "\(Fmt.gb(total)) on disk" : "—"
    }

    private var exposedDetail: String {
        let exposed = state.ports.entries.filter { $0.isExposed }.count
        if state.ports.entries.isEmpty { return "—" }
        return exposed == 0 ? "all localhost only" : "\(exposed) on all interfaces"
    }
}
