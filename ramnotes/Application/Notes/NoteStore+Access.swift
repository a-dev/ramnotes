import ramnotesDomain
import Foundation

extension NoteStore {
    #if DEBUG
    /// Isolated UI fixture: the picker repairs a damaged bookmark without using personal files.
    func seedFolderAccessFixture() throws {
        guard identities.mapping.isEmpty else { return }
        let parent = defaultFolder().appendingPathComponent("Access Fixture", isDirectory: true)
        try StorageFiles.createDirectory(parent)
        let file = parent.appendingPathComponent("Folder access fixture.txt")
        try Data("Folder repair UI content".utf8).write(to: file)
        let location = NoteLocationRecord(id: NoteID(), resource: try StorageFiles.fileResourceID(file), path: file.path,
            parentResource: try StorageFiles.resourceID(parent),
            access: NoteAccessDescriptor(url: parent, bookmark: Data("damaged bookmark".utf8), scope: .folder))
        var updated = identities
        _ = updated.remember(location)
        try writeIdentities(updated)
    }

    /// Isolated manual-check fixture: every file-only grant gets bookmark data that cannot resolve,
    /// so Restore File Access can be tested on the session's own disposable notes.
    func damageFileBookmarksFixture() throws {
        var updated = identities
        for var record in identities.mapping {
            var changed = false
            if record.access?.scope == .file { record.access?.bookmark = Data("damaged bookmark".utf8); changed = true }
            if record.fileAccess?.scope == .file { record.fileAccess?.bookmark = Data("damaged bookmark".utf8); changed = true }
            if changed { _ = updated.remember(record) }
        }
        try writeIdentities(updated)
    }
    #endif

    /// Resolves registered files only. File-only grants remain file-only; sibling files are never listed.
    func customLocations(defaultURL: URL, only requestedID: NoteID? = nil, unchanged: Set<NoteID> = []) throws -> [NoteLocationRecord] {
        var custom: [NoteLocationRecord] = []
        let unfinished = Set(unfinishedLocationOperations().map(\.noteID))
        // Several IDs can share a path, so collisions check for any other owner.
        func pathOwners() -> [String: Set<NoteID>] {
            identities.catalog.notes.reduce(into: [:]) { $0[$1.value.path, default: []].insert($1.key) }
        }
        var owners = pathOwners()
        for original in identities.mapping {
            if let requestedID, original.id != requestedID { continue }
            if unfinished.contains(original.id) {
                var retained = original
                if (try? StorageFiles.supported(URL(fileURLWithPath: original.path))) != true {
                    retained.availability = .unavailable(reason: String(localized: "A location operation needs retry or review.", comment: "Reason shown for a note whose unfinished move or rename must be retried"))
                }
                custom.append(retained)
                continue
            }
            let oldURL = URL(fileURLWithPath: original.path).standardizedFileURL
            let wasDefault = oldURL.deletingLastPathComponent() == defaultURL.standardizedFileURL
            guard !wasDefault || original.fileAccess != nil else { continue }
            if wasDefault {
                if unchanged.contains(original.id) { continue }
                // The default-folder scanner owns replacements at the same path.
                // Only a bookmark that follows this note outside that path needs file restoration.
                guard let data = original.fileAccess?.bookmark,
                      let resolved = try? folderAccess.hooks.resolve(data),
                      resolved.url.standardizedFileURL != oldURL else { continue }
            }
            var location = original
            do {
                // Keep prior scopes alive until the narrowed descriptor is durable.
                let priorLeases = accessLeases[original.id] ?? []
                defer { withExtendedLifetime(priorLeases) {} }
                let restored = try restoreRegisteredFile(original)
                defer { withExtendedLifetime(restored) {} }
                let file = restored.0
                let target = file.url
                guard owners[target.path, default: []].subtracting([original.id]).isEmpty else {
                    throw NoteOperationError.conflict
                }
                location.fileAccess = restored.1
                location.access = nil
                if target != oldURL {
                    location.path = target.path
                    location.parentResource = try? StorageFiles.resourceID(target.deletingLastPathComponent())
                    location.revision.advance()
                }
                location.availability = trashService.contains(target) ? .trashed : .available
                var updated = identities
                _ = updated.remember(location)
                // Never release a legacy parent before the file descriptor is on disk.
                if updated.catalog.notes != identities.catalog.notes {
                    try fault(.accessMigrationCatalog)
                    try writeIdentities(updated)
                    owners = pathOwners()
                }
                accessLeases[location.id] = [file]
                accessFailures[location.id] = nil
            } catch {
                if original.availability == .trashed, StorageFiles.isMissing(oldURL) {
                    accessFailures[original.id] = nil
                    accessLeases[original.id] = nil
                    continue
                }
                // A failed migration keeps every descriptor and revision for retry/repair.
                location = original
                let failure = NoteFailureMapping.accessFailure(error)
                accessFailures[location.id] = original.access != nil && failure.reason == .unknown
                    ? NoteAccessFailure(reason: .staleBookmark, domain: failure.domain, code: failure.code, message: failure.message)
                    : failure
                location.availability = StorageFiles.isMissing(oldURL) ? .missingOriginal : .unavailable(reason: error.localizedDescription)
            }
            if URL(fileURLWithPath: location.path).deletingLastPathComponent().standardizedFileURL != defaultURL.standardizedFileURL {
                custom.append(location)
            }
        }
        return custom
    }

