import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var sort: SortKey = .memory
    @State private var confirmForceQuit: ProcessGroup?

    enum SortKey: String, CaseIterable, Identifiable {
        case memory = "Memory"
        case cpu = "CPU"
        case name = "Name"
        var id: String { return rawValue }
    }

    var body: some View {
        let p = Palette(scheme)
        let mem = state.memory.snapshot
        let rows = filteredGroups

        return Page(title: "Memory",
                    subtitle: Section.memory.blurb,
                    trailing: {
            HStack(spacing: 10) {
                SearchField(placeholder: "Search processes", text: $query)
                Picker("", selection: $sort) {
                    ForEach(SortKey.allCases) { key in Text(key.rawValue).tag(key) }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 190)
            }
        }) {
            breakdown(p: p, mem: mem)

            Card(padding: 0, spacing: 0) {
                header(p: p)
                Divider()

                if rows.isEmpty {
                    LoadingRow(text: "Reading the process list…")
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, group in
                        ProcessRow(group: group,
                                   striped: index % 2 == 1,
                                   totalMemory: max(mem.totalBytes, 1),
                                   onQuit: { MemoryMonitor.quit(pids: group.pids) },
                                   onForceQuit: { self.confirmForceQuit = group })
                        if index < rows.count - 1 { Divider().padding(.leading, 46) }
                    }
                }
            }

            Text("Updates every 3 seconds. Quitting asks the app to close and save first; force quitting does not.")
                .font(.system(size: 11))
                .foregroundColor(p.textMuted)
        }
        .alert(item: $confirmForceQuit) { group in
            Alert(title: Text("Force quit \(group.name)?"),
                  message: Text("\(group.members.count) process\(group.members.count == 1 ? "" : "es") will be killed immediately. Any unsaved work in \(group.name) is lost."),
                  primaryButton: .destructive(Text("Force Quit")) {
                      MemoryMonitor.forceQuit(pids: group.pids)
                      self.state.memory.refresh()
                  },
                  secondaryButton: .cancel())
        }
    }

    // MARK: - Breakdown

    private func breakdown(p: Palette, mem: MemorySnapshot) -> some View {
        let segments = [
            MeterSegment(label: "App memory", bytes: mem.appBytes, color: p.series1),
            MeterSegment(label: "Wired", bytes: mem.wiredBytes, color: p.series2),
            MeterSegment(label: "Compressed", bytes: mem.compressedBytes, color: p.series3),
            MeterSegment(label: "Cached files", bytes: mem.cachedBytes, color: p.series4),
        ]

        return Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "In use", value: Fmt.gb(mem.usedBytes),
                         detail: "of \(Fmt.gb(mem.totalBytes)) installed")
                Divider().frame(height: 40)
                StatTile(label: "Pressure", value: mem.pressureLevel.label,
                         detail: pressureAdvice(mem.pressureLevel),
                         accent: mem.pressureLevel == .normal ? p.good : p.critical)
                Divider().frame(height: 40)
                StatTile(label: "Swap used", value: Fmt.bytes(mem.swapUsedBytes),
                         detail: mem.swapUsedBytes > 1_000_000_000
                            ? "your Mac is paging to disk" : "of \(Fmt.bytes(mem.swapTotalBytes))")
                Divider().frame(height: 40)
                StatTile(label: "Processes", value: "\(state.memory.processCount)",
                         detail: "\(state.memory.groups.count) apps and services")
            }

            SegmentedMeter(segments: segments, total: max(mem.totalBytes, 1))

            HStack(spacing: 16) {
                ForEach(segments) { seg in
                    LegendItem(color: seg.color, label: seg.label, value: Fmt.bytes(seg.bytes))
                }
                LegendItem(color: p.track, label: "Free", value: Fmt.bytes(mem.freeBytes))
                Spacer()
            }
        }
    }

    private func pressureAdvice(_ level: MemorySnapshot.Pressure) -> String {
        switch level {
        case .normal: return "no action needed"
        case .warning: return "close something large"
        case .critical: return "your Mac is struggling"
        }
    }

    private func header(p: Palette) -> some View {
        HStack(spacing: 10) {
            Text("").frame(width: 26)
            Text("PROCESS").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(maxWidth: .infinity, alignment: .leading)
            Text("SHARE").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 90, alignment: .leading)
            Text("MEMORY").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 76, alignment: .trailing)
            Text("CPU").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 54, alignment: .trailing)
            Text("").frame(width: 128)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var filteredGroups: [ProcessGroup] {
        var list = state.memory.groups

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }

        switch sort {
        case .memory: list.sort { $0.memoryBytes > $1.memoryBytes }
        case .cpu: list.sort { $0.cpuPercent > $1.cpuPercent }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return Array(list.prefix(60))
    }
}

struct ProcessRow: View {
    @Environment(\.colorScheme) private var scheme
    let group: ProcessGroup
    let striped: Bool
    let totalMemory: Int64
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        let p = Palette(scheme)
        let share = Double(group.memoryBytes) / Double(totalMemory)

        return HStack(spacing: 10) {
            Group {
                if let iconPath = group.iconPath {
                    Image(nsImage: IconCache.shared.icon(for: iconPath))
                        .resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(p.textMuted)
                }
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13))
                    .foregroundColor(p.textPrimary)
                    .lineLimit(1)
                Text(group.members.count == 1
                        ? "PID \(group.members[0].pid)"
                        : "\(group.members.count) processes")
                    .font(.system(size: 10))
                    .foregroundColor(p.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // A single-series magnitude bar — one hue, no legend needed since
            // the value sits right beside it.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(p.track).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(p.series1)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, share))), height: 6)
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(width: 90, height: 20)

            Text(Fmt.bytes(group.memoryBytes))
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(p.textPrimary)
                .frame(width: 76, alignment: .trailing)

            Text(String(format: "%.1f%%", group.cpuPercent))
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(group.cpuPercent > 50 ? p.serious : p.textSecondary)
                .frame(width: 54, alignment: .trailing)

            HStack(spacing: 5) {
                RowButton(title: "Quit", icon: "xmark", action: onQuit)
                RowButton(title: "Force", icon: "bolt", destructive: true, action: onForceQuit)
            }
            .frame(width: 128, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(striped ? p.track.opacity(0.28) : Color.clear)
    }
}
