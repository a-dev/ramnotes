# Architecture

RAMnotes uses Swift 6 and AppKit. It runs as a sandboxed accessory app with `LSUIElement` enabled.
Note files contain the authoritative text. Catalogs track files and operations. Journals preserve unsaved text.

## Code map

Paths start in `ramnotes/`. AppKit controllers run on the main actor.

| Directory | Responsibility |
| --- | --- |
| `Domain/` | Pure rules for identity, revisions, saves, recovery, registration, and location operations. |
| `Application/Notes/` | The `NoteStore` actor serializes collection changes. Its extensions implement each workflow. |
| `Application/Recovery/` | Recovery decisions and the store's recovery workflows. |
| `Application/Discovery/` | Scan results and identity matching. |
| `Application/Ports/` | Capabilities for editors, windows, and recovery controllers. |
| `Infrastructure/Access/` | Bookmarks, security scopes, and leases. |
| `Infrastructure/Files/` | Coordinated file access, scanning, observation, export, and Trash. |
| `Infrastructure/Persistence/` | Catalogs, identity maps, window metadata, and journals. |
| `Presentation/` | Views and feature controllers for editing, the list, windows, recovery, and Settings. |
| `Editing/`, `Windows/`, `Settings/` | Recovery controllers, window coordination, location dialogs, and settings persistence. |
| `App/` | Service composition, menus, file panels, and platform entry points. |
| `Search/`, `Invocation/` | Background search and app invocation through shortcuts, gestures, or login. |

## Ownership

Only the `ramnotesDomain` static library compiles domain sources. Both apps link it in every configuration.
Domain code uses Foundation values and the Swift standard library. It performs no I/O.
Application, infrastructure, and presentation share the app target.

Application owns transaction order. It uses `StorageFiles`, `LocationFiles`, `RecoveryFiles`, and `FolderAccess` for platform effects.
Save and Trash use `NSFileCoordinator` directly because their claims change store state.
Presentation consumes application capabilities. Views hold no store, catalog, journal, or file grant.

`AppCoordinator` adopts each collection snapshot on the main actor. Presentation formats errors and isolates paths in translated sentences.
`LocationWorkflow` includes live editor text in location actions. `DeletionWorkflow` locks and flushes editors before sequential Trash operations.
`LifecycleController` coordinates startup, folder changes, and Quit.

## Stored files

These paths are inside the app container's Application Support directory.
The selected default notes folder can be elsewhere.

| Path                       | Contents                                                                                                        |
| -------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `settings.json`            | Versioned settings and global note typography.                                                                  |
| `collection.json`          | The source of truth for which notes exist: bookmarks, locations, pending operations, recovery notices, and folder-change batches. |
| `collection-metadata.json` | Frames, displays, open state, focus order, font sizes, tints, editor positions, and external-change timestamps. |
| `Recovery/`                | Checksummed journals with retained edits, including detached records in `Retained/`.                            |
| `Notes/`                   | Initial default notes folder.                                                                                   |

Removal first commits `CollectionCatalog.forgetting(_:)`, which removes all catalog references to the note.
Without suspending, `NoteStore.forget` clears session state and publishes removal. Journal cleanup failures trigger an error.
At startup, the store retries cleanup for unregistered notes and keeps detached records marked `trackingRemoved`.

### Catalog checkpoints

NoteStore reads, saves, and installs a catalog without suspension. A failed save preserves the disk catalog. CatalogPersistence rejects corrupt catalogs.

| Path | Starts from | Failure semantics |
| --- | --- | --- |
| `writeIdentities` | `collection.json`, with the given map's notes. Dropped notes go through `forgetting` | Installs and clears `identitiesDirty` only after the save. |
| `checkpointSavedIdentity` | In-memory map | Keeps the verified identity in memory and marks it dirty before bookmarking, then calls `writeIdentities`. A later failure keeps the newer identity for the next checkpoint. |
| `checkpointDiskCatalog` (`persistLocationOperation`, `forgetRecoveryNotices`) | `collection.json`, with the in-memory notes, so deferred identities are written | Installs only after the save. `identitiesDirty` is unchanged. |
| `checkpointMemoryCatalog` (`persistDefaultBatch`, promotion links, fixture links) | In-memory map | Installs only after the save. |
| Default-folder commit | A catalog the workflow built during the step | Installs only after the save. |
| `FolderAccess.commit` | `collection.json` | Writes the default-folder grant only. Kept separate because its authorization differs. |
| Startup link pruning | `collection.json` | A failure keeps the links for the next pass. |

Window metadata never determines collection membership. The coordinator prunes it against the store.
Catalogs and window metadata contain no note bodies. Version-two journals store metadata, a SHA-256 checksum, and UTF-8 text.
The store reads version-one journals and upgrades them on the next write. It preserves corrupt or unsupported journals.
Invalid settings load defaults without overwriting the file. Catalog decoding checks IDs, path bindings, operations, and batch sources.
Recovery presentation reads summaries. Only the store writes journals and recovery links.

`CollectionRegistration` checks live registration. The decoder independently checks untrusted records.
`StorageTests` includes literal version-one catalog and journal fixtures.

