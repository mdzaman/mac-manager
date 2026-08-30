import SwiftUI

/// Review-then-confirm sheet for removing an app.
///
/// Two rules shape this screen: nothing is removed until the user has seen the
/// exact list, and nothing is ever deleted outright — every item goes to the
/// Trash, so any mistake is one "Put Back" away.
struct UninstallSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) private var scheme

    let app: InstalledApp
    let onRemoved: (String) -> Void

    @State private var leftovers: [LeftoverItem] = []
    @State private var loading = true
    @State private var working = false
    @State private var appIsRunning = false
    @State private var failures: [(String, String)] = []
    @State private var finished = false
    @State private var movedCount = 0

    var body: some View {
        let p = Palette(scheme)

        return VStack(alignment: .leading, spacing: 0) {
            headerBar(p: p)
            Divider()

            if finished {
                resultView(p: p)
            } else {
                reviewView(p: p)
                Divider()
                footer(p: p)
            }
        }
        .frame(width: 620, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear(perform: load)
    }

    // MARK: - Header

    private func headerBar(p: Palette) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.shared.icon(for: app.path))
                .resizable()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Remove \(app.name)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(p.textPrimary)
                Text("\(app.version) · \(Fmt.bytes(app.sizeBytes)) · \(app.bundleID.isEmpty ? app.path : app.bundleID)")
                    .font(.system(size: 11))
                    .foregroundColor(p.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Review

    private func reviewView(p: Palette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                if appIsRunning {
                    noticeRow(p: p,
                              icon: "exclamationmark.triangle.fill",
                              color: p.serious,
                              title: "\(app.name) is running right now",
                              message: "Quit it first so it does not rewrite its files while they are being moved.",
                              action: ("Quit \(app.name)", {
                                  AppScanner.quit(self.app)
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                      self.appIsRunning = AppScanner.isRunning(self.app)
                                  }
                              }))
                }

                Text("The application")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(p.textMuted)

                itemRow(p: p,
                        title: (app.path as NSString).lastPathComponent,
                        subtitle: app.path,
                        size: app.sizeBytes ?? 0,
                        category: app.location.rawValue,
                        binding: nil)

                HStack {
                    Text("Support files")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(p.textMuted)
                    Spacer()
                    if !leftovers.isEmpty {
                        Button(action: toggleAll) {
                            Text(allSelected ? "Deselect all" : "Select all")
                                .font(.system(size: 11))
                                .foregroundColor(p.series1)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                if loading {
                    LoadingRow(text: "Looking for files this app left behind…")
                } else if leftovers.isEmpty {
                    Text("No leftover files were found. Only the app bundle will be moved.")
                        .font(.system(size: 12))
                        .foregroundColor(p.textSecondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(leftovers.indices, id: \.self) { index in
                        itemRow(p: p,
                                title: (self.leftovers[index].path as NSString).lastPathComponent,
                                subtitle: self.leftovers[index].displayPath,
                                size: self.leftovers[index].sizeBytes,
                                category: self.leftovers[index].category,
                                binding: self.$leftovers[index].selected)
                    }

                    noticeRow(p: p,
                              icon: "info.circle.fill",
                              color: p.series1,
                              title: "Matched by bundle identifier and exact folder name",
                              message: "Anything that looked ambiguous was left out. Uncheck anything you want to keep.",
                              action: nil)
                }
            }
            .padding(16)
        }
    }

    private func itemRow(p: Palette,
                         title: String,
                         subtitle: String,
                         size: Int64,
                         category: String,
                         binding: Binding<Bool>?) -> some View {
        HStack(spacing: 9) {
            if let binding = binding {
                Toggle("", isOn: binding).labelsHidden()
            } else {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 13))
                    .foregroundColor(p.textMuted)
                    .help("The app bundle itself is always removed.")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(p.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(category)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(p.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(p.track.opacity(0.7)))

            Text(Fmt.bytes(size))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(p.textPrimary)
                .frame(width: 68, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private func noticeRow(p: Palette,
                           icon: String,
                           color: Color,
                           title: String,
                           message: String,
                           action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                Text(message).font(.system(size: 11)).foregroundColor(p.textSecondary)
            }
            Spacer()
            if let action = action {
                Button(action: action.1) { Text(action.0).font(.system(size: 11)) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }

    // MARK: - Footer

    private func footer(p: Palette) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedCount) items · \(Fmt.bytes(selectedBytes))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(p.textPrimary)
                Text("Moved to the Trash, not deleted. Empty the Trash to reclaim the space.")
                    .font(.system(size: 10))
                    .foregroundColor(p.textSecondary)
            }
            Spacer()

            Button("Cancel") { self.presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(action: performRemoval) {
                Text(working ? "Moving…" : "Move to Trash")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(working || loading)
        }
        .padding(14)
    }

    // MARK: - Result

    private func resultView(p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(failures.isEmpty ? p.good : p.serious)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failures.isEmpty
                            ? "Moved \(movedCount) items to the Trash"
                            : "Moved \(movedCount) items · \(failures.count) could not be moved")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(p.textPrimary)
                    Text("Open the Trash in Finder to put anything back, or to empty it and reclaim the space.")
                        .font(.system(size: 11))
                        .foregroundColor(p.textSecondary)
                }
            }

            if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(failures.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(self.failures[index].0)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(p.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(self.failures[index].1)
                                    .font(.system(size: 10))
                                    .foregroundColor(p.textSecondary)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(p.track.opacity(0.5)))
            }

            Spacer()

            HStack {
                Button("Open Trash") { StorageScanner.revealTrashInFinder() }
                Spacer()
                Button("Done") { self.presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Logic

    private var allSelected: Bool {
        return !leftovers.isEmpty && leftovers.allSatisfy { $0.selected }
    }

    private func toggleAll() {
        let target = !allSelected
        for index in leftovers.indices { leftovers[index].selected = target }
    }

    private var selectedLeftovers: [LeftoverItem] {
        return leftovers.filter { $0.selected }
    }

    private var selectedCount: Int { return selectedLeftovers.count + 1 }

    private var selectedBytes: Int64 {
        return (app.sizeBytes ?? 0) + selectedLeftovers.reduce(0) { $0 + $1.sizeBytes }
    }

    private func load() {
        appIsRunning = AppScanner.isRunning(app)
        AppScanner.findLeftovers(for: app) { items in
            self.leftovers = items
            self.loading = false
        }
    }

    private func performRemoval() {
        working = true
        let paths = [app.path] + selectedLeftovers.map { $0.path }

        AppScanner.moveToTrash(paths: paths) { failed in
            self.failures = failed
            self.movedCount = paths.count - failed.count
            self.working = false
            self.finished = true

            // Only drop it from the list if the bundle itself actually moved.
            let bundleFailed = failed.contains { $0.0 == self.app.path }
            if !bundleFailed { self.onRemoved(self.app.path) }
        }
    }
}
