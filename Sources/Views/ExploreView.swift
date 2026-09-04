import SwiftUI

/// A disk explorer that shows everything — including the dot-prefixed names and
/// hidden-flagged folders Finder omits, which is where large caches hide.
struct ExploreView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var showHiddenOnly = false
    @State private var confirmTrash: ExploreEntry?
    @State private var note: String?

    var body: some View {
        let p = Palette(scheme)
        let rows = filteredEntries

        return Page(title: "Explore",
                    subtitle: Section.explore.blurb,
                    trailing: {
            HStack(spacing: 10) {
                SearchField(placeholder: "Filter this folder", text: $query)
                Toggle("Hidden only", isOn: $showHiddenOnly)
                    .font(.system(size: 11))
                Button(action: { self.state.storage.refreshExplore() }) { Text("Re-measure") }
            }
        }) {
            shortcuts(p: p)
            breadcrumbs(p: p)

            if let note = note {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13)).foregroundColor(p.good)
                        Text(note).font(.system(size: 12)).foregroundColor(p.textPrimary)
                        Spacer()
                        Button("Open Trash") { StorageScanner.revealTrashInFinder() }
                        Button(action: { self.note = nil }) {
                            Image(systemName: "xmark").font(.system(size: 10))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

            Card(padding: 0, spacing: 0) {
                header(p: p)
                Divider()

                if let message = state.storage.exploreNote {
                    EmptyState(icon: "lock", title: "Cannot read this folder", message: message)
                } else if rows.isEmpty && state.storage.isExploring {
                    LoadingRow(text: "Reading folder…")
                } else if rows.isEmpty {
                    EmptyState(icon: "folder",
                               title: "Nothing to show",
                               message: query.isEmpty
                                ? "This folder is empty."
                                : "Nothing here matches “\(query)”.")
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        ExploreRow(entry: entry,
                                   striped: index % 2 == 1,
                                   largest: largestSize,
                                   onOpen: {
                                       if entry.isDirectory { self.state.storage.explore(entry.path) }
                                       else { StorageScanner.reveal(entry.path) }
                                   },
                                   onReveal: { StorageScanner.reveal(entry.path) },
                                   onTrash: { self.confirmTrash = entry })
                        if index < rows.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }

            footerNote(p: p, shown: rows.count)
        }
        .onAppear {
            if state.storage.exploreEntries.isEmpty { state.storage.explore(NSHomeDirectory()) }
        }
        .alert(item: $confirmTrash) { entry in
            Alert(title: Text("Move “\(entry.name)” to the Trash?"),
                  message: Text(trashWarning(for: entry)),
                  primaryButton: .destructive(Text("Move to Trash")) { self.trash(entry) },
                  secondaryButton: .cancel())
        }
    }

    // MARK: - Chrome

    private func shortcuts(p: Palette) -> some View {
        Card {
            Text("Jump to")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(p.textMuted)
            HStack(spacing: 7) {
                ForEach(ExploreShortcut.all) { shortcut in
                    Button(action: { self.state.storage.explore(shortcut.path) }) {
                        HStack(spacing: 5) {
                            Image(systemName: shortcut.icon).font(.system(size: 10))
                            Text(shortcut.label).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(self.isCurrent(shortcut.path) ? .white : p.series1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(self.isCurrent(shortcut.path)
                                                ? p.series1 : p.series1.opacity(0.12)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }
        }
    }

    private func isCurrent(_ path: String) -> Bool {
        return (path as NSString).standardizingPath == state.storage.explorePath
    }

    private func breadcrumbs(p: Palette) -> some View {
        let crumbs = state.storage.exploreBreadcrumbs
        return Card {
            HStack(spacing: 5) {
                Button(action: { self.state.storage.exploreUp() }) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(p.series1)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Go up one folder")

                Divider().frame(height: 14)

                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    HStack(spacing: 5) {
                        Button(action: { self.state.storage.explore(crumb.1) }) {
                            Text(crumb.0)
                                .font(.system(size: 12,
                                              weight: index == crumbs.count - 1 ? .semibold : .regular))
                                .foregroundColor(index == crumbs.count - 1 ? p.textPrimary : p.series1)
                        }
                        .buttonStyle(PlainButtonStyle())
                        if index < crumbs.count - 1 {
                            Text("›").font(.system(size: 11)).foregroundColor(p.textMuted)
                        }
                    }
                }

                if state.storage.isExploring {
                    ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
                    Text("measuring…").font(.system(size: 11)).foregroundColor(p.textSecondary)
                }
                Spacer()

                Button(action: { StorageScanner.reveal(self.state.storage.explorePath) }) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundColor(p.textMuted)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Show this folder in Finder")
            }
        }
    }

    private func header(p: Palette) -> some View {
        HStack(spacing: 10) {
            Text("").frame(width: 22)
            Text("NAME").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(maxWidth: .infinity, alignment: .leading)
            Text("SHARE").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 96, alignment: .leading)
            Text("SIZE").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 84, alignment: .trailing)
            Text("CHANGE").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 86, alignment: .trailing)
            Text("").frame(width: 96)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func footerNote(p: Palette, shown: Int) -> some View {
        let hidden = state.storage.exploreEntries.filter { $0.isHidden }.count
        let total = state.storage.exploreEntries.reduce(0) { $0 + $1.sizeBytes }
        return Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye.slash").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(shown) shown · \(hidden) hidden from Finder · \(Fmt.bytes(total)) in this folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(p.textPrimary)
                    Text("Folders are listed instantly and measured afterwards, because a folder's size is only known once its whole tree has been walked — ~/Library can take a few minutes. Items marked Hidden are the ones Finder does not show you. Moving anything from here goes to the Trash, never straight to deletion.")
                        .font(.system(size: 11))
                        .foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Data

    private var filteredEntries: [ExploreEntry] {
        var list = state.storage.exploreEntries
        if showHiddenOnly { list = list.filter { $0.isHidden } }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
        return list
    }

    private var largestSize: Int64 {
        return max(1, state.storage.exploreEntries.map { $0.sizeBytes }.max() ?? 1)
    }

    /// Some folders are load-bearing. Say so plainly instead of relying on the
    /// user to recognise the path.
    private func trashWarning(for entry: ExploreEntry) -> String {
        let sensitive = ["Library", "Containers", "Application Support", "Group Containers",
                         "Mobile Documents", "Preferences", "Keychains", "Documents",
                         "Desktop", "Pictures", "Photos Library.photoslibrary"]
        let base = "\(entry.displayPath) — \(Fmt.bytes(entry.sizeBytes)) — will be moved to the Trash. Nothing is deleted until you empty it."

        if sensitive.contains(entry.name) {
            return "⚠︎ \(entry.name) holds data that apps depend on, and removing it can lose settings or documents.\n\n" + base
        }
        return base
    }

    private func trash(_ entry: ExploreEntry) {
        AppScanner.moveToTrash(paths: [entry.path]) { failures in
            if failures.isEmpty {
                self.note = "Moved “\(entry.name)” to the Trash. Empty the Trash to reclaim \(Fmt.bytes(entry.sizeBytes))."
            } else {
                self.note = "Could not move “\(entry.name)”: \(failures[0].1)"
            }
            self.state.storage.refreshExplore()
        }
    }
}

struct ExploreRow: View {
    @Environment(\.colorScheme) private var scheme
    let entry: ExploreEntry
    let striped: Bool
    let largest: Int64
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        let p = Palette(scheme)
        let share = Double(entry.sizeBytes) / Double(max(largest, 1))

        return HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 12))
                .foregroundColor(entry.isHidden ? p.textMuted : p.series1)
                .frame(width: 22)

            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundColor(p.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isHidden {
                        Text("Hidden")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(p.serious)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(p.serious.opacity(0.14)))
                    }
                    if entry.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(p.textMuted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(p.track).frame(height: 6)
                    if entry.measured {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(p.series1)
                            .frame(width: max(2, geo.size.width * CGFloat(min(1, share))), height: 6)
                    }
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(width: 96, height: 18)

            Group {
                if entry.measured {
                    Text(Fmt.bytes(entry.sizeBytes))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(p.textPrimary)
                } else {
                    Text("measuring…")
                        .font(.system(size: 10))
                        .foregroundColor(p.textMuted)
                }
            }
            .frame(width: 84, alignment: .trailing)

            // Change since this folder was last measured. Direction is carried
            // by an arrow and a sign, so colour is never doing the work alone.
            Group {
                if let delta = entry.deltaBytes, delta != 0 {
                    HStack(spacing: 3) {
                        Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(Fmt.signedBytes(delta))
                            .font(.system(size: 11, design: .rounded))
                    }
                    .foregroundColor(delta > 0 ? p.serious : p.good)
                    .help(entry.deltaSince.map { "Since \(Fmt.date($0))" } ?? "")
                } else if entry.deltaBytes != nil {
                    Text("no change").font(.system(size: 10)).foregroundColor(p.textMuted)
                } else {
                    Text("—").font(.system(size: 10)).foregroundColor(p.textMuted)
                        .help("First measurement — revisit to see change")
                }
            }
            .frame(width: 86, alignment: .trailing)

            HStack(spacing: 5) {
                Button(action: onReveal) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundColor(p.textMuted)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Show in Finder")
                RowButton(title: "Trash", icon: "trash", destructive: true, action: onTrash)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(striped ? p.track.opacity(0.28) : Color.clear)
    }
}
