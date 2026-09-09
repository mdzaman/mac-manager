import SwiftUI

/// Search by meaning and by name, and tag what you find.
struct FindView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var kindFilter: FileKind?
    @State private var tagFilter: String?
    @State private var taggingPath: String?
    @State private var newTag = ""

    var body: some View {
        let p = Palette(scheme)
        let hits = state.search.search(query, kind: kindFilter, tag: tagFilter)

        return Page(title: "Find",
                    subtitle: Section.find.blurb,
                    trailing: {
            HStack(spacing: 10) {
                SearchField(placeholder: "e.g. tax paperwork, holiday photos", text: $query)
                Button(action: { self.state.search.rebuild() }) {
                    Text(state.search.isIndexing ? "Indexing…" : "Rebuild index")
                }
                .disabled(state.search.isIndexing)
            }
        }) {
            status(p: p)
            filters(p: p)

            Card(padding: 0, spacing: 0) {
                header(p: p)
                Divider()

                if state.search.files.isEmpty {
                    EmptyState(icon: "sparkle.magnifyingglass",
                               title: "No index yet",
                               message: "Build an index of Desktop, Documents, Downloads, Pictures and Movies to search them.")
                } else if hits.isEmpty {
                    EmptyState(icon: "magnifyingglass",
                               title: "Nothing found",
                               message: query.isEmpty
                                ? "Type a query, or pick a type or tag."
                                : "Nothing matches “\(query)”.")
                } else {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        FindRow(hit: hit,
                                striped: index % 2 == 1,
                                onReveal: { StorageScanner.reveal(hit.file.path) },
                                onTag: { self.taggingPath = hit.file.path; self.newTag = "" },
                                onRemoveTag: { tag in
                                    self.state.search.removeTag(tag, from: hit.file.path)
                                })
                        if index < hits.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }

            explainer(p: p)
        }
        .onAppear { state.search.loadIfNeeded() }
        .sheet(item: Binding(
            get: { taggingPath.map { TagTarget(path: $0) } },
            set: { taggingPath = $0?.path })) { target in
            TagSheet(path: target.path, index: state.search)
        }
    }

    private struct TagTarget: Identifiable {
        var id: String { return path }
        let path: String
    }

    private func status(p: Palette) -> some View {
        Card {
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Files indexed", value: "\(state.search.indexedCount)",
                         detail: state.search.isIndexing ? "scanning…" : indexAge)
                Divider().frame(height: 40)
                StatTile(label: "Understood by meaning",
                         value: state.search.isEmbedding
                            ? "\(state.search.embeddedCount)" : "\(state.search.embeddedCount)",
                         detail: state.search.isEmbedding ? "building…" : "ready for semantic search")
                Divider().frame(height: 40)
                StatTile(label: "Tags in use", value: "\(state.search.allTags.count)",
                         detail: state.search.allTags.isEmpty ? "none yet" : "across your files")
                Divider().frame(height: 40)
                StatTile(label: "Results", value: "\(state.search.search(query, kind: kindFilter, tag: tagFilter).count)",
                         detail: query.isEmpty ? "most recent first" : "best match first")
            }
        }
    }

    private var indexAge: String {
        guard let last = state.search.lastIndexed else { return "never indexed" }
        return "indexed \(Fmt.relative(last).lowercased())"
    }

    private func filters(p: Palette) -> some View {
        Card {
            HStack(spacing: 6) {
                Text("Type").font(.system(size: 10, weight: .semibold)).foregroundColor(p.textMuted)
                    .frame(width: 34, alignment: .leading)
                chip(p: p, label: "All", active: kindFilter == nil) { self.kindFilter = nil }
                ForEach(FileKind.allCases.filter { $0 != .other }, id: \.rawValue) { kind in
                    chip(p: p, label: kind.rawValue, active: self.kindFilter == kind) {
                        self.kindFilter = (self.kindFilter == kind) ? nil : kind
                    }
                }
                Spacer()
            }

            if !state.search.allTags.isEmpty {
                HStack(spacing: 6) {
                    Text("Tags").font(.system(size: 10, weight: .semibold)).foregroundColor(p.textMuted)
                        .frame(width: 34, alignment: .leading)
                    chip(p: p, label: "All", active: tagFilter == nil) { self.tagFilter = nil }
                    ForEach(state.search.allTags.prefix(12), id: \.tag) { entry in
                        chip(p: p, label: "\(entry.tag) (\(entry.count))",
                             active: self.tagFilter == entry.tag) {
                            self.tagFilter = (self.tagFilter == entry.tag) ? nil : entry.tag
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func chip(p: Palette, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(active ? .white : p.series1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                                .fill(active ? p.series1 : p.series1.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func header(p: Palette) -> some View {
        HStack(spacing: 10) {
            Text("").frame(width: 20)
            Text("FILE").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(maxWidth: .infinity, alignment: .leading)
            Text("MATCH").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 96, alignment: .leading)
            Text("SIZE").font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textMuted).frame(width: 72, alignment: .trailing)
            Text("").frame(width: 86)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func explainer(p: Palette) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundColor(p.series1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("How the search works")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(p.textPrimary)
                    Text("Scoring blends two things: matching the words you typed against names, folders and tags, and comparing the meaning of your query against each file using an on-device language model. Meaning alone is not reliable on short filenames — asked for \"work slides\" it can rank a holiday photo above a real presentation — so keyword matching carries most of the weight and semantics fill the gaps. Nothing is sent anywhere; the model runs on this Mac.")
                        .font(.system(size: 11)).foregroundColor(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct FindRow: View {
    @Environment(\.colorScheme) private var scheme
    let hit: SearchHit
    let striped: Bool
    let onReveal: () -> Void
    let onTag: () -> Void
    let onRemoveTag: (String) -> Void

    var body: some View {
        let p = Palette(scheme)
        let file = hit.file

        return HStack(spacing: 10) {
            Image(systemName: file.kind.icon)
                .font(.system(size: 12)).foregroundColor(p.series1).frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13)).foregroundColor(p.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(file.displayFolder)
                        .font(.system(size: 10)).foregroundColor(p.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(file.tags, id: \.self) { tag in
                        Button(action: { self.onRemoveTag(tag) }) {
                            HStack(spacing: 2) {
                                Text(tag).font(.system(size: 9, weight: .medium))
                                Image(systemName: "xmark").font(.system(size: 6, weight: .bold))
                            }
                            .foregroundColor(p.series3)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(p.series3.opacity(0.15)))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Remove tag")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Why this matched, in words — a bare score means nothing.
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.matchedOnName ? "name / tag" : "meaning")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(hit.matchedOnName ? p.textPrimary : p.series1)
                Text(String(format: "%.0f%%", hit.score * 100))
                    .font(.system(size: 9)).foregroundColor(p.textMuted)
            }
            .frame(width: 96, alignment: .leading)

            Text(Fmt.bytes(file.sizeBytes))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(p.textSecondary)
                .frame(width: 72, alignment: .trailing)

            HStack(spacing: 5) {
                Button(action: onReveal) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundColor(p.textMuted)
                }
                .buttonStyle(PlainButtonStyle()).help("Show in Finder")
                RowButton(title: "Tag", icon: "tag", action: onTag)
            }
            .frame(width: 86, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(striped ? p.track.opacity(0.28) : Color.clear)
    }
}

/// Adding a tag writes a real Finder tag, so it shows up in Finder too.
struct TagSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) private var scheme

    let path: String
    let index: SearchIndex

    @State private var text = ""
    @State private var current: [String] = []

    var body: some View {
        let p = Palette(scheme)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Tag this file")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(p.textPrimary)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 12)).foregroundColor(p.textSecondary)
                .lineLimit(1).truncationMode(.middle)

            HStack(spacing: 6) {
                TextField("New tag", text: $text, onCommit: add)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("Add", action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !current.isEmpty {
                Text("Current tags").font(.system(size: 10, weight: .semibold)).foregroundColor(p.textMuted)
                HStack(spacing: 6) {
                    ForEach(current, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Text(tag).font(.system(size: 11))
                            Button(action: { self.remove(tag) }) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .foregroundColor(p.series3)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(p.series3.opacity(0.15)))
                    }
                    Spacer()
                }
            }

            Text("These are standard macOS tags — they appear in Finder's sidebar and survive outside this app.")
                .font(.system(size: 10)).foregroundColor(p.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            HStack {
                Spacer()
                Button("Done") { self.presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420, height: 300)
        .onAppear { current = TagStore.tags(of: path) }
    }

    private func add() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return }
        index.applyTag(trimmed, to: path)
        current = TagStore.tags(of: path)
        text = ""
    }

    private func remove(_ tag: String) {
        index.removeTag(tag, from: path)
        current = TagStore.tags(of: path)
    }
}
