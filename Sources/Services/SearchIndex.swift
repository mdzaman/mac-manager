import Foundation
import NaturalLanguage

/// Indexes your files and searches them by meaning as well as by name.
///
/// Semantic search alone is not trustworthy on short filenames — asking for
/// "work slides" can rank a holiday photo above an actual presentation, because
/// a filename carries very little text. So scoring is hybrid: lexical matching
/// on names, folders, tags and file kind, combined with embedding similarity.
/// Lexical carries the weight; semantics fill in the gaps a keyword misses.
final class SearchIndex: ObservableObject {

    @Published private(set) var files: [IndexedFile] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var isEmbedding = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var embeddedCount = 0
    @Published private(set) var lastIndexed: Date?
    @Published var roots: [String] = SearchIndex.defaultRoots

    /// Embeddings are memory-only: 512 doubles per file is far too much to
    /// write to disk for a large index, and recomputing is cheap enough.
    private var vectors: [String: [Double]] = [:]
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    private let work = DispatchQueue(label: "com.macmanager.search", qos: .userInitiated)

    /// Indexing everything is neither useful nor fast; these are the folders
    /// that hold documents a person actually looks for.
    static var defaultRoots: [String] {
        let home = NSHomeDirectory()
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Build folders and package internals are noise in a file search.
    private static let skipDirectories: Set<String> = [
        "node_modules", ".git", ".svn", "Library", ".Trash", "__pycache__",
        ".venv", "venv", "DerivedData", ".build", "Pods", ".next", "dist",
        ".cache", ".gradle", "vendor", ".terraform",
    ]

    private static let maxFiles = 25_000

    private var indexFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("MacManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }

    // MARK: - Lifecycle

    func loadIfNeeded() {
        if !files.isEmpty || isIndexing { return }
        work.async {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let data = try? Data(contentsOf: self.indexFileURL),
                  let saved = try? decoder.decode([IndexedFile].self, from: data) else { return }
            DispatchQueue.main.async {
                self.files = saved
                self.indexedCount = saved.count
                self.lastIndexed = (try? self.indexFileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                self.buildEmbeddings()
            }
        }
    }

    // MARK: - Indexing

    func rebuild() {
        if isIndexing { return }
        isIndexing = true
        indexedCount = 0
        vectors = [:]
        embeddedCount = 0

        let targets = roots
        work.async {
            var found: [IndexedFile] = []
            let fm = FileManager.default

            for root in targets {
                guard let walker = fm.enumerator(at: URL(fileURLWithPath: root),
                                                 includingPropertiesForKeys: [.isDirectoryKey,
                                                                              .totalFileAllocatedSizeKey,
                                                                              .contentModificationDateKey],
                                                 options: []) else { continue }

                for case let url as URL in walker {
                    if found.count >= SearchIndex.maxFiles { break }

                    let name = url.lastPathComponent
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey,
                                                                   .totalFileAllocatedSizeKey,
                                                                   .contentModificationDateKey])

                    if values?.isDirectory == true {
                        if SearchIndex.skipDirectories.contains(name) || name.hasPrefix(".") {
                            walker.skipDescendants()
                        }
                        continue
                    }

                    if name.hasPrefix(".") { continue }

                    found.append(IndexedFile(
                        path: url.path,
                        name: name,
                        ext: url.pathExtension,
                        sizeBytes: Int64(values?.totalFileAllocatedSize ?? 0),
                        modified: values?.contentModificationDate ?? Date(),
                        tags: TagStore.tags(of: url.path)))

                    if found.count % 500 == 0 {
                        let snapshot = found.count
                        DispatchQueue.main.async { self.indexedCount = snapshot }
                    }
                }
            }

            self.persist(found)

            DispatchQueue.main.async {
                self.files = found
                self.indexedCount = found.count
                self.lastIndexed = Date()
                self.isIndexing = false
                self.buildEmbeddings()
            }
        }
    }

    private func persist(_ files: [IndexedFile]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(files) else { return }
        try? data.write(to: indexFileURL, options: .atomic)
    }

    /// Roughly 335 files a second on Apple silicon, so a large index takes
    /// about a minute. Search works lexically while this runs.
    private func buildEmbeddings() {
        guard let embedding = embedding, !files.isEmpty else { return }
        isEmbedding = true
        let snapshot = files

        work.async {
            var built: [String: [Double]] = [:]
            built.reserveCapacity(snapshot.count)

            for (offset, file) in snapshot.enumerated() {
                if let vector = embedding.vector(for: file.searchableText) {
                    built[file.path] = vector
                }
                if offset % 250 == 0 {
                    let done = offset
                    DispatchQueue.main.async { self.embeddedCount = done }
                }
            }

            DispatchQueue.main.async {
                self.vectors = built
                self.embeddedCount = built.count
                self.isEmbedding = false
            }
        }
    }

    // MARK: - Searching

    func search(_ rawQuery: String, kind: FileKind? = nil, tag: String? = nil, limit: Int = 60) -> [SearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)

        var pool = files
        if let kind = kind { pool = pool.filter { $0.kind == kind } }
        if let tag = tag { pool = pool.filter { $0.tags.contains(tag) } }

        if query.isEmpty {
            return pool.sorted { $0.modified > $1.modified }
                .prefix(limit)
                .map { SearchHit(file: $0, score: 0, matchedOnName: false) }
        }

        let queryVector = embedding?.vector(for: query)
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }

