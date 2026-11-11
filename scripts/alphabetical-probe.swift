import Foundation

// Only throwaway generated sources call these counters. Latency runs don't use them.
enum Probe {
    nonisolated(unsafe) static var previews = 0
    nonisolated(unsafe) static var comparisons = 0
    nonisolated(unsafe) static var comparisonMS = 0.0
}
func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let d = start.duration(to: .now).components
    return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
}
@main struct AlphabeticalProbe {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let generation = FolderGeneration()
        let notes = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                NoteSnapshot(id: NoteID(), folderGeneration: generation, fileURL: $0, fileRevision: nil,
                    text: try String(contentsOf: $0, encoding: .utf8), availability: .available)
            }
        precondition(notes.count == 1001)
        let index = SearchIndex()
        _ = await index.search(notes: notes, query: "", sort: .alphabetical)
        let warmupPreviews = Probe.previews
        Probe.previews = 0; Probe.comparisons = 0; Probe.comparisonMS = 0
        var samples: [Double] = []
        for i in 0..<30 {
            let begin = ContinuousClock.now
            _ = await index.search(notes: notes, query: ["", "note", "marker", "missingterm", "stress"][i % 5], sort: .alphabetical, ascending: i % 2 == 0)
            samples.append(elapsed(begin))
        }
        let sorted = samples.sorted()
        let payload: [String: Any] = ["variant": CommandLine.arguments[2], "instrumented": CommandLine.arguments[3],
            "samples": 30, "p50_ms": sorted[14], "p95_ms": sorted[28], "max_ms": sorted[29],
            "warmup_preview_derivations": warmupPreviews, "warm_preview_derivations": Probe.previews,
            "comparisons": Probe.comparisons, "comparator_ms": Probe.comparisonMS, "raw_ms": samples]
        print(String(decoding: try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), as: UTF8.self))
    }
}
