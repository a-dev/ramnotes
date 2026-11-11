import ramnotesDomain
import Foundation
import Synchronization

/// Reads a notes folder off the storage actor. Coordinated reads block their thread, so a
/// scan on the storage actor would hold up every save and journal write.
/// The result depends only on the inputs. The storage actor decides if it still applies.
struct FolderScanner: Sendable {
    struct Scan: Sendable {
        let discovery: IdentityDiscovery
        /// Edit revisions are zero here. The storage actor fills them in when it applies the scan.
        let snapshots: [NoteSnapshot]
        /// The input cache, refreshed and trimmed to the files that still exist.
        let cache: [String: CachedBody]
    }

    struct Candidates: Sendable {
        let files: [FileCandidate]
        let parentResource: String?
        let failure: NoteOperationError?

        static func capture(_ folder: URL, failure: NoteOperationError?) -> Self {
            do {
                if let failure { throw failure }
                let files = try FolderScanner.candidates(in: folder) { try Task.checkCancellation() }
                return Self(files: files, parentResource: try StorageFiles.fileResourceID(folder), failure: nil)
            } catch {
                return Self(files: [], parentResource: nil, failure: NoteFailureMapping.operationError(error))
            }
        }

        func unchangedIDs(previous: [NoteLocationRecord]) -> Set<NoteID> {
            let old = Dictionary(grouping: previous.compactMap { $0.resource }, by: { $0 })
            let current = Dictionary(grouping: files.compactMap { $0.resource }, by: { $0 })
            let paths = Dictionary(grouping: files, by: { $0.url.path })
            let ids = Dictionary(grouping: previous, by: \.id)
            return Set(previous.compactMap { location in
                guard failure == nil, location.availability == .available,
                      let resource = location.resource, let parent = location.parentResource,
                      old[resource]?.count == 1, current[resource]?.count == 1,
                      ids[location.id]?.count == 1,
                      let matches = paths[location.path], matches.count == 1,
                      matches[0].resource == resource, matches[0].parentResource == parent,
                      parentResource == parent else { return nil }
                return location.id
            })
        }
    }

