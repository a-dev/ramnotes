import ramnotesDomain
import Foundation

/// Runs startup and folder changes one at a time. Only the current token can publish results.
@MainActor
final class LifecycleController {
    enum State: Equatable { case idle, loading, ready, retrying, switching, quitting, failed }
    private var observed: (any NoteNotifications)?
    private var eventTask: Task<Void, Never>?
    private(set) var state: State = .idle
    private(set) var token = UUID()
    private var operation: Task<Void, Never>?
    private var pendingReveal = false
    private var quitRequested = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
    var reveal: () -> Void = {}
    var busy: Bool { operation != nil || state == .quitting || state == .switching || state == .retrying }

    /// Events published before the current subscription, and events received since.
    private var publishedBeforeObservation = 0
    private var receivedEvents = 0
    private var deliveryWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    deinit { eventTask?.cancel() }

    func stopObservation() {
        eventTask?.cancel()
        eventTask = nil
        releaseDeliveryWaiters(all: true)
    }

    func observe(_ store: any NoteNotifications, receive: @escaping (NoteEvent) -> Void) async {
        stopObservation()
        self.observed = store
        let subscription = await store.subscribe()
        publishedBeforeObservation = subscription.published
        receivedEvents = 0
        eventTask = Task { [weak self, weak store] in
            defer { self?.releaseDeliveryWaiters(all: true) }
            for await event in subscription.events {
                guard !Task.isCancelled, let self, let store, self.observed === store else { return }
                receive(event)
                receivedEvents += 1
                releaseDeliveryWaiters(all: false)
            }
        }
    }

    /// Waits until every event the store has published so far has been received.
    /// A flush publishes `.saved` asynchronously; state captured before it arrives is stale.
    func awaitPublishedEvents() async {
        guard let store = observed, eventTask != nil else { return }
        let target = await store.publishedEventCount() - publishedBeforeObservation
        guard eventTask != nil, observed === store, receivedEvents < target else { return }
        await withCheckedContinuation { deliveryWaiters.append((target, $0)) }
    }

    private func releaseDeliveryWaiters(all: Bool) {
        let ready = deliveryWaiters.filter { all || $0.target <= receivedEvents }
        deliveryWaiters.removeAll { all || $0.target <= receivedEvents }
        for waiter in ready { waiter.continuation.resume() }
    }

    func requestReveal() {
        guard !quitRequested else { return }
        guard state == .ready || state == .failed else { pendingReveal = true; return }
        reveal()
    }

    func initialize(_ load: @escaping (UUID) async -> Bool) async {
        if let operation { await operation.value; return }
        guard !busy, state != .ready else { return }
        state = .loading
        let current = UUID()
        token = current
        let task = Task { [weak self] in
            let success = await load(current)
            guard let self, self.token == current else { return }
            self.state = success ? .ready : .failed
            self.operation = nil
            if self.pendingReveal && !self.quitRequested { self.pendingReveal = false; self.reveal() }
        }
        operation = task
        await task.value
    }

    func isCurrent(_ candidate: UUID) -> Bool { token == candidate && state != .quitting }

    /// Rejects a second retry or switch while one runs. Quit waits for the running change
    /// before it takes its lock, so no store is replaced during the quit flush.
    /// On failure, releases only this operation's lock.
    func transact(_ next: State, editors: @escaping () -> (any LifecycleEditors)?,
                  captureGeometry: @escaping () -> Void = {},
                  flushMetadata: @escaping () async throws -> Void,
                  commit: @escaping () async throws -> Void) async throws {
        if next == .quitting { quitRequested = true; pendingReveal = false }
        if next == .quitting, let operation { await operation.value }
        if next == .quitting, state == .switching || state == .retrying {
            await withCheckedContinuation { transactionWaiters.append($0) }
        }
        guard !busy, state != .loading else { throw CancellationError() }
        defer {
            let waiters = transactionWaiters
            transactionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let previous = state
        state = next
        let current = UUID()
        token = current
        let locked = editors()
        let lock = locked?.beginEditingLock()
        do {
            if next != .retrying {
                if next == .switching { try await locked?.flushForDefaultFolderChange() }
                else if next == .quitting { try await locked?.flushForQuit() }
                else { try await locked?.flush() }
                // Positions must describe the saved file, so apply the flush's events first.
                await awaitPublishedEvents()
                captureGeometry()
                try await flushMetadata()
            }
            try Task.checkCancellation()
            try await commit()
            if next != .quitting { state = .ready }
        } catch {
            if next == .quitting { quitRequested = false }
            state = previous
            if let lock { locked?.endEditingLock(lock) }
            if pendingReveal && !quitRequested { pendingReveal = false; reveal() }
            throw error
        }
        if next != .quitting {
            if let lock { locked?.endEditingLock(lock) }
            if pendingReveal { pendingReveal = false; reveal() }
        }
    }
}


/// Locks and flushes live editor buffers; geometry persistence is supplied separately.
@MainActor
protocol LifecycleEditors: AnyObject {
    func beginEditingLock() -> UUID
    func endEditingLock(_ token: UUID)
    func flush() async throws
    func flushForDefaultFolderChange() async throws
    func flushForQuit() async throws
}

protocol DefaultFolderChanging: Sendable {
    var collectionToken: CollectionToken { get async }
    func prepareDefaultFolder(to url: URL, moveExisting: Bool, from token: CollectionToken) async throws -> PreparedDefaultFolderChange
    func commitDefaultFolder(_ prepared: PreparedDefaultFolderChange) async throws -> DefaultFolderChangeResult
    func retryDefaultFolderChange(_ id: UUID, from token: CollectionToken) async throws -> DefaultFolderChangeResult
}

extension LifecycleController {
    func changeDefaultFolder(to url: URL, moveExisting: Bool, using storage: any DefaultFolderChanging,
                             editors: @escaping () -> (any LifecycleEditors)?,
                             captureGeometry: @escaping () -> Void,
                             flushMetadata: @escaping () async throws -> Void,
                             willCommit: @escaping () -> Void,
                             didCommit: @escaping (DefaultFolderChangeResult) async -> Void) async throws {
        let token = await storage.collectionToken
        let prepared = try await storage.prepareDefaultFolder(to: url, moveExisting: moveExisting, from: token)
        try await transact(.switching, editors: editors, captureGeometry: captureGeometry, flushMetadata: flushMetadata) {
            willCommit()
            let result = try await storage.commitDefaultFolder(prepared)
            await didCommit(result)
        }
    }

    func retryDefaultFolder(_ id: UUID, from token: CollectionToken, using storage: any DefaultFolderChanging,
                            editors: @escaping () -> (any LifecycleEditors)?,
                            captureGeometry: @escaping () -> Void,
                            flushMetadata: @escaping () async throws -> Void,
                            willCommit: @escaping () -> Void,
                            didCommit: @escaping (DefaultFolderChangeResult) async -> Void) async throws {
        try await transact(.switching, editors: editors, captureGeometry: captureGeometry, flushMetadata: flushMetadata) {
            willCommit()
            let result = try await storage.retryDefaultFolderChange(id, from: token)
            await didCommit(result)
        }
    }
}
