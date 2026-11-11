import ramnotesDomain
import Foundation

/// Platform-independent classification used by access-repair workflows.
enum NoteAccessFailureReason: Sendable {
    case folderAuthorization, staleBookmark, missingFile, unavailableVolume, cloudPlaceholder, permission, unsupportedEncoding, unknown
}

/// Why a note's file can't be read or written. Consumers need it without knowing the catalog schema.
struct NoteAccessFailure: Equatable, Sendable {
    typealias Reason = NoteAccessFailureReason
    let reason: Reason
    let domain: String
    let code: Int
    /// Display text resolved by presentation in the current locale.
    let message: LocalizedStringResource
    var requiresFolderAccess: Bool { reason == .folderAuthorization || reason == .staleBookmark }
}

/// Maps system errors to the application's typed failures.
enum NoteFailureMapping {
    static func operationError(_ error: Error) -> NoteOperationError {
        if let typed = error as? NoteOperationError { return typed }
        return .accessFailure(accessFailure(error))
    }

    static func accessFailure(_ error: Error, bookmark: Bool = false) -> NoteAccessFailure {
        if case let .accessFailure(failure) = error as? NoteOperationError { return failure }
        let ns = error as NSError
        let reason: NoteAccessFailure.Reason
        if bookmark { reason = .folderAuthorization }
        else if ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code)
            || ns.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(ns.code) { reason = .permission }
        else if ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code)
            || ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { reason = .missingFile }
        else if ns.domain == NSPOSIXErrorDomain && [Int(ENODEV), Int(ENXIO)].contains(ns.code) { reason = .unavailableVolume }
        else if (error as? NoteOperationError) == .unsupportedEncoding { reason = .unsupportedEncoding }
        else { reason = .unknown }
        return NoteAccessFailure(reason: reason, domain: ns.domain, code: ns.code, message: LocalizedStringResource(stringLiteral: error.localizedDescription))
    }
}
