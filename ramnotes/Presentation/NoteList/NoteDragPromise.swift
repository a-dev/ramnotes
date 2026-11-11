import ramnotesDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A promise owns its producer until the receiver finishes, including after the drag ends.
@MainActor
final class NoteDragPromise: NSObject, NSFilePromiseProviderDelegate {
    let name: String
    let write: (URL) async throws -> Void
    var provider: NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: self)
        provider.userInfo = self
        return provider
    }
    init(name: String, write: @escaping (URL) async throws -> Void) {
        self.name = name
        self.write = write
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        Task { @MainActor in
            do { try await write(url); completionHandler(nil) }
            catch { completionHandler(error) }
        }
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
}
