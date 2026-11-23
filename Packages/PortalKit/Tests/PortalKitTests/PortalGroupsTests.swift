import Testing

@testable import PortalKit

/// **The four group headings are translated, every other separator stays as it came**
/// (screenshot run 2026-11-15: "Werkzeuge" above "Search" in the English interface).
@Suite("Portal group headings")
struct PortalGroupsTests {
    @Test("The four headings of app and server have a catalog key")
    func groupsHaveKeys() {
        #expect(PortalGroups.wordingKey(for: PortalGroups.recentlyUsed) == "portal.group.recent")
        #expect(PortalGroups.wordingKey(for: PortalGroups.all) == "portal.group.all")
        #expect(PortalGroups.wordingKey(for: PortalGroups.myAreas) == "portal.group.mine")
        #expect(PortalGroups.wordingKey(for: PortalGroups.tools) == "portal.group.tools")
    }

    @Test("A heading the portal names itself stays verbatim")
    func foreignHeadingStays() {
        #expect(PortalGroups.wordingKey(for: "Neu auf Flimmerkiste") == nil)
        #expect(PortalGroups.wordingKey(for: "") == nil)
    }

    @Test("The root separators carry the same wording the key is found by")
    func rootSeparatorsAreTranslatable() {
        let entries = [
            BridgeReply.EntryPoint(id: "a", name: "Search", character: nil, count: nil, group: "tools"),
            BridgeReply.EntryPoint(id: "b", name: "Vault", character: nil, count: nil, group: "mine"),
        ]
        let titles = PortalSource.entriesAsFolders(portal: "p", entries)
            .filter { $0.kind == .separator }.map(\.title)
        #expect(!titles.isEmpty)
        #expect(titles.allSatisfy { PortalGroups.wordingKey(for: $0) != nil })
    }
}
