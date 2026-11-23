import Core
import Foundation
import Testing

@testable import PortalKit

/// Sorting happens at the CL-Server across all pages, not on the device across the loaded one (AP60).
///
/// **The owner's requirement (2026-09-30):** sorted by rating, no 6 may stand before an 8 from page 3 on page
/// 1. Here it is checked that the app tells the server what to sort by, and reads its answer — also the one
/// that it is still collecting.
@Suite("Sorting across all pages")
struct PortalSortingTests {

    private func reader() -> JSONDecoder {
        let reader = JSONDecoder()
        reader.keyDecodingStrategy = .custom { path in
            DialectKey(PortalDialect.cinelounge.key(path: path))
        }
        return reader
    }

    @Test("Title and rating go to the server, the natural order does not")
    func fromFilter() {
        let rating = PortalSorting(ItemFilter(sortBy: .rating, ascending: false))
        #expect(rating == PortalSorting(kind: .rating, descending: true))
        let title = PortalSorting(ItemFilter(sortBy: .title, ascending: true))
        #expect(title == PortalSorting(kind: .title, descending: false))
        #expect(PortalSorting(ItemFilter(sortBy: .natural)) == nil)
        #expect(PortalSorting(ItemFilter(sortBy: .dateAdded)) == nil)
    }

    @Test("The query parts are called sort and order on the server")
    func queryParts() {
        let asks = PortalDialect.cinelounge.asks([
            "einstieg": "e", "sortierung": "rating", "richtung": "desc", "weiter": "@48",
        ])
        #expect(asks == ["entry": "e", "sort": "rating", "order": "desc", "next": "@48"])
    }

    @Test("While the server is collecting, the state comes and no titles")
    func preparation() throws {
        let reply = Data(
            """
            {"portal": "serieshub", "total": null, "next": null, "note": null,
             "needs_input": null, "input_suggestion": null, "question": null,
             "preparing": {"done": 240}, "truncated": null, "items": []}
            """.utf8)
        let read = try reader().decode(BridgeReply.Page.self, from: reply)
        #expect(read.preparation?.done == 240)
        #expect(read.items.isEmpty)
    }

    @Test("A sorted page carries its own token")
    func sortedPage() throws {
        let reply = Data(
            """
            {"portal": "serieshub", "total": 900, "next": "@48", "note": null,
             "needs_input": null, "input_suggestion": null, "question": null,
             "preparing": null, "truncated": false, "items": []}
            """.utf8)
        let read = try reader().decode(BridgeReply.Page.self, from: reply)
        #expect(read.preparation == nil)
        #expect(read.next == "@48")
        #expect(read.total == 900)
        #expect(read.truncated == false)
    }

    @Test("An older response without the new fields stays readable")
    func withoutNewFields() throws {
        let reply = Data(#"{"portal": "ahorn", "total": 3, "next": null, "items": []}"#.utf8)
        let read = try reader().decode(BridgeReply.Page.self, from: reply)
        #expect(read.preparation == nil)
        #expect(read.truncated == nil)
    }
}
