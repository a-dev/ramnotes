import Foundation

extension NoteOperationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .accessFailure(failure): String(localized: failure.message)
        case .destinationOccupied: String(localized: "A file already exists at the destination. Choose another name.", comment: "Error when renaming or moving onto an existing file")
        case .invalidFilename: String(localized: "Enter a nonempty filename without separators and with a .txt extension.", comment: "Error for an invalid note filename. Keep .txt unchanged")
        case .locationOperationPending: String(localized: "A location operation needs reconciliation. Retry it before changing this note.", comment: "Error when an unfinished move or rename blocks a new one")
        case .conflict: String(localized: "The note changed outside RAMnotes.", comment: "Error when the note file changed on disk. Keep the product name RAMnotes unchanged.")
        case .notOriginalFile: String(localized: "The selected file is not the original file of this note. Select the original file to restore access.", comment: "Error when Restore File Access receives a different file")
        case .originalNotMissing: String(localized: "The file is no longer missing, so RAMnotes keeps this note in the list.", comment: "Error when Remove from List finds the note file again. Keep the product name RAMnotes unchanged.")
        case .permissionDenied: String(localized: "Permission to write the notes folder was denied.", comment: "Error when macOS denies write access to the notes folder")
        case .unavailable: String(localized: "The note or notes folder is unavailable.", comment: "Error when the note or its folder cannot be reached")
        case .unsupportedEncoding: String(localized: "The file is not valid UTF-8.", comment: "Error when a file cannot be read as text. Keep UTF-8 unchanged")
        case let .inputOutput(message): String(localized: message)
        case let .unfinishedMove(destination):
            String(localized: "Finish the interrupted move to \(PathIsolation.isolate(destination.path)) before choosing another location.", comment: "Error; value is the destination file path")
        case let .moveInterrupted(underlying):
            if let underlying {
                String(localized: "The move was interrupted. Choose Move To… again to retry. \(underlying)", comment: "Error after an interrupted move; value is the system error")
            } else {
                String(localized: "The move was interrupted. Choose Move To… again to retry.", comment: "Error after an interrupted move")
            }
        case let .locationChangeInterrupted(underlying):
            if let underlying {
                String(localized: "The location change was interrupted. Save again to retry the recorded operation. \(underlying)", comment: "Error after an interrupted rename or Save As; value is the system error")
            } else {
                String(localized: "The location change was interrupted. Save again to retry the recorded operation.", comment: "Error after an interrupted rename or Save As")
            }
        case .cancelled: String(localized: "The operation was cancelled.", comment: "Error shown when the user or the system cancelled an operation")
        case .staleLocation: String(localized: "The note location changed. Retry with its current location.", comment: "Error when the note was moved while an operation ran")
        case .staleCollection: String(localized: "The collection session changed. Retry in the current collection.", comment: "Error when the notes folder changed while an operation ran")
        }
    }

}