    /// Legacy parent access is used only here, and never acquired from a new path.
    /// Unfinished transactions bypass migration and retain their original evidence.
    private func restoreRegisteredFile(_ original: NoteLocationRecord) throws -> (FolderLease, NoteAccessDescriptor, FolderLease?) {
        func verified(_ descriptor: NoteAccessDescriptor) throws -> (FolderLease, NoteAccessDescriptor) {
            guard descriptor.scope == .file, descriptor.bookmark != nil else { throw NoteOperationError.unavailable }
            let restored = try folderAccess.restore(descriptor)
            guard try StorageFiles.supported(restored.0.url) else { throw NoteOperationError.unavailable }
            if try StorageFiles.fileResourceID(restored.0.url) != original.resource {
                // Preserve the existing observed-replacement rule. This authorizes reading,
                // never replaying an old buffer: save still checks identity and base revision.
                guard restored.0.url.standardizedFileURL.path == original.path,
                      let parent = original.parentResource,
                      try StorageFiles.resourceID(restored.0.url.deletingLastPathComponent()) == parent else {
                    throw NoteOperationError.conflict
                }
            }
            return restored
        }
        if let descriptor = original.fileAccess {
            do {
                let checked = try verified(descriptor)
                return (checked.0, checked.1, nil)
            }
            catch {
                // Once migrated there is no parent fallback during ordinary operation.
                guard original.access != nil else { throw error }
            }
        }
        guard let descriptor = original.access else { throw NoteOperationError.unavailable }
        let (parent, _) = try folderAccess.restore(descriptor)
        defer { withExtendedLifetime(parent) {} }
        let oldURL = URL(fileURLWithPath: original.path)
        let target = parent.url.appendingPathComponent(oldURL.lastPathComponent)
        guard try StorageFiles.supported(target) else { throw NoteOperationError.unavailable }
        let resource = try StorageFiles.fileResourceID(target)
        if resource != original.resource {
            guard target.standardizedFileURL.path == original.path,
                  let expectedParent = original.parentResource,
                  try StorageFiles.resourceID(parent.url) == expectedParent else { throw NoteOperationError.conflict }
        }
        // The derived URL has only the parent's existing authorization. Encode first,
        // then resolve the file bookmark to obtain its independent retained scope.
        let fileDescriptor = NoteAccessDescriptor(url: target,
            bookmark: try folderAccess.hooks.bookmark(target), scope: .file)
        // Resolve the newly encoded bookmark before replacing the legacy descriptor.
        let checked = try verified(fileDescriptor)
        guard checked.0.url.standardizedFileURL == target.standardizedFileURL,
              try StorageFiles.fileResourceID(checked.0.url) == resource else { throw NoteOperationError.conflict }
        return (checked.0, checked.1, parent)
    }

    #if DEBUG
    /// Seeds legacy parent-and-file authorization for compatibility and transaction tests.
    func registerCustomFile(_ url: URL, parent: FolderLease) throws -> NoteSnapshot {
        guard folder != nil else { throw NoteOperationError.unavailable }
        let parent = try folderAccess.acquire(parent.url)
        guard url.deletingLastPathComponent().standardizedFileURL == parent.url.standardizedFileURL,
              try StorageFiles.supported(url) else { throw NoteOperationError.unavailable }
        let file = try folderAccess.acquireFile(url)
        let resource = try StorageFiles.fileResourceID(url)
        if let existing = identities.mapping.first(where: { $0.resource != nil && $0.resource == resource }) {
            guard URL(fileURLWithPath: existing.path).resolvingSymlinksInPath().standardizedFileURL ==
                  url.resolvingSymlinksInPath().standardizedFileURL else { throw NoteOperationError.conflict }
            return try read(existing.id, collectionToken: collectionToken)
        }
        guard identities.identity(atPath: url.path, parentResource: try StorageFiles.resourceID(parent.url)) == nil else {
            throw NoteOperationError.conflict
        }
        let id = NoteID()
        var location = NoteLocationRecord(id: id, resource: resource, path: url.path,
            parentResource: try StorageFiles.resourceID(parent.url), access: try folderAccess.descriptor(for: parent))
        // Preserve the old dual-descriptor shape so tests exercise migration.
        let fileAccess = try folderAccess.descriptor(for: file, scope: .file)
        location.fileAccess = fileAccess
        var updated = identities
        _ = updated.remember(location)
        try writeIdentities(updated)
        accessLeases[id] = [parent, file]
        let note = snapshot(id: id, url: url, collectionToken: collectionToken)
        records[id] = note
        session.knownLocations[id] = url
        startObserving()
        emit(.discovered(note))
        return note
    }

    #endif
}

extension NoteLocationRecord {
    var applicationLocation: NoteLocation { NoteLocation(id: id, revision: revision) }
}

extension DefaultFolderBatch {
    var applicationResult: DefaultFolderResultBatch {
        DefaultFolderResultBatch(id: id, state: .init(rawValue: state.rawValue)!, entries: entries.map {
            .init(sourceID: $0.source.id, sourceURL: URL(fileURLWithPath: $0.source.path),
                  destination: $0.destination, state: .init(rawValue: $0.state.rawValue)!, message: $0.message)
        })
    }
}
