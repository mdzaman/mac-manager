import Foundation

/// Proposes a folder structure for a messy folder, and applies it only after
/// the user has seen every move.
///
/// Two rules make this safe to use on real files: nothing moves until the plan
/// has been reviewed, and every applied run writes an undo record so the whole
/// thing can be put back exactly where it was.
final class Organizer: ObservableObject {

    @Published private(set) var moves: [OrganizeMove] = []
    @Published private(set) var isPlanning = false
    @Published private(set) var sourcePath: String = NSHomeDirectory() + "/Downloads"
    @Published private(set) var lastResult: String?
    @Published private(set) var canUndo = false

    @Published var scheme: OrganizeScheme = .byKind

    private let work = DispatchQueue(label: "com.macmanager.organizer", qos: .userInitiated)

    static let undoFileName = "last-organize.json"
    private var undoURL: URL { return StateStore.url(Organizer.undoFileName) }

    init() {
        canUndo = FileManager.default.fileExists(atPath: undoURL.path)
    }

    // MARK: - Planning

    /// Builds the proposed moves. Nothing touches the disk here.
    func plan(source: String) {
        if isPlanning { return }
        isPlanning = true
        sourcePath = source
        moves = []
        lastResult = nil

        let scheme = self.scheme
        work.async {
            let planned = Organizer.buildPlan(source: source, scheme: scheme)
            DispatchQueue.main.async {
                self.moves = planned
                self.isPlanning = false
            }
        }
    }

    private static func buildPlan(source: String, scheme: OrganizeScheme) -> [OrganizeMove] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .isHiddenKey]

        guard let children = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: source),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]) else { return [] }

        let calendar = Calendar.current
        var planned: [OrganizeMove] = []

        for url in children {
            let values = try? url.resourceValues(forKeys: Set(keys))

            // Only loose files are organized. Existing folders are left alone —
            // they usually represent a structure the user already chose.
            if values?.isDirectory == true { continue }
            if values?.isHidden == true { continue }

            let name = url.lastPathComponent
            let ext = url.pathExtension
            let kind = FileKind.of(extension: ext)
            let modified = values?.contentModificationDate ?? Date()

            let folder: String
            switch scheme {
            case .byKind:
                folder = kind.rawValue
            case .byKindAndYear:
                let year = calendar.component(.year, from: modified)
                folder = "\(kind.rawValue)/\(year)"
            case .byYearAndMonth:
                let year = calendar.component(.year, from: modified)
                let month = calendar.component(.month, from: modified)
                let names = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]
                let monthName = names[max(0, min(11, month - 1))]
                folder = String(format: "%d/%02d-%@", year, month, monthName)
            }

            let destination = source + "/" + folder + "/" + name
            planned.append(OrganizeMove(
                sourcePath: url.path,
                destinationPath: destination,
                kind: kind,
                sizeBytes: Int64(values?.totalFileAllocatedSize ?? 0),
                modified: modified,
                selected: true,
                conflict: fm.fileExists(atPath: destination)))
        }

        return planned.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func setSelection(_ selected: Bool, for id: String) {
        guard let index = moves.firstIndex(where: { $0.id == id }) else { return }
        moves[index].selected = selected
    }

    func setAllSelected(_ selected: Bool) {
        for index in moves.indices { moves[index].selected = selected }
    }

    func setSelected(_ selected: Bool, kind: FileKind) {
        for index in moves.indices where moves[index].kind == kind {
            moves[index].selected = selected
        }
    }

    var selectedMoves: [OrganizeMove] { return moves.filter { $0.selected } }

    /// Folders that would be created, with how many files land in each.
    var plannedFolders: [(name: String, count: Int, bytes: Int64)] {
        var groups: [String: (Int, Int64)] = [:]
        for move in selectedMoves {
            let folder = move.destinationFolder
            let short = folder.replacingOccurrences(of: sourcePath + "/", with: "")
            let current = groups[short] ?? (0, 0)
            groups[short] = (current.0 + 1, current.1 + move.sizeBytes)
        }
        return groups.map { (name: $0.key, count: $0.value.0, bytes: $0.value.1) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Applying

    /// Moves the selected files. A file that would overwrite something gets a
    /// numbered suffix rather than replacing it.
    func apply(completion: @escaping (Int, [String]) -> Void) {
        let batch = selectedMoves
        if batch.isEmpty { completion(0, []); return }

        work.async {
            let fm = FileManager.default
            var undo: [String: String] = [:]
            var failures: [String] = []

            for move in batch {
                let folder = move.destinationFolder
                do {
                    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)

                    var destination = move.destinationPath
                    if fm.fileExists(atPath: destination) {
                        destination = Organizer.uniquePath(for: destination)
                    }

                    try fm.moveItem(atPath: move.sourcePath, toPath: destination)
                    undo[destination] = move.sourcePath
                } catch {
                    failures.append("\(move.name): \(error.localizedDescription)")
                }
            }

            self.writeUndo(UndoRecord(time: Date(), moves: undo))

            DispatchQueue.main.async {
                self.canUndo = !undo.isEmpty
                self.lastResult = failures.isEmpty
                    ? "Moved \(undo.count) files into \(self.plannedFolders.count) folders."
                    : "Moved \(undo.count) files; \(failures.count) could not be moved."
                self.moves = []
                completion(undo.count, failures)
            }
        }
    }

    /// "report.pdf" -> "report 2.pdf" rather than clobbering the original.
    private static func uniquePath(for path: String) -> String {
        let ns = path as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var counter = 2

        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
            counter += 1
            if counter > 999 { return path }
        }
    }

    // MARK: - Undo

    private func writeUndo(_ record: UndoRecord) {
        StateStore.save(record, as: Organizer.undoFileName)
    }

    func undoLastRun(completion: @escaping (Int, [String]) -> Void) {
        guard let record = StateStore.load(UndoRecord.self, from: Organizer.undoFileName).value else {
            completion(0, ["No organize run to undo."])
            return
        }

        work.async {
            let fm = FileManager.default
            var restored = 0
            var failures: [String] = []

            for (current, original) in record.moves {
                do {
                    let parent = (original as NSString).deletingLastPathComponent
                    try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    try fm.moveItem(atPath: current, toPath: original)
                    restored += 1
                } catch {
                    failures.append((current as NSString).lastPathComponent)
                }
            }

            // Undo should leave no trace. Remove folders the run created, but
            // only where they are now empty — a folder that already held
            // something is not ours to delete.
            let createdFolders = Set(record.moves.keys.map { ($0 as NSString).deletingLastPathComponent })
            for folder in createdFolders.sorted(by: { $0.count > $1.count }) {
                let contents = (try? fm.contentsOfDirectory(atPath: folder)) ?? ["keep"]
                let meaningful = contents.filter { $0 != ".DS_Store" }
                if meaningful.isEmpty { try? fm.removeItem(atPath: folder) }
            }

            StateStore.reset(Organizer.undoFileName)

            DispatchQueue.main.async {
                self.canUndo = false
                self.lastResult = "Put \(restored) files back where they were."
                completion(restored, failures)
            }
        }
    }

    var undoDescription: String? {
        guard let record = StateStore.load(UndoRecord.self, from: Organizer.undoFileName).value else { return nil }
        return "\(record.moves.count) files moved \(Fmt.relative(record.time).lowercased())"
    }
}
