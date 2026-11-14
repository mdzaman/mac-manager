import AppKit
import SwiftUI

/// Diagnosis with the fix attached: what was found, why it matters, how to do
/// it by hand, and a button that does it where that is safe.
struct HealthView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var category: HealthCategory?
    @State private var expanded: Set<String> = []
    @State private var pending: PendingFix?
    @State private var showHealthy = false

    /// A fix waiting on its confirmation.
    struct PendingFix: Identifiable {
        let id = UUID()
        let fix: HealthFix
        let finding: HealthFinding
    }

    var body: some View {
        let p = Palette(scheme)
        let health = state.health

        return Page(title: "Health",
                    subtitle: Section.health.blurb,
                    trailing: {
            Button(action: runCheck) {
                Text(health.isRunning ? "Checking…" : "Run health check")
            }
            .disabled(health.isRunning)
        }) {
            overview(p: p, health: health)
            messageBanner(p: p, health: health)
            filters(p: p, health: health)
            findingList(p: p, health: health)
            quarantineCard(p: p)
            explainer(p: p)
        }
        .onAppear { if health.lastRun == nil && !health.isRunning { runCheck() } }
        .alert(item: $pending) { item in
            Alert(title: Text(item.fix.label + "?"),
                  message: Text(item.fix.confirmation ?? ""),
                  primaryButton: item.fix.destructive
                    ? .destructive(Text(item.fix.label)) { self.perform(item.fix) }
                    : .default(Text(item.fix.label)) { self.perform(item.fix) },
                  secondaryButton: .cancel())
        }
    }

    // MARK: - Running

    private func runCheck() { state.runHealthCheck() }

    /// Buttons that only open or show something act at once. Anything that
    /// changes the Mac goes through a confirmation first.
    private func request(_ fix: HealthFix, for finding: HealthFinding) {
        if fix.confirmation == nil { perform(fix) }
        else { pending = PendingFix(fix: fix, finding: finding) }
    }

    private func perform(_ fix: HealthFix) {
        let health = state.health
        switch fix.action {
        case .openURL(let url):
            Shell.run("/usr/bin/open", [url])
        case .navigate(let section):
            state.section = section
        case .reveal(let path):
            Shell.run("/usr/bin/open", [FileManager.default.fileExists(atPath: path) ? path : NSHomeDirectory()])
        case .quitProcesses(let pids):
            MemoryMonitor.quit(pids: pids)
            health.note("Asked \(pids.count) process\(pids.count == 1 ? "" : "es") to quit.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.runCheck() }
        case .quarantine(let items):
            health.quarantine(items) { _ in self.runCheck() }
        case .trash(let paths):
            AppScanner.moveToTrash(paths: paths, useFinderFallback: false) { failures in
                health.note("Moved \(paths.count - failures.count) items to the Trash.")
                self.runCheck()
            }
        case .reclaimCaches:
            state.storage.reclaimAllSafe { moved, freed, failures in
                health.note("Moved \(moved) items — \(Fmt.bytes(freed)) — to the Trash."
                            + (failures.isEmpty ? "" : " \(failures.count) protected items were skipped."))
                self.runCheck()
            }
        }
    }

    // MARK: - Overview

    private func overview(p: Palette, health: HealthScanner) -> some View {
        let worst = health.worst
        return Card {
            HStack(alignment: .center, spacing: 14) {
                if health.isRunning {
                    ProgressView().scaleEffect(0.7).frame(width: 34, height: 34)
                } else {
                    Image(systemName: worst.icon)
                        .font(.system(size: 30))
                        .foregroundColor(color(p: p, worst))
                        .frame(width: 34)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(health.isRunning ? (health.stage.isEmpty ? "Checking…" : health.stage)
                                          : headline(health: health))
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(p.textPrimary)
                    Text(health.lastRun.map { "Checked \(Fmt.relative($0).lowercased()) · nothing is changed until you press a fix" }
                         ?? "Reads only — nothing is changed until you press a fix")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                }
                Spacer()

                HStack(spacing: 14) {
                    tally(p: p, health: health, .critical)
                    tally(p: p, health: health, .warning)
                    tally(p: p, health: health, .info)
                    tally(p: p, health: health, .ok)
                }
            }
        }
    }

    private func headline(health: HealthScanner) -> String {
        if health.findings.isEmpty { return "Not checked yet" }
        switch health.worst {
        case .critical: return "\(health.count(.critical)) problem\(health.count(.critical) == 1 ? "" : "s") need action now"
        case .warning: return "\(health.count(.warning)) thing\(health.count(.warning) == 1 ? "" : "s") need attention"
        case .info: return "Healthy, with a few things worth knowing"
        case .ok: return "Everything checked is healthy"
        }
    }

    private func tally(p: Palette, health: HealthScanner, _ severity: HealthSeverity) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: severity.icon).font(.system(size: 10))
                    .foregroundColor(color(p: p, severity))
                Text("\(health.count(severity))")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundColor(p.textPrimary)
            }
            Text(severity.label).font(.system(size: 9)).foregroundColor(p.textMuted)
        }
    }

    private func color(p: Palette, _ severity: HealthSeverity) -> Color {
        switch severity {
        case .ok: return p.good
        case .info: return p.series1
        case .warning: return p.serious
        case .critical: return p.critical
        }
    }

    @ViewBuilder
    private func messageBanner(p: Palette, health: HealthScanner) -> some View {
        if let message = health.lastFixMessage {
            Card {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(p.good)
                    Text(message).font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Spacer()
                }
            }
        }
    }

    private func filters(p: Palette, health: HealthScanner) -> some View {
        Card {
            HStack(spacing: 6) {
                chip(p: p, label: "All", icon: "square.grid.2x2", active: category == nil) { self.category = nil }
                ForEach(HealthCategory.allCases) { item in
                    self.chip(p: p,
                              label: "\(item.rawValue) \(self.issueCount(health: health, item))",
                              icon: item.icon,
                              active: self.category == item) {
                        self.category = (self.category == item) ? nil : item
                    }
                }
                Spacer()
                Toggle("Show healthy", isOn: $showHealthy).font(.system(size: 11))
            }
        }
    }

    private func issueCount(health: HealthScanner, _ item: HealthCategory) -> String {
        let count = health.findings.filter { $0.category == item && $0.severity != .ok }.count
        return count == 0 ? "" : "(\(count))"
    }

    private func chip(p: Palette, label: String, icon: String, active: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(active ? .white : p.series1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(active ? p.series1 : p.series1.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Findings

    private func visibleFindings(health: HealthScanner) -> [HealthFinding] {
        return health.findings.filter { finding in
            (category == nil || finding.category == category)
                && (showHealthy || finding.severity != .ok)
        }
    }

    @ViewBuilder
    private func findingList(p: Palette, health: HealthScanner) -> some View {
        let rows = visibleFindings(health: health)
        if rows.isEmpty && !health.isRunning && health.lastRun != nil {
            Card {
                EmptyState(icon: "checkmark.seal", title: "Nothing to fix here",
                           message: showHealthy ? "No findings in this category."
                                                : "Turn on “Show healthy” to see what passed.")
            }
        } else {
            ForEach(rows) { finding in
                HealthFindingCard(finding: finding,
                                  expanded: self.expanded.contains(finding.id)
                                    != (finding.severity == .critical),
                                  tint: self.color(p: p, finding.severity),
                                  onToggle: {
                                      if self.expanded.contains(finding.id) { self.expanded.remove(finding.id) }
                                      else { self.expanded.insert(finding.id) }
                                  },
                                  onFix: { fix in self.request(fix, for: finding) })
            }
        }
    }

    // MARK: - Quarantine

    @ViewBuilder
    private func quarantineCard(p: Palette) -> some View {
        let runs = ((try? FileManager.default.contentsOfDirectory(atPath: HealthScanner.quarantineRoot)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted(by: >)
        if !runs.isEmpty {
            Card {
                HStack {
                    Text("Quarantine").font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                    Spacer()
                    Button("Show in Finder") { Shell.run("/usr/bin/open", [HealthScanner.quarantineRoot]) }
                }
                Text("Startup files disabled from here are moved, not deleted. Each keeps its original path in its name, so putting one back means moving it to that path. Delete a folder once you are sure you do not need it.")
                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(runs.prefix(6), id: \.self) { run in
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox").font(.system(size: 10)).foregroundColor(p.textMuted)
                        Text(run).font(.system(size: 11, design: .monospaced)).foregroundColor(p.textPrimary)
                        Spacer()
                    }
                }
            }
        }
    }

    private func explainer(p: Palette) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What this cannot see").font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("Fan speeds, internal temperature sensors and SSD wear counters need root access, which this app never takes. For a complete hardware test use Apple Diagnostics: shut down, hold the power button until the startup options appear, then press Command-D. It tests the logic board, memory, battery and sensors and gives a reference code for any fault.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("How fixes work").font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("The check only reads. A fix button either opens the right settings pane, or makes a change after telling you exactly what it will do. Changes are reversible: files go to the Trash or to quarantine, processes are asked to quit rather than killed, and security settings are never switched by this app — it takes you to the switch. Where macOS needs an administrator, its own password prompt appears; the password never passes through Mac Manager.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One finding. Collapsed it shows the problem and its fix buttons; expanded
/// it adds why it matters, the manual steps, a command and the evidence.
struct HealthFindingCard: View {
    @Environment(\.colorScheme) private var scheme

    let finding: HealthFinding
    let expanded: Bool
    let tint: Color
    let onToggle: () -> Void
    let onFix: (HealthFix) -> Void

    @State private var copied = false

    var body: some View {
        let p = Palette(scheme)
        return Card {
            header(p: p)
            if expanded { details(p: p) }
        }
    }

    private func header(p: Palette) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity.icon)
                .font(.system(size: 16)).foregroundColor(tint).frame(width: 20)

            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(finding.title)
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(p.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(finding.category.rawValue)
                            .font(.system(size: 9, weight: .medium)).foregroundColor(p.textSecondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(p.track.opacity(0.7)))
                    }
                    Text(finding.summary)
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(expanded ? "Hide details" : "Why, and how to fix it")
                        .font(.system(size: 10)).foregroundColor(p.series1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            VStack(alignment: .trailing, spacing: 5) {
                ForEach(finding.fixes) { fix in
                    RowButton(title: fix.label, icon: fix.icon, destructive: fix.destructive) {
                        self.onFix(fix)
                    }
                }
            }
        }
    }

    private func details(p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            section(p: p, title: "Why it matters") {
                Text(self.finding.why)
                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !finding.rootCause.isEmpty {
                section(p: p, title: "Root cause on this Mac") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(self.finding.rootCause, id: \.self) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 9)).foregroundColor(self.tint)
                                Text(line)
                                    .font(.system(size: 11, weight: .medium)).foregroundColor(p.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }

            section(p: p, title: "How to fix it") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(self.finding.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 7) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(p.series1))
                            Text(step)
                                .font(.system(size: 11)).foregroundColor(p.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            if let command = finding.command { commandBlock(p: p, command: command) }
            if !finding.evidence.isEmpty { evidenceBlock(p: p) }
        }
        .padding(.leading, 30)
    }

    private func section<Content: View>(p: Palette, title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundColor(p.textMuted).tracking(0.6)
            content()
        }
    }

    private func commandBlock(p: Palette, command: String) -> some View {
        section(p: p, title: "Or in Terminal") {
            HStack(alignment: .top, spacing: 8) {
                Text(command)
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(p.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    self.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.copied = false }
                }) {
                    Text(copied ? "Copied" : "Copy").font(.system(size: 10))
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.track.opacity(0.5)))
        }
    }

    private func evidenceBlock(p: Palette) -> some View {
        section(p: p, title: "What was found") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(finding.evidence.prefix(12), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(p.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if finding.evidence.count > 12 {
                    Text("…and \(finding.evidence.count - 12) more")
                        .font(.system(size: 10)).foregroundColor(p.textMuted)
                }
            }
        }
    }
}
