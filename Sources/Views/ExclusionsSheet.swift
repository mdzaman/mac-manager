import SwiftUI

/// The shared exclusion list, editable in one place because it applies
/// everywhere the app walks the disk: search indexing, backup, and duplicate
/// detection.
struct ExclusionsSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) private var scheme

    @ObservedObject var rules: ExclusionRules
    @State private var newPattern = ""

    var body: some View {
        let p = Palette(scheme)

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What to leave out")
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(p.textPrimary)
                Text("Applies to search indexing, backups and duplicate scans. \(rules.activeCount) rules active.")
                    .font(.system(size: 11)).foregroundColor(p.textSecondary)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(rules.groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(p.textMuted).tracking(0.6)

                            ForEach(self.rules.rules.filter { $0.group == group }) { rule in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(
                                        get: { rule.enabled },
                                        set: { self.rules.setEnabled($0, for: rule) }))
                                        .labelsHidden()

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(rule.pattern)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(p.textPrimary)
                                        Text(rule.note)
                                            .font(.system(size: 10)).foregroundColor(p.textSecondary)
                                    }
                                    Spacer()

                                    if rule.group == "Yours" {
                                        Button(action: { self.rules.remove(rule) }) {
                                            Image(systemName: "trash").font(.system(size: 10))
                                                .foregroundColor(p.critical)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Add a pattern — node_modules, *.iso, or /Archive/",
                              text: $newPattern, onCommit: add)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("Add", action: add)
                        .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("A bare name matches any folder or file called that. `*.ext` matches an extension. Anything containing a slash matches that part of a path.")
                    .font(.system(size: 10)).foregroundColor(p.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Restore recommended") { self.rules.restoreRecommended() }
                    Spacer()
                    Button("Done") { self.presentationMode.wrappedValue.dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func add() {
        rules.add(pattern: newPattern)
        newPattern = ""
    }
}
