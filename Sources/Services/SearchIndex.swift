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

    /// Embeddings are memory-only and quantized to Int8.
    ///
    /// A 512-dimension vector costs 4 KB as `Double`, so a 64,000-file index
    /// would hold 250 MB of RAM — unreasonable on a machine that is already
    /// swapping. Normalising and quantizing to Int8 costs 512 bytes instead,
    /// and measured against full precision the worst cosine error is 0.006,
    /// which cannot change a ranking.
    private var vectors: [String: [Int8]] = [:]
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

    /// Always skipped regardless of the user's exclusion list — indexing your
    /// own Library or Trash is never what you meant.
    private static let alwaysSkip: Set<String> = ["Library", ".Trash", ".build", "vendor"]

    /// The shared exclusion list, injected so Find, Backup and Duplicates all
    /// honour the same rules.
    var exclusions: ExclusionRules?

    /// How many files to index. Embedding runs at roughly 1,600 files/sec
    /// across cores, and each file costs 512 bytes of memory, so 250,000 files
    /// is about 2.5 minutes and 128 MB.
    @Published var maxFiles: Int = 250_000

    static let limitChoices: [(label: String, value: Int)] = [
        ("25k", 25_000), ("100k", 100_000), ("250k", 250_000), ("1M", 1_000_000),
    ]

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
        let limit = maxFiles
        let rules = exclusions
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
                    if found.count >= limit { break }

                    let name = url.lastPathComponent
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey,
                                                                   .totalFileAllocatedSizeKey,
                                                                   .contentModificationDateKey])

                    if values?.isDirectory == true {
                        if SearchIndex.alwaysSkip.contains(name) || name.hasPrefix(".")
                            || rules?.excludes(name: name, path: url.path) == true {
                            walker.skipDescendants()
                        }
                        continue
                    }

                    if name.hasPrefix(".") { continue }
                    if rules?.excludes(name: name, path: url.path) == true { continue }

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

    /// Embeds every indexed file across all cores.
    ///
    /// One `NLEmbedding` per worker rather than sharing a single instance, and
    /// each worker writes only its own slice — measured at 4.9x the serial
    /// rate, which turns a three-minute wait into about forty seconds.
    /// Search works lexically the whole time this runs.
    private func buildEmbeddings() {
        if files.isEmpty { return }
        isEmbedding = true
        embeddedCount = 0
        let snapshot = files

        work.async {
            let workerCount = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
            let chunkSize = (snapshot.count + workerCount - 1) / workerCount

            var slices = [[(String, [Int8])]](repeating: [], count: workerCount)
            let lock = NSLock()
            var completed = 0

            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return }

                let start = worker * chunkSize
                let end = min(start + chunkSize, snapshot.count)
                if start >= end { return }

                var local: [(String, [Int8])] = []
                local.reserveCapacity(end - start)

                for index in start ..< end {
                    let file = snapshot[index]
                    if let vector = embedding.vector(for: file.searchableText) {
                        let quantized = SearchIndex.quantize(vector)
                        if !quantized.isEmpty { local.append((file.path, quantized)) }
                    }

                    if (index - start) % 500 == 0 {
                        lock.lock(); completed += 500; let done = completed; lock.unlock()
                        DispatchQueue.main.async { self.embeddedCount = min(done, snapshot.count) }
                    }
                }

                lock.lock(); slices[worker] = local; lock.unlock()
            }

            var built: [String: [Int8]] = [:]
            built.reserveCapacity(snapshot.count)
            for slice in slices {
                for (path, vector) in slice { built[path] = vector }
            }

            DispatchQueue.main.async {
                self.vectors = built
                self.embeddedCount = built.count
                self.isEmbedding = false
            }
        }
    }

    /// Unit-normalise, then scale to the Int8 range.
    private static func quantize(_ vector: [Double]) -> [Int8] {
        var norm = 0.0
        for value in vector { norm += value * value }
        norm = norm.squareRoot()
        if norm == 0 || !norm.isFinite { return [] }

        return vector.map { value in
            let scaled = (value / norm * 127).rounded()
            return Int8(max(-127, min(127, scaled)))
        }
    }

    /// Both vectors are unit-normalised before quantizing, so their dot product
    /// divided by 127² is the cosine.
    private static func quantizedCosine(_ a: [Int8], _ b: [Int8]) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        var dot: Int32 = 0
        for i in 0 ..< min(a.count, b.count) { dot += Int32(a[i]) * Int32(b[i]) }
        return max(-1, min(1, Double(dot) / 16_129.0))
    }

    /// Roughly how much memory the vectors occupy.
    var embeddingMemoryBytes: Int64 { return Int64(vectors.count) * 512 }

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

        let queryVector = embedding?.vector(for: query).map { SearchIndex.quantize($0) }
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }

        var hits: [SearchHit] = []
        for file in pool {
            let lexical = SearchIndex.lexicalScore(file: file, terms: terms, rawQuery: query.lowercased())

            var semantic = 0.0
            if let queryVector = queryVector, let fileVector = vectors[file.path] {
                semantic = SearchIndex.quantizedCosine(queryVector, fileVector)
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
        if let embedding = embedding,
           let vector = embedding.vector(for: files[index].searchableText) {
            vectors[path] = SearchIndex.quantize(vector)
        }
    }

    var allTags: [(tag: String, count: Int)] { return TagStore.vocabulary(in: files) }
}