    func candidatesSnapshot(_ folder: URL, failure: NoteOperationError?) async -> Candidates {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: Candidates.capture(folder, failure: failure)) }
        }
    }

    /// Private and serial, so blocking I/O stays off Swift concurrency threads and
    /// overlapping scans don't multiply disk load.
    private static let queue = DispatchQueue(label: "ramnotes.folder-scanner", qos: .utility)
    let readBody: @Sendable (URL) throws -> Data

    func scan(_ folder: URL, identities: IdentityMap, cache: [String: CachedBody],
              collectionToken: CollectionToken, custom: [NoteLocationRecord] = [], defaultFailure: NoteOperationError? = nil, candidates: Candidates? = nil) async throws -> Scan {
        let cancelled = CancelFlag()
        let check: @Sendable () throws -> Void = { if cancelled.isSet { throw CancellationError() } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try run(folder, identities: identities, cache: cache, collectionToken: collectionToken, custom: custom, defaultFailure: defaultFailure, prepared: candidates, check: check)
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    func run(_ folder: URL, identities: IdentityMap, cache: [String: CachedBody],
                     collectionToken: CollectionToken, custom: [NoteLocationRecord], defaultFailure: NoteOperationError? = nil, prepared: Candidates? = nil, check: () throws -> Void) throws -> Scan {
        var candidates: [FileCandidate] = []
        var unavailable: [NoteLocationRecord] = []
        let key: String
        do {
            if let defaultFailure { throw defaultFailure }
            if let prepared {
                if let failure = prepared.failure { throw failure }
                candidates = prepared.files
                key = try prepared.parentResource ?? StorageFiles.resourceID(folder)
            } else {
                candidates = try Self.candidates(in: folder, check: check)
                key = try StorageFiles.resourceID(folder)
            }
        } catch {
            try check()
            guard !identities.mapping.isEmpty else { throw error }
            key = identities.mapping.first { URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }?.parentResource ?? "unavailable:\(folder.path)"
            unavailable = identities.mapping.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }.map {
                var location = $0
                location.availability = .unavailable(reason: NoteFailureMapping.operationError(error).localizedDescription)
                return location
            }
        }
        // An unfinished move owns both its source and destination. Don't list the
        // destination as a second note before the catalog records the move.
        let operations = identities.catalog.operations.values.filter { $0.stage != .complete }
        candidates.removeAll { candidate in
            operations.contains { operation in
                candidate.url.path != operation.source.path &&
                candidate.url.lastPathComponent == operation.destinationName &&
                candidate.url.deletingLastPathComponent().standardizedFileURL == operation.destination.url.standardizedFileURL &&
                (candidate.resource == operation.destinationResource || (!operation.crossVolume && candidate.resource == operation.source.resource))
            }
        }
        var candidatePaths = Set(candidates.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        for location in custom {
            try check()
            let url = URL(fileURLWithPath: location.path)
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            if candidatePaths.contains(canonicalPath) { continue }
            if location.availability == .available, (try? StorageFiles.supported(url)) == true {
                candidatePaths.insert(canonicalPath)
                candidates.append(FileCandidate(url: url, resource: try? StorageFiles.fileResourceID(url),
                    parentResource: try? StorageFiles.resourceID(url.deletingLastPathComponent())))
            } else { unavailable.append(location) }
        }
        var mapping = try IdentityResolution.resolve(candidates, previous: identities.mapping)
        let bound = Set(mapping.map(\.id))
        mapping += unavailable.filter { !bound.contains($0.id) }
        let parents = mapping.reduce(into: [URL: String]()) { parents, identity in
            if identity.availability == .available, let resource = identity.parentResource {
                parents[URL(fileURLWithPath: identity.path).deletingLastPathComponent()] = resource
            }
        }
        try Self.checkParents(parents)
        var cache = cache
        var snapshots: [NoteSnapshot] = []
        for identity in mapping {
            try check()
            var note: NoteSnapshot
            if identity.availability != .available {
                note = NoteSnapshot(id: identity.id, collectionToken: collectionToken, fileURL: URL(fileURLWithPath: identity.path),
                    fileRevision: nil, text: "", availability: identity.availability, locationRevision: identity.revision)
            } else {
                // Enumeration is evidence for bookmark reuse, not permission to bind
                // replacement bytes to the enumerated file's identity.
                note = Self.snapshot(id: identity.id, url: URL(fileURLWithPath: identity.path), collectionToken: collectionToken,
                    editRevision: EditRevision(rawValue: 0), cache: &cache, readBody: readBody)
                note.locationRevision = identity.revision
                if note.availability == .available { try Self.checkIdentity(identity) }
            }
            snapshots.append(note)
        }
        try Self.checkParents(parents)
        let live = Set(mapping.map(\.path))
        return Scan(discovery: IdentityDiscovery(folderIdentity: key, folderURL: folder, mapping: mapping),
                    snapshots: snapshots, cache: cache.filter { live.contains($0.key) })
    }

    private static func checkIdentity(_ identity: NoteLocationRecord) throws {
        let url = URL(fileURLWithPath: identity.path)
        // Missing or unreadable files still become unavailable snapshots. A readable
        // replacement must instead wait for a new enumeration and identity decision.
        if let expected = identity.resource, let current = try? StorageFiles.fileResourceID(url),
           current != expected { throw NoteOperationError.conflict }
    }

    private static func checkParents(_ parents: [URL: String]) throws {
        for (url, expected) in parents {
            if let current = try? StorageFiles.resourceID(url), current != expected {
                throw NoteOperationError.conflict
            }
        }
    }

    static func candidates(in folder: URL, check: () throws -> Void) throws -> [FileCandidate] {
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        StorageFiles.removeStaleTemporaries(among: children)
        let parentResource = try StorageFiles.resourceID(folder)
        var candidates: [FileCandidate] = []
        for url in children {
            try check()
            // On a metadata error, throw. Don't report the note as deleted.
            guard try StorageFiles.supported(url) else { continue }
            candidates.append(FileCandidate(url: url, resource: try StorageFiles.fileResourceID(url), parentResource: parentResource))
        }
        return candidates
    }

    static func snapshot(id: NoteID, url: URL, collectionToken: CollectionToken, editRevision: EditRevision,
                         cache: inout [String: CachedBody], readBody: @Sendable (URL) throws -> Data) -> NoteSnapshot {
        do {
            let value = try read(url, cache: &cache, readBody: readBody)
            return NoteSnapshot(id: id, collectionToken: collectionToken, fileURL: url, fileRevision: value.revision, text: value.text, availability: .available, editRevision: editRevision, createdAt: value.createdAt)
        } catch {
            return NoteSnapshot(id: id, collectionToken: collectionToken, fileURL: url, fileRevision: nil, text: "", availability: StorageFiles.isMissing(url) ? .missingOriginal : .unavailable(reason: error.localizedDescription), accessFailure: NoteFailureMapping.accessFailure(error), editRevision: editRevision)
        }
    }

    /// Takes the stamp before the read. If a write races the read, the stamp is old and
    /// mismatches next time. It never marks newer bytes as unchanged.
    static func read(_ url: URL, cache: inout [String: CachedBody],
                     readBody: @Sendable (URL) throws -> Data) throws -> (text: String, revision: FileRevision, createdAt: Date?) {
        let stamp = try? StorageFiles.stamp(url)
        // A symlink put in place of a moved file can have the same stamp. Check the file again.
        if let stamp, let cached = cache[url.path], cached.stamp == stamp, (try? StorageFiles.supported(url)) == true {
            return (cached.text, cached.revision, stamp.created)
        }
        // A rescan must not undo Remove Download or Optimize Mac Storage. Keep the
        // cached text and the downloaded stamp. Launch and opening the note still read.
        if let stamp, let cached = cache[url.path], stamp.isEvictedCopy(of: cached.stamp),
           (try? StorageFiles.supported(url)) == true {
            return (cached.text, cached.revision, stamp.created)
        }
        do {
            let value = try StorageFiles.read(url, readBody: readBody)
            if let stamp { cache[url.path] = CachedBody(stamp: stamp, text: value.text, revision: value.revision) }
            else { cache[url.path] = nil }
            return (value.text, value.revision, stamp?.created ?? StorageFiles.creationDate(url))
        } catch {
            cache[url.path] = nil
            throw error
        }
    }
}

/// Task cancellation can't reach a GCD block, so the scan checks this flag between files.
private final class CancelFlag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}
