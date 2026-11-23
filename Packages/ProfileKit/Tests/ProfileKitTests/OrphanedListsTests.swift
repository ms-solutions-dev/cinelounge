import Testing

@testable import ProfileKit

/// Lists from the time before profiles go to a profile (phone, 2026-09-28).
@Suite("Orphaned IPTV lists")
struct OrphanedListsTests {

    @Test("A list without a profile goes to the active profile")
    func toTheActive() {
        var ledger = ProfileBook()
        let old = Profile(name: "d")
        ledger.create(old)
        let first = ledger.adoptOrphaned(available: ["y-iptv"], isFresh: { _ in false })
        #expect(first)
        #expect(ledger.activeProfile?.channelLists.compactMap(\.channelListID) == ["y-iptv"])
        let again = ledger.adoptOrphaned(available: ["y-iptv"], isFresh: { _ in false })
        #expect(!again)
    }

    @Test("A fresh active profile gets nothing, the older one does")
    func notToFresh() {
        var ledger = ProfileBook()
        let old = Profile(name: "d")
        let fresh = Profile(name: "neu")
        ledger.create(old)
        ledger.create(fresh)
        ledger.switchTo(zu: fresh.identifier)
        let adopted = ledger.adoptOrphaned(available: ["y-iptv"], isFresh: { $0 == fresh.identifier })
        #expect(adopted)
        #expect(ledger.profile.first { $0.identifier == fresh.identifier }?.channelLists.isEmpty == true)
        #expect(ledger.profile.first { $0.identifier == old.identifier }?.channelLists.count == 1)
    }
}