`MetadataStore` (`Infrastructure/Persistence/`) writes atomically. `MetadataPersistence` (`Application/`) serializes writes and keeps the latest pending snapshot per destination.
Failures retain that snapshot for retry. An older failure cannot replace a newer snapshot.
A flush waits for earlier submissions. A newer persisted snapshot satisfies an older flush target.

## Identity and access

`NoteID` identifies a tracked note. Paths and matching text do not establish identity.
Verified resource identifiers follow moves and renames. Default-folder replacement requires the same parent identity.
The volume UUID and file ID identify a file across remounts. If either is missing, folders use path keys and files lack resource identities.
Uncertain default-folder identity produces a removal and an addition. Relinking rejects files tracked by another note.

Filename generation uses the domain word list. Exclusive creation retries name collisions. See [word list attribution](../ramnotes/App/ThirdPartyNotices.txt).

`registerFile` validates the file, acquires file access, reads UTF-8 under coordination, and checkpoints the catalog before publication.

`FolderAccess` (`Infrastructure/Access/`) owns bookmark creation, security scopes, and lease lifetime.
Finder drops can provide sandbox-granted URLs without a security scope.
If scope acquisition fails, the adapter creates and resolves a file bookmark to obtain a scoped URL.

Custom notes retain file grants. Default-folder discovery and creation retain a directory grant.
Access renewal verifies the tracked file identity and checkpoints its bookmark before replacing leases.
Background saves never open permission panels. Cancellation and failure release temporary leases.

Stored parent grants migrate per note to verified file bookmarks without requesting new folder access.
Migration checkpoints the file descriptor before releasing parent access. Failure preserves the original record and retained edits.
At load, `CatalogRetention` removes successful batches and completed operations that no remaining batch references. Failed entries and unfinished operations stay available for retry.
Unfinished location operations retain their grants until reconciliation completes. Default-folder descriptors remain unchanged.

Delayed work checks the collection token, location revision, and edit revision before mutation or publication.
A default-folder change preserves the collection token. Moves and relinks advance the location revision.
Each editor change advances the edit revision.

## Save and recovery transactions

`NoteSaveState`, `NoteSavePolicy`, and `RetainedEditPolicy` own pure save decisions.
`NoteEditorController` owns the live buffer. `Application/Notes/NoteStore+Saving.swift` applies the rules under file coordination.

1. Journal the edit. Within the 250 ms journal debounce, keep the newest revision and write it when the interval ends.
2. Storage debounces the note write for 500 ms. A newer edit cancels the previous debounce.
3. Storage compares the file with the editor's base under coordination.
4. A matching base permits replacement. A conflicting file remains unchanged while retained text becomes a separate recovery note.
5. Storage verifies the written bytes before reporting success. Saving revision N cannot mark revision N+1 as saved.

Default-folder writes use sibling temporary files and directory syncing under their folder grant.
Each folder scan deletes regular `.ramnotes-*` files older than 10 minutes, left by a crash. It ignores symlinks and errors.
Custom-note writes use `NSDocument.writeSafely` with autosaving and versions disabled.
They do not create arbitrary siblings or sync the parent directory.
Custom saves verify bytes and checkpoint the renewed identity and bookmark under the same coordination.
A failed catalog checkpoint retains the pending edit and journal. Default-folder identity updates become durable on explicit flush.

Recovery promotion records its destination and identity before creation.
It verifies the file, records adoption, and commits the catalog link before journal cleanup.
Retries reuse completed work only for the same revision and text. Newer text receives a new promotion identity.
Later edits on the same conflicting base can update the recovery note. Verify that save before clearing the source journal. A changed base, missing original, or independent recovery edit ends reuse. Restart also clears this session state.
Verified relocation updates the journal's original URL and identity without changing an existing recovery reservation.

