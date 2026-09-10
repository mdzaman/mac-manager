import SwiftUI

/// Mirror folders to an external drive, with previous versions kept.
struct BackupView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var confirmRun = false
    @State private var showExclusions = false

    var body: some View {
        let p = Palette(scheme)
        let backup = state.backup

        return Page(title: "Backup",
                    subtitle: Section.backup.blurb,
                    trailing: {
            HStack(spacing: 10) {
                Button(action: { self.showExclusions = true }) {
                    Text("Exclusions (\(self.state.exclusions.activeCount))")
                }
                Button(action: { backup.refreshVolumes() }) { Text("Find drives") }
                Button(action: { backup.preview() }) {
                    Text(backup.isScanning ? "Checking…" : "Preview")
                }
                .disabled(backup.selectedVolume == nil || backup.isScanning || backup.isRunning)
            }
        }) {
            interruptionSection(p: p, backup: backup)
            drives(p: p, backup: backup)
            sources(p: p, backup: backup)
            options(p: p, backup: backup)
            summarySection(p: p, backup: backup)
            progressSection(p: p, backup: backup)
            versionsCard(p: p, backup: backup)
            stateHealthCard(p: p)
            safetyNote(p: p, backup: backup)
        }
        .onAppear { if backup.volumes.isEmpty { backup.refreshVolumes() } }
        .sheet(isPresented: $showExclusions) { ExclusionsSheet(rules: self.state.exclusions) }
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

    @ViewBuilder
    private func interruptionSection(p: Palette, backup: BackupService) -> some View {
        if let interrupted = backup.resumable {
            resumeBanner(p: p, backup: backup, job: interrupted)
        } else if let reason = backup.interruptionReason {
            noticeBanner(p: p, text: reason)
        }
    }

    @ViewBuilder
    private func summarySection(p: Palette, backup: BackupService) -> some View {
        if let summary = backup.summary {
            Card {
                HStack(spacing: 8) {
                    Image(systemName: backup.changes.isEmpty && !backup.isRunning
                            ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 13)).foregroundColor(p.good)
                    Text(summary).font(.system(size: 12, weight: .medium))
                        .foregroundColor(p.textPrimary)
                    Spacer()
                    if !backup.changes.isEmpty && !backup.isRunning {
                        Button(action: { self.confirmRun = true }) { Text("Back up now") }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func progressSection(p: Palette, backup: BackupService) -> some View {
        if backup.isRunning || backup.lastRun != nil || !backup.log.isEmpty {
            progressCard(p: p, backup: backup)
        }
        if !backup.sourceStates.isEmpty { sourceStatesCard(p: p, backup: backup) }
        if !backup.changes.isEmpty { changeList(p: p, backup: backup) }
    }

    /// Shown when a previous run did not finish. Resuming skips folders that
    /// completed and lets rsync skip files that already match, so it costs a
    /// scan rather than a re-copy.
    private func resumeBanner(p: Palette, backup: BackupService, job: BackupJob) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 20)).foregroundColor(p.serious)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unfinished backup to \(job.volumeName)")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                    Text(job.lastMessage ?? "This backup did not finish.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                    Text("\(job.describeProgress) · \(Fmt.bytes(job.copiedBytes)) copied · started \(Fmt.relative(job.startedAt).lowercased())")
                        .font(.system(size: 11)).foregroundColor(p.textMuted)

                    HStack(spacing: 5) {
                        ForEach(job.sources, id: \.path) { source in
                            Text(source.name)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(source.state == .done ? p.good : p.textSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3)
                                                .fill((source.state == .done ? p.good : p.textMuted).opacity(0.14)))
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer()
                VStack(spacing: 6) {
                    Button(action: { backup.resume { _ in } }) { Text("Resume") }
                        .disabled(!FileManager.default.fileExists(atPath: job.volumePath) || backup.isRunning)
                    Button("Discard") { backup.dismissResume() }
                }
            }
        }
    }

    private func noticeBanner(p: Palette, text: String) -> some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundColor(p.serious)
                Text(text).font(.system(size: 12)).foregroundColor(p.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
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

    /// Live progress: overall bar, the file in flight, throughput and ETA.
    private func progressCard(p: Palette, backup: BackupService) -> some View {
        Card {
            HStack(spacing: 8) {
                if backup.isRunning {
                    ProgressView().scaleEffect(0.45).frame(width: 16, height: 16)
                }
                Text(backup.isRunning ? "Backing up" : "Last run")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Spacer()
                if backup.isRunning {
                    Text(Fmt.percent(backup.progress))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(p.series1)
                } else if let last = backup.lastRun {
                    Text(Fmt.relative(last)).font(.system(size: 11)).foregroundColor(p.textSecondary)
                }
            }

            // Progress is measured in bytes, not files: one file can be a
            // gigabyte and the next a kilobyte, so a file-count bar lies.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(p.track).frame(height: 10)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(backup.isRunning ? p.series1 : p.good)
                        .frame(width: max(4, geo.size.width * CGFloat(backup.progress)), height: 10)
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(height: 14)

            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Files copied",
                         value: "\(backup.copiedFiles)",
                         detail: "of \(backup.pendingNew + backup.pendingUpdated) to copy")
                Divider().frame(height: 38)
                StatTile(label: "Data copied",
                         value: Fmt.bytes(backup.copiedBytes),
                         detail: "of \(Fmt.bytes(backup.totalPendingBytes))")
                Divider().frame(height: 38)
                StatTile(label: "Speed",
                         value: backup.bytesPerSecond > 0
                            ? Fmt.bytes(Int64(backup.bytesPerSecond)) + "/s" : "—",
                         detail: backup.isRunning ? "current transfer rate" : "finished")
                Divider().frame(height: 38)
                StatTile(label: "Remaining",
                         value: backup.estimatedRemaining.map { BackupView.duration($0) } ?? "—",
                         detail: backup.isRunning ? "estimated" : "done")
            }

            if let file = backup.currentFile {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.doc.on.clipboard")
                        .font(.system(size: 10)).foregroundColor(p.series1)
                    Text(file)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(p.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.track.opacity(0.5)))
            }

            if !backup.log.isEmpty {
                Divider()
                ForEach(Array(backup.log.suffix(6).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced))
                        .foregroundColor(line.contains("⚠︎") ? p.critical : p.textSecondary)
                }
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return String(format: "%.0fm %02.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.0fh %02.0fm", seconds / 3600, (seconds / 60).truncatingRemainder(dividingBy: 60))
    }

    /// Source against target, folder by folder, so the two sides can be
    /// compared without leaving the screen.
    private func sourceStatesCard(p: Palette, backup: BackupService) -> some View {
        Card(padding: 0, spacing: 0) {
            HStack {
                Text("This Mac vs the drive")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)

            HStack(spacing: 10) {
                Text("FOLDER").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 96, alignment: .leading)
                Text("ON THIS MAC").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 130, alignment: .leading)
                Text("ON THE DRIVE").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 130, alignment: .leading)
                Text("TO COPY").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 120, alignment: .leading)
                Text("PROGRESS").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                Text("STATUS").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(p.textMuted).frame(width: 78, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.bottom, 7)

            Divider()

            ForEach(Array(backup.sourceStates.enumerated()), id: \.element.id) { index, state in
                HStack(spacing: 10) {
                    Text(state.name)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                        .frame(width: 96, alignment: .leading).lineLimit(1)

                    sideColumn(p: p, files: state.sourceFiles, bytes: state.sourceBytes)
                        .frame(width: 130, alignment: .leading)
                    sideColumn(p: p, files: state.targetFiles, bytes: state.targetBytes)
                        .frame(width: 130, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.pendingFiles == 0 ? "nothing" : "\(state.pendingFiles) files")
                            .font(.system(size: 11))
                            .foregroundColor(state.pendingFiles == 0 ? p.good : p.textPrimary)
                        if state.pendingBytes > 0 {
                            Text(Fmt.bytes(state.pendingBytes))
                                .font(.system(size: 9)).foregroundColor(p.textMuted)
                        }
                    }
                    .frame(width: 120, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(p.track).frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(state.status == .failed ? p.critical
                                        : (state.status == .done ? p.good : p.series1))
                                .frame(width: max(2, geo.size.width * CGFloat(state.progress)), height: 6)
                        }
                        .frame(height: geo.size.height, alignment: .center)
                    }
                    .frame(height: 18)
                    .frame(maxWidth: .infinity)

                    Text(state.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(statusColor(p: p, status: state.status))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3)
                                        .fill(statusColor(p: p, status: state.status).opacity(0.14)))
                        .frame(width: 78, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(index % 2 == 1 ? p.track.opacity(0.28) : Color.clear)

                if index < backup.sourceStates.count - 1 { Divider().padding(.leading, 14) }
            }
        }
    }

    private func sideColumn(p: Palette, files: Int?, bytes: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let files = files {
                Text("\(files) files").font(.system(size: 11)).foregroundColor(p.textPrimary)
                Text(Fmt.bytes(bytes)).font(.system(size: 9)).foregroundColor(p.textMuted)
            } else {
                Text("measuring…").font(.system(size: 10)).foregroundColor(p.textMuted)
            }
        }
    }

    private func statusColor(p: Palette, status: BackupSourceState.Status) -> Color {
        switch status {
        case .done: return p.good
        case .failed: return p.critical
        case .running: return p.series1
        case .measuring: return p.series2
        default: return p.textMuted
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

    /// What the app has remembered, and whether it is readable.
    ///
    /// Every one of these is written atomically with a previous-good copy kept
    /// alongside, so a crash or power loss mid-write leaves the old file intact
    /// rather than a truncated one.
    private func stateHealthCard(p: Palette) -> some View {
        let files = StateStore.health().filter { $0.exists }
        let quarantined = StateStore.quarantinedFiles()

        return Card {
            HStack {
                Text("Saved state")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                Spacer()
                Button("Show in Finder") { StorageScanner.reveal(StateStore.directory.path) }
            }

            if files.isEmpty {
                Text("Nothing saved yet.").font(.system(size: 11)).foregroundColor(p.textMuted)
            } else {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        Image(systemName: file.readable ? "checkmark.circle.fill"
                                                        : "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(file.readable ? p.good : p.critical)
                        Text(file.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(p.textPrimary)
                        if file.hasBackup {
                            Text("has backup")
                                .font(.system(size: 9)).foregroundColor(p.textMuted)
                        }
                        Spacer()
                        Text(Fmt.bytes(file.sizeBytes))
                            .font(.system(size: 10, design: .rounded)).foregroundColor(p.textSecondary)
                        Text(Fmt.relative(file.modified))
                            .font(.system(size: 10)).foregroundColor(p.textMuted)
                            .frame(width: 90, alignment: .trailing)
                    }
                }
            }

            if !quarantined.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundColor(p.serious)
                    Text("\(quarantined.count) damaged file\(quarantined.count == 1 ? "" : "s") were set aside rather than deleted.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                    Spacer()
                    Button("Clear them") { StateStore.clearQuarantine() }
                }
            }

            Text("Each of these is written atomically with the previous version kept beside it, so losing power mid-write leaves the old file intact rather than a half-written one. A file that cannot be read is restored from its backup automatically.")
                .font(.system(size: 10)).foregroundColor(p.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func safetyNote(p: Palette, backup: BackupService) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("How the backup behaves")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("A run is journalled to disk as it goes, so an interrupted backup — the drive unplugged, the Mac asleep or shut down — can carry on from where it stopped rather than starting over. Folders that finished are skipped, and within a folder rsync skips files that already match, so resuming costs a scan rather than a re-copy. It copies new and changed files onto the drive and never deletes anything there — so removing a file on your Mac does not remove it from the backup. Preview shows exactly what would be copied before a single byte moves. This is a mirror with history, not a Time Machine replacement: it does not snapshot your whole system, and a copy on a drive that lives next to your Mac is not protection against fire or theft.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
