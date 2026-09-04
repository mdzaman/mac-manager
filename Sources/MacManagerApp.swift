import Combine
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case dashboard = "Overview"
    case apps = "Applications"
    case memory = "Memory"
    case storage = "Storage"
    case explore = "Explore"
    case growth = "Growth"
    case ports = "Ports"

    var id: String { return rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge"
        case .apps: return "square.grid.2x2"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .explore: return "eye.slash"
        case .growth: return "chart.line.uptrend.xyaxis"
        case .ports: return "network"
        }
    }

    var blurb: String {
        switch self {
        case .dashboard: return "How this Mac is doing right now."
        case .apps: return "Everything installed, what it costs you, and how to remove it cleanly."
        case .memory: return "What is using your memory, grouped by app."
        case .storage: return "Where your disk space went, and what is safe to reclaim."
        case .explore: return "Drill into any folder — including the hidden ones Finder will not show you."
        case .growth: return "What grew, what shrank, and which files changed recently."
        case .ports: return "Which programs are listening for network connections."
        }
    }
}

/// One owner for every service, so each tab shows the same numbers and a
/// refresh in one place is visible everywhere.
final class AppState: ObservableObject {
    let appScanner = AppScanner()
    let memory = MemoryMonitor()
    let storage = StorageScanner()
    let ports = PortScanner()

    @Published var section: Section = .dashboard

    private var started = false
    private var forwarding: [AnyCancellable] = []

    init() {
        // Nested ObservableObjects do not republish through their owner, so a
        // @Published change inside a service would otherwise never redraw the
        // view observing AppState. Forward each service's signal upward.
        let sources: [ObservableObjectPublisher] = [
            appScanner.objectWillChange,
            memory.objectWillChange,
            storage.objectWillChange,
            ports.objectWillChange,
        ]
        for source in sources {
            source
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &forwarding)
        }
    }

    func startIfNeeded() {
        if started { return }
        started = true
        appScanner.refresh()
        storage.refresh()
        memory.start()
        ports.start()
    }

    func refreshAll() {
        appScanner.refresh()
        storage.refresh()
        memory.refresh()
        ports.refresh()
    }
}

@main
struct MacManagerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Mac Manager") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1000, idealWidth: 1140, minHeight: 640, idealHeight: 780)
                .onAppear { state.startIfNeeded() }
        }
        .windowToolbarStyle(UnifiedWindowToolbarStyle(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Button("Refresh Everything") { state.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.section {
        case .dashboard: DashboardView()
        case .apps: AppsView()
        case .memory: MemoryView()
        case .storage: StorageView()
        case .explore: ExploreView()
        case .growth: GrowthView()
        case .ports: PortsView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(p.series1)
                Text("Mac Manager")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(p.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            ForEach(Section.allCases) { item in
                SidebarRow(section: item, selected: state.section == item) {
                    state.section = item
                }
            }

            Spacer()

            Button(action: { self.state.refreshAll() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    Text("Refresh").font(.system(size: 12))
                }
                .foregroundColor(p.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Re-scan apps, memory, storage and ports (Command-R)")
        }
        .frame(width: 194)
        .background(Color(NSColor.underPageBackgroundColor))
    }
}

struct SidebarRow: View {
    @Environment(\.colorScheme) private var scheme
    let section: Section
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let p = Palette(scheme)
        return Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 12))
                    .frame(width: 17)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundColor(selected ? .white : p.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? p.series1 : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Shared page frame: title, optional trailing controls, scrolling body.
struct Page<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    let trailing: () -> Trailing
    let content: () -> Content

    init(title: String,
         subtitle: String,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                SectionTitle(text: title, subtitle: subtitle)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14, content: content)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
            }
        }
    }
}
