import ramnotesDomain
import Foundation

actor NoteStore {
    let support: URL
    let folderAccess: FolderAccess
    var lease: FolderLease?
    var defaultAccessFailure: NoteOperationError?
    var edits = EditState()
    var preservedBuffers: [NoteID: EditSnapshot] {
        get { edits.preservedBuffers }
        _modify { yield &edits.preservedBuffers }
    }
    let trashService: TrashService
    let recovery: RecoveryStore
    /// Every snapshot and save read goes through here, so tests can count real reads.
    let readBody: @Sendable (URL) throws -> Data
    /// Recovery journals use a separate writer.
    let writeBody: @Sendable (Data, URL) throws -> Void
    let fault: StorageFault
    var observer: ExternalEventAdapter?
    var fileObservers: [NoteID: ExternalEventAdapter] = [:]
    private var observerToken: CollectionToken?
    private var fileObserverRevisions: [NoteID: LocationRevision] = [:]
    var accessFailures: [NoteID: NoteAccessFailure] = [:]
    var accessLeases: [NoteID: [FolderLease]] = [:]
    var reconcileTask: Task<Void, Never>?
    var subscribers: [UUID: AsyncStream<NoteEvent>.Continuation] = [:]
    /// How many events `emit` has published. Observers compare it with what they received.
    var emittedEventCount = 0
    var notices: [RecoveryNotice] = []
    var pending: [NoteID: EditSnapshot] {
        get { edits.pending }
        _modify { yield &edits.pending }
    }
    /// Writes journals and remembers which ones are already on disk.
    var journals: JournalWriter
    /// Change only through `setStatus`, which emits the change. No need to diff the whole dictionary.
    private(set) var statuses: [NoteID: StorageSaveStatus] = [:]
    func setStatus(_ id: NoteID, _ status: StorageSaveStatus) {
        guard statuses[id] != status else { return }
        statuses[id] = status
        emit(.saveStatus(id, collectionToken, status))
    }
    /// Drops a `.saved` status once no save is pending. The editor no longer needs it.
    func pruneStatus(_ id: NoteID) {
        if case .saved = statuses[id], pending[id] == nil { statuses.removeValue(forKey: id) }
    }
    func clearStatuses() { statuses.removeAll() }
    func clearStatus(_ id: NoteID) { statuses.removeValue(forKey: id) }
    var filenameGenerator: NoteFilenameGenerator
    let timing: StoreTiming
    let clock: any Clock
    /// Per-note state for this collection. Kept across default-folder changes.
    var session = CollectionSession()
    var journalRecords: [NoteID: RecoveryRecord] { session.journalRecords }
    var writing: Set<NoteID> { session.writing }
    var lastWritten: [NoteID: FileRevision] { session.lastWritten }
    var activeFolderIdentity: String?
    var folder: URL?
    var collectionToken = CollectionToken()
    /// Any change, even our own save, makes an earlier-started scan stale.
    var records: [NoteID: NoteSnapshot] = [:] { didSet { recordsEpoch &+= 1 } }
    private(set) var recordsEpoch = 0
    let scanner: FolderScanner
    /// File-event reconciles: one pass runs, and at most one more waits.
    var reconcileRunning = false
    var reconcileOwed = false
    /// File text by path, valid while the stamp is unchanged. An unchanged note then costs
    /// one stat per reconcile, not a read and a hash.
    var bodyCache: [String: CachedBody] = [:]
    /// Reconcile passes started. Lets tests see scans we caused ourselves.
    var reconcileCount = 0
    private(set) var identities = IdentityMap()
    /// The map in memory is newer than collection.json. A deferred write is pending or failed.
    private(set) var identitiesDirty = false
    private var identityWrite: Task<Void, Never>?

    init(support: URL, clock: any Clock = SystemClock(), timing: StoreTiming = StoreTiming(), fault: @escaping StorageFault = { _ in }, trashService: TrashService = TrashService(), folderAccessHooks: FolderAccessHooks = FolderAccessHooks(), readBody: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }, filenameGenerator: NoteFilenameGenerator? = nil, writeBody: @escaping @Sendable (Data, URL) throws -> Void = { try StorageFiles.atomic($0, at: $1) }) throws {
        self.writeBody = writeBody
        self.readBody = readBody
        scanner = FolderScanner(readBody: readBody)
        self.support = support
        self.clock = clock
        self.timing = timing
        self.filenameGenerator = filenameGenerator ?? NoteFilenameGenerator()
        self.fault = fault
        self.trashService = trashService
        folderAccess = FolderAccess(support: support, hooks: folderAccessHooks)
        recovery = RecoveryStore(root: support.appendingPathComponent("Recovery"), fault: fault)
        journals = JournalWriter(store: recovery)
        try StorageFiles.createDirectory(support.appendingPathComponent("Notes"))
        try StorageFiles.createDirectory(support.appendingPathComponent("Recovery"))
        let catalogURL = support.appendingPathComponent("collection.json")
        let loaded = try CatalogPersistence.load(at: catalogURL)
        let pruned = loaded.pruningOrphans().pruningFinished()
        if pruned != loaded { try? CatalogPersistence.save(pruned, at: catalogURL) }
        identities = IdentityMap(catalog: pruned)
        notices = Array(identities.catalog.recoveryLinks.values)
    }

    /// The app uses this factory, so startup I/O also runs off the main actor.
    static func make(support: URL, clock: any Clock = SystemClock(), fault: @escaping StorageFault = { _ in },
                     trashService: TrashService = TrashService(), folderAccessHooks: FolderAccessHooks = FolderAccessHooks()) async throws -> NoteStore {
        try await Task.detached {
            try NoteStore(support: support, clock: clock, timing: .app, fault: fault, trashService: trashService, folderAccessHooks: folderAccessHooks)
        }.value
    }

    deinit {
        observer?.cancel()
        for presenter in fileObservers.values { presenter.cancel() }
        reconcileTask?.cancel()
        identityWrite?.cancel()
        session.cancelSaves()
    }

    func defaultFolder() -> URL { support.appendingPathComponent("Notes", isDirectory: true) }

    func isDefaultFolderMissing(collectionToken: CollectionToken) throws -> Bool {
        try validate(collectionToken)
        guard let folder else { return false }
        return StorageFiles.isFolderMissing(folder)
    }

    func discover(in folder: URL, collectionToken: CollectionToken) throws -> [NoteSnapshot] {
        if let active = self.folder {
            try validate(collectionToken)
            guard active.standardizedFileURL == folder.standardizedFileURL else { throw NoteOperationError.staleCollection }
        }
        let found = try scan(in: folder, collectionToken: collectionToken)
        activeFolderIdentity = try StorageFiles.resourceID(folder)
        self.folder = folder
        self.collectionToken = collectionToken
        records = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        for note in found { session.knownLocations[note.id] = note.fileURL }
        return found
    }

    func discoverIdentities(in folder: URL) throws -> IdentityDiscovery {
        try Task.checkCancellation()
        let candidates = try FolderScanner.candidates(in: folder) { try Task.checkCancellation() }
        let key = try StorageFiles.resourceID(folder)
        return IdentityDiscovery(folderIdentity: key, folderURL: folder,
            mapping: try IdentityResolution.resolve(candidates, previous: identities.mapping))
    }

    func loadSnapshots(_ discovery: IdentityDiscovery, collectionToken: CollectionToken,
                       progress: (@Sendable ([NoteSnapshot]) -> Void)? = nil) throws -> [NoteSnapshot] {
        var found: [NoteSnapshot] = []
        for (index, identity) in discovery.mapping.enumerated() {
            try Task.checkCancellation()
            var note = snapshot(id: identity.id, url: URL(fileURLWithPath: identity.path), collectionToken: collectionToken)
            note.locationRevision = identity.revision
            found.append(note)
            try Task.checkCancellation()
            if index == 0 || (index + 1).isMultiple(of: 32) { progress?(found) }
        }
        // A full pass lists every live file. Drop entries for missing files and other folders.
        let live = Set(discovery.mapping.map(\.path))
        bodyCache = bodyCache.filter { live.contains($0.key) }
        return found
    }

    /// If loading fails or is cancelled, saved mappings and published records stay as they are.
    /// Progress snapshots are provisional. After the atomic write succeeds, callers install
    /// records and publish events with no further `await`.
    func commitIdentities(_ discovery: IdentityDiscovery) throws {
        try Task.checkCancellation()
        var updated = identities
        var mapping = discovery.mapping
        let found = Set(mapping.map(\.id))
        var dropped: [(id: NoteID, path: String)] = []
        for location in identities.mapping where location.availability == .trashed && !found.contains(location.id) {
            if StorageFiles.isMissing(URL(fileURLWithPath: location.path)) {
                updated.remove(location.id)
                dropped.append((location.id, location.path))
            }
        }
        // Access repair is transient. Discovery must not replace a failed migration's
        // durable record with its unavailable presentation snapshot.
        for index in mapping.indices where accessFailures[mapping[index].id] != nil {
            if let original = identities.identity(mapping[index].id) { mapping[index] = original }
        }
        // A file bookmark lets us find a moved note after a restart without guessing
        // from its name or text.
        for index in mapping.indices where mapping[index].fileAccess == nil && mapping[index].availability == .available && accessFailures[mapping[index].id] == nil {
            let url = URL(fileURLWithPath: mapping[index].path)
            if let bookmark = try? folderAccess.hooks.bookmark(url) {
                mapping[index].fileAccess = NoteAccessDescriptor(url: url, bookmark: bookmark, scope: .file)
            }
        }
        _ = updated.set(mapping, parentResource: discovery.folderIdentity)
        guard updated.catalog.notes != identities.catalog.notes || identitiesDirty else { return }
        try writeIdentities(updated)
        for note in dropped { forget(note.id, path: note.path) }
    }

    func scan(in folder: URL, collectionToken: CollectionToken, commit: Bool = true,
              progress: (@Sendable ([NoteSnapshot]) -> Void)? = nil) throws -> [NoteSnapshot] {
        let discovery = try discoverIdentities(in: folder)
        let found = try loadSnapshots(discovery, collectionToken: collectionToken, progress: progress)
        if commit { try commitIdentities(discovery) }
        return found
    }

    func knownNote(_ id: NoteID) -> NoteSnapshot? {
        if let note = records[id] { return note }
        guard let url = session.knownLocations[id] else { return nil }
        return snapshot(id: id, url: url, collectionToken: collectionToken)
    }

    func knownResourceIdentity(_ id: NoteID) -> String? {
        identities.identity(id)?.resource
    }

    /// Skips the write if nothing changed. Use `deferred` after an atomic replacement,
    /// which always changes the file ID. A deferred change defers the catalog checkpoint.
    /// The scheduled write or a flush persists the new identity.
    func rememberIdentity(_ note: NoteSnapshot, deferred: Bool = false) throws {
        guard folder != nil else { throw NoteOperationError.unavailable }
        var updated = identities
        var identity = identities.identity(note.id) ?? NoteLocationRecord(id: note.id, resource: nil, path: note.fileURL.path)
        if identity.path != note.fileURL.path { identity.revision.advance() }
        if let bookmark = try? folderAccess.hooks.bookmark(note.fileURL) {
            identity.fileAccess = NoteAccessDescriptor(url: note.fileURL, bookmark: bookmark, scope: .file)
        }
        identity.resource = try StorageFiles.fileResourceID(note.fileURL)
        identity.path = note.fileURL.path
        identity.parentResource = try StorageFiles.resourceID(note.fileURL.deletingLastPathComponent())
        // A non-deferred call also writes any pending deferred change.
        guard updated.remember(identity) || (!deferred && identitiesDirty) else { return }
        guard deferred else { return try writeIdentities(updated) }
        deferIdentityWrite(updated)
    }

    /// Keeps an in-memory catalog change and schedules its durable checkpoint.
    func deferIdentityWrite(_ updated: IdentityMap) {
        identities = updated
        identitiesDirty = true
        guard identityWrite == nil else { return }
        identityWrite = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.writeIdentitiesIfDirty()
        }
    }

    /// A replacement is not complete until its new file grant and identity are durable.
    func checkpointSavedIdentity(_ note: NoteSnapshot) throws {
        guard var identity = identities.identity(note.id) else { throw NoteOperationError.unavailable }
        identity.resource = try StorageFiles.fileResourceID(note.fileURL)
        identity.path = note.fileURL.path
        // Retain the verified identity in memory even if bookmark creation or persistence fails.
        // The pending edit and journal remain until a later successful checkpoint.
        _ = identities.remember(identity)
        identitiesDirty = true
        identity.fileAccess = NoteAccessDescriptor(url: note.fileURL,
            bookmark: try folderAccess.hooks.bookmark(note.fileURL), scope: .file)
        var updated = identities
        _ = updated.remember(identity)
        try writeIdentities(updated)
    }

    /// Installs `updated` only after it is on disk. A failed write keeps the old map.
    func writeIdentities(_ updated: IdentityMap) throws {
        let url = support.appendingPathComponent("collection.json")
        let disk = try CatalogPersistence.load(at: url)
        // A note dropped from the map is forgotten everywhere in the catalog, not only in `notes`.
        let dropped = Set(disk.notes.keys).subtracting(updated.catalog.notes.keys)
        var catalog = disk.forgetting(dropped)
        catalog.notes = updated.catalog.notes
        try CatalogPersistence.save(catalog, at: url)
        identities = IdentityMap(catalog: catalog)
        identitiesDirty = false
    }

    func installCatalog(_ catalog: CollectionCatalog) {
        identities = IdentityMap(catalog: catalog)
        recordsEpoch &+= 1
    }

    /// Durable-record checkpoint. Starts from collection.json so records written outside the
    /// in-memory map survive, then takes the in-memory notes, including deferred identities.
    /// Installs only after the save succeeds. A load failure leaves a corrupt catalog untouched.
    /// Keep `mutate` synchronous: no suspension may split the load, save, and install.
    func checkpointDiskCatalog(_ mutate: (inout CollectionCatalog) throws -> Void) throws {
        var catalog = try CatalogPersistence.load(at: folderAccess.selectionURL)
        catalog.notes = identities.catalog.notes
        try mutate(&catalog)
        try CatalogPersistence.save(catalog, at: folderAccess.selectionURL)
        installCatalog(catalog)
    }

    /// In-memory checkpoint. The installed map is the source of truth. Installs only after
    /// the save succeeds. Keep `mutate` synchronous.
    func checkpointMemoryCatalog(_ mutate: (inout CollectionCatalog) throws -> Void) throws {
        var catalog = identities.catalog
        try mutate(&catalog)
        try CatalogPersistence.save(catalog, at: folderAccess.selectionURL)
        installCatalog(catalog)
    }

    /// Best effort. On failure, the map stays dirty for the next write or flush.
    func writeIdentitiesIfDirty() {
        identityWrite?.cancel()
        identityWrite = nil
        guard identitiesDirty else { return }
        try? writeIdentities(identities)
    }

    /// Registers a file this store just wrote, without a folder scan. A known path with the
    /// same file ID keeps its NoteID, so a retried promotion is safe to repeat.
    func adopt(_ url: URL) throws -> NoteSnapshot {
        guard activeFolderIdentity != nil else { throw NoteOperationError.unavailable }
        let resource = try StorageFiles.fileResourceID(url)
        let known = identities.identity(atPath: url.path, parentResource: try StorageFiles.resourceID(url.deletingLastPathComponent())).flatMap { $0.resource != nil && $0.resource == resource ? $0 : nil }
        let note = snapshot(id: known?.id ?? NoteID(), url: url, collectionToken: collectionToken)
        try rememberIdentity(note)
        records[note.id] = note
        session.knownLocations[note.id] = url
        return note
    }

    func read(_ id: NoteID, collectionToken: CollectionToken) throws -> NoteSnapshot {
        try validate(collectionToken)
        guard let record = records[id] else { throw NoteOperationError.unavailable }
        var url = record.fileURL
        var failure = defaultAccessFailure
        if let folder, url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            _ = try customLocations(defaultURL: folder, only: id)
            if let location = identities.identity(id) {
                url = URL(fileURLWithPath: location.path)
                failure = location.availability == .available ? nil : accessFailures[id].map(NoteOperationError.accessFailure) ?? .unavailable
            }
        }
        var current: NoteSnapshot
        if let failure {
            current = NoteSnapshot(id: id, collectionToken: collectionToken, fileURL: url, fileRevision: nil, text: "",
                availability: StorageFiles.isMissing(url) ? .missingOriginal : .unavailable(reason: failure.localizedDescription), locationRevision: identities.identity(id)?.revision ?? LocationRevision())
        } else { current = snapshot(id: id, url: url, collectionToken: collectionToken) }
        requestDownloadIfEvicted(current)
        current.accessFailure = accessFailures[id] ?? current.accessFailure
        records[id] = current
        return current
    }

    func create(in folder: URL, collectionToken: CollectionToken) throws -> NoteSnapshot {
        if let active = self.folder {
            try validate(collectionToken)
            guard active.standardizedFileURL == folder.standardizedFileURL else { throw NoteOperationError.staleCollection }
        } else {
            _ = try discover(in: folder, collectionToken: collectionToken)
        }
        for _ in 1...10_000 {
            let name = filenameGenerator.next()
            let url = folder.appendingPathComponent(name)
            do { try StorageFiles.create(Data(), at: url) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) { continue }
            // We know the new file, so skip the O(folder) scan for each New Note.
            // The observer still reports changes to other notes.
            let note = try adopt(url)
            emit(.discovered(note))
            return note
        }
        throw NoteOperationError.inputOutput(LocalizedStringResource("No free filename", comment: "Error when no unused file name could be found for a new note"))
    }

    func startObserving() {
        guard let folder else { return }
        let token = collectionToken
        if observerToken != token {
            observer?.cancel()
            observer = nil
            for presenter in fileObservers.values { presenter.cancel() }
            fileObservers.removeAll()
            fileObserverRevisions.removeAll()
            observerToken = token
        }
        let custom = records.filter {
            $0.value.fileURL.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL
        }
        for id in fileObservers.keys where custom[id] == nil {
            fileObservers.removeValue(forKey: id)?.cancel()
            fileObserverRevisions.removeValue(forKey: id)
        }
        // Reconcile and each batch entry come back here. Keep unchanged presenters.
        // Rebuilding all of them would multiply coordination work by the files moved.
        for (id, note) in custom {
            let revision = note.locationRevision
            if let existing = fileObservers[id], existing.isActive, existing.presentedItemURL == note.fileURL,
               fileObserverRevisions[id] == revision { continue }
            fileObservers.removeValue(forKey: id)?.cancel()
            fileObservers[id] = ExternalEventAdapter(folder: note.fileURL, observesActivation: false) { [weak self] url in
                Task { await self?.customExternalEvent(id: id, revision: revision, token: token, at: url) }
            }
            fileObserverRevisions[id] = revision
        }
        if observer?.presentedItemURL != folder || observer?.isActive == false {
            observer?.cancel()
            observer = ExternalEventAdapter(folder: folder) { [weak self] url in
                Task { await self?.externalEvent(collectionToken: token, at: url) }
            }
        }
    }

    func customExternalEvent(id: NoteID, revision: LocationRevision, token: CollectionToken, at url: URL?) {
        guard token == collectionToken, identities.identity(id)?.revision == revision else { return }
        externalEvent(collectionToken: token, at: url)
    }

    func validate(_ requested: CollectionToken) throws {
        guard requested == collectionToken else { throw NoteOperationError.staleCollection }
    }

    /// A rescan may serve an evicted file from the cache. Opening it brings the file back,
    /// so that saving finds local bytes.
    func requestDownloadIfEvicted(_ note: NoteSnapshot) {
        guard note.availability == .available, StorageFiles.isDataless(note.fileURL) else { return }
        StorageFiles.startDownloading(note.fileURL)
    }

    func snapshot(id: NoteID, url: URL, collectionToken: CollectionToken) -> NoteSnapshot {
        var result = FolderScanner.snapshot(id: id, url: url, collectionToken: collectionToken, editRevision: session.completions[id]?.revision ?? EditRevision(rawValue: 0),
                               cache: &bodyCache, readBody: readBody)
        result.accessFailure = accessFailures[id] ?? result.accessFailure
        result.locationRevision = identities.identity(id)?.revision ?? LocationRevision()
        return result
    }
}
