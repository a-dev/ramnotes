import Foundation
import AppKit

/// Forwards NSFilePresenter callbacks, which run on a serial queue. NoteStore owns all state.
/// `changed` gets the subitem URL, or nil for a folder-wide event.
final class ExternalEventAdapter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let changed: @Sendable (URL?) -> Void
    private var activation: NSObjectProtocol?
    private let lock = NSLock()
    private var evicted = false
    /// False after iCloud evicted the item. The store registers a new presenter on its next pass.
    var isActive: Bool { lock.withLock { !evicted } }

    init(folder: URL, observesActivation: Bool = true, changed: @escaping @Sendable (URL?) -> Void) {
        presentedItemURL = folder
        self.changed = changed
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        if observesActivation {
            activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in changed(nil) }
        }
    }

    func presentedItemDidMove(to newURL: URL) { changed(newURL) }
    func presentedItemDidChange() { changed(nil) }
    func presentedSubitemDidAppear(at url: URL) { changed(url) }
    func presentedSubitemDidChange(at url: URL) { changed(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed(nil) }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed(nil)
        completionHandler(nil)
    }
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        changed(nil)
        completionHandler(nil)
    }

    /// Without this method the system refuses to evict the item, so Remove Download and
    /// Optimize Mac Storage fail while RAMnotes runs. Eviction requires removing the presenter.
    func accommodatePresentedItemEviction(completionHandler: @escaping (Error?) -> Void) {
        lock.withLock { evicted = true }
        NSFileCoordinator.removeFilePresenter(self)
        completionHandler(nil)
    }

    func cancel() {
        NSFileCoordinator.removeFilePresenter(self)
        let token = lock.withLock { let token = activation; activation = nil; return token }
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    deinit {
        NSFileCoordinator.removeFilePresenter(self)
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }
}

