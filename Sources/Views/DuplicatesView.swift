import SwiftUI

/// Identical copies, and files sharing a name but not their contents.
struct DuplicatesView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var expanded: Set<String> = []
    @State private var confirmTrash = false
    @State private var showExclusions = false

    var body: some View {
        let p = Palette(scheme)
        let finder = state.duplicates

        return Page(title: "Duplicates",
                    subtitle: Section.duplicates.blurb,
                    trailing: {
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { finder.minimumSizeKB },
                                              set: { finder.minimumSizeKB = $0 })) {
                    Text("10 KB+").tag(10)
                    Text("100 KB+").tag(100)
                    Text("1 MB+").tag(1024)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)
                Button(action: { self.showExclusions = true }) {
                    Text("Exclusions (\(state.exclusions.activeCount))")
                }
                Button(action: { finder.scan(rules: self.state.exclusions) }) {
                    Text(finder.isScanning ? "Scanning…" : "Scan")
                }
                .disabled(finder.isScanning)
            }
        }) {
            summary(p: p, finder: finder)

            if finder.isScanning {
                Card { LoadingRow(text: finder.stage.isEmpty ? "Scanning…" : finder.stage) }
            }

            if let note = finder.note {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12)).foregroundColor(p.series1)
                        Text(note).font(.system(size: 12)).foregroundColor(p.textPrimary)
                        Spacer()
                        Button("Open Trash") { StorageScanner.revealTrashInFinder() }
                    }
                }
            }

            if !finder.identical.isEmpty {
                actionBar(p: p, finder: finder)
                groupList(p: p, finder: finder, groups: finder.identical,
                          title: "Identical files",
                          note: "Byte-for-byte the same, whatever they are called. Keeping one copy loses nothing.")
            }

            if !finder.sameName.isEmpty {
                groupList(p: p, finder: finder, groups: finder.sameName,
                          title: "Same name, different contents",
                          note: "These share a filename but differ inside — usually versions of one document. Nothing is preselected, because they are not interchangeable.")
            }

            explainer(p: p)
        }
        .sheet(isPresented: $showExclusions) {
            ExclusionsSheet(rules: state.exclusions)
        }
        .alert(isPresented: $confirmTrash) {
            Alert(title: Text("Move \(state.duplicates.selectedFiles.count) files to the Trash?"),
                  message: Text(trashMessage),
                  primaryButton: .destructive(Text("Move to Trash")) {
                      self.state.duplicates.removeSelected { _, _ in }
                  },
                  secondaryButton: .cancel())
        }
    }

    private var trashMessage: String {
        let finder = state.duplicates
        let base = "\(Fmt.bytes(finder.selectedBytes)) will be moved to the Trash. Nothing is deleted until you empty it."
        if finder.wouldDeleteEverythingSomewhere {
            return "⚠︎ In at least one group you have selected every copy, which removes that file completely rather than deduplicating it.\n\n" + base
        }
        return base
    }

    private func summary(p: Palette, finder: DuplicateFinder) -> some View {
        Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Identical groups", value: "\(finder.identical.count)",
                         detail: finder.lastScan == nil ? "not scanned yet" : "wasting space")
                Divider().frame(height: 40)
                StatTile(label: "Space you could reclaim",
                         value: Fmt.bytes(finder.totalReclaimable),
                         detail: "keeping one copy of each",
                         accent: finder.totalReclaimable > 0 ? p.good : nil)
                Divider().frame(height: 40)
                StatTile(label: "Same-name conflicts", value: "\(finder.sameName.count)",
                         detail: finder.sameName.isEmpty ? "none" : "review individually",
                         accent: finder.sameName.isEmpty ? nil : p.serious)
                Divider().frame(height: 40)
                StatTile(label: "Files compared", value: "\(finder.filesScanned)",
                         detail: finder.lastScan.map { "scanned \(Fmt.relative($0).lowercased())" } ?? "—")
            }
        }
    }

    private func actionBar(p: Palette, finder: DuplicateFinder) -> some View {
        Card {
            HStack(spacing: 8) {
                Text("Select").font(.system(size: 11, weight: .semibold)).foregroundColor(p.textMuted)
                Button("Keep newest of each") { finder.keepNewestInIdenticalGroups() }
                Button("Keep oldest of each") { finder.keepOldestInIdenticalGroups() }
                Button("Clear") { finder.clearSelection() }
                Spacer()
                Text("\(finder.selectedFiles.count) selected · \(Fmt.bytes(finder.selectedBytes))")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                Button(action: { self.confirmTrash = true }) { Text("Move to Trash") }
                    .disabled(finder.selectedFiles.isEmpty)
            }
        }
    }

    private func groupList(p: Palette, finder: DuplicateFinder,
                           groups: [DuplicateGroup], title: String, note: String) -> some View {
        Card(padding: 0, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Text(note).font(.system(size: 11)).foregroundColor(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)

            Divider()

            ForEach(Array(groups.prefix(60).enumerated()), id: \.element.id) { index, group in
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: {
                        if self.expanded.contains(group.key) { self.expanded.remove(group.key) }
                        else { self.expanded.insert(group.key) }
                    }) {
                        HStack(spacing: 9) {
                            Image(systemName: self.expanded.contains(group.key)
                                    ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(p.textMuted).frame(width: 12)

                            Text(group.files.first?.name ?? group.key)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(p.textPrimary)
                                .lineLimit(1).truncationMode(.middle)

                            Text("\(group.files.count) copies")
                                .font(.system(size: 10)).foregroundColor(p.textMuted)

                            if group.selectedCount > 0 {
                                Text("\(group.selectedCount) selected")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(group.wouldDeleteAll ? p.critical : p.series1)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3)
                                                    .fill((group.wouldDeleteAll ? p.critical : p.series1).opacity(0.14)))
                            }

                            Spacer()

                            if group.kind == .identical {
                                Text("frees \(Fmt.bytes(group.reclaimableBytes))")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundColor(p.good)
                            } else {
                                Text(Fmt.bytes(group.unitBytes))
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundColor(p.textSecondary)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    if self.expanded.contains(group.key) {
                        ForEach(group.files) { file in
                            HStack(spacing: 9) {
                                Toggle("", isOn: Binding(
                                    get: { file.selected },
                                    set: { finder.setSelection($0, groupKey: group.key, path: file.path) }))
                                    .labelsHidden().frame(width: 20)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name)
                                        .font(.system(size: 11)).foregroundColor(p.textPrimary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(file.displayFolder)
                                        .font(.system(size: 10)).foregroundColor(p.textMuted)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if file.path == group.newest?.path {
                                    Text("newest")
                                        .font(.system(size: 9, weight: .medium)).foregroundColor(p.good)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(p.good.opacity(0.14)))
                                }

                                Text(Fmt.relative(file.modified))
                                    .font(.system(size: 10)).foregroundColor(p.textSecondary)
                                    .frame(width: 92, alignment: .trailing)
                                Text(Fmt.bytes(file.sizeBytes))
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(p.textSecondary)
                                    .frame(width: 68, alignment: .trailing)

                                Button(action: { StorageScanner.reveal(file.path) }) {
                                    Image(systemName: "folder").font(.system(size: 10))
                                        .foregroundColor(p.textMuted)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.leading, 30).padding(.trailing, 14).padding(.vertical, 4)
                            .background(p.track.opacity(0.2))
                        }
                    }
                }

                if index < min(60, groups.count) - 1 { Divider().padding(.leading, 14) }
            }

            if groups.count > 60 {
                Text("…and \(groups.count - 60) more groups")
                    .font(.system(size: 11)).foregroundColor(p.textMuted).padding(14)
            }
        }
    }

    private func explainer(p: Palette) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("How duplicates are found")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("Files are compared by content, not by name. Three passes, cheapest first: group by exact size, then compare the first 64 KB, then hash the whole file for anything still matching — so two files are only ever called identical after every byte has been checked. Files sharing a name but differing inside are listed separately, because those are versions rather than duplicates and deleting the wrong one loses work. Nothing is preselected there, and everything you remove goes to the Trash.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
