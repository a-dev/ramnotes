import Foundation
@main struct Benchmark {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: measure-search CORPUS_DIRECTORY") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let index = SearchIndex()
        let start = ContinuousClock.now
        let generation = FolderGeneration()
        let notes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "txt" }.map { url in
            NoteSnapshot(id: NoteID(), folderGeneration: generation, fileURL: url, fileRevision: nil, text: try String(contentsOf: url, encoding: .utf8), availability: .available)
        }
        print("Read/decode ms: \(Double(start.duration(to: .now).components.attoseconds) / 1e15)")
        let initial = ContinuousClock.now
        _ = await index.search(notes: notes, query: "")
        print("Initial index and empty results: \(initial.duration(to: .now))")
        var samples: [Double] = []
        for query in ["note", "marker", "missingterm", "unicode", "stress"] {
            for _ in 0..<6 {
                let begin = ContinuousClock.now
                let found = await index.search(notes: notes, query: query)
                let time = begin.duration(to: .now)
                samples.append(Double(time.components.seconds) * 1000 + Double(time.components.attoseconds) / 1e15)
                print("\(query): \(found.count)")
            }
        }
        samples.sort()
        print("Files: \(notes.count); search p50 ms: \(samples[15]); p95 ms: \(samples[28]); worst ms: \(samples.last!)")
    }
}
