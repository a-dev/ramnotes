import ramnotesDomain
import Foundation
import Darwin

/// Coordinated filesystem facts and effects. The caller retains leases and owns all
/// durable checkpoints; the synchronous callback never releases the coordination claim.
enum LocationFiles {
    static func verifySource(_ source: NoteLocationRecord, revision: FileRevision?) throws {
        let url = URL(fileURLWithPath: source.path)
        guard let revision, source.resource != nil, try StorageFiles.supported(url),
              try StorageFiles.resourceID(url.deletingLastPathComponent()) == source.parentResource,
              try StorageFiles.fileResourceID(url) == source.resource,
              try StorageFiles.locationRevision(url) == revision else { throw NoteOperationError.conflict }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw NoteOperationError.conflict }
    }

    static func coordinate(source: URL, target: URL, presenter: NSFilePresenter?,
                           work: (URL, URL, NSFileCoordinator) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var failure: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: target, options: [], error: &failure) { from, to in
            result = Result { try work(from, to, coordinator) }
        }
        if let failure { throw failure }
        guard let result else { throw NoteOperationError.unavailable }
        try result.get()
    }

    static func createDestination(_ operation: LocationOperation, from: URL, to: URL,
                                  coordinator: NSFileCoordinator, fault: StorageFault) throws -> String {
        guard let revision = operation.expectedFileRevision else { throw NoteOperationError.conflict }
        // A same-volume rename can land before its checkpoint. The resource ID,
        // not matching text, proves the destination holds the original.
        let arrived = !operation.crossVolume &&
            (StorageFiles.isMissing(from) || (try? StorageFiles.fileResourceID(from)) != operation.source.resource) &&
            (try? StorageFiles.fileResourceID(to)) == operation.source.resource
        if !arrived {
            try verifySource(operation.source, revision: revision)
            if operation.crossVolume {
                try fault(.moveFilesystem)
                try StorageFiles.copyExclusive(from, to: to,
                    syncParentDirectory: operation.destination.scope != .file)
            } else {
                try fault(.moveFilesystem)
                try StorageFiles.renameExclusive(from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        try fault(.moveAfterFilesystem)
        guard try StorageFiles.supported(to), try StorageFiles.locationRevision(to) == revision else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("The destination could not be verified. Both locations were retained for review.", comment: "Error when a moved file could not be verified at its destination"))
        }
        guard let resource = try StorageFiles.fileResourceID(to) else { throw NoteOperationError.conflict }
        return resource
    }

    static func removeSource(_ operation: LocationOperation, from: URL, to: URL,
                             coordinator: NSFileCoordinator, syncParentDirectory: Bool,
                             fault: StorageFault) throws {
        guard let revision = operation.expectedFileRevision else { throw NoteOperationError.conflict }
        guard try StorageFiles.fileResourceID(to) == operation.destinationResource,
              try StorageFiles.locationRevision(to) == revision else { throw NoteOperationError.conflict }
        if operation.crossVolume, !StorageFiles.isMissing(from) {
            try verifySource(operation.source, revision: revision)
            try fault(.moveSourceRemoval)
            // Check again after the delay, under the same coordination.
            try verifySource(operation.source, revision: revision)
            guard try StorageFiles.fileResourceID(to) == operation.destinationResource,
                  try StorageFiles.locationRevision(to) == revision else { throw NoteOperationError.conflict }
            try FileManager.default.removeItem(at: from)
            if syncParentDirectory { try StorageFiles.syncDirectory(from.deletingLastPathComponent()) }
            coordinator.item(at: from, didMoveTo: to)
            try fault(.moveAfterSourceRemoval)
        } else if !operation.crossVolume {
            // A new file may now be at the old path. The original is verified
            // at the destination, so never touch the new file.
            guard operation.destinationResource == operation.source.resource else { throw NoteOperationError.conflict }
        }
    }

    static func verifyDestination(_ operation: LocationOperation, at target: URL) throws {
        guard let revision = operation.expectedFileRevision,
              try StorageFiles.supported(target),
              try StorageFiles.fileResourceID(target) == operation.destinationResource,
              try StorageFiles.read(target).revision == revision else { throw NoteOperationError.conflict }
    }
}

extension StorageFiles {
    /// Reads directly, inside a move that is already coordinated. A second coordinator
    /// here would wait on our own write claim and deadlock.
    static func locationRevision(_ url: URL) throws -> FileRevision {
        guard try supported(url) else { throw NoteOperationError.unavailable }
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
        guard values.ubiquitousItemDownloadingStatus != .notDownloaded else { throw NoteOperationError.unavailable }
        return FileRevision(fingerprint: digest(try Data(contentsOf: url)), modifiedAt: values.contentModificationDate ?? .distantPast)
    }

    static func volume(_ url: URL) throws -> String {
        guard let volume = try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { throw NoteOperationError.unavailable }
        return String(describing: volume)
    }

    static func renameExclusive(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw NoteOperationError.destinationOccupied }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try syncDirectory(destination.deletingLastPathComponent())
        if source.deletingLastPathComponent() != destination.deletingLastPathComponent() { try syncDirectory(source.deletingLastPathComponent()) }
    }

    static func copyExclusive(_ source: URL, to destination: URL, syncParentDirectory: Bool = true) throws {
        // COPYFILE_ALL keeps extended attributes, ACLs, permissions, flags, and times.
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL)) == 0 else {
            if errno == EEXIST { throw NoteOperationError.destinationOccupied }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let descriptor = open(destination.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        try StorageFiles.barrier(descriptor)
        // A Save panel authorizes the selected file, not opening its parent for fsync.
        // Flush the file above; sync the directory only with a retained folder grant.
        if syncParentDirectory { try syncDirectory(destination.deletingLastPathComponent()) }
    }
}
import Foundation

/// File effects for Save a Copy. The caller retains the destination grant and owns
/// collection registration after these write and verification steps succeed.
enum SaveCopyFiles {
    static func write(_ data: Data, to url: URL) throws {
        try StorageFiles.saveAuthorizedFile(data, at: url)
    }

    static func existingResourceID(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try StorageFiles.supported(url) else { throw NoteOperationError.unavailable }
        return try StorageFiles.fileResourceID(url)
    }

    static func verify(_ expected: Data, at url: URL) throws {
        guard try StorageFiles.coordinatedRead(url) == expected else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("Copy verification failed", comment: "Error when a copied file does not match the original"))
        }
    }
}
