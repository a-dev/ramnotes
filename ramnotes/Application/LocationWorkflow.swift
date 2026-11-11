import ramnotesDomain
import Foundation

/// Live-buffer work stays with the editor. The application owns location requests and sequencing.
@MainActor
protocol LocationEditor: AnyObject {
    var note: NoteSnapshot { get }
    func beginEditingLock(_ token: UUID) -> UUID
    func endEditingLock(_ token: UUID)
    func prepareForTrackingRemoval() async throws
    func prepareForMove() async throws -> EditRevision
    func acceptLocation(_ note: NoteSnapshot)
}

@MainActor
final class LocationWorkflow {
    private let notes: any NoteLocations
    init(notes: any NoteLocations) { self.notes = notes }

    private func withEditor<T>(_ editor: (any LocationEditor)?,
                               perform: () async throws -> T) async throws -> T {
        let lock = editor?.beginEditingLock(UUID())
        defer { if let lock { editor?.endEditingLock(lock) } }
        return try await perform()
    }

    func move(_ expected: NoteSnapshot, to target: URL, retry: UUID? = nil,
              editor: (any LocationEditor)? = nil) async throws -> NoteMoveResult {
        if let retry { return try await notes.retryLocationOperation(retry) }
        return try await withEditor(editor) {
            let current: NoteSnapshot
            let revision: EditRevision
            if let editor {
                guard editor.note.collectionToken == expected.collectionToken,
                      editor.note.locationRevision == expected.locationRevision else { throw NoteOperationError.staleLocation }
                revision = try await editor.prepareForMove()
                current = editor.note
            } else {
                current = try await notes.read(expected.id, collectionToken: expected.collectionToken)
                guard current.locationRevision == expected.locationRevision else { throw NoteOperationError.staleLocation }
                revision = current.editRevision
            }
            let result = await notes.moveNote(current.id, to: target, collectionToken: current.collectionToken,
                locationRevision: current.locationRevision, editRevision: revision)
            if case .moved = result.outcome, let editor {
                editor.acceptLocation(try await notes.read(current.id, collectionToken: current.collectionToken))
            }
            return result
        }
    }

    func renewAccess(_ expected: NoteSnapshot, file: any FileGrant, editor: (any LocationEditor)? = nil) async throws -> NoteSnapshot {
        try await withEditor(editor) {
            if let editor {
                guard editor.note.collectionToken == expected.collectionToken,
                      editor.note.locationRevision == expected.locationRevision else { throw NoteOperationError.staleLocation }
                try await editor.prepareForTrackingRemoval()
            }
            return try await notes.renewFileAccess(expected.id, file: file,
                collectionToken: expected.collectionToken, locationRevision: expected.locationRevision)
        }
    }

    func renewAccess(_ expected: NoteSnapshot, at fileURL: URL, editor: (any LocationEditor)? = nil) async throws -> NoteSnapshot {
        try await renewAccess(expected, file: try await notes.acquireFile(fileURL), editor: editor)
    }

    func relink(_ expected: NoteSnapshot, file: any FileGrant,
                editor: (any LocationEditor)? = nil) async throws -> NoteSnapshot {
        try await withEditor(editor) {
            if let editor {
                guard editor.note.collectionToken == expected.collectionToken,
                      editor.note.locationRevision == expected.locationRevision else { throw NoteOperationError.staleLocation }
                try await editor.prepareForTrackingRemoval()
            }
            return try await notes.relinkNote(expected.id, file: file,
                collectionToken: expected.collectionToken, locationRevision: expected.locationRevision)
        }
    }

    func relink(_ expected: NoteSnapshot, to url: URL,
                editor: (any LocationEditor)? = nil) async throws -> NoteSnapshot {
        try await relink(expected, file: try await notes.acquireFile(url), editor: editor)
    }

    func removeTracking(_ expected: NoteSnapshot, editor: (any LocationEditor)? = nil) async throws {
        try await withEditor(editor) {
            try await editor?.prepareForTrackingRemoval()
            try await notes.removeUnavailableNote(expected.id, collectionToken: expected.collectionToken,
                locationRevision: expected.locationRevision)
        }
    }
}
