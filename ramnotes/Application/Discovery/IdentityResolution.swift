import ramnotesDomain
import Foundation

/// Matches discovered files to saved location records. Orchestration only: it checks cancellation and rebuilds records.
enum IdentityResolution {
    static func resolve(_ candidates: [FileCandidate], previous: [NoteLocationRecord]) throws -> [NoteLocationRecord] {
        let oldResources = Dictionary(grouping: previous.filter { $0.resource != nil }, by: { $0.resource! })
        let oldPaths = Dictionary(grouping: previous, by: \.path)
        let currentResources = Dictionary(grouping: candidates.filter { $0.resource != nil }, by: { $0.resource! })
        let currentPaths = Dictionary(grouping: candidates, by: { $0.url.path })
        let resources = Set(currentResources.keys)
        let idCounts = Dictionary(grouping: previous, by: \.id)
        var used: Set<NoteID> = []
        var mapping: [NoteLocationRecord] = []
        for candidate in candidates.sorted(by: { $0.url.path < $1.url.path }) {
            try Task.checkCancellation()
            var match: NoteLocationRecord?
            if let resource = candidate.resource, let old = oldResources[resource] {
                // A hard link or a duplicate saved identity is ambiguous, even if an earlier
                // candidate already took one of its matches.
                if old.count == 1, currentResources[resource]?.count == 1 { match = old[0] }
            } else if candidate.resource.map({ currentResources[$0]?.count == 1 }) ?? true,
                      let paths = oldPaths[candidate.url.path]?.filter({ $0.parentResource == candidate.parentResource }), paths.count == 1,
                      currentPaths[candidate.url.path]?.count == 1 {
                let old = paths[0]
                // Match by path when the file ID is missing or changed by atomic replacement.
                // Never take the identity of a file that is now at another path.
                if old.parentResource == candidate.parentResource,
                   old.resource.map({ !resources.contains($0) && oldResources[$0]?.count == 1 }) ?? true { match = old }
            }
            let id: NoteID
            if let match, idCounts[match.id]?.count == 1, !used.contains(match.id) { id = match.id }
            else { id = NoteID() }
            used.insert(id)
            var location: NoteLocationRecord
            if let match, match.id == id { location = match }
            else { location = NoteLocationRecord(id: id, resource: candidate.resource, path: candidate.url.path) }
            if location.path != candidate.url.path { location.revision.advance() }
            location.path = candidate.url.path
            location.resource = candidate.resource
            location.parentResource = candidate.parentResource
            location.availability = .available
            mapping.append(location)
        }
        return mapping
    }
}
