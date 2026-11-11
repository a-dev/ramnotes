import AppKit
import Foundation
import ramnotesDomain

@main
struct UIPerformanceProbe {
    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    @MainActor
    static func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }

    @MainActor
    static func revealSamples(_ coordinator: WindowCoordinator, count: Int) async throws -> [Double] {
        var samples: [Double] = []
        for _ in 0..<30 {
            coordinator.perform(.hide)
            pumpRunLoop()
            guard coordinator.windows.values.allSatisfy({ $0.window?.isVisible != true }) else {
                throw NSError(domain: "hide failed before reveal sample", code: 1)
            }
            let start = ContinuousClock.now
            await coordinator.revealVerified()
            samples.append(milliseconds(start))
            pumpRunLoop()
            let visible = coordinator.windows.values.filter { $0.window?.isVisible == true }.count
            guard visible == count else { throw NSError(domain: "reveal visible window count mismatch", code: visible) }
        }
        return samples
    }

    static func report(_ name: String, samples: [Double], unit: String = "milliseconds", expectedCount: Int,
                       checks: [String: Any] = [:]) throws {
        let row: [String: Any] = [
            "workload": name,
            "scope": "unsigned optimized UI component; not signed Release or end-to-end input latency",
            "sampleCount": samples.count,
            "expectedSampleCount": expectedCount,
            "countsValid": samples.count == expectedCount,
            "sampleUnit": unit,
            "rawSamples": samples,
        ].merging(checks) { _, new in new }
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "fixture path required", code: 1) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().standardizedFileURL
        let safeTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard fixture.path.hasPrefix(safeTemporaryRoot.path + "/") else {
            throw NSError(domain: "fixture must be under /private/tmp", code: 2)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-ui-component-" + UUID().uuidString)
        let corpus = root.appendingPathComponent("corpus")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: corpus)

        let store = try NoteStore(support: root.appendingPathComponent("support"))
        let token = CollectionToken()
        let notes = try await store.discover(in: corpus, collectionToken: token)
        let discoveredBytes = notes.filter { $0.availability == .available }
            .reduce(0) { $0 + $1.text.utf8.count }
        guard notes.count == 1001, notes.allSatisfy({ $0.availability == .available }),
              discoveredBytes == 11_288_576 else {
            let firstUnavailable = notes.first { $0.availability != .available }
            throw NSError(domain: "fixture validation failed: count=\(notes.count), bytes=\(discoveredBytes), firstUnavailable=\(String(describing: firstUnavailable?.availability))", code: 1)
        }
        let coordinator = WindowCoordinator(store: store)
        coordinator.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        for count in [1, 10, 50] {
            coordinator.reset()
            coordinator.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
            let cohort = Array(notes.filter { $0.fileURL.lastPathComponent != "Stress 1MB.txt" }.prefix(count))
            for note in cohort {
                coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
                coordinator.open(note, focus: false)
            }
            guard coordinator.windows.values.filter({ $0.window?.isVisible == true }).count == count else {
                throw NSError(domain: "visible window count mismatch", code: coordinator.windows.values.filter({ $0.window?.isVisible == true }).count)
            }
            let samples = try await revealSamples(coordinator, count: count)
            try report("reveal_\(count)_windows", samples: samples, expectedCount: 30,
                       checks: ["openWindowCount": count, "visibleWindowCount": count])
        }

        let stress = notes.first { $0.fileURL.lastPathComponent == "Stress 1MB.txt" }!
        let tenKB = notes.first { $0.fileURL.lastPathComponent == "Note 0000.txt" }!
        for note in [tenKB, stress] {
            coordinator.reset()
            coordinator.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
            coordinator.open(note)
            guard let editor = coordinator.windows[note.id]?.editor else { throw NSError(domain: "editor window unavailable", code: 1) }
            let startingLength = (editor.textView.string as NSString).length
            var samples: [Double] = []
            for _ in 0..<100 {
                let start = ContinuousClock.now
                editor.textView.insertText("x", replacementRange: editor.textView.selectedRange())
                samples.append(milliseconds(start))
                pumpRunLoop()
            }
            guard editor.capturedText == editor.textView.string else { throw NSError(domain: "textDidChange capture missing", code: 1) }
            let insertedLength = (editor.textView.string as NSString).length - startingLength
            guard insertedLength == 100 else { throw NSError(domain: "expected exactly 100 inserted characters", code: insertedLength) }
            try report(note.fileURL.lastPathComponent == stress.fileURL.lastPathComponent ? "component_insert_1mb" : "component_insert_10kb",
                       samples: samples, expectedCount: 100, checks: ["insertedCharacters": insertedLength])
            try await editor.flush()
            guard try Data(contentsOf: note.fileURL) == Data(editor.capturedText.utf8) else {
                throw NSError(domain: "saved editor content did not verify", code: 1)
            }
        }

        coordinator.reset()
        coordinator.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let tenNotes = Array(notes.filter { $0.fileURL.lastPathComponent != "Stress 1MB.txt" }.prefix(10))
        for note in tenNotes {
            coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
            coordinator.open(note, focus: false)
        }
        guard coordinator.windows.values.filter({ $0.window?.isVisible == true }).count == 10 else {
            throw NSError(domain: "ten-window preparation failed", code: 1)
        }
        var footprint: [Int] = []
        for _ in 0..<10 {
            coordinator.perform(.hide)
            pumpRunLoop()
            await coordinator.revealVerified()
            pumpRunLoop()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
            let output = Pipe(); process.standardOutput = output
            try process.run(); process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let kilobytes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) { footprint.append(kilobytes * 1024) }
        }
        try report("ten_window_hide_reveal_resident_bytes", samples: footprint.map(Double.init), unit: "bytes_resident_rss",
                   expectedCount: 10, checks: ["windowCount": 10, "isPhysicalFootprint": false])
        try await store.flush()
    }
}

