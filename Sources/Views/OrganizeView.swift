import SwiftUI

/// Plan-then-apply folder organisation. The plan is always shown in full before
/// anything moves, and the last run can be reversed.
struct OrganizeView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var source: String = NSHomeDirectory() + "/Downloads"
    @State private var confirmApply = false
    @State private var confirmUndo = false

    private var sourceChoices: [(String, String)] {
        let home = NSHomeDirectory()
        return [("Downloads", home + "/Downloads"),
                ("Desktop", home + "/Desktop"),
                ("Documents", home + "/Documents"),
                ("Pictures", home + "/Pictures")]
            .filter { FileManager.default.fileExists(atPath: $0.1) }
    }

    var body: some View {
        let p = Palette(scheme)
        let organizer = state.organizer

        return Page(title: "Organize",
                    subtitle: Section.organize.blurb,
                    trailing: {
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { organizer.scheme },
                                              set: { organizer.scheme = $0 })) {
                    ForEach(OrganizeScheme.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 280)
                Button(action: { organizer.plan(source: self.source) }) {
                    Text(organizer.isPlanning ? "Planning…" : "Preview plan")
                }
                .disabled(organizer.isPlanning)
            }
        }) {
            controls(p: p, organizer: organizer)

            if let result = organizer.lastResult {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13)).foregroundColor(p.good)
                        Text(result).font(.system(size: 12)).foregroundColor(p.textPrimary)
                        Spacer()
                        if organizer.canUndo {
                            Button("Undo") { self.confirmUndo = true }
                        }
                    }
                }
            }

            if !organizer.moves.isEmpty {
                summary(p: p, organizer: organizer)
                plan(p: p, organizer: organizer)
            } else if !organizer.isPlanning {
                Card {
                    EmptyState(icon: "folder.badge.gearshape",
                               title: "No plan yet",
                               message: "Pick a folder and a scheme, then Preview plan. Nothing moves until you approve it.")
                }
            }

            safetyNote(p: p, organizer: organizer)
        }
        .alert(isPresented: $confirmApply) {
            Alert(title: Text("Move \(state.organizer.selectedMoves.count) files?"),
                  message: Text("They will be moved into \(state.organizer.plannedFolders.count) folders inside \((source as NSString).lastPathComponent). Files are moved, not copied, and nothing is overwritten — a name clash gets a numbered suffix. This run can be undone."),
                  primaryButton: .default(Text("Move Files")) {
                      self.state.organizer.apply { _, _ in
                          self.state.search.rebuild()
                      }
                  },
                  secondaryButton: .cancel())
        }
        .alert(isPresented: $confirmUndo) {
            Alert(title: Text("Undo the last organize run?"),
                  message: Text(state.organizer.undoDescription.map { "Puts back \($0)." }
                                ?? "Every file from the last run goes back where it was."),
                  primaryButton: .default(Text("Put Files Back")) {
                      self.state.organizer.undoLastRun { _, _ in }
                  },
                  secondaryButton: .cancel())
        }
    }

    private func controls(p: Palette, organizer: Organizer) -> some View {
        Card {
            HStack(spacing: 7) {
                Text("Folder").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 46, alignment: .leading)
                ForEach(sourceChoices, id: \.1) { choice in
                    Button(action: { self.source = choice.1; organizer.plan(source: choice.1) }) {
                        Text(choice.0)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(self.source == choice.1 ? .white : p.series1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                            .fill(self.source == choice.1 ? p.series1 : p.series1.opacity(0.12)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
                Text(organizer.scheme.explanation)
                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
            }
        }
    }

    private func summary(p: Palette, organizer: Organizer) -> some View {
        let selected = organizer.selectedMoves
        let bytes = selected.reduce(0) { $0 + $1.sizeBytes }
        let conflicts = selected.filter { $0.conflict }.count

        return Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Files to move", value: "\(selected.count)",
                         detail: "of \(organizer.moves.count) loose files")
                Divider().frame(height: 40)
                StatTile(label: "Folders created", value: "\(organizer.plannedFolders.count)",
                         detail: "inside \((source as NSString).lastPathComponent)")
                Divider().frame(height: 40)
                StatTile(label: "Total size", value: Fmt.bytes(bytes), detail: "moved, not copied")
                Divider().frame(height: 40)
                StatTile(label: "Name clashes", value: "\(conflicts)",
                         detail: conflicts == 0 ? "none" : "will get a numbered suffix",
                         accent: conflicts > 0 ? p.serious : nil)
            }

            Divider()

            HStack(spacing: 6) {
                Text("Folders").font(.system(size: 10, weight: .semibold)).foregroundColor(p.textMuted)
                ForEach(organizer.plannedFolders.prefix(10), id: \.name) { folder in
                    Text("\(folder.name) · \(folder.count)")
                        .font(.system(size: 10))
                        .foregroundColor(p.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(p.track.opacity(0.7)))
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button("Select all") { organizer.setAllSelected(true) }
                Button("Select none") { organizer.setAllSelected(false) }
                Spacer()
                Button(action: { self.confirmApply = true }) {
                    Text("Move \(selected.count) files")
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    private func plan(p: Palette, organizer: Organizer) -> some View {
        Card(padding: 0, spacing: 0) {
            HStack(spacing: 10) {
                Text("").frame(width: 22)
                Text("FILE").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                Text("GOES TO").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 170, alignment: .leading)
                Text("SIZE").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)

            Divider()

            ForEach(Array(organizer.moves.enumerated()), id: \.element.id) { index, move in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { move.selected },
                        set: { organizer.setSelection($0, for: move.id) }))
                        .labelsHidden()
                        .frame(width: 22)

                    HStack(spacing: 6) {
                        Image(systemName: move.kind.icon)
                            .font(.system(size: 10)).foregroundColor(p.series1)
                        Text(move.name)
                            .font(.system(size: 12)).foregroundColor(p.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        if move.conflict {
                            Text("name clash")
                                .font(.system(size: 9, weight: .medium)).foregroundColor(p.serious)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(p.serious.opacity(0.14)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(p.textMuted)
                        Text(move.destinationFolder
                                .replacingOccurrences(of: self.source + "/", with: "") + "/")
                            .font(.system(size: 11)).foregroundColor(p.series1)
                            .lineLimit(1)
                    }
                    .frame(width: 170, alignment: .leading)

                    Text(Fmt.bytes(move.sizeBytes))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(p.textSecondary)
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(index % 2 == 1 ? p.track.opacity(0.28) : Color.clear)

                if index < organizer.moves.count - 1 { Divider().padding(.leading, 14) }
            }
        }
    }

    private func safetyNote(p: Palette, organizer: Organizer) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What this will and will not do")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("Only loose files in the chosen folder are moved — existing subfolders are left exactly as they are, since they usually reflect a structure you already chose. Nothing is ever overwritten: a file whose name is already taken gets a numbered suffix. Every run records where each file came from, so Undo puts them all back.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if organizer.canUndo, let description = organizer.undoDescription {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10)).foregroundColor(p.good)
                            Text("Undo available: \(description)")
                                .font(.system(size: 11, weight: .medium)).foregroundColor(p.textPrimary)
                            Button("Undo now") { self.confirmUndo = true }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }
}
