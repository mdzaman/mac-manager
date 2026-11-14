import Combine
import SwiftUI

/// One owner for every service, so each tab shows the same numbers and a
/// refresh in one place is visible everywhere.
final class AppState: ObservableObject {
    let appScanner = AppScanner()
    let memory = MemoryMonitor()
    let storage = StorageScanner()
    let ports = PortScanner()
    let organizer = Organizer()
    let search = SearchIndex()
    let backup = BackupService()
    let duplicates = DuplicateFinder()
    let exclusions = ExclusionRules()
    let growth = GrowthExplorer()
    let permissions = Permissions()
    let health = HealthScanner()
    let startup = StartupManager()

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
            organizer.objectWillChange,
            search.objectWillChange,
            backup.objectWillChange,
            duplicates.objectWillChange,
            exclusions.objectWillChange,
            growth.objectWillChange,
            permissions.objectWillChange,
            health.objectWillChange,
            startup.objectWillChange,
        ]
        // One exclusion list, shared by everything that walks the disk.
        search.exclusions = exclusions
        backup.exclusions = exclusions

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
        // A few seconds in, once ports and memory have reported, so a serious
        // finding shows on the sidebar without the tab having to be opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.runHealthCheck()
        }
        backup.begin()
        backup.refreshVolumes()
        search.loadIfNeeded()
    }

    /// Gathers what the other services already know and runs the health check.
    func runHealthCheck() {
        var inputs = HealthInputs()
        inputs.ports = ports.entries
        inputs.memory = memory.snapshot
        inputs.volume = storage.volume
        inputs.reclaimableBytes = storage.reclaimableBytes
        inputs.trashBytes = storage.trashBytes
        inputs.lastBackup = backup.history.lastCompleted?.finishedAt
        inputs.hasFullDiskAccess = permissions.hasFullDiskAccess
        inputs.topMemory = Array(memory.groups.prefix(6))
        inputs.topStorage = storage.targets
            .filter { ($0.sizeBytes ?? 0) > 0 }
            .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
            .prefix(5).map { (name: $0.name, bytes: $0.sizeBytes ?? 0) }
        health.run(inputs: inputs)
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
        case .health: HealthView()
        case .startup: StartupView()
        case .apps: AppsView()
        case .memory: MemoryView()
        case .storage: StorageView()
        case .explore: ExploreView()
        case .growth: GrowthView()
        case .ports: PortsView()
        case .find: FindView()
        case .organize: OrganizeView()
        case .backup: BackupView()
        case .duplicates: DuplicatesView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// Problems that need action — critical and warning, not informational.
    private var healthBadge: Int {
        return state.health.count(.critical) + state.health.count(.warning)
    }

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

            ForEach(["System", "Files"], id: \.self) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(p.textMuted)
                        .tracking(0.6)
                        .padding(.horizontal, 18)
                        .padding(.top, group == "Files" ? 14 : 0)
                        .padding(.bottom, 4)

                    ForEach(Section.allCases.filter { $0.group == group }) { item in
                        SidebarRow(section: item, selected: self.state.section == item,
                                   badge: item == .health ? self.healthBadge : nil,
                                   badgeCritical: self.state.health.worst == .critical) {
                            self.state.section = item
                        }
                    }
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
    var badge: Int? = nil
    var badgeCritical: Bool = false
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
                if let badge = badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(badgeCritical ? p.critical : p.serious))
                }
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
