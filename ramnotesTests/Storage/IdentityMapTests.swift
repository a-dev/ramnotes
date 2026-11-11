import ramnotesDomain
import XCTest
@testable import ramnotes

final class IdentityMapTests: XCTestCase {
    private func record(_ id: NoteID = NoteID(), path: String, parent: String? = "p") -> NoteLocationRecord {
        NoteLocationRecord(id: id, resource: nil, path: path, parentResource: parent)
    }

    func testPathLookupFollowsRememberReplaceAndRemove() {
        var map = IdentityMap()
        let id = NoteID()
        XCTAssertTrue(map.remember(record(id, path: "/a")))
        XCTAssertEqual(map.identity(atPath: "/a", parentResource: "p")?.id, id)
        XCTAssertNil(map.identity(atPath: "/a", parentResource: "other"))

        XCTAssertTrue(map.remember(record(id, path: "/b")))
        XCTAssertNil(map.identity(atPath: "/a", parentResource: "p"))
        XCTAssertEqual(map.identity(atPath: "/b", parentResource: "p")?.id, id)

        map.remove(id)
        XCTAssertNil(map.identity(atPath: "/b", parentResource: "p"))
        XCTAssertTrue(map.mapping.isEmpty)
    }

    func testRememberEvictsDifferentNoteAtSameLocation() {
        var map = IdentityMap()
        let old = record(path: "/a"), new = record(path: "/a")
        _ = map.remember(old)
        XCTAssertTrue(map.remember(new))
        XCTAssertNil(map.identity(old.id))
        XCTAssertEqual(map.identity(atPath: "/a", parentResource: "p")?.id, new.id)
        XCTAssertEqual(map.mapping.count, 1)
    }

    func testSamePathInAnotherParentCoexists() {
        var map = IdentityMap()
        let a = record(path: "/a", parent: "p"), b = record(path: "/a", parent: "q")
        _ = map.remember(a)
        _ = map.remember(b)
        XCTAssertEqual(map.mapping.count, 2)
        XCTAssertEqual(map.identity(atPath: "/a", parentResource: "q")?.id, b.id)
    }

    func testSetPrunesOnlyItsParentAndKeepsIndexConsistent() {
        var map = IdentityMap()
        let gone = record(path: "/gone"), kept = record(path: "/kept"), other = record(path: "/o", parent: "q")
        [gone, kept, other].forEach { _ = map.remember($0) }
        XCTAssertTrue(map.set([kept, record(path: "/new")], parentResource: "p"))
        XCTAssertNil(map.identity(atPath: "/gone", parentResource: "p"))
        XCTAssertNotNil(map.identity(atPath: "/new", parentResource: "p"))
        XCTAssertNotNil(map.identity(atPath: "/o", parentResource: "q"))
        XCTAssertFalse(map.set(map.mapping.filter { $0.parentResource == "p" }, parentResource: "p"))
    }

    func testInitIndexesDecodedCatalog() {
        var catalog = CollectionCatalog()
        let r = record(path: "/a")
        catalog.notes[r.id] = r
        XCTAssertEqual(IdentityMap(catalog: catalog).identity(atPath: "/a", parentResource: "p")?.id, r.id)
    }
}
