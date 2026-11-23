import Core
import Foundation
import Testing

@testable import ParentalControls

/// The allow list for channels (AP52, decision 14) — **empty means no Live, and
/// only what is explicitly there is allowed.**
@Suite("Channel allow list")
struct ChannelApprovalTests {

    private static func channels(
        _ id: String, group: String?, list: String = "l", adult: Bool = false
    ) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "https://beispiel.test/\(id)")!,
            playlistID: list, group: group, isAdult: adult)
    }

    private static let children = ChannelApproval.Group(list: "l", name: "DE| Kinder")

    @Test("Empty is the default and lets nothing through")
    func empty() {
        let approval = ChannelApproval()
        #expect(approval.isEmpty)
        #expect(!approval.isAllowed(Self.channels("a", group: "DE| Kinder")))
    }

    @Test("Only the named group of the same list is allowed")
    func onlyNamed() {
        let approval = ChannelApproval(groups: [Self.children])
        #expect(approval.isAllowed(Self.channels("a", group: "DE| Kinder")))
        #expect(!approval.isAllowed(Self.channels("b", group: "DE| News")))
        #expect(!approval.isAllowed(Self.channels("c", group: "DE| Kinder", list: "l2")))
        #expect(!approval.isAllowed(Self.channels("d", group: nil)), "without a group never")
    }

    @Test("An adult channel does not pass even in an allowed group")
    func adult() {
        let approval = ChannelApproval(groups: [Self.children])
        #expect(!approval.isAllowed(Self.channels("n", group: "DE| Kinder", adult: true)))
    }

    @Test("Selectable are groups with channels without an adult flag, in provider order")
    func selectable() {
        let catalog = [
            Self.channels("a", group: "DE| News"),
            Self.channels("b", group: "DE| Kinder"),
            Self.channels("c", group: "DE| Kinder"),
            Self.channels("d", group: "DE| Kinder", adult: true),
            Self.channels("e", group: "FOR ADULTS", adult: true),
            Self.channels("f", group: nil),
        ]
        let choice = ChannelApproval.selectable(catalog)
        #expect(choice.map(\.group.name) == ["DE| News", "DE| Kinder"])
        #expect(choice.map(\.channels) == [1, 2])
    }

    @Test("The store is kept per profile and reads corrupt data as empty")
    func store() throws {
        let store = InMemoryStore()
        ChannelApproval(groups: [Self.children]).save(to: store, forItem: "selin")
        #expect(ChannelApproval.load(from: store, forItem: "selin").contains(Self.children))
        #expect(ChannelApproval.load(from: store, forItem: "max").isEmpty)
        #expect(ChannelApproval.load(from: store, forItem: nil).isEmpty)

        ChannelApproval().save(to: store, forItem: "selin")
        let key = ProfileSlot.key(ChannelApproval.storeKey, forItem: "selin")
        #expect((try? store.value(for: key)) == nil, "empty means deleted")

        try store.set("kein json", for: key)
        #expect(ChannelApproval.load(from: store, forItem: "selin").isEmpty)
    }

    @Test("The rule: Live tab and channel list only with a list that allows something")
    func rule() {
        let without = ProtectionRule(deviceLocked: false, accountKind: .kind, isPinSet: true)
        #expect(!without.scope.remains("live"))
        #expect(!without.scope.delivers("senderliste"))

        let using = without.using(channelApproval: ChannelApproval(groups: [Self.children]))
        #expect(using.scope.remains("live"))
        #expect(using.scope.delivers("senderliste"))
        #expect(!using.scope.remains("portale"), "portals stay away")
        #expect(!using.scope.delivers("anbieter"))
        #expect(without != using, "the list is part of the rule state")

        // Without an active lock the list changes nothing.
        #expect(ProtectionRule.pending.scope.remains("live"))
    }
}
