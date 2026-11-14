import SwiftUI

/// Everything that starts with the Mac, with the three things you can do
/// about each: turn it off, remove it, or uninstall the app behind it.
struct StartupView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var pendingRemoval: Removal?
    @State private var pendingUninstall: InstalledApp?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case always = "Always running"
        case leftover = "Leftover"
        case disabled = "Disabled"
        case login = "Login items"
        var id: String { return rawValue }
    }

    /// A removal waiting on its confirmation.
    struct Removal: Identifiable {
        let id = UUID()
        let entries: [StartupEntry]
    }

    var body: some View {
        let p = Palette(scheme)
        let startup = state.startup
        let rows = filtered(startup.entries)

        return Page(title: "Startup",
                    subtitle: Section.startup.blurb,
                    trailing: {
            HStack(spacing: 10) {
                SearchField(placeholder: "Search startup items", text: $query)
                Button(action: reload) { Text(startup.isLoading ? "Loading…" : "Refresh") }
                    .disabled(startup.isLoading)
            }
        }) {
            summary(p: p, startup: startup)
            messageBanner(p: p, startup: startup)
            filterBar(p: p, startup: startup)
            table(p: p, startup: startup, rows: rows)
            explainer(p: p)
        }
        .onAppear { if startup.entries.isEmpty { reload() } }
        .alert(item: $pendingRemoval) { removal in
            Alert(title: Text("Remove \(removal.entries.count) startup item\(removal.entries.count == 1 ? "" : "s")?"),
                  message: Text(removalMessage(removal.entries)),
                  primaryButton: .destructive(Text("Remove")) {
                      self.state.startup.remove(removal.entries, apps: self.state.appScanner.apps)
                  },
                  secondaryButton: .cancel())
        }
        .sheet(item: $pendingUninstall) { app in
            UninstallSheet(app: app) { removedPath in
                self.state.appScanner.removeFromList(paths: [removedPath])
                self.reload()
            }
        }
    }

    private func reload() { state.startup.refresh(apps: state.appScanner.apps) }

    private func removalMessage(_ entries: [StartupEntry]) -> String {
        let names = entries.prefix(5).map { $0.displayName }.joined(separator: ", ")
        let more = entries.count > 5 ? ", and \(entries.count - 5) more" : ""
        let admin = entries.contains { $0.kind != .userAgent } ? " macOS will ask for your password." : ""
        return "\(names)\(more).\n\nEach job is stopped and its file moved to quarantine. Nothing is deleted, and the files can be moved back.\(admin)"
    }

    // MARK: - Summary

    private func summary(p: Palette, startup: StartupManager) -> some View {
        let leftovers = startup.leftovers.filter { $0.path != nil }
        return Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Startup items", value: "\(startup.entries.count)",
                         detail: startup.isLoading ? "reading login items…" : "agents, services and login items")
                Divider().frame(height: 40)
                StatTile(label: "Always running", value: "\(startup.alwaysRunning.count)",
                         detail: "relaunched whenever they quit",
                         accent: startup.alwaysRunning.count > 8 ? p.serious : nil)
                Divider().frame(height: 40)
                StatTile(label: "Memory in use", value: Fmt.bytes(startup.backgroundMemory),
                         detail: "by startup items running now")
                Divider().frame(height: 40)
                HStack(spacing: 10) {
                    StatTile(label: "Leftover", value: "\(startup.leftovers.count)",
                             detail: startup.leftovers.isEmpty ? "none" : "from apps no longer installed",
                             accent: startup.leftovers.isEmpty ? nil : p.serious)
                    if !leftovers.isEmpty {
                        Button(action: { self.pendingRemoval = Removal(entries: leftovers) }) {
                            Text("Remove \(leftovers.count)")
                        }
                        .help("Remove every leftover agent and service in one go")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBanner(p: Palette, startup: StartupManager) -> some View {
        if let message = startup.message {
            Card {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(p.good)
                    Text(message).font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Spacer()
                }
            }
        }
    }

    private func filterBar(p: Palette, startup: StartupManager) -> some View {
        Card {
            HStack(spacing: 6) {
                ForEach(Filter.allCases) { item in
                    Button(action: { self.filter = item }) {
                        Text("\(item.rawValue) \(self.count(item, startup.entries))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(self.filter == item ? .white : p.series1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                            .fill(self.filter == item ? p.series1 : p.series1.opacity(0.12)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }
        }
    }

    private func matches(_ entry: StartupEntry, _ item: Filter) -> Bool {
        switch item {
        case .all: return true
        case .always: return entry.keepAlive && !entry.broken
        case .leftover: return entry.broken
        case .disabled: return entry.disabled
        case .login: return entry.kind == .loginItem
        }
    }

    private func count(_ item: Filter, _ entries: [StartupEntry]) -> String {
        return "(\(entries.filter { matches($0, item) }.count))"
    }

    private func filtered(_ entries: [StartupEntry]) -> [StartupEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            matches(entry, filter) && (trimmed.isEmpty
                || entry.displayName.localizedCaseInsensitiveContains(trimmed)
                || entry.label.localizedCaseInsensitiveContains(trimmed))
        }
    }

    // MARK: - Table

    private func table(p: Palette, startup: StartupManager, rows: [StartupEntry]) -> some View {
        Card(padding: 0, spacing: 0) {
            HStack(spacing: 10) {
                Text("").frame(width: 24)
                Text("ITEM").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                Text("WHEN").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 104, alignment: .leading)
                Text("STATE").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 112, alignment: .leading)
                Text("").frame(width: 250)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)

            Divider()

            if rows.isEmpty {
                if startup.isLoading { LoadingRow(text: "Reading startup items…") }
                else { EmptyState(icon: "power", title: "Nothing here", message: "No startup items match.") }
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                    StartupRow(entry: entry,
                               striped: index % 2 == 1,
                               onToggle: { self.toggle(entry) },
                               onRemove: { self.pendingRemoval = Removal(entries: [entry]) },
                               onUninstall: { self.uninstall(entry) },
                               onSettings: {
                                   Shell.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension"])
                               },
                               onReveal: { StorageScanner.reveal(entry.path ?? entry.program ?? NSHomeDirectory()) })
                    if index < rows.count - 1 { Divider().padding(.leading, 14) }
                }
            }
        }
    }

    /// Disabling is exactly reversible, so it acts at once. For a system
    /// service the macOS password prompt is itself the confirmation.
    private func toggle(_ entry: StartupEntry) {
        if entry.disabled { state.startup.enable(entry, apps: state.appScanner.apps) }
        else { state.startup.disable(entry, apps: state.appScanner.apps) }
    }

    /// Hands over to the app uninstaller, which shows every file before
    /// anything moves and takes the app's startup items along with it.
    private func uninstall(_ entry: StartupEntry) {
        guard let path = entry.appPath else { return }
        if let app = state.appScanner.apps.first(where: { $0.path == path }) {
            pendingUninstall = app
        } else {
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any]
            pendingUninstall = InstalledApp(path: path, name: name,
                                            bundleID: (info?["CFBundleIdentifier"] as? String) ?? "",
                                            version: (info?["CFBundleShortVersionString"] as? String) ?? "—",
                                            location: .applications,
                                            sizeBytes: AppScanner.size(of: path), lastUsed: nil)
        }
    }

    private func explainer(p: Palette) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Disable, remove, or uninstall")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("Disable stops the item now and tells macOS not to start it again; the file is untouched and Enable reverses it exactly. Remove also moves its file to quarantine. Uninstall opens the app uninstaller, which lists every file before anything moves and takes the app's startup items with it. Login items are managed by macOS itself, so for those the button opens the right settings pane. Leftover login items that point into the Trash disappear when the Trash is emptied.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct StartupRow: View {
    @Environment(\.colorScheme) private var scheme
    let entry: StartupEntry
    let striped: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onUninstall: () -> Void
    let onSettings: () -> Void
    let onReveal: () -> Void

    var body: some View {
        let p = Palette(scheme)
        return HStack(spacing: 10) {
            icon(p: p).frame(width: 24)
            identity(p: p).frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.schedule)
                .font(.system(size: 10, weight: entry.keepAlive ? .medium : .regular))
                .foregroundColor(entry.keepAlive ? p.textPrimary : p.textSecondary)
                .frame(width: 104, alignment: .leading)

            stateLabel(p: p).frame(width: 112, alignment: .leading)
            actions(p: p).frame(width: 250, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(striped ? p.track.opacity(0.28) : Color.clear)
        .opacity(entry.disabled ? 0.6 : 1)
    }

    @ViewBuilder
    private func icon(p: Palette) -> some View {
        if let app = entry.appPath {
            Image(nsImage: IconCache.shared.icon(for: app)).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: entry.broken ? "questionmark.app.dashed" : "gearshape.2")
                .font(.system(size: 13)).foregroundColor(p.textMuted)
        }
    }

    private func identity(p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.displayName)
                .font(.system(size: 12)).foregroundColor(p.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Text("\(entry.kind.rawValue) · \(entry.developer ?? entry.vendor)")
                .font(.system(size: 10)).foregroundColor(p.textMuted).lineLimit(1)
        }
    }

    /// State is always a word with its icon, never colour on its own.
    private func stateLabel(p: Palette) -> some View {
        let state: (String, String, Color)
        if entry.broken { state = ("Program missing", "exclamationmark.triangle.fill", p.serious) }
        else if entry.disabled { state = ("Disabled", "pause.circle.fill", p.textMuted) }
        else if entry.isRunning { state = ("Running · \(Fmt.bytes(entry.memoryBytes))", "play.circle.fill", p.good) }
        else { state = (entry.kind == .loginItem ? "Enabled" : "Not running", "circle", p.textMuted) }

        return HStack(spacing: 4) {
            Image(systemName: state.1).font(.system(size: 9)).foregroundColor(state.2)
            Text(state.0).font(.system(size: 10)).foregroundColor(p.textSecondary).lineLimit(1)
        }
    }

    private func actions(p: Palette) -> some View {
        HStack(spacing: 5) {
            if entry.isManagedBySystem {
                RowButton(title: "Login Items", icon: "gear", action: onSettings)
            } else {
                if !entry.broken {
                    RowButton(title: entry.disabled ? "Enable" : "Disable",
                              icon: entry.disabled ? "play" : "pause", action: onToggle)
                }
                RowButton(title: "Remove", icon: "trash", destructive: true, action: onRemove)
            }
            if entry.appPath != nil {
                RowButton(title: "Uninstall", icon: "xmark.bin", destructive: true, action: onUninstall)
            }
            Button(action: onReveal) {
                Image(systemName: "folder").font(.system(size: 10)).foregroundColor(p.textMuted)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Show in Finder")
        }
    }
}
