import AppKit

// Prints only names and counts. No note text, IDs, or file paths.
enum ProbeMetrics {
    static let lock = NSLock()
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    static func hit(_ name: String) { lock.lock(); defer { lock.unlock() }; counts[name, default: 0] += 1 }
    static func reset() { lock.lock(); defer { lock.unlock() }; counts = [:] }
    static func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

@main struct Baseline {
    static func ms(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    static func report(_ name: String, _ values: [Double]) throws {
        let sorted = values.sorted()
        let payload: [String: Any] = ["workload": name, "samples": values.count,
            "p50_ms": sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1],
            "p95_ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
            "max_ms": sorted.last!, "counts": ProbeMetrics.snapshot(), "raw_ms": values]
        var line = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        line.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: line)
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let corpus = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard ["/private/tmp", "/tmp"].contains(corpus.deletingLastPathComponent().path) && corpus.lastPathComponent.hasPrefix("ramnotes-benchmark-") else { throw NSError(domain: "Unsafe corpus location", code: 1) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-ar01-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Work on a private copy, so saving never changes the reference notes.
        let folder = root.appendingPathComponent("corpus")
        try FileManager.default.copyItem(at: corpus, to: folder)
        let store = try NoteStore(support: root.appendingPathComponent("support"))
        let generation = FolderGeneration()
        ProbeMetrics.reset()
        let begin = ContinuousClock.now
        let notes = try await store.discover(in: folder, generation: generation)
        guard notes.count == 1001 && notes.allSatisfy({ $0.availability == .available }) else { throw NSError(domain: "Corpus unavailable or wrong count: \(notes.count); \(String(describing: notes.first?.availability))", code: 1) }
        try report("initial_discover", [ms(begin)])
        let target = notes.first { $0.fileURL.lastPathComponent == "Note 0000.txt" }!
        var current = target
        var times: [Double] = []
        ProbeMetrics.reset()
        for i in 1...30 {
            let edit = EditSnapshot(id: target.id, folderGeneration: generation, revision: EditRevision(rawValue: UInt64(i)), baseRevision: current.fileRevision, text: target.text + "\nBaseline \(i)")
            let start = ContinuousClock.now
            let result = await store.save(edit)
            times.append(ms(start))
            guard case .saved = result else { fatalError("Baseline save failed") }
            current = await store.knownNote(target.id)!
        }
        try report("save", times)
        times = []; ProbeMetrics.reset()
        for _ in 0..<30 {
            let start = ContinuousClock.now
            try await store.reconcile(generation: generation)
            times.append(ms(start))
        }
        try report("reconcile", times)
        let index = SearchIndex()
        _ = await index.search(notes: notes, query: "", sort: .alphabetical)
        times = []; ProbeMetrics.reset()
        for i in 0..<30 {
            let start = ContinuousClock.now
            _ = await index.search(notes: notes, query: ["", "note", "marker", "missingterm", "stress"][i % 5], sort: .alphabetical, ascending: i % 2 == 0)
            times.append(ms(start))
        }
        try report("alphabetical_query", times)
        let app = AppCoordinator()
        app.store = store
        app.windows = WindowCoordinator(store: store)
        app.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        app.metadataStore = MetadataStore(root: root.appendingPathComponent("metadata"))
        app.folderID = "baseline"
        app.windows!.metadata.notes[target.id] = NoteWindowMetadata(isOpen: true)
        // Build the list controls without a window, like a list that was opened and then hidden.
        app.listStack = NSStackView()
        app.windows!.changed = { app.persistMetadata() }
        times = []; ProbeMetrics.reset()
        for i in 0..<100 {
            app.windows!.metadata.notes[target.id]?.frame = CGRect(x: i, y: i, width: 560, height: 460)
            let start = ContinuousClock.now
            app.windows!.recordFocus(target.id)
            await app.metadataDelivery?.value
            await app.discovery.task?.value
            times.append(ms(start))
        }
        try report("hidden_focus_geometry", times)
        times = []; ProbeMetrics.reset()
        for i in 0..<30 {
            let start = ContinuousClock.now
            for j in 0..<10 {
                app.windows!.metadata.notes[target.id]?.frame = CGRect(x: i, y: j, width: 560, height: 460)
                app.windows!.recordFocus(target.id)
            }
            await app.metadataDelivery?.value
            await app.discovery.task?.value
            times.append(ms(start))
        }
        try report("hidden_metadata_burst_10", times)
        // Measures the real editor capture, callback, journal, and hidden search. Not key or display events.
        let editor = NoteEditorController(note: current, store: store, settings: AppSettings())
        editor.contentChanged = { note in app.notes[note.id] = note; app.refreshList() }
        times = []; ProbeMetrics.reset()
        for _ in 0..<100 {
            let start = ContinuousClock.now
            editor.textView.string += "a"
            editor.capture()
            await editor.delivery?.value
            await app.discovery.task?.value
            times.append(ms(start))
        }
        try report("hidden_typing_capture", times)
        // Cancel debounce tasks before removing this harness's disposable files.
        await store.cancelBaselineTasks()
    }
}
extension NoteStore {
    func cancelBaselineTasks() { for task in saveTasks.values { task.cancel() } }
}
