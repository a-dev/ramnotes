import ramnotesDomain
import Foundation

extension NoteStore {
    func acquireFile(_ url: URL) throws -> any FileGrant { AuthorizedFile(try folderAccess.acquireFile(url)) }

    func acquireDestinationFile(_ url: URL) throws -> any FileGrant {
        AuthorizedFile(try folderAccess.acquireDestinationFile(url))
    }

    /// Writes and verifies the copy before registering it. When the copy holds the source's
    /// pending edit, that edit is released like a verified export: close is unblocked and the
    /// original file, journal, and conflict state stay as they are.
    func createCopy(from source: NoteSnapshot, editRevision: EditRevision, text: String,
                    to destination: any FileGrant) throws -> NoteSnapshot {
        defer { withExtendedLifetime(destination) {} }
        try validate(source.collectionToken)
        guard let current = records[source.id], current.collectionToken == source.collectionToken,
              let location = identities.identity(source.id), location.revision.matches(source.locationRevision) else {
            throw NoteOperationError.staleLocation
        }
        let latestEditRevision = [
            pending[source.id]?.revision.rawValue,
            preservedBuffers[source.id]?.revision.rawValue,
            session.journalRecords[source.id]?.editRevision.rawValue,
            session.completions[source.id]?.revision.rawValue,
            current.editRevision.rawValue
        ].compactMap { $0 }.max() ?? 0
        guard editRevision.rawValue == latestEditRevision else { throw NoteOperationError.conflict }
        let target = destination.url.standardizedFileURL
        guard target.isFileURL, NoteFilename(target.lastPathComponent) != nil else {
            throw NoteOperationError.invalidFilename
        }
        let destinationResource = try SaveCopyFiles.existingResourceID(at: target)
        guard !identities.mapping.contains(where: {
            $0.path == target.path || (destinationResource != nil && $0.resource == destinationResource)
        }) else { throw NoteOperationError.destinationOccupied }
        let bytes = Data(text.utf8)
        try SaveCopyFiles.write(bytes, to: target)
        try fault(.copyVerification)
        try SaveCopyFiles.verify(bytes, at: target)
        try fault(.copyCatalog)
        let copy = try registerFile(target, collectionToken: source.collectionToken)
        if let edit = pending[source.id], edit.revision == editRevision, edit.text == text { release(edit, to: target) }
        return copy
    }
}


extension NoteStore {
    /// Register the selected file with its file grant.
    func registerFile(_ url: URL, collectionToken token: CollectionToken) throws -> NoteSnapshot {
        try validate(token)
        guard url.isFileURL, NoteFilename(url.lastPathComponent) != nil else { throw NoteOperationError.invalidFilename }
        let file = try folderAccess.acquireFile(url)
        let target = file.url.standardizedFileURL
        let resource = try StorageFiles.fileResourceID(target)
        let body = try StorageFiles.read(target, readBody: readBody)
        guard try StorageFiles.fileResourceID(target) == resource else { throw NoteOperationError.conflict }
        if let known = identities.mapping.first(where: { resource != nil && $0.resource == resource }),
           let note = records[known.id] {
            if note.availability != .available {
                return try renewFileAccess(known.id, file: AuthorizedFile(file), collectionToken: token, locationRevision: known.revision)
            }
            return note
        }
        guard !identities.mapping.contains(where: { $0.path == target.path }) else { throw NoteOperationError.conflict }
        let id = NoteID()
        let location = NoteLocationRecord(id: id, resource: resource, path: target.path,
            parentResource: try? StorageFiles.resourceID(target.deletingLastPathComponent()),
            fileAccess: try folderAccess.descriptor(for: file, scope: .file))
        var updated = identities
        _ = updated.remember(location)
        try writeIdentities(updated)
        let note = NoteSnapshot(id: id, collectionToken: token, fileURL: target,
            fileRevision: body.revision, text: body.text, availability: .available, createdAt: StorageFiles.creationDate(target))
        accessLeases[id] = [file]
        records[id] = note
        session.knownLocations[id] = target
        startObserving()
        emit(.discovered(note))
        return note
    }
}

struct NoteRegistrationResult: Sendable {
    let url: URL
    let outcome: Result<NoteSnapshot, NoteOperationError>
    var alreadyRegistered = false
}

extension NoteStore {
    func registerFiles(_ urls: [URL], collectionToken token: CollectionToken) -> [NoteRegistrationResult] {
        urls.map { url in
            do {
                let tracked = Set(identities.mapping.map(\.id))
                let note = try registerFile(url, collectionToken: token)
                return NoteRegistrationResult(url: url, outcome: .success(note), alreadyRegistered: tracked.contains(note.id))
            }
            catch { return NoteRegistrationResult(url: url, outcome: .failure(NoteFailureMapping.operationError(error))) }
        }
    }
}
