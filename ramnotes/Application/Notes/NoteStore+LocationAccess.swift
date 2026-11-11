import ramnotesDomain
import Foundation

extension NoteStore {
    func renewFileAccess(_ id: NoteID, file grant: any FileGrant,
                           collectionToken token: CollectionToken, locationRevision: LocationRevision) throws -> NoteSnapshot {
        try validate(token)
        try requireNoLocationOperation(id)
        guard var location = identities.identity(id), location.revision.matches(locationRevision) else { throw NoteOperationError.staleLocation }
        guard !session.writing.contains(id) else { throw NoteOperationError.conflict }
        if let edit = pending[id] ?? preservedBuffers[id] {
            try persistJournal(journal(for: edit, url: URL(fileURLWithPath: location.path)))
        }
        guard let authorized = grant as? AuthorizedFile else { throw NoteOperationError.permissionDenied }
        let file = authorized.lease
        let target = file.url
        let known = URL(fileURLWithPath: location.path)
        guard let resource = location.resource, NoteFileIdentityPolicy.permitsRenewal(tracked: resource, selected: try StorageFiles.fileResourceID(target))
        else { throw NoteOperationError.notOriginalFile }
        guard try StorageFiles.supported(target) else { throw NoteOperationError.conflict }
        let body = try StorageFiles.read(target, readBody: readBody)
        location.access = nil
        location.fileAccess = try folderAccess.descriptor(for: file, scope: .file)
        location.path = target.path
        location.availability = .available
        location.revision.advance()
        guard try StorageFiles.fileResourceID(target) == resource else { throw NoteOperationError.conflict }
        var updated = identities
        _ = updated.remember(location)
        try writeIdentities(updated)
        accessLeases[id] = [file]
        accessFailures[id] = nil
        session.saveTasks[id]?.cancel()
        let edit = pending[id] ?? preservedBuffers[id]
        if let edit {
            pending[id] = EditSnapshot(id: id, collectionToken: token, revision: edit.revision,
                baseRevision: edit.baseRevision, text: edit.text, locationRevision: location.revision)
        }
        let note = NoteSnapshot(id: id, collectionToken: token, fileURL: target, fileRevision: body.revision,
            text: body.text, availability: .available, editRevision: session.completions[id]?.revision ?? EditRevision(rawValue: 0),
            locationRevision: location.revision, createdAt: StorageFiles.creationDate(target))
        records[id] = note
        session.knownLocations[id] = target
        bodyCache[known.path] = nil
        startObserving()
        emit(.changed(note))
        if let retained = pending[id] {
            // Normal saving compares the retained base with disk and promotes conflicts.
            let result = save(retained)
            if case let .failed(error) = result { throw error }
        }
        return records[id] ?? note
    }

    func relinkNote(_ id: NoteID, file grant: any FileGrant,
                    collectionToken token: CollectionToken, locationRevision: LocationRevision) throws -> NoteSnapshot {
        try validate(token)
        try requireNoLocationOperation(id)
        guard var location = identities.identity(id), location.revision.matches(locationRevision) else { throw NoteOperationError.staleLocation }
        guard !session.writing.contains(id), records[id]?.availability != .available || StorageFiles.isMissing(URL(fileURLWithPath: location.path)) else { throw NoteOperationError.conflict }
        guard let authorized = grant as? AuthorizedFile else { throw NoteOperationError.permissionDenied }
        let file = authorized.lease
        let url = file.url
        guard try StorageFiles.supported(url) else { throw NoteOperationError.unavailable }
        let resource = try StorageFiles.fileResourceID(url)
        if NoteFileIdentityPolicy.permitsRenewal(tracked: location.resource, selected: resource) {
            return try renewFileAccess(id, file: grant, collectionToken: token, locationRevision: locationRevision)
        }
        guard !identities.mapping.contains(where: { $0.id != id && ($0.path == url.path || (resource != nil && $0.resource == resource)) }) else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("This file is already linked to another note. Choose a different file.", comment: "Error when relinking a note to a file that another note already uses"))
        }
        let body = try StorageFiles.read(url)
        location.path = url.path
        location.resource = resource
        location.parentResource = try? StorageFiles.resourceID(url.deletingLastPathComponent())
        location.access = nil
        location.fileAccess = try folderAccess.descriptor(for: file, scope: .file)
        location.availability = .available
        location.revision.advance()
        var updated = identities
        _ = updated.remember(location)
        // Retain the old binding's text without authorizing replay onto the selected resource.
        if let edit = pending[id] ?? preservedBuffers[id] {
            var retained = journal(for: edit, url: URL(fileURLWithPath: identities.identity(id)!.path))
            retained.trackingRemoved = true
            try persistJournal(retained)
            try recovery.retain(retained)
        }
        for var retained in recovery.load().records where retained.noteID == id && !retained.trackingRemoved {
            retained.trackingRemoved = true
            try persistJournal(retained)
            try recovery.retain(retained)
        }
        guard try StorageFiles.fileResourceID(url) == resource else { throw NoteOperationError.conflict }
        try writeIdentities(updated)
        if let prior = session.journalRecords[id] ?? recovery.load().records.first(where: { $0.noteID == id }) {
            try? removeJournal(id, through: prior.editRevision)
        }
        session.journalRecords[id] = nil
        session.saveTasks[id]?.cancel()
        accessFailures[id] = nil
        accessLeases[id] = [file]
        let note = NoteSnapshot(id: id, collectionToken: token, fileURL: url, fileRevision: body.revision, text: body.text,
            availability: .available, editRevision: session.completions[id]?.revision ?? EditRevision(rawValue: 0), locationRevision: location.revision,
            createdAt: StorageFiles.creationDate(url))
        records[id] = note
        session.knownLocations[id] = url
        if let edit = pending.removeValue(forKey: id) {
            preservedBuffers[id] = edit
        }
        startObserving()
        emit(.rebound(note))
        return note
    }
}
