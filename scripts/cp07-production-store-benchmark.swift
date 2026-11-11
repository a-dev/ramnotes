import Foundation

final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var paths: Set<String> = []
    func increment(path: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        value += 1
        if let path { paths.insert(path) }
    }
    func clearPaths() { lock.lock(); paths.removeAll(); lock.unlock() }
    func observedPaths() -> Set<String> { lock.lock(); defer { lock.unlock() }; return paths }
    func snapshot() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

struct BenchmarkReport: Codable {
    var environment: [String: String]
    var corpus: [String: Int]
    var openSelectedFolderMilliseconds: Double
    var openProgressCallbacks: Int
    var openReturnedNotes: Int
    var ordinarySaves: [String: Double]
    var ordinarySaveSamplesMilliseconds: [Double]
    var ordinarySaveBodyReads: [Int]
    var reconcileMilliseconds: [Double]
    var reconcileBodyReads: [Int]
    var batchMoveMilliseconds: Double
    var batchExpectedMoves: Int
    var batchMovedCount: Int
    var batchFailedCount: Int
    var batchState: String
}

func elapsed<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let result = try operation()
    return (result, Double(start.duration(to: .now).components.seconds) * 1000 +
              Double(start.duration(to: .now).components.attoseconds) / 1e15)
}

func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@main
struct CP07ProductionStoreBenchmark {
    static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            fputs("usage: cp07-production-store-benchmark <new-or-empty-work-directory> [--startup-only|--prebatch-only]\n", stderr)
            exit(64)
        }
        let mode = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : ""
        guard ["", "--startup-only", "--prebatch-only"].contains(mode) else {
            throw NoteOperationError.inputOutput("Unknown benchmark mode")
        }
        let startupOnly = mode == "--startup-only"
        let prebatchOnly = mode == "--prebatch-only"
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path), !(try fm.contentsOfDirectory(atPath: root.path)).isEmpty {
            fputs("work directory must be new or empty: \(root.path)\n", stderr)
            exit(64)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let defaultFolder = support.appendingPathComponent("Notes", isDirectory: true)
        let customRoot = root.appendingPathComponent("Custom", isDirectory: true)
        let destination = root.appendingPathComponent("Moved", isDirectory: true)
        try fm.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: customRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let body = String(repeating: "x", count: 10_240)
        var customRecords: [NoteID: NoteLocationRecord] = [:]
        var customCount = 0
        for parentIndex in 0..<5 {
            let parent = customRoot.appendingPathComponent("parent-\(parentIndex)", isDirectory: true)
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            for itemIndex in 0..<100 {
                let url = parent.appendingPathComponent(String(format: "custom-%03d-%03d.txt", parentIndex, itemIndex))
                try Data(body.utf8).write(to: url)
                let id = NoteID()
                let descriptor = NoteAccessDescriptor(url: parent, bookmark: Data(parent.path.utf8), scope: .folder)
                let fileAccess = NoteAccessDescriptor(url: url, bookmark: Data(url.path.utf8), scope: .file)
                customRecords[id] = NoteLocationRecord(id: id, resource: try StorageFiles.fileResourceID(url),
                    path: url.path, parentResource: try StorageFiles.resourceID(parent), access: descriptor,
                    fileAccess: fileAccess, availability: .available)
                customCount += 1
            }
            // These siblings must never be discovered because the parent is custom.
            try Data(body.utf8).write(to: parent.appendingPathComponent("unregistered-sibling.txt"))
        }
        let defaultNoteCount = Int(ProcessInfo.processInfo.environment["CP07_DEFAULT_COUNT"] ?? "500") ?? 500
        guard defaultNoteCount >= 30 else { throw NoteOperationError.inputOutput("CP07_DEFAULT_COUNT must be at least 30") }
        for itemIndex in 0..<defaultNoteCount {
            try Data(body.utf8).write(to: defaultFolder.appendingPathComponent(String(format: "default-%04d.txt", itemIndex)))
        }
        try Data(repeating: 0x7a, count: 1_048_576).write(to: defaultFolder.appendingPathComponent("stress.txt"))
        var catalog = CollectionCatalog()
        catalog.notes = customRecords
        try catalog.save(at: support.appendingPathComponent("collection.json"))

        let counter = ReadCounter()
        let hooks = FolderAccessHooks(
            bookmark: { Data($0.path.utf8) },
            resolve: { data in (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false) },
            start: { _ in true }, stop: { _ in })
        let store = try NoteStore(support: support, folderAccessHooks: hooks,
                                  readBody: { url in counter.increment(path: url.path); return try Data(contentsOf: url) })

        let progressCounter = ReadCounter()
        let openStart = ContinuousClock.now
        let selection = try await store.openSelectedFolder { _ in progressCounter.increment() }
        let openMilliseconds = ms(openStart.duration(to: .now))
        let progressCount = progressCounter.snapshot()
        let notes = selection.notes
        let expectedNoteCount = defaultNoteCount + 1 + customCount
        guard notes.count == expectedNoteCount else {
            throw NoteOperationError.inputOutput("Expected \(expectedNoteCount) discovered notes (\(defaultNoteCount) default + stress + \(customCount) registered custom); got \(notes.count)")
        }

        guard notes.allSatisfy({ $0.availability == .available }),
              !notes.contains(where: { $0.fileURL.lastPathComponent == "unregistered-sibling.txt" }) else {
            throw NoteOperationError.inputOutput("Unavailable content or discovered custom sibling invalidates benchmark")
        }

        if startupOnly {
            let report = BenchmarkReport(environment: [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": "arm64",
                "processorCount": String(ProcessInfo.processInfo.processorCount),
                "swiftVersion": "See `swiftc --version` output from build script",
                "configuration": "swiftc -O production component harness",
                "filesystemPath": root.path,
                "machine": ProcessInfo.processInfo.environment["CP07_MACHINE"] ?? ProcessInfo.processInfo.hostName,
            ], corpus: ["defaultNotes": defaultNoteCount, "customRegisteredNotes": customCount,
                        "customParents": 5, "unregisteredCustomSiblings": 5,
                        "stressNoteBytes": 1_048_576, "ordinaryNoteBytes": 10_240],
                openSelectedFolderMilliseconds: openMilliseconds, openProgressCallbacks: progressCount,
                openReturnedNotes: notes.count, ordinarySaves: [:], ordinarySaveSamplesMilliseconds: [],
                ordinarySaveBodyReads: [], reconcileMilliseconds: [], reconcileBodyReads: [],
                batchMoveMilliseconds: 0, batchExpectedMoves: 0, batchMovedCount: 0, batchFailedCount: 0,
                batchState: "not run (startup-only)")
            let output = root.appendingPathComponent("cp07-report.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output)
            print("report=\(output.path)")
            print("openMs=\(String(format: "%.3f", openMilliseconds)) returned=\(notes.count) progressCallbacks=\(progressCount)")
            return
        }

        var saveTimes: [Double] = []
        var saveReads: [Int] = []
        let ordinary = notes.filter { $0.fileURL.deletingLastPathComponent() == defaultFolder && $0.fileURL.lastPathComponent != "stress.txt" }.sorted { $0.fileURL.path < $1.fileURL.path }
        for (index, note) in ordinary.prefix(30).enumerated() {
            let before = counter.snapshot()
            counter.clearPaths()
            let start = ContinuousClock.now
            let edit = EditSnapshot(id: note.id, collectionToken: selection.collectionToken,
                revision: EditRevision(rawValue: UInt64(index + 1)), baseRevision: note.fileRevision,
                text: note.text + "\n", locationRevision: note.locationRevision)
            let result = await store.save(edit)
            guard case .saved = result else {
                if case let .failed(error) = result { throw NoteOperationError.inputOutput("Ordinary save \(index) failed: \(error.localizedDescription)") }
                throw NoteOperationError.inputOutput("Ordinary save \(index) returned a recovery result")
            }
            saveTimes.append(ms(start.duration(to: .now)))
            saveReads.append(counter.snapshot() - before)
            guard counter.observedPaths() == [note.fileURL.path] else {
                throw NoteOperationError.inputOutput("An ordinary save read an unrelated body")
            }
        }

        var reconcileTimes: [Double] = []
        var reconcileReads: [Int] = []
        for _ in 0..<30 {
            let before = counter.snapshot()
            let start = ContinuousClock.now
            try await store.reconcile(collectionToken: selection.collectionToken)
            reconcileTimes.append(ms(start.duration(to: .now)))
            reconcileReads.append(counter.snapshot() - before)
        }

        let moveStart = ContinuousClock.now
        let moved = prebatchOnly ? nil : try await store.changeDefaultFolder(to: destination, moveExisting: true,
                                                        from: selection.collectionToken)
        let moveMilliseconds = prebatchOnly ? 0 : ms(moveStart.duration(to: .now))
        let batch = moved?.batch
        let movedCount = batch?.entries.filter { $0.state == .moved }.count ?? 0
        let failedCount = batch?.entries.filter { $0.state == .failed }.count ?? 0
        let environment = ProcessInfo.processInfo.environment
        let processInfo = ProcessInfo.processInfo
        let report = BenchmarkReport(environment: [
            "os": processInfo.operatingSystemVersionString,
            "architecture": "arm64",
            "processorCount": String(processInfo.processorCount),
            "swiftVersion": "See `swiftc --version` output from build script",
            "configuration": "swiftc -O production component harness",
            "filesystemPath": root.path,
            "machine": environment["CP07_MACHINE"] ?? ProcessInfo.processInfo.hostName,
            ], corpus: ["defaultNotes": defaultNoteCount, "customRegisteredNotes": customCount,
                    "customParents": 5, "unregisteredCustomSiblings": 5,
                    "stressNoteBytes": 1_048_576, "ordinaryNoteBytes": 10_240],
            openSelectedFolderMilliseconds: openMilliseconds, openProgressCallbacks: progressCount,
            openReturnedNotes: notes.count,
            ordinarySaves: ["count": Double(saveTimes.count), "medianMs": saveTimes.sorted()[saveTimes.count / 2],
                            "p95Ms": saveTimes.sorted()[Int(ceil(Double(saveTimes.count) * 0.95)) - 1],
                            "maxMs": saveTimes.max() ?? 0], ordinarySaveSamplesMilliseconds: saveTimes,
            ordinarySaveBodyReads: saveReads,
            reconcileMilliseconds: reconcileTimes, reconcileBodyReads: reconcileReads,
            batchMoveMilliseconds: moveMilliseconds, batchExpectedMoves: batch?.entries.count ?? 0,
            batchMovedCount: movedCount, batchFailedCount: failedCount,
            batchState: batch.map { String(describing: $0.state) } ?? "no batch")
        let output = root.appendingPathComponent("cp07-report.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output)
        print("report=\(output.path)")
        print("selectionNotes=\(selection.notes.count) progressCallbacks=\(progressCount) customInput=\(customCount)")
        print("openMs=\(String(format: "%.3f", openMilliseconds)) saves=\(saveTimes.count) saveReads=\(saveReads.reduce(0,+)) reconcilePasses=\(reconcileTimes.count) reconcileReads=\(reconcileReads.reduce(0,+))")
        print("batchMs=\(String(format: "%.3f", moveMilliseconds)) expected=\(batch?.entries.count ?? 0) moved=\(movedCount) failed=\(failedCount) state=\(batch.map { String(describing: $0.state) } ?? "none")")
    }
}
