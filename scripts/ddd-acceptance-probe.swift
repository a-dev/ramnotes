import Foundation
#if canImport(ramnotesDomain)
import ramnotesDomain
#endif

struct Output: Codable {
    let variant: String
    let corpusNotes: Int
    let discoveryMilliseconds: Double
    let discovered: Int
    let unavailable: Int
    let discoveredUTF8Bytes: Int
    let saveMilliseconds: [Double]
    let savesSucceeded: Int
    let savedBytesVerified: Bool
    let eachSaveChangedExpectedContent: Bool
    let searchMilliseconds: [Double]
    let searchCounts: [Int]
    let searchNoteIDs: [[String]]
}

@main struct Probe {
    static func announceProfileReady() throws {
        guard let path = ProcessInfo.processInfo.environment["RAMNOTES_PROFILE_READY_FILE"] else { return }
        try Data("ready".utf8).write(to: URL(fileURLWithPath: path))
    }

    static func profileSaves(notes: [NoteSnapshot], store: NoteStore, token: CollectionToken) async throws {
        guard let target = notes.first(where: { $0.fileURL.lastPathComponent == "Note 0000.txt" }) else {
            throw NSError(domain: "profile save target missing", code: 10)
        }
        try announceProfileReady()
        try await Task.sleep(for: .seconds(1))
        let start = ContinuousClock.now
        var current = target
        var operations = 0
        var expectedText = target.text
        while start.duration(to: .now) < .seconds(5) {
            operations += 1
            let edit = EditSnapshot(id: target.id, collectionToken: token,
                revision: EditRevision(rawValue: UInt64(operations)), baseRevision: current.fileRevision,
                text: current.text + "\nprofile-save-\(operations)", locationRevision: current.locationRevision)
            let result = await store.save(edit)
            guard case .saved = result else { throw NSError(domain: "profile save failed at \(operations)", code: 11) }
            guard let updated = await store.knownNote(target.id), updated.text == edit.text else {
                throw NSError(domain: "profile save content mismatch at \(operations)", code: 12)
            }
            expectedText = edit.text
            current = updated
        }
        let savedText = try String(contentsOf: current.fileURL, encoding: .utf8)
        guard operations > 0, savedText == expectedText else {
            throw NSError(domain: "profile save disk verification failed", code: 13)
        }
        print("profile save completed: \(operations) verified saves")
    }

    static func profileSearch(notes: [NoteSnapshot]) async throws {
        let index = SearchIndex()
        _ = await index.search(notes: notes, query: "", sort: .alphabetical)
        let targetID = notes.first { $0.fileURL.lastPathComponent == "Note 0000.txt" }!.id.rawValue.uuidString
        let stressID = notes.first { $0.fileURL.lastPathComponent == "Stress 1MB.txt" }!.id.rawValue.uuidString
        let cases: [(String, [String])] = [
            ("Note 0000.txt", [targetID]), ("marker-0000", [targetID]),
            ("not-a-real-term", []), ("stress", [stressID]),
        ]
        try announceProfileReady()
        try await Task.sleep(for: .seconds(1))
        let start = ContinuousClock.now
        var operations = 0
        while start.duration(to: .now) < .seconds(5) {
            for (query, expectedIDs) in cases {
                let found = await index.search(notes: notes, query: query, sort: .alphabetical)
                let actualIDs = found.map { $0.note.id.rawValue.uuidString }
                guard actualIDs == expectedIDs else {
                    throw NSError(domain: "profile search mismatch for \(query): \(actualIDs)", code: 14)
                }
                operations += 1
            }
        }
        print("profile search completed: \(operations) validated queries")
    }

