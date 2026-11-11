import ramnotesDomain
import Foundation

/// Compute record changes and effects for `NoteStore.apply`.
/// The caller checks for missing files before computing the changes.
struct ReconcileDiff {
    /// Where a retained edit is promoted to a recovery note.
    enum Promotion {
        /// The file is gone from disk: restore the old record, then promote with `missing: true`.
        case missing(URL)
        /// The file changed under the edit: promote against the scanned file.
        case changed(URL)
    }

    /// A note with a pending edit, seen again by the scan.
    struct EditReconcile {
        let id: NoteID
        let edit: EditSnapshot
        let old: NoteSnapshot
        let disk: NoteSnapshot?
        /// The edit pointed at the note's verified new location. The relocation is published.
        let rebound: EditSnapshot?
        let promotion: Promotion?
        /// The disk revision changed but the edit's base did not: rewrite the journal, then publish the disk record.
        let refreshJournal: Bool
    }

    enum Effect {
        /// Set the record and emit `.changed`.
        case publish(NoteSnapshot)
        /// Set the record without an event.
        case keep(NoteSnapshot)
        /// The file was trashed with a pending edit: keep `old`, promote the edit, and publish `disk` if it was retained.
        case retainTrashed(EditSnapshot, old: NoteSnapshot, disk: NoteSnapshot)
        case reconcileEdit(EditReconcile)
        /// Emit `.changed` for the record already in place.
        case changed(NoteSnapshot)
        case removed(NoteID)
        case discovered(NoteSnapshot)
    }

    /// The scanned records with edit revisions and file observations applied.
    let current: [NoteSnapshot]
    /// The records before any effect runs.
    let records: [NoteID: NoteSnapshot]
    let effects: [Effect]

    /// - Parameter missingFiles: Notes with a pending edit and no scanned record whose old file is missing.
    init(previous: [NoteID: NoteSnapshot], scanned: [NoteSnapshot], edits: EditState,
         session: CollectionSession, missingFiles: Set<NoteID>, token: CollectionToken) {
        let current = scanned.map { note in
            var note = note
            note.editRevision = session.completions[note.id]?.revision ?? EditRevision(rawValue: 0)
            if note.availability == .available {
                note.fileObservation = note.fileRevision == session.lastWritten[note.id] ? .ownWrite : .disk
            }
            return note
        }
        let found = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var effects: [Effect] = []
        for (id, old) in previous {
            let disk = found[id]
            if let disk, disk.availability == .trashed {
                if let edit = edits.pending[id] { effects.append(.retainTrashed(edit, old: old, disk: disk)) }
                else { effects.append(.publish(disk)) }
            } else if session.writing.contains(id) {
                if let disk, Self.moved(disk, from: old) {
                    effects.append(.publish(NoteSnapshot(id: id, collectionToken: token, fileURL: disk.fileURL,
                        fileRevision: old.fileRevision, text: old.text, availability: disk.availability,
                        editRevision: old.editRevision, locationRevision: disk.locationRevision, createdAt: disk.createdAt)))
                } else { effects.append(.keep(old)) }
            } else if let edit = edits.pending[id] {
                var rebound: EditSnapshot?
                if let disk, Self.moved(disk, from: old) {
                    rebound = EditSnapshot(id: edit.id, collectionToken: token, revision: edit.revision,
                        baseRevision: edit.baseRevision, text: edit.text, locationRevision: disk.locationRevision)
                }
                let lastWritten = session.lastWritten[id]?.fingerprint
                let changed = disk == nil || (disk?.fileRevision?.fingerprint != edit.baseRevision?.fingerprint &&
                    (lastWritten == nil || disk?.fileRevision?.fingerprint != lastWritten))
                var promotion: Promotion?
                if changed {
                    if disk == nil, missingFiles.contains(id) { promotion = .missing(old.fileURL) }
                    else if let disk, disk.availability == .available { promotion = .changed(disk.fileURL) }
                }
                let hasJournal = rebound != nil || session.journalRecords[id] != nil
                let refresh = !changed && disk != nil && disk?.fileRevision != old.fileRevision && hasJournal
                effects.append(.reconcileEdit(EditReconcile(id: id, edit: edit, old: old, disk: disk,
                    rebound: rebound, promotion: promotion, refreshJournal: refresh)))
            } else if let disk {
                if disk.fileURL != old.fileURL || disk.fileRevision != old.fileRevision || disk.availability != old.availability {
                    effects.append(.changed(disk))
                }
            } else {
                effects.append(.removed(id))
            }
        }
        for disk in current where previous[disk.id] == nil { effects.append(.discovered(disk)) }
        self.current = current
        self.records = found
        self.effects = effects
    }

    private static func moved(_ disk: NoteSnapshot, from old: NoteSnapshot) -> Bool {
        disk.fileURL != old.fileURL || disk.locationRevision != old.locationRevision
    }
}
