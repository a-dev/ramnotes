import ramnotesDomain
import Foundation

/// Identities for every folder. A full default-folder scan prunes only that folder.
/// Records in other folders stay saved when the default changes.
struct IdentityMap: Sendable {
    private struct Location: Hashable, Sendable {
        let parentResource: String?
        let path: String
    }

    private(set) var catalog: CollectionCatalog
    /// Derived from `catalog.notes` and never stored. Keeps path lookups and conflict checks O(1).
    private var idsByLocation: [Location: Set<NoteID>] = [:]

    init(catalog: CollectionCatalog = CollectionCatalog()) {
        self.catalog = catalog
        for (id, record) in catalog.notes { index(id, record) }
    }
    var mapping: [NoteLocationRecord] { Array(catalog.notes.values) }
    func identity(_ id: NoteID) -> NoteLocationRecord? { catalog.notes[id] }
    func identity(atPath path: String, parentResource: String?) -> NoteLocationRecord? {
        idsByLocation[Location(parentResource: parentResource, path: path)]?.first.flatMap { catalog.notes[$0] }
    }
    mutating func set(_ mapping: [NoteLocationRecord], parentResource: String) -> Bool {
        let before = catalog.notes
        let live = Set(mapping.map(\.id))
        for (id, record) in before where !live.contains(id) && record.parentResource == parentResource {
            remove(id)
        }
        for identity in mapping { _ = remember(identity) }
        return before != catalog.notes
    }
    mutating func remove(_ id: NoteID) {
        guard let old = catalog.notes.removeValue(forKey: id) else { return }
        unindex(id, old)
    }
    mutating func remember(_ identity: NoteLocationRecord) -> Bool {
        if catalog.notes[identity.id] == identity { return false }
        let key = Location(parentResource: identity.parentResource, path: identity.path)
        for other in idsByLocation[key] ?? [] where other != identity.id { remove(other) }
        remove(identity.id)
        catalog.notes[identity.id] = identity
        index(identity.id, identity)
        return true
    }

    private mutating func index(_ id: NoteID, _ record: NoteLocationRecord) {
        idsByLocation[Location(parentResource: record.parentResource, path: record.path), default: []].insert(id)
    }
    private mutating func unindex(_ id: NoteID, _ record: NoteLocationRecord) {
        let key = Location(parentResource: record.parentResource, path: record.path)
        idsByLocation[key]?.remove(id)
        if idsByLocation[key]?.isEmpty == true { idsByLocation[key] = nil }
    }
}
