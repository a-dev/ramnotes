import ramnotesDomain
import Foundation

/// Immutable discovery inputs and results. Scanners and the store share them; neither owns them.
struct CachedBody: Sendable {
    let stamp: StorageFiles.Stamp
    let text: String
    let revision: FileRevision
}


/// Discovery and resolution only look. They don't change records or save mappings,
/// so callers can inspect locations without running a reconcile.
struct FileCandidate: Sendable {
    let url: URL
    let resource: String?
    var parentResource: String? = nil
}

struct IdentityDiscovery: Sendable {
    let folderIdentity: String
    let folderURL: URL
    let mapping: [NoteLocationRecord]
}
