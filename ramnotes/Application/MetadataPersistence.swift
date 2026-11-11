import ramnotesDomain
import Foundation

/// A value that replaces any earlier value with the same key.
protocol LatestWinsKeyed: Sendable {
    associatedtype Key: Hashable & Sendable
    var key: Key { get }
}

/// Writes one value at a time and keeps only the latest pending value per key.
/// A failed value waits for a retry. A newer value for that key replaces it and retries.
@MainActor
final class LatestWinsQueue<Value: LatestWinsKeyed> {
    typealias Key = Value.Key
    private struct Submission {
        let sequence: UInt64
        let value: Value
    }
    private let write: @Sendable (Value) async throws -> Void
    var failed: ((Key, Error) -> Void)?
    private var sequence: UInt64 = 0
    private var submitted: [Key: UInt64] = [:]
    private var persisted: [Key: UInt64] = [:]
    private var pending: [Key: Submission] = [:]
    private var failures: [Key: Error] = [:]
    private var worker: Task<Void, Never>?
    var pendingCount: Int { pending.count }

    init(write: @escaping @Sendable (Value) async throws -> Void) { self.write = write }

    func submit(_ value: Value) {
        sequence += 1
        submitted[value.key] = sequence
        pending[value.key] = Submission(sequence: sequence, value: value)
        // A new value counts as a retry. Otherwise one brief failure blocks the key until flush.
        failures.removeValue(forKey: value.key)
        start()
    }
    private func start() {
        guard worker == nil,
              let (key, submission) = pending
                .filter({ failures[$0.key] == nil })
                .min(by: { $0.value.sequence < $1.value.sequence }) else { return }
        pending.removeValue(forKey: key)
        worker = Task { [self] in
            do {
                try await write(submission.value)
                persisted[key] = submission.sequence
                failures.removeValue(forKey: key)
            } catch {
                if pending[key] == nil {
                    pending[key] = submission
                    failures[key] = error
                    failed?(key, error)
                }
            }
            worker = nil
            start()
        }
    }
    /// Waits for the values submitted before this call. A newer saved value also counts.
    /// Does not wait for later writes. Cancelling stops only this caller's wait, not the writer.
    func flush() async throws {
        try Task.checkCancellation()
        let targets = submitted
        failures.removeAll() // A flush retries earlier failures once.
        start()
        while targets.contains(where: { persisted[$0.key, default: 0] < $0.value }) {
            if let worker { await worker.value }
            try Task.checkCancellation()
            for (key, target) in targets where persisted[key, default: 0] < target {
                if let error = failures[key] { throw error }
            }
            start()
        }
    }
}

/// Metadata snapshots, one destination file each.
enum MetadataSnapshot: LatestWinsKeyed {
    enum Destination: Hashable, Sendable {
        case settings, collection
    }
    case settings(AppSettings), collection(CollectionMetadata)
    var key: Destination {
        switch self {
        case .settings: .settings
        case .collection: .collection
        }
    }
}

typealias MetadataPersistence = LatestWinsQueue<MetadataSnapshot>

extension LatestWinsQueue where Value == MetadataSnapshot {
    convenience init(store: MetadataStore) {
        self.init { value in
            switch value {
            case let .settings(value): try await store.saveSettings(value)
            case let .collection(value): try await store.saveCollection(value)
            }
        }
    }
}