    static func ms(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    static func main() async throws {
        let profileMode: String? = CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : nil
        let validProfileModes: Set<String> = ["--profile-discovery", "--profile-save", "--profile-search"]
        guard CommandLine.arguments.count == 4 || (CommandLine.arguments.count == 5 && validProfileModes.contains(profileMode!)) else {
            fatalError("usage: Probe CORPUS WORK VARIANT [--profile-discovery|--profile-save|--profile-search]")
        }
        let corpus = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let variant = CommandLine.arguments[3]
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let support = work.appendingPathComponent("support", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let folder = support.appendingPathComponent("Notes", isDirectory: true)
        try fm.copyItem(at: corpus, to: folder)
        let token = CollectionToken()
        let store = try NoteStore(support: support)
        if profileMode == "--profile-discovery" {
            try Self.announceProfileReady()
            try await Task.sleep(for: .seconds(1))
        }
        let discoveryStart = ContinuousClock.now
        let notes = try await store.discover(in: folder, collectionToken: token)
        let discoveryMS = ms(discoveryStart)
        guard notes.count == 1001 else { throw NSError(domain: "wrong discovery count: \(notes.count)", code: 1) }
        let unavailable = notes.filter { $0.availability != .available }.count
        let discoveredUTF8Bytes = notes.reduce(0) { $0 + $1.text.utf8.count }
        guard discoveredUTF8Bytes == 11_288_576 else {
            throw NSError(domain: "wrong materialized body byte count: \(discoveredUTF8Bytes)", code: 15)
        }
        guard unavailable == 0 else { throw NSError(domain: "unavailable notes: \(unavailable)", code: 2) }
        if let profileMode {
            switch profileMode {
            case "--profile-discovery":
                print("profile discovery completed: \(notes.count) available notes")
                try await Task.sleep(for: .seconds(4))
                return
            case "--profile-save":
                try await Self.profileSaves(notes: notes, store: store, token: token)
                try await Task.sleep(for: .seconds(4))
                return
            case "--profile-search":
                try await Self.profileSearch(notes: notes)
                try await Task.sleep(for: .seconds(4))
                return
            default:
                fatalError("unsupported profile mode")
            }
        }

        let target = notes.first { $0.fileURL.lastPathComponent == "Note 0000.txt" }!
        var current = target
        var saveTimes: [Double] = []
        var succeeded = 0
        var expectedFinalText = target.text
        for i in 1...30 {
            let edit = EditSnapshot(id: current.id, collectionToken: token,
                revision: EditRevision(rawValue: UInt64(i)), baseRevision: current.fileRevision,
                text: current.text + "\nprobe-save-\(i)", locationRevision: current.locationRevision)
            let start = ContinuousClock.now
            let result = await store.save(edit)
            saveTimes.append(ms(start))
            guard case .saved = result else { throw NSError(domain: "save failed at \(i): \(result)", code: 3) }
            succeeded += 1
            guard let updated = await store.knownNote(target.id) else { throw NSError(domain: "saved note missing", code: 4) }
            guard updated.text == edit.text else { throw NSError(domain: "save did not apply expected content at \(i)", code: 7) }
            expectedFinalText = edit.text
            current = updated
        }
        let savedText = try String(contentsOf: current.fileURL, encoding: .utf8)
        guard savedText == expectedFinalText, current.text == expectedFinalText else { throw NSError(domain: "final disk bytes do not contain all expected save edits", code: 6) }
        let index = SearchIndex()
        _ = await index.search(notes: notes, query: "", sort: .alphabetical)
        let queries = ["Note 0000.txt", "marker-0000", "not-a-real-term", "stress", "probe-save-30"]
        let expected = [1, 1, 0, 1, 1]
        let stressID = notes.first { $0.fileURL.lastPathComponent == "Stress 1MB.txt" }!.id.rawValue.uuidString
        let targetID = target.id.rawValue.uuidString
        var searchTimes: [Double] = []
        var searchCounts: [Int] = []
        var searchNoteIDs: [[String]] = []
        for repeatIndex in 0..<6 {
            for queryIndex in queries.indices {
                let query = queries[queryIndex]
                let searchNotes = query == "probe-save-30" ? notes.map { $0.id == current.id ? current : $0 } : notes
                let start = ContinuousClock.now
                let found = await index.search(notes: Array(searchNotes), query: query, sort: .alphabetical)
                searchTimes.append(ms(start))
                searchCounts.append(found.count)
                let actualIDs = found.map { $0.note.id.rawValue.uuidString }
                searchNoteIDs.append(actualIDs)
                let expectedIDs = expected[queryIndex] == 0 ? [] : [queryIndex == 3 ? stressID : targetID]
                guard found.count == expected[queryIndex], actualIDs == expectedIDs else {
                    throw NSError(domain: "search count mismatch for \(query): \(found.count), expected \(expected[queryIndex]) (pass \(repeatIndex))", code: 5)
                }
            }
        }
        let output = Output(variant: variant, corpusNotes: notes.count, discoveryMilliseconds: discoveryMS,
            discovered: notes.count, unavailable: unavailable, discoveredUTF8Bytes: discoveredUTF8Bytes, saveMilliseconds: saveTimes,
            savesSucceeded: succeeded, savedBytesVerified: true, eachSaveChangedExpectedContent: true, searchMilliseconds: searchTimes, searchCounts: searchCounts, searchNoteIDs: searchNoteIDs)
        let data = try JSONEncoder().encode(output)
        print(String(decoding: data, as: UTF8.self))
    }
}
