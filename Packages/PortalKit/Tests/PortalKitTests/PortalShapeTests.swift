import Core
import Foundation
import Testing

@testable import PortalKit

/// The two portal rules that TV and phone have shared since AP58 R7 (finding E4).
@Suite("Portal shape and portal search")
struct PortalShapeTests {

    private func folder(_ name: String) -> MediaItem {
        MediaItem(
            id: PortalItemID(portal: "p", key: "", address: name).identifier, kind: .folder,
            title: name)
    }

    private func title(_ name: String) -> MediaItem {
        MediaItem(
            id: PortalItemID(portal: "p", key: name, address: name).identifier, kind: .movie,
            title: name)
    }

    /// **As soon as there is something to show, a grid** (viewer finding 2026-08-28).
    @Test("Only a level of folders and separators becomes rows")
    func areFolders() {
        let separator = MediaItem(id: "t", kind: .separator, title: "--- Tipps ---")
        #expect(PortalShape.areFolders([folder("a"), folder("b")]))
        #expect(PortalShape.areFolders([separator, folder("a")]))
        #expect(!PortalShape.areFolders([folder("a"), title("Film")]))
        #expect(!PortalShape.areFolders([]))
    }

    /// **Since AP77 from two characters, whether typed or submitted** — one letter is not a
    /// question with ten thousand series but a page that the server spends five seconds collecting.
    @Test("From two characters, typed as submitted, always without margin")
    func term() {
        #expect(PortalSearch.term(" a ", whileTyping: true) == nil)
        #expect(PortalSearch.term(" ab ", whileTyping: true) == "ab")
        #expect(PortalSearch.term(" a ", whileTyping: false) == nil)
        #expect(PortalSearch.term(" ab ", whileTyping: false) == "ab")
        #expect(PortalSearch.term("   ", whileTyping: false) == nil)
        #expect(PortalSearch.pause > .milliseconds(350), "longer than the global search")
    }
}
