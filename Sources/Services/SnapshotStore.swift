import Foundation

/// One measurement of one folder at one moment.
struct SizeSample: Codable {
    let time: Date
    let bytes: Int64
}

/// Remembers folder sizes across launches so the app can answer "what grew?"
///
/// A single measurement can only say how big things are. Growth needs history,
/// so every folder the explorer measures is recorded here and compared against
/// what it was last time.
final class SnapshotStore {

    static let shared = SnapshotStore()

    private(set) var history: [String: [SizeSample]] = [:]

    /// Keeping a dozen samples per folder is enough for a trend without the
    /// file growing without bound.
    private let maxSamples = 12

    /// Two measurements taken minutes apart are the same observation; replace
    /// rather than append so navigating around does not flood the history.
    private let coalesceWindow: TimeInterval = 15 * 60

    static let fileName = "history.json"

    /// Set when the last load had to fall back to the backup copy or start
    /// over, so the UI can say so rather than silently losing history.
    private(set) var loadProblem: String?

    private init() { load() }

    // MARK: - Persistence

    private func load() {
        let result = StateStore.load([String: [SizeSample]].self, from: SnapshotStore.fileName)
        history = result.value ?? [:]
        loadProblem = result.problem
    }

    private func save() {
        StateStore.save(history, as: SnapshotStore.fileName)
    }

    // MARK: - Recording

    /// Records a batch of freshly measured sizes.
    func record(_ sizes: [String: Int64], at time: Date = Date()) {
        if sizes.isEmpty { return }

        for (path, bytes) in sizes {
            var samples = history[path] ?? []

            if let last = samples.last, time.timeIntervalSince(last.time) < coalesceWindow {
                samples[samples.count - 1] = SizeSample(time: time, bytes: bytes)
            } else {
                samples.append(SizeSample(time: time, bytes: bytes))
            }

            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            history[path] = samples
        }
        save()
    }

    // MARK: - Reading

    func latest(for path: String) -> SizeSample? { return history[path]?.last }

    /// The measurement before the current one — the baseline a delta is against.
    func previous(for path: String) -> SizeSample? {
        guard let samples = history[path], samples.count >= 2 else { return nil }
        return samples[samples.count - 2]
    }

    /// Change since the previous measurement, or nil when there is no baseline.
    func delta(for path: String) -> (bytes: Int64, since: Date)? {
        guard let now = latest(for: path), let before = previous(for: path) else { return nil }
        return (now.bytes - before.bytes, before.time)
    }

    /// Everything with a recorded change, biggest movement first.
    func movements() -> [GrowthRow] {
        var rows: [GrowthRow] = []
        for (path, samples) in history where samples.count >= 2 {
            let now = samples[samples.count - 1]
            let before = samples[samples.count - 2]
            let change = now.bytes - before.bytes
            if change == 0 { continue }
            rows.append(GrowthRow(path: path,
                                  currentBytes: now.bytes,
                                  previousBytes: before.bytes,
                                  measuredAt: now.time,
                                  baselineAt: before.time))
        }
        return rows.sorted { abs($0.changeBytes) > abs($1.changeBytes) }
    }

    /// Oldest baseline on record — tells the user how far back "since" reaches.
    var earliestBaseline: Date? {
        return history.values.compactMap { $0.first?.time }.min()
    }

    var trackedFolderCount: Int { return history.count }

    func reset() {
        history = [:]
        StateStore.reset(SnapshotStore.fileName)
    }
}
