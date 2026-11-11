import ramnotesDomain
import Foundation
import AppKit

// Carries the prepared bookmark and its grant across the editor flush.
final class PreparedFolderGrant: FolderGrant {
    let lease: FolderLease
    let descriptor: NoteAccessDescriptor
    var url: URL { lease.url }
    init(lease: FolderLease, descriptor: NoteAccessDescriptor) {
        self.lease = lease
        self.descriptor = descriptor
    }
}

/// A file capability retains the underlying scope without exposing folder authorization.
final class AuthorizedFile: FileGrant {
    let lease: FolderLease
    var url: URL { lease.url }
    init(_ lease: FolderLease) { self.lease = lease }
}