        var hits: [SearchHit] = []
        for file in pool {
            let lexical = SearchIndex.lexicalScore(file: file, terms: terms, rawQuery: query.lowercased())

            var semantic = 0.0
            if let queryVector = queryVector, let fileVector = vectors[file.path] {
                semantic = SearchIndex.cosine(queryVector, fileVector)
            }

            // Lexical dominates because it is precise; semantics rescue the
            // cases where the words simply are not in the filename.
            let score = 0.65 * lexical + 0.35 * max(0, semantic)
            if score < 0.12 { continue }

            hits.append(SearchHit(file: file, score: score, matchedOnName: lexical > 0.3))
        }

        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// 1.0 for an exact name match, scaling down through substring and
    /// per-term hits across name, folder, tags and kind.
    private static func lexicalScore(file: IndexedFile, terms: [String], rawQuery: String) -> Double {
        if terms.isEmpty { return 0 }

        let name = file.name.lowercased()
        let folder = file.folder.lowercased()
        let tags = file.tags.joined(separator: " ").lowercased()
        let kind = file.kind.rawValue.lowercased()
        let ext = file.ext.lowercased()

        if name == rawQuery { return 1.0 }
        if name.contains(rawQuery) { return 0.9 }

        var matched = 0.0
        for term in terms {
            if name.contains(term) { matched += 1.0 }
            else if tags.contains(term) { matched += 0.85 }
            else if kind.contains(term) || ext == term { matched += 0.6 }
            else if folder.contains(term) { matched += 0.5 }
        }
        return min(1.0, matched / Double(terms.count))
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0 ..< min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denominator = na.squareRoot() * nb.squareRoot()
        return denominator == 0 ? 0 : dot / denominator
    }

    // MARK: - Tags

    /// Applies a tag to a file and updates the in-memory index to match.
    func applyTag(_ tag: String, to path: String) {
        TagStore.add(tag, to: path)
        refreshTags(for: path)
    }

    func removeTag(_ tag: String, from path: String) {
        TagStore.remove(tag, from: path)
        refreshTags(for: path)
    }

    private func refreshTags(for path: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        files[index].tags = TagStore.tags(of: path)
        persist(files)
        if let embedding = embedding {
            vectors[path] = embedding.vector(for: files[index].searchableText)
        }
    }

    var allTags: [(tag: String, count: Int)] { return TagStore.vocabulary(in: files) }
}
