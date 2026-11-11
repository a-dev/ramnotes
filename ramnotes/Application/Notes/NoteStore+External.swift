import ramnotesDomain
import Foundation
import os

extension NoteStore {
    /// Reconcile identity and protect retained edits before exposing fresh disk state.
    func verifyForPresentation(_ note: NoteSnapshot) async throws -> NoteSnapshot {
        try validate(note.collectionToken)
        guard let result = try await verifyForPresentation([note])[note.id] else { throw NoteOperationError.unavailable }
        return try result.get()
    }

    /// One reconciliation pass serves every note in a presentation operation;
    /// each note keeps its own location and retained-edit guards.
    func verifyForPresentation(_ notes: [NoteSnapshot]) async throws -> [NoteID: Result<NoteSnapshot, Error>] {
        guard let token = notes.first?.collectionToken else { return [:] }
        try validate(token)
        let edits = Dictionary(notes.map { ($0.id, pending[$0.id]?.revision) }, uniquingKeysWith: { lhs, _ in lhs })
        let completed = Dictionary(notes.map { ($0.id, session.completions[$0.id]?.revision) }, uniquingKeysWith: { lhs, _ in lhs })
        try await reconcile(collectionToken: token)
        try validate(token)
        var results: [NoteID: Result<NoteSnapshot, Error>] = [:]
        for note in notes {
            results[note.id] = Result {
                guard note.collectionToken == token else { throw NoteOperationError.cancelled }
                guard let current = records[note.id] else { throw NoteOperationError.unavailable }
                guard current.locationRevision == note.locationRevision else { throw NoteOperationError.staleLocation }
                let edit = edits[note.id] ?? nil
                let baseline = completed[note.id] ?? nil
                guard edit != nil || baseline == session.completions[note.id]?.revision,
                      !session.writing.contains(note.id), pending[note.id] == nil,
                      edit == nil || session.completions[note.id]?.revision == edit else {
                    throw NoteOperationError.cancelled
                }
                requestDownloadIfEvicted(current)
                return current
            }
        }
        return results
    }

    func events() -> AsyncStream<NoteEvent> {
        let id = UUID()
        let pair = AsyncStream<NoteEvent>.makeStream()
        subscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return pair.stream
    }

    /// Subscribes and returns how many events were published before this subscription.
    func subscribe() -> (events: AsyncStream<NoteEvent>, published: Int) { (events(), emittedEventCount) }
    func publishedEventCount() -> Int { emittedEventCount }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
    func emit(_ event: NoteEvent) {
        emittedEventCount += 1
        for subscriber in subscribers.values { subscriber.yield(event) }
    }
    func recoveryNotices() -> [RecoveryNotice] { notices }
    /// Every note the catalog knows, available or not. Presentation state for any other ID is stale.
    func registeredNoteIDs() -> Set<NoteID> { Set(identities.catalog.notes.keys) }

    /// The catalog is the only durable home of recovery notices.
    func forgetRecoveryNotices(_ recoveryURLs: Set<URL>) throws {
        guard !recoveryURLs.isEmpty else { return }
        try checkpointDiskCatalog { catalog in
            catalog.recoveryLinks = catalog.recoveryLinks.filter { !recoveryURLs.contains($0.value.recoveryURL) }
        }
        notices.removeAll { recoveryURLs.contains($0.recoveryURL) }
    }

