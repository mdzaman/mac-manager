import SwiftUI

/// Mirror folders to an external drive, with previous versions kept.
struct BackupView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var confirmRun = false

    var body: some View {
        let p = Palette(scheme)
        let backup = state.backup

        return Page(title: "Backup",
                    subtitle: Section.backup.blurb,
                    trailing: {
            HStack(spacing: 10) {
                Button(action: { backup.refreshVolumes() }) { Text("Find drives") }
                Button(action: { backup.preview() }) {
                    Text(backup.isScanning ? "Checking…" : "Preview")
                }
                .disabled(backup.selectedVolume == nil || backup.isScanning || backup.isRunning)
            }
        }) {
            drives(p: p, backup: backup)
            sources(p: p, backup: backup)
            options(p: p, backup: backup)

            if let summary = backup.summary {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: backup.changes.isEmpty && !backup.isRunning
                                ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 13)).foregroundColor(p.good)
                        Text(summary).font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                        Spacer()
                        if !backup.changes.isEmpty && !backup.isRunning {
                            Button(action: { self.confirmRun = true }) { Text("Back up now") }
                        }
                    }
                }
            }

            if !backup.log.isEmpty { logCard(p: p, backup: backup) }
            if !backup.changes.isEmpty { changeList(p: p, backup: backup) }

            versionsCard(p: p, backup: backup)
            safetyNote(p: p, backup: backup)
        }
        .onAppear { if backup.volumes.isEmpty { backup.refreshVolumes() } }
        .alert(isPresented: $confirmRun) {
            Alert(title: Text("Back up to \(state.backup.selectedVolume?.name ?? "drive")?"),
                  message: Text(runDescription),
                  primaryButton: .default(Text("Start Backup")) {
                      self.state.backup.run { _ in }
                  },
                  secondaryButton: .cancel())
        }
    }

    private var runDescription: String {
        let backup = state.backup
        let files = backup.pendingNew + backup.pendingUpdated
        let versions = backup.keepVersions
            ? " Files being replaced are moved into a dated versions folder first, so the previous copy is kept."
            : " Replaced files are overwritten, with no previous version kept."
        return "\(files) files will be copied.\(versions) Nothing on the drive is ever deleted."
    }

    // MARK: - Sections

    private func drives(p: Palette, backup: BackupService) -> some View {
        Card {
            Text("Destination")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)

            if backup.volumes.isEmpty {
                Text("No writable drives found. Connect an external drive and press Find drives.")
                    .font(.system(size: 12)).foregroundColor(p.textSecondary)
            } else {
                ForEach(backup.volumes) { volume in
                    Button(action: { backup.destinationVolume = volume.path }) {
                        HStack(spacing: 10) {
                            Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive")
                                .font(.system(size: 15))
                                .foregroundColor(backup.destinationVolume == volume.path ? p.series1 : p.textMuted)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(volume.name)
                                        .font(.system(size: 13, weight: .medium)).foregroundColor(p.textPrimary)
                                    Text(volume.isRemovable ? "External" : "Internal")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(volume.isRemovable ? p.good : p.textMuted)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(RoundedRectangle(cornerRadius: 3)
                                                        .fill((volume.isRemovable ? p.good : p.textMuted).opacity(0.14)))
                                    Text(volume.fileSystem)
                                        .font(.system(size: 9)).foregroundColor(p.textMuted)
                                }
                                Text("\(Fmt.bytes(volume.freeBytes)) free of \(Fmt.bytes(volume.totalBytes))")
                                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
                            }
                            Spacer()

                            if backup.destinationVolume == volume.path {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14)).foregroundColor(p.series1)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                // A drive that cannot hold extended attributes loses tags on
                // copy, so say so rather than letting it fail quietly.
                if let volume = backup.selectedVolume, !volume.preservesMetadata {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11)).foregroundColor(p.serious)
                        Text("\(volume.fileSystem) cannot store macOS permissions or tags. Your files copy fine, and tags are written alongside them as tags.json so nothing is lost — but the tags will not show in Finder on this drive.")
                            .font(.system(size: 11)).foregroundColor(p.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(p.serious.opacity(0.10)))
                }
            }
        }
    }

    private func sources(p: Palette, backup: BackupService) -> some View {
        let home = NSHomeDirectory()
        let options = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }

        return Card {
            Text("What to back up")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
            HStack(spacing: 7) {
                ForEach(options, id: \.self) { path in
                    let active = backup.sources.contains(path)
                    Button(action: {
                        if active { backup.sources.removeAll { $0 == path } }
                        else { backup.sources.append(path) }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 10))
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(active ? .white : p.series1)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(active ? p.series1 : p.series1.opacity(0.12)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }
        }
    }

    private func options(p: Palette, backup: BackupService) -> some View {
        Card {
            Toggle(isOn: Binding(get: { backup.skipBuildFolders },
                                 set: { backup.skipBuildFolders = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip build folders")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("Leaves out node_modules, caches, virtual environments and other regenerable build output. A single node_modules can hold a hundred thousand files that add nothing to a backup.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Toggle(isOn: Binding(get: { backup.keepVersions },
                                 set: { backup.keepVersions = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep previous versions")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("When a file has changed, the copy already on the drive is moved into a dated folder before the new one lands — so you can go back to how it was.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func logCard(p: Palette, backup: BackupService) -> some View {
        Card {
            HStack(spacing: 6) {
                if backup.isRunning { ProgressView().scaleEffect(0.4).frame(width: 14, height: 14) }
                Text(backup.isRunning ? "Backing up…" : "Last run")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(p.textPrimary)
                Spacer()
                if let last = backup.lastRun {
                    Text(Fmt.relative(last)).font(.system(size: 11)).foregroundColor(p.textSecondary)
                }
            }
            ForEach(Array(backup.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 11, design: .monospaced))
                    .foregroundColor(line.contains("⚠︎") ? p.critical : p.textSecondary)
            }
        }
    }

    private func changeList(p: Palette, backup: BackupService) -> some View {
        let files = backup.changes.filter { $0.action != .directory }
        let total = backup.pendingNew + backup.pendingUpdated
        return Card(padding: 0, spacing: 0) {
            HStack {
                Text("Will be copied")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Text("\(total) files")
                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)

            Divider()

            ForEach(Array(files.prefix(120).enumerated()), id: \.element.id) { index, change in
                HStack(spacing: 10) {
                    Text(change.action.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(change.action == .new ? p.good : p.series2)
                        .frame(width: 56, alignment: .leading)
                    Text(change.relativePath)
                        .font(.system(size: 11)).foregroundColor(p.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(index % 2 == 1 ? p.track.opacity(0.28) : Color.clear)
            }

            if total > 120 {
                Text("…and \(total - min(120, files.count)) more")
                    .font(.system(size: 11)).foregroundColor(p.textMuted)
                    .padding(14)
            }
        }
    }

    private func versionsCard(p: Palette, backup: BackupService) -> some View {
        let versions = backup.existingVersions()
        return Card {
            HStack {
                Text("Saved versions")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Spacer()
                if let volume = backup.selectedVolume {
                    Button("Open backup folder") {
                        StorageScanner.reveal(volume.path + "/" + BackupService.backupFolderName)
                    }
                }
            }
            if versions.isEmpty {
                Text("No previous versions yet. They appear here once a backup replaces a file that changed.")
                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
            } else {
                ForEach(versions.prefix(12), id: \.path) { version in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11)).foregroundColor(p.series1)
                        Text(version.name).font(.system(size: 12)).foregroundColor(p.textPrimary)
                        Spacer()
                        Button(action: { StorageScanner.reveal(version.path) }) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundColor(p.textMuted)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
    }

    private func safetyNote(p: Palette, backup: BackupService) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("How the backup behaves")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("It copies new and changed files onto the drive and never deletes anything there — so removing a file on your Mac does not remove it from the backup. Preview shows exactly what would be copied before a single byte moves. This is a mirror with history, not a Time Machine replacement: it does not snapshot your whole system, and a copy on a drive that lives next to your Mac is not protection against fire or theft.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
