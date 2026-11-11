import Foundation
import Darwin

/// Exclusive recovery-file creation and verification, separate from the journal /
/// catalog checkpoints sequenced by the serialized recovery workflow.
enum RecoveryFiles {
    static func createOrVerify(_ record: RecoveryRecord) throws -> String? {
        guard let promoted = record.promotionURL else { throw NoteOperationError.unavailable }
        let data = Data(record.text.utf8)
        // Once creation is checkpointed, matching bytes cannot substitute for identity.
        if let resource = record.promotionResource {
            guard try StorageFiles.fileResourceID(promoted) == resource else { throw NoteOperationError.conflict }
        } else {
            do { try StorageFiles.create(data, at: promoted) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                guard try StorageFiles.coordinatedRead(promoted) == data else { throw NoteOperationError.destinationOccupied }
            }
        }
        guard try StorageFiles.coordinatedRead(promoted) == data else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("Recovery verification failed", comment: "Error when a recovery file does not match the saved text"))
        }
        return try StorageFiles.fileResourceID(promoted)
    }
}

/// Export recovery text off the main actor and verify the written bytes.
struct VerifiedRecoveryExporter: RecoveryTextExporting {
    func exportRecoveryText(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try StorageFiles.export(data, to: url)
        }.value
    }
}