    /// Also handles dropped or merged events, availability retry, and app activation.
    /// Ignores a file event that surely changed nothing. macOS reports our own writes
    /// through FSEvents even when we name our presenter.
    func externalEvent(collectionToken token: CollectionToken, at url: URL? = nil) {
        guard token == collectionToken else { return }
        if let url, isUnchanged(url) { return }
        // Cancel only the debounce, never a running pass. Otherwise a steady stream of
        // events, such as an iCloud upload, could stop every pass from finishing.
        reconcileTask?.cancel()
        let debounce = timing.reconcileDebounce
        reconcileTask = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.requestReconcile(collectionToken: token)
        }
    }

    /// Requests that arrive during a pass merge into one follow-up pass.
    private func requestReconcile(collectionToken token: CollectionToken) {
        guard token == collectionToken else { return }
        reconcileOwed = true
        guard !reconcileRunning else { return }
        reconcileRunning = true
        Task { [weak self] in await self?.drainReconcile() }
    }

    private func drainReconcile() async {
        while reconcileOwed {
            reconcileOwed = false
            // Read the token now, so after a folder switch the follow-up scans the new folder.
            let token = collectionToken
            do { try await reconcile(collectionToken: token) }
            catch is CancellationError {}
            catch { externalFailure(NoteFailureMapping.operationError(error), collectionToken: token) }
        }
        reconcileRunning = false
    }

    /// True only if the event cannot change what a scan would see. When in doubt (nested
    /// paths, missing stamps, uncached files), returns false and a full reconcile runs.
    private func isUnchanged(_ url: URL) -> Bool {
        guard let folder,
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path else { return false }
        let name = url.lastPathComponent
        if name.hasPrefix(StorageFiles.temporaryPrefix) && url.pathExtension.isEmpty { return true }
        let local = folder.appendingPathComponent(name)
        guard let cached = bodyCache[local.path], let stamp = try? StorageFiles.stamp(local) else { return false }
        return cached.stamp == stamp
    }

    private func externalFailure(_ error: NoteOperationError, collectionToken token: CollectionToken) {
        guard token == collectionToken else { return }
        emit(.failed(nil, error))
    }

    func setWriting(_ active: Bool, for id: NoteID) async throws {
        if active { session.writing.insert(id) }
        else {
            session.writing.remove(id)
            try await reconcile(collectionToken: collectionToken)
        }
    }

    /// Submits the text from the end of a composition, then allows external reconcile again.
    func finishWriting(_ capturedEdit: EditSnapshot) async throws {
        try validate(capturedEdit.collectionToken)
        var edit = capturedEdit
        // This capture has the latest text. Point it at the note's verified location.
        // Ordinary saves to the old location still fail.
        if session.writing.contains(edit.id), let location = identities.identity(edit.id),
           location.revision != edit.locationRevision {
            edit = EditSnapshot(id: edit.id, collectionToken: edit.collectionToken, revision: edit.revision,
                baseRevision: edit.baseRevision, text: edit.text, locationRevision: location.revision)
        }
        let result = submit(edit)
        let captured = pending[edit.id]?.revision == edit.revision
        let alreadySaved = (session.completions[edit.id]?.revision).map { $0 >= edit.revision } == true
        guard captured || alreadySaved else {
            if case let .failed(_, error, _) = result { throw error }
            throw NoteOperationError.unavailable
        }
        // Every keystroke arrives here. Reconcile only when a composition ends.
        // A scan per keystroke would delay the next recovery journal.
        if session.writing.remove(edit.id) != nil {
            try await reconcile(collectionToken: collectionToken)
        }
    }

    /// Scans on `FolderScanner`, so saves and journal writes never wait for a scan.
    /// Applies the result only if `records` did not change during the scan. Otherwise it
    /// could publish bytes older than ours. Retries are cheap thanks to the stat cache.
    /// If changes keep coming, the last pass runs on the actor, where nothing can interleave.
    func reconcile(collectionToken token: CollectionToken) async throws {
        try validate(token)
        reconcileCount += 1
        for diagnostic in reconcileLocationOperations() {
            emit(.failed(nil, .inputOutput(diagnostic)))
        }
        // The folder itself can move while the app runs. Refresh its bookmark but
        // keep the collection token.
        // One catalog read per pass. Recreate the bookmark only when it is stale or the folder moved.
        var catalog = try CatalogPersistence.load(at: folderAccess.selectionURL)
        if catalog.defaultFolder != nil {
            do {
                let (restored, current) = try folderAccess.restore(from: catalog)
                if !current { try folderAccess.commit(restored, into: &catalog) }
                lease = restored
                folder = restored.url
                activeFolderIdentity = try StorageFiles.resourceID(restored.url)
                defaultAccessFailure = nil
            } catch {
                Log.access.error("default folder restore failed error=\(error.localizedDescription, privacy: .private)")
                defaultAccessFailure = NoteFailureMapping.operationError(error)
            }
        }
        for pass in 0..<3 {
            try validate(token)
            guard let folder else { throw NoteOperationError.unavailable }
            let epoch = recordsEpoch
            let candidates = await scanner.candidatesSnapshot(folder, failure: defaultAccessFailure)
            try Task.checkCancellation()
            try validate(token)
            guard epoch == recordsEpoch else { Log.reconcile.notice("dropped candidate scan: records changed pass=\(pass)"); continue }
            let custom = try customLocations(defaultURL: folder, unchanged: candidates.unchangedIDs(previous: identities.mapping))
            let scanned: FolderScanner.Scan
            do {
                scanned = try await scanner.scan(folder, identities: identities, cache: bodyCache, collectionToken: token,
                    custom: custom, defaultFailure: defaultAccessFailure, candidates: candidates)
            } catch NoteOperationError.conflict {
                // A file changed after enumeration. Retry with fresh bookmark evidence,
                // just as we retry when a concurrent edit invalidates the records epoch.
                Log.reconcile.notice("dropped scan: file changed during scan pass=\(pass)")
                try validate(token)
                continue
            }
            try validate(token)
            guard epoch == recordsEpoch else { Log.reconcile.notice("dropped scan: records changed pass=\(pass)"); continue }
            bodyCache = scanned.cache
            try commitIdentities(scanned.discovery)
            return apply(scanned.snapshots.map { note in
                var note = note
                note.accessFailure = accessFailures[note.id] ?? note.accessFailure
                return note
            }, collectionToken: token)
        }
        guard let folder else { throw NoteOperationError.unavailable }
        let candidates = FolderScanner.Candidates.capture(folder, failure: defaultAccessFailure)
        let custom = try customLocations(defaultURL: folder, unchanged: candidates.unchangedIDs(previous: identities.mapping))
        let scanned = try scanner.run(folder, identities: identities, cache: bodyCache, collectionToken: token,
                                       custom: custom, defaultFailure: defaultAccessFailure, prepared: candidates, check: { try Task.checkCancellation() })
        bodyCache = scanned.cache
        try commitIdentities(scanned.discovery)
        apply(scanned.snapshots.map { note in
            var note = note
            note.accessFailure = accessFailures[note.id] ?? note.accessFailure
            return note
        }, collectionToken: token)
    }

    /// Synchronous, so the diff is built and published against the current state.
    /// `ReconcileDiff` decides; this method runs its effects in order.
    private func apply(_ scanned: [NoteSnapshot], collectionToken token: CollectionToken) {
        let previous = records
        let found = Set(scanned.map(\.id))
        let missing = Set(previous.compactMap { id, old in
            pending[id] != nil && !found.contains(id) && StorageFiles.isMissing(old.fileURL) ? id : nil
        })
        let diff = ReconcileDiff(previous: previous, scanned: scanned, edits: edits, session: session,
                                 missingFiles: missing, token: token)
        records = diff.records
        for note in diff.current { session.knownLocations[note.id] = note.fileURL }
        for effect in diff.effects {
            switch effect {
            case .publish(let note):
                records[note.id] = note
                emit(.changed(note))
            case .keep(let note):
                records[note.id] = note
            case .retainTrashed(let edit, let old, let disk):
                // Retain local text durably before presentation closes the editor.
                records[old.id] = old
                _ = promote(edit, original: old.fileURL, missing: true)
                guard pending[old.id] == nil else { continue }
                records[old.id] = disk
                emit(.changed(disk))
            case .reconcileEdit(let plan):
                run(plan, token: token)
            case .changed(let note):
                emit(.changed(note))
            case .removed(let id):
                emit(.removed(id, token))
            case .discovered(let note):
                emit(.discovered(note))
            }
        }
        startObserving()
    }

    private func run(_ plan: ReconcileDiff.EditReconcile, token: CollectionToken) {
        let id = plan.id
        // Do not publish accepted file observations until recovery is durable.
        records[id]?.fileObservation = nil
        // Keep the local buffer separate from the new disk record.
        if plan.disk == nil { records[id] = plan.old }
        // Publish a rename even with unsaved text. Editors take the new URL and keep their text.
        if let rebound = plan.rebound, let disk = plan.disk {
            // The note is verified at its new location. Point the retained edit there.
            // Requests already sent to the old location still fail.
            pending[id] = rebound
            let journal = journal(for: rebound, url: disk.fileURL, verifiedRelocation: disk.availability == .available)
            session.journalRecords[id] = journal
            do { try persistJournal(journal) }
            catch { setStatus(id, .failed(plan.edit.revision, NoteFailureMapping.operationError(error), journaled: false)) }
            schedule(rebound, delay: timing.saveDebounce)
            var relocation = disk
            relocation.fileObservation = nil
            emit(.changed(relocation))
        }
        switch plan.promotion {
        case .missing(let url):
            records[id] = plan.old
            _ = promote(plan.edit, original: url, missing: true)
        case .changed(let url):
            _ = promote(plan.edit, original: url, missing: false)
        case nil:
            break
        }
        if pending[id] == nil, var disk = plan.disk {
            disk.editRevision = session.completions[id]?.revision ?? disk.editRevision
            records[id] = disk
            emit(.changed(disk))
        } else if plan.refreshJournal, let disk = plan.disk, let journal = session.journalRecords[id] {
            do {
                try persistJournal(journal)
                records[id] = disk
                emit(.changed(disk))
            } catch {
                setStatus(id, .failed(plan.edit.revision, NoteFailureMapping.operationError(error), journaled: false))
            }
        }
    }

}
