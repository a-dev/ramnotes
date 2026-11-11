import ramnotesDomain
import Foundation

/// Application replay and promotion decisions over durable recovery records.
enum RecoveryPolicy {
    enum Replay: Equatable { case retain, save, promote }

    static func replay(_ record: RecoveryRecord, folderAvailable: Bool,
                       activeFolderIdentity: String?, trackedParent: String?, tracked: Bool) -> Replay {
        guard !record.trackingRemoved, folderAvailable else { return .retain }
        if record.promotionURL == nil {
            if let identity = record.folderIdentity {
                guard identity == activeFolderIdentity || (tracked && trackedParent == identity) else { return .retain }
            } else if !tracked { return .retain }
        }
        return record.promotionURL != nil || record.reason != .saveFailure ? .promote : .save
    }

    static func journal(for edit: EditSnapshot, url: URL, prior: RecoveryRecord?,
                        folderIdentity: String?, resourceIdentity: String?, now: Date,
                        verifiedRelocation: Bool = false) -> RecoveryRecord {
        if let prior, prior.editRevision == edit.revision {
            guard verifiedRelocation, let folderIdentity, let resourceIdentity else { return prior }
            var rebound = RecoveryRecord(id: prior.id, noteID: prior.noteID, collectionToken: prior.collectionToken,
                originalURL: url, folderIdentity: folderIdentity, originalResourceIdentity: resourceIdentity,
                baseRevision: prior.baseRevision, editRevision: prior.editRevision, text: prior.text,
                createdAt: prior.createdAt, reason: prior.reason, promotedNoteID: prior.promotedNoteID)
            rebound.trackingRemoved = prior.trackingRemoved
            rebound.promotionURL = prior.promotionURL
            rebound.promotionAccess = prior.promotionAccess
            rebound.promotionParentResource = prior.promotionParentResource
            rebound.promotionResource = prior.promotionResource
            return rebound
        }
        // A newer edit must not reuse the identity of a reserved/completed promotion.
        let id = prior?.promotionURL == nil ? (prior?.id ?? UUID()) : UUID()
        return RecoveryRecord(id: id, noteID: edit.id, collectionToken: edit.collectionToken,
            originalURL: url, folderIdentity: folderIdentity,
            originalResourceIdentity: prior?.originalResourceIdentity ?? resourceIdentity,
            baseRevision: edit.baseRevision, editRevision: edit.revision, text: edit.text,
            createdAt: prior?.createdAt ?? now, reason: .saveFailure)
    }

    static func promotion(for edit: EditSnapshot, original: URL, missing: Bool,
                          prior: RecoveryRecord, collectionToken: CollectionToken,
                          folderIdentity: String?, resourceIdentity: String?) -> RecoveryRecord {
        var record = RecoveryRecord(id: prior.id, noteID: edit.id, collectionToken: collectionToken,
            originalURL: original, folderIdentity: prior.folderIdentity ?? folderIdentity,
            originalResourceIdentity: prior.originalResourceIdentity ?? resourceIdentity,
            baseRevision: edit.baseRevision, editRevision: edit.revision, text: edit.text,
            createdAt: prior.createdAt, reason: missing ? .missingOriginal : .conflict)
        record.promotionURL = prior.promotionURL
        record.promotionAccess = prior.promotionAccess
        record.promotionParentResource = prior.promotionParentResource
        record.promotionResource = prior.promotionResource
        record.promotedNoteID = prior.promotedNoteID
        return record
    }

    static func completedPromotion(_ record: RecoveryRecord?, for edit: EditSnapshot,
                                   links: [UUID: RecoveryNotice]) -> RecoveryNotice? {
        guard let record, record.editRevision == edit.revision, record.text == edit.text else { return nil }
        return links[record.id]
    }

    /// One external-change conflict produces one recovery note. A later edit of the source
    /// note that still starts from the conflicted base, and arrives while the recovery note
    /// holds only text this window wrote, updates that recovery note.
    static func reusesConflictRecovery(_ window: ConflictRecovery?, for edit: EditSnapshot, missing: Bool,
                                       recoveryEditRevision: EditRevision?, recoveryPending: Bool) -> Bool {
        guard let window, !missing, !recoveryPending,
              edit.baseRevision == window.baseRevision, edit.revision > window.sourceRevision else { return false }
        return recoveryEditRevision == window.recoveryRevision
    }
}

/// The recovery note that one conflict created, and the revisions this window last wrote.
struct ConflictRecovery: Sendable {
    let record: RecoveryRecord
    let baseRevision: FileRevision?
    var sourceRevision: EditRevision
    let recoveryNoteID: NoteID
    var recoveryRevision: EditRevision
}