See [Editing and saving](SPEC.md#editing-and-saving) for recovery options and the limits of crash recovery.

### Checkpoint flush

Before each note write, save the journal. Flush deferred journals before explicit flushes, folder changes, and Quit.
`StorageFiles.barrier` uses `F_BARRIERFSYNC` for files and directories and falls back to `fsync` on failure.
The barrier orders writes. Power loss can still discard the newest checkpoint from the drive cache.

## Location transactions

`NoteStore+LocationMove.swift` records intent before file effects.
`LocationOperationState` defines evidence requirements and stage transitions. Incomplete evidence cannot authorize execution.
`LocationFiles.coordinate` retains one two-file coordination claim through verification and durable checkpoints.
It checks resource identity, parent identity, revision, and link count before effects.
Cross-volume cleanup verifies both copies before source removal. Restart leaves replacements at the old path untouched.

Move To uses this transaction with a destination-file grant from the Save panel.
File-only moves copy before removing the source, even on the same volume.
The transaction checkpoints the new file bookmark after destination verification and before source removal.
A crash before that checkpoint can require selecting the destination again. The recorded operation remains available for verified retry.
Access leases remain active through effects, persistence, and observer updates.
After catalog commit, the workflow rebinds journals and pending edits before completion.

Moves flush destination files. Parent syncing requires folder access, so file-only moves cannot promise directory durability across power loss.
Identity checks and catalog checkpoints still precede source removal.

A default-folder change flushes edits and captures the old folder's membership.
One catalog write commits the new default and batch intent. Retries use that membership and skip completed moves.
Reservations ignore case. Exclusive creation protects files that appear during a move.

A different-resource relink detaches old retained text with replay disabled before committing the new binding.
The editor receives `rebound`, installs a clean session, and clears Undo and queued old-binding deliveries.
Revision guards reject stale submissions. Matching text never authorizes replay onto the selected resource.

Save a Copy completes composition and locks editing without flushing or resolving the original.
`createCopy` rejects tracked destinations, writes through the selected file grant, and verifies bytes before registration with a new NoteID.
The original binding, retained edits, and conflict state remain intact.

`NoteTrackingRemovalPolicy` checks availability before removal. For a missing original, storage rechecks the bookmark and path. It commits catalog removal before clearing journals and releasing grants.

## Trash and export

`TrashService` uses coordinated deletion and a verified file grant.
Storage checks pending edits, collection identity, location operations, file identity, and base revision before Trash.
A failed catalog write after successful Trash leaves a dirty catalog for retry.

External Trash publishes a tracked `.trashed` state without reading the file body.
Before disposal, a dirty or composing editor drains deliveries and submits its latest buffer through `retainForExternalTrash`.
Recovery durably detaches that buffer without writing to Trash. Changed composition requires another acknowledgement.
The editor closes only after it releases the retained buffer safely. Closing clears open state and preserves window metadata.

Drag export uses `NSFilePromiseProvider` with current editor text.
`writeDragCopy` checks collection and location revisions and retains access through writing.
The promise retains its producer until the write completes.

## Lifecycle and presentation

Operation-specific lock tokens control editor changes. Releasing one lock recomputes editability.
Folder-change locks also cover editors opened during the transaction.
Startup callers share one load task. Failed loads permit retry on activation or volume mount.
Startup loads settings, recovery links, storage, recovery, and window metadata before reveal.
Quit waits for startup or a folder transaction.
Folder changes and Quit lock editors and flush edits. They wait for consumers to apply all published store events. Then they capture positions and persist metadata before commit.
Failure releases only that transaction's lock. Successful Quit retains its lock until termination.

Group reveal flushes dirty editors and verifies all open notes with one reconciliation pass.
Per-note guards still apply. Hide or newer navigation cancels remaining presentation.
Batch Open uses one presentation generation and focuses the last selected note.
`NoteListController` preserves selection by NoteID across updates and defers sorting while hidden.
`NoteListController` sends actions through `NoteListDelegate`. Each row uses a verified snapshot and any unsaved editor text.
`SearchIndex` reads application search documents, including file creation dates. Presentation formats results and availability messages.

Editor metadata contains UTF-16 selection ranges, viewport coordinates, caret state, and accepted file timestamps, without note text.
Restoration clamps positions after layout and reveals the selection. Focus order is independent of the last edit.
### Reveal verification

Before a note opens or reappears, `NoteStore` restores default-folder access. Then `FolderScanner` lists the supported files with their paths, file identities, and folder identity.
The scan runs outside the `NoteStore` actor, so saves continue. `NoteStore` uses the same list for bookmark checks and discovery.

`NoteStore` does not resolve the bookmark of a default-folder note when all these conditions are true:

- The note is available and has no unfinished location operation.
- The file remains at the stored path.
- The file identity and folder identity exist and match the stored identities.
- The file identity occurs once in the stored notes and once in the current file list.
- The note ID occurs once in the stored notes.

All other notes resolve their bookmarks. This includes custom-path notes and notes with missing or duplicate file identities.

The scanner checks each file identity after it reads the text, and the folder identity before and after the scan.
If an identity changes, or a newer edit changes the records during the scan, `NoteStore` discards the results and scans again.

### Editor events

Verified writes advance the editor's timestamp baseline. `PlainTextView` shares URL detection across pointer, menu, and accessibility actions.
Accessibility actions check the current text before opening a link.

## Logging

`Infrastructure/Log.swift` defines categories for saves, reconciliation, moves, recovery, and access. Logs include note IDs and stages. Paths and system errors are private. Logs exclude note text.

```sh
log stream --predicate 'subsystem == "com.ramnotes.RAMnotes"'
```

## Platform and distribution

Carbon registers global shortcuts.
An `NSEvent` monitor handles menu-bar scroll events.
The direct login helper opens `ramnotes-login://login` without activation.
AppKit delivers that URL at launch, so the app waits only 150 ms for a late delivery before revealing notes on a normal launch.

Only the direct app links Sparkle. `RAMnotesMAS` defines `APP_STORE` and omits update services.
Both targets share app sources, the domain library, and bundle identity.
`AppCoordinator` retains the direct updater and starts it only with validated feed metadata.
Settings accepts an optional native update view without depending on Sparkle.
Update relaunch uses the existing save-and-quit transaction.
CI inspects built bundles. See [build and release](build.md) for commands.
