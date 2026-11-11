import ramnotesDomain
import Foundation

struct TrashService: Sendable {
    let move: @Sendable (URL) throws -> URL
    var contains: @Sendable (URL) -> Bool = { url in
        var relationship: FileManager.URLRelationship = .other
        do {
            try FileManager.default.getRelationship(&relationship, of: .trashDirectory,
                in: .userDomainMask, toItemAt: url)
            return relationship == .contains || relationship == .same
        } catch { return false }
    }

    init(move: @escaping @Sendable (URL) throws -> URL = { url in
        var returned: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &returned)
        // The resulting location was only needed for application-level restoration. Finder
        // owns restoration now, so a successful Trash operation does not depend on this value.
        return returned as URL? ?? url
    }) { self.move = move }
}
