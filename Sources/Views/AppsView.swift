import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var sort: SortKey = .size
    @State private var showSystem = false
    @State private var pendingUninstall: InstalledApp?

    enum SortKey: String, CaseIterable, Identifiable {
        case size = "Size"
        case name = "Name"
        case lastUsed = "Last used"
        var id: String { return rawValue }
    }

    var body: some View {
        let p = Palette(scheme)
        let rows = filteredApps

        return Page(title: "Applications",
                    subtitle: Section.apps.blurb,
                    trailing: {
            HStack(spacing: 10) {
                SearchField(placeholder: "Search apps", text: $query)
                Picker("", selection: $sort) {
                    ForEach(SortKey.allCases) { key in Text(key.rawValue).tag(key) }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 220)
                Toggle("System apps", isOn: $showSystem)
                    .font(.system(size: 11))
            }
        }) {
            summaryBar(p: p, rows: rows)

            Card(padding: 0, spacing: 0) {
                header(p: p)
                Divider()

                if state.appScanner.isScanning {
                    LoadingRow(text: "Looking for installed applications…")
                } else if rows.isEmpty {
                    EmptyState(icon: "magnifyingglass",
                               title: "No matching apps",
                               message: query.isEmpty
                                ? "Nothing was found in /Applications or your home Applications folder."
                                : "Nothing matches “\(query)”.")
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, app in
                        AppRow(app: app,
                               striped: index % 2 == 1,
                               onUninstall: { self.pendingUninstall = app })
                        if index < rows.count - 1 { Divider().padding(.leading, 46) }
                    }
                }
            }
        }
        .sheet(item: $pendingUninstall) { app in
            UninstallSheet(app: app) { removedPath in
                self.state.appScanner.removeFromList(paths: [removedPath])
                self.state.storage.refresh()
            }
        }
    }

    // MARK: - Pieces

    private func summaryBar(p: Palette, rows: [InstalledApp]) -> some View {
        let sized = rows.compactMap { $0.sizeBytes }
        let total = sized.reduce(0, +)
        let unopened = rows.filter { $0.lastUsed == nil && $0.location.removable }.count

        return Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Showing", value: "\(rows.count) apps",
                         detail: state.appScanner.isMeasuring ? "measuring sizes…" : "\(sized.count) measured")
                Divider().frame(height: 40)
                StatTile(label: "Disk space", value: Fmt.gb(total),
                         detail: "combined size of the apps listed")
                Divider().frame(height: 40)
                StatTile(label: "Never opened", value: "\(unopened)",
                         detail: unopened == 0 ? "nothing unused" : "candidates for removal",
                         accent: unopened > 0 ? p.serious : nil)
            }
        }
    }

    private func header(p: Palette) -> some View {
        HStack(spacing: 10) {
            Text("").frame(width: 26)
            Text("Application").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("VERSION").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 84, alignment: .leading)
            Text("LAST OPENED").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 110, alignment: .leading)
            Text("SIZE").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 76, alignment: .trailing)
            Text("").frame(width: 96)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var filteredApps: [InstalledApp] {
        var list = state.appScanner.apps

        if !showSystem { list = list.filter { $0.location != .system } }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.bundleID.localizedCaseInsensitiveContains(trimmed)
            }
        }

        switch sort {
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            return list.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        case .lastUsed:
            // Never-opened first: those are the ones worth acting on.
            return list.sorted {
                ($0.lastUsed ?? Date.distantPast) < ($1.lastUsed ?? Date.distantPast)
            }
        }
    }
}

struct AppRow: View {
    @Environment(\.colorScheme) private var scheme
    let app: InstalledApp
    let striped: Bool
    let onUninstall: () -> Void

    var body: some View {
        let p = Palette(scheme)

        return HStack(spacing: 10) {
            Image(nsImage: IconCache.shared.icon(for: app.path))
                .resizable()
                .frame(width: 24, height: 24)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 13))
                    .foregroundColor(p.textPrimary)
                    .lineLimit(1)
                Text(app.bundleID.isEmpty ? app.location.rawValue : app.bundleID)
                    .font(.system(size: 10))
                    .foregroundColor(p.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(app.version)
                .font(.system(size: 11))
                .foregroundColor(p.textSecondary)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)

            Text(Fmt.relative(app.lastUsed))
                .font(.system(size: 11))
                .foregroundColor(app.lastUsed == nil ? p.serious : p.textSecondary)
                .frame(width: 110, alignment: .leading)

            Text(app.location == .system ? "System" : Fmt.bytes(app.sizeBytes))
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(p.textPrimary)
                .frame(width: 76, alignment: .trailing)

            HStack(spacing: 5) {
                if app.location.removable {
                    RowButton(title: "Remove", icon: "trash", destructive: true, action: onUninstall)
                } else {
                    Text("Protected")
                        .font(.system(size: 10))
                        .foregroundColor(p.textMuted)
                }
                Button(action: { StorageScanner.reveal(self.app.path) }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(p.textMuted)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Show in Finder")
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(striped ? p.track.opacity(0.28) : Color.clear)
    }
}
