import Foundation
import XCTest
@testable import ramnotes

struct FixedClock: Clock {
    let instant: Date
    func now() -> Date { instant }
}

final class TestFixture {
    let root: URL
    let clock = FixedClock(instant: Date(timeIntervalSince1970: 1_700_000_000))

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Only remove the random directory owned by this fixture.
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TestWaitError: Error {
    case timedOut
    case streamEnded
}

/// The condition must return promptly and cooperate with task cancellation.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    poll: Duration = .milliseconds(10),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    if await condition() { return }
                    try await Task.sleep(for: poll)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestWaitError.timedOut
            }
            try await group.next()
        }
    } catch TestWaitError.timedOut {
        XCTFail("Condition did not become true within \(timeout)", file: file, line: line)
        throw TestWaitError.timedOut
    }
}

// The inout borrow excludes caller access. Only the worker child touches the
// iterator until the task group joins; the caller then receives its final state.
private final class TestIteratorBox<I: AsyncIteratorProtocol>: @unchecked Sendable {
    var iterator: I

    init(_ iterator: I) { self.iterator = iterator }
}

/// Requires a cancellation-cooperative iterator (such as AsyncStream.Iterator).
/// A timeout cancels the pending read and can terminate the underlying stream.
func nextEvent<I: AsyncIteratorProtocol & SendableMetatype>(
    from iterator: inout I,
    timeout: Duration = .seconds(2),
    file: StaticString = #filePath,
    line: UInt = #line,
    where match: @escaping @Sendable (I.Element) -> Bool
) async throws -> I.Element where I.Element: Sendable {
    let box = TestIteratorBox(iterator)
    defer { iterator = box.iterator }
    do {
        return try await withThrowingTaskGroup(of: I.Element.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    guard let event = try await box.iterator.next() else {
                        try Task.checkCancellation()
                        throw TestWaitError.streamEnded
                    }
                    if match(event) { return event }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestWaitError.timedOut
            }
            return try await group.next()!
        }
    } catch TestWaitError.timedOut {
        XCTFail("No matching event within \(timeout)", file: file, line: line)
        throw TestWaitError.timedOut
    } catch TestWaitError.streamEnded {
        XCTFail("Stream ended before a matching event arrived", file: file, line: line)
        throw TestWaitError.streamEnded
    }
}
