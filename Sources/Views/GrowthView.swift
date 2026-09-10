import SwiftUI

/// What changed, where, and when — drillable to the file.
///
/// The distinguishing idea: other disk tools show what is *big*. This shows
/// what *grew*, attributed down the tree, for any period you choose, with no
/// prior snapshot required.
struct GrowthView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var root: String = NSHomeDirectory()
    @State private var showAllFiles = false

    var body: some View {
        let p = Palette(scheme)
        let explorer = state.growth

        return Page(title: "Growth",
                    subtitle: Section.growth.blurb,
                    trailing: {
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { explorer.window },
                                              set: { explorer.window = $0 })) {
                    ForEach(ChangeWindow.allCases) { w in Text(w.rawValue).tag(w) }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 380)
                Button(action: { explorer.scan(root: self.root, rules: self.state.exclusions) }) {
                    Text(explorer.isScanning ? "Scanning…" : "Find changes")
                }
                .disabled(explorer.isScanning)
            }
        }) {
            controls(p: p, explorer: explorer)
            headline(p: p, explorer: explorer)

            if explorer.isScanning {
                Card { LoadingRow(text: "\(explorer.stage) \(explorer.scannedCount) files checked") }
            } else if let note = explorer.note {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundColor(p.good)
                        Text(note).font(.system(size: 12)).foregroundColor(p.textPrimary)
                        Spacer()
                    }
                }
            }

            if !explorer.changed.isEmpty {
                timeline(p: p, explorer: explorer)
                breadcrumbBar(p: p, explorer: explorer)
                folderTable(p: p, explorer: explorer)
                fileTable(p: p, explorer: explorer)
            }

            deletionsCard(p: p)
            explainer(p: p)
        }
    }

    // MARK: - Controls

    private func controls(p: Palette, explorer: GrowthExplorer) -> some View {
        Card {
            HStack(spacing: 7) {
                Text("Look in").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 48, alignment: .leading)
                ForEach(ExploreShortcut.all) { shortcut in
                    Button(action: { self.root = shortcut.path }) {
                        Text(shortcut.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(self.root == shortcut.path ? .white : p.series1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                            .fill(self.root == shortcut.path
                                                    ? p.series1 : p.series1.opacity(0.12)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }

            HStack(spacing: 10) {
                if explorer.window == .custom {
                    Text("Since").font(.system(size: 10, weight: .semibold)).foregroundColor(p.textMuted)
                    DatePicker("", selection: Binding(get: { explorer.customDate },
                                                      set: { explorer.customDate = $0 }),
                               displayedComponents: .date)
                        .labelsHidden()
                        .frame(width: 130)
                }
                Text("Ignore files under").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(p.textMuted)
                Picker("", selection: Binding(get: { explorer.minimumFileKB },
                                              set: { explorer.minimumFileKB = $0 })) {
                    Text("nothing").tag(0)
                    Text("100 KB").tag(100)
                    Text("1 MB").tag(1024)
                    Text("10 MB").tag(10240)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 260)
                Spacer()
            }
        }
    }

    // MARK: - Headline

    private func headline(p: Palette, explorer: GrowthExplorer) -> some View {
        Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Added",
                         value: Fmt.bytes(explorer.addedBytesHere),
                         detail: "\(explorer.addedCountHere) new files",
                         accent: explorer.addedBytesHere > 0 ? p.serious : nil)
                Divider().frame(height: 40)
                StatTile(label: "Updated",
                         value: Fmt.bytes(explorer.updatedBytesHere),
                         detail: "\(explorer.updatedCountHere) existing files rewritten")
                Divider().frame(height: 40)
                StatTile(label: "Total written",
                         value: Fmt.bytes(explorer.totalBytesHere),
                         detail: explorer.changed.isEmpty ? "—" : explorer.windowDescription)
                Divider().frame(height: 40)
                StatTile(label: "Files examined",
                         value: "\(explorer.scannedCount)",
                         detail: explorer.lastScan.map { Fmt.relative($0).lowercased() } ?? "not scanned")
            }
        }
    }

    /// When the growth happened. A single series, so no legend — the title
    /// says what it is and the axis labels carry the dates.
    private func timeline(p: Palette, explorer: GrowthExplorer) -> some View {
        let buckets = explorer.dailyTotals()
        let peak = max(1, buckets.map { $0.bytes }.max() ?? 1)
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"

        return Card {
            HStack {
                Text("When it happened")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Spacer()
                Text("peak \(Fmt.bytes(peak))")
                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                    VStack(spacing: 3) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bucket.bytes > 0 ? p.series1 : p.track)
                            .frame(height: max(2, 54 * CGFloat(Double(bucket.bytes) / Double(peak))))
                    }
                    .frame(height: 58)
                }
            }

            HStack {
                Text(formatter.string(from: explorer.cutoff))
                    .font(.system(size: 9)).foregroundColor(p.textMuted)
                Spacer()
                Text("now").font(.system(size: 9)).foregroundColor(p.textMuted)
            }
        }
    }

    // MARK: - Drilling

    private func breadcrumbBar(p: Palette, explorer: GrowthExplorer) -> some View {
        Card {
            HStack(spacing: 5) {
                Button(action: { explorer.drillUp() }) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(explorer.currentPath == explorer.scanRoot ? p.textMuted : p.series1)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(explorer.currentPath == explorer.scanRoot)

                Divider().frame(height: 14)

                ForEach(Array(explorer.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    HStack(spacing: 5) {
                        Button(action: { explorer.drill(into: crumb.path) }) {
                            Text(crumb.name)
                                .font(.system(size: 12,
                                              weight: index == explorer.breadcrumbs.count - 1
                                                ? .semibold : .regular))
                                .foregroundColor(index == explorer.breadcrumbs.count - 1
                                                    ? p.textPrimary : p.series1)
                        }
                        .buttonStyle(PlainButtonStyle())
                        if index < explorer.breadcrumbs.count - 1 {
                            Text("›").font(.system(size: 11)).foregroundColor(p.textMuted)
                        }
                    }
                }
                Spacer()
                Button(action: { StorageScanner.reveal(explorer.currentPath) }) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundColor(p.textMuted)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func folderTable(p: Palette, explorer: GrowthExplorer) -> some View {
        let rows = explorer.childrenHere
        let peak = max(1, rows.map { $0.totalBytes }.max() ?? 1)

        return Card(padding: 0, spacing: 0) {
            HStack(spacing: 10) {
                Text("").frame(width: 20)
                Text("WHERE").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                Text("SHARE").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 90, alignment: .leading)
                Text("ADDED").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 82, alignment: .trailing)
                Text("UPDATED").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 82, alignment: .trailing)
                Text("LAST CHANGE").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)

            Divider()

            if rows.isEmpty {
                Text("No changes inside subfolders here — see the files below.")
                    .font(.system(size: 11)).foregroundColor(p.textMuted).padding(14)
            } else {
                ForEach(Array(rows.prefix(40).enumerated()), id: \.element.id) { index, row in
                    Button(action: {
                        if row.isDirectory { explorer.drill(into: row.path) }
                        else { StorageScanner.reveal(row.path) }
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                                .font(.system(size: 11)).foregroundColor(p.series1).frame(width: 20)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name)
                                    .font(.system(size: 12)).foregroundColor(p.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(row.isDirectory
                                        ? "\(row.addedCount) new, \(row.updatedCount) updated"
                                        : (row.addedCount > 0 ? "new file" : "updated"))
                                    .font(.system(size: 10)).foregroundColor(p.textMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Two-part bar: new against rewritten, always
                            // labelled by the two figures beside it.
                            GeometryReader { geo in
                                let scale = geo.size.width / CGFloat(peak)
                                HStack(spacing: 1) {
                                    Rectangle().fill(p.series2)
                                        .frame(width: max(0, CGFloat(row.addedBytes) * scale))
                                    Rectangle().fill(p.series1)
                                        .frame(width: max(0, CGFloat(row.updatedBytes) * scale))
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 7)
                                .background(p.track)
                                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                .frame(height: geo.size.height, alignment: .center)
                            }
                            .frame(width: 90, height: 18)

                            Text(row.addedBytes > 0 ? Fmt.bytes(row.addedBytes) : "—")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(row.addedBytes > 0 ? p.series2 : p.textMuted)
                                .frame(width: 82, alignment: .trailing)
                            Text(row.updatedBytes > 0 ? Fmt.bytes(row.updatedBytes) : "—")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(row.updatedBytes > 0 ? p.textPrimary : p.textMuted)
                                .frame(width: 82, alignment: .trailing)
                            Text(Fmt.relative(row.lastChange))
                                .font(.system(size: 10)).foregroundColor(p.textSecondary)
                                .frame(width: 96, alignment: .trailing)

                            if row.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold)).foregroundColor(p.textMuted)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(index % 2 == 1 ? p.track.opacity(0.28) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    if index < min(40, rows.count) - 1 { Divider().padding(.leading, 14) }
                }
            }

            HStack(spacing: 12) {
                LegendItem(color: p.series2, label: "Added", value: Fmt.bytes(explorer.addedBytesHere))
                LegendItem(color: p.series1, label: "Updated", value: Fmt.bytes(explorer.updatedBytesHere))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    private func fileTable(p: Palette, explorer: GrowthExplorer) -> some View {
        let files = showAllFiles ? explorer.biggestBeneath(limit: 60) : explorer.filesHere

        return Card(padding: 0, spacing: 0) {
            HStack {
                Text(showAllFiles ? "Biggest changed files anywhere below" : "Changed files in this folder")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Spacer()
                Button(showAllFiles ? "Only this folder" : "Show everything below") {
                    self.showAllFiles.toggle()
                }
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)

            Divider()

            if files.isEmpty {
                Text(showAllFiles ? "Nothing changed below here."
                                  : "No changed files sit directly in this folder — open a subfolder above.")
                    .font(.system(size: 11)).foregroundColor(p.textMuted).padding(14)
            } else {
                ForEach(Array(files.prefix(60).enumerated()), id: \.element.id) { index, file in
                    HStack(spacing: 10) {
                        Text(file.isNew ? "New" : "Updated")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(file.isNew ? p.series2 : p.series1)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3)
                                            .fill((file.isNew ? p.series2 : p.series1).opacity(0.14)))
                            .frame(width: 58, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name)
                                .font(.system(size: 12)).foregroundColor(p.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            if showAllFiles {
                                Text(file.displayFolder)
                                    .font(.system(size: 10)).foregroundColor(p.textMuted)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(Fmt.relative(file.modified))
                            .font(.system(size: 10)).foregroundColor(p.textSecondary)
                            .frame(width: 96, alignment: .trailing)
                        Text(Fmt.bytes(file.sizeBytes))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(p.textPrimary)
                            .frame(width: 78, alignment: .trailing)

                        Button(action: { StorageScanner.reveal(file.path) }) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundColor(p.textMuted)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(index % 2 == 1 ? p.track.opacity(0.28) : Color.clear)
                }
            }
        }
    }

    // MARK: - Snapshots

    /// Timestamps cannot show what was removed — a deleted file leaves no file
    /// behind to carry a date. Measured snapshots can, so both are kept.
    private func deletionsCard(p: Palette) -> some View {
        let movements = SnapshotStore.shared.movements()
        let shrank = movements.filter { !$0.isGrowth }.prefix(6)

        return Card {
            HStack {
                Text("Folders that shrank")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Spacer()
                Text("from measured snapshots")
                    .font(.system(size: 10)).foregroundColor(p.textMuted)
            }
            if shrank.isEmpty {
                Text("Nothing has shrunk yet. Measure a folder in Explore twice and the difference appears here — this is the one thing file timestamps cannot tell you, since a deleted file leaves nothing behind to read a date from.")
                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(shrank), id: \.id) { row in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(p.good)
                        Text(row.name).font(.system(size: 12)).foregroundColor(p.textPrimary)
                        Text(row.displayPath).font(.system(size: 10)).foregroundColor(p.textMuted)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.signedBytes(row.changeBytes))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(p.good)
                    }
                }
            }
        }
    }

    private func explainer(p: Palette) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Why this works with no history")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("Every file records when it was created and when it was last written, so growth over any period can be read straight off the disk — no prior snapshot, no background agent, nothing running while you were away. A file created inside the window counts as Added; one created earlier but rewritten inside it counts as Updated, which separates real growth from an application merely touching its own files. One pass collects the changes and every level of drill-down is grouped from that, so going deeper is instant. The one thing timestamps cannot show is deletion, which is why measured snapshots are kept alongside.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
