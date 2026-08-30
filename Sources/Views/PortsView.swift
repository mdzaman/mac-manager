import SwiftUI

struct PortsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var confirmQuit: PortEntry?

    var body: some View {
        let p = Palette(scheme)
        let rows = filteredEntries

        return Page(title: "Ports",
                    subtitle: Section.ports.blurb,
                    trailing: {
            HStack(spacing: 10) {
                SearchField(placeholder: "Search port or process", text: $query)
                Button(action: { self.state.ports.refresh() }) { Text("Refresh") }
            }
        }) {
            summary(p: p)

            Card(padding: 0, spacing: 0) {
                header(p: p)
                Divider()

                if state.ports.isScanning && rows.isEmpty {
                    LoadingRow(text: "Checking which ports are open…")
                } else if rows.isEmpty {
                    EmptyState(icon: "network",
                               title: "No listening ports",
                               message: "Nothing on this Mac is currently accepting TCP connections.")
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        PortRow(entry: entry,
                                striped: index % 2 == 1,
                                onQuit: { self.confirmQuit = entry })
                        if index < rows.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }

            Card {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12)).foregroundColor(p.series1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("What you are seeing")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(p.textPrimary)
                        Text("Only TCP ports in the LISTEN state, and only processes your account can see — ports owned by root or another user are hidden unless Mac Manager is run with elevated privileges. “All interfaces” means other devices on your network can reach that port; “localhost only” means nothing outside this Mac can.")
                            .font(.system(size: 11))
                            .foregroundColor(p.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .alert(item: $confirmQuit) { entry in
            Alert(title: Text("Quit \(entry.processName)?"),
                  message: Text("Process \(entry.pid) is listening on port \(entry.port). It will be asked to shut down, which frees the port. Unsaved work in that process may be lost."),
                  primaryButton: .destructive(Text("Quit Process")) {
                      MemoryMonitor.quit(pids: [entry.pid])
                      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                          self.state.ports.refresh()
                      }
                  },
                  secondaryButton: .cancel())
        }
    }

    private func summary(p: Palette) -> some View {
        let entries = state.ports.entries
        let exposed = entries.filter { $0.isExposed }
        let processes = Set(entries.map { $0.pid }).count

        return Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Listening ports", value: "\(entries.count)",
                         detail: "across \(processes) process\(processes == 1 ? "" : "es")")
                Divider().frame(height: 40)
                StatTile(label: "Reachable on your network", value: "\(exposed.count)",
                         detail: exposed.isEmpty ? "nothing is exposed" : "bound to all interfaces",
                         accent: exposed.isEmpty ? p.good : p.serious)
                Divider().frame(height: 40)
                StatTile(label: "Localhost only", value: "\(entries.count - exposed.count)",
                         detail: "not reachable from outside")
            }
        }
    }

    private func header(p: Palette) -> some View {
        HStack(spacing: 10) {
            Text("PORT").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 62, alignment: .leading)
            Text("PROCESS").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(maxWidth: .infinity, alignment: .leading)
            Text("BOUND TO").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 150, alignment: .leading)
            Text("PID").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 56, alignment: .trailing)
            Text("").frame(width: 78)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var filteredEntries: [PortEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return state.ports.entries }
        return state.ports.entries.filter {
            "\($0.port)".contains(trimmed)
                || $0.processName.localizedCaseInsensitiveContains(trimmed)
                || ($0.serviceHint ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }
}

struct PortRow: View {
    @Environment(\.colorScheme) private var scheme
    let entry: PortEntry
    let striped: Bool
    let onQuit: () -> Void

    var body: some View {
        let p = Palette(scheme)

        return HStack(spacing: 10) {
            Text("\(entry.port)")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(p.textPrimary)
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.processName)
                    .font(.system(size: 13))
                    .foregroundColor(p.textPrimary)
                    .lineLimit(1)
                Text(entry.serviceHint ?? entry.networkProtocol)
                    .font(.system(size: 10))
                    .foregroundColor(p.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Exposure is a state, so it gets the status ramp — always with
            // its icon and its wording, never colour on its own.
            HStack(spacing: 5) {
                Image(systemName: entry.isExposed ? "globe" : "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(entry.isExposed ? p.serious : p.good)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.scopeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(p.textPrimary)
                    Text(entry.address)
                        .font(.system(size: 9))
                        .foregroundColor(p.textMuted)
                }
            }
            .frame(width: 150, alignment: .leading)

            Text("\(entry.pid)")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(p.textSecondary)
                .frame(width: 56, alignment: .trailing)

            RowButton(title: "Quit", icon: "xmark", destructive: true, action: onQuit)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(striped ? p.track.opacity(0.28) : Color.clear)
    }
}
