import Core
import Foundation
import PlaylistKit
import PortalKit
import ProfileKit
import Testing

@testable import FeaturesPhone

/// **A new profile is new, and Settings do not contradict themselves** (on-device test
/// build 1332, 2026-09-27, findings 1 and 3).
///
/// The overview said "IPTV accesses: none", the list below showed `Y-IPTV` (active),
/// and Favorites and Search carried the portal titles of the deleted profile. Both lay with the
/// device and were built for whoever sat in front of it.
///
/// Counter-checks (run against the code before the fix): without the window in
/// ``SourceAssembly/inWindow(_:ledgerStore:)`` ``listLikeOverview()`` turns red; without the latch in
/// ``SourceAssembly/portalSourceForProfile(state:environment:source:)`` ``portalsOnlyOnRequest()`` does.
@MainActor
@Suite("Channel lists and portals per profile on the phone")
struct PerProfilePhoneTests {

    struct Setup {
        let state: SetupState
        let listen: PlaylistStore
        let ledger: InMemoryStore
    }

    /// A phone with `Y-IPTV` on the device, an old profile that had the list and the portals,
    /// and a new, empty profile sitting in front of it.
    private func setup() -> (Setup, old: Profile.Identifier, fresh: Profile.Identifier) {
        let name = "probe.\(UUID().uuidString)"
        let ledger = InMemoryStore()
        let listen = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        listen.add(
            Playlist(
                id: "xtream|provider.example|y", name: "Y-IPTV",
                kind: .xtream(server: URL(string: "http://provider.example")!, username: "y")),
            password: "secret")
        var profile = ProfileBook()
        var old = Profile(name: "Old")
        old.create(.channelList(identifier: "xtream|provider.example|y"))
        old.create(.portals(person: nil))
        let fresh = Profile(name: "New")
        profile.create(old)
        profile.create(fresh)
        profile.switchTo(zu: fresh.identifier)
        profile.write(in: ledger)
        let state = SetupState(
            keychain: SecureStore(service: name), listen: listen,
            store: UserDefaults(suiteName: name) ?? .standard, ledgerStore: ledger)
        return (Setup(state: state, listen: listen, ledger: ledger), old.identifier, fresh.identifier)
    }

    @Test("The \"IPTV accesses\" list shows what the overview counts")
    func listLikeOverview() {
        let (a, old, _) = setup()
        let seen = SourceAssembly.inWindow(a.listen, ledgerStore: a.ledger)

        #expect(a.state.channelLists.isEmpty, "the overview says \"nothing\"")
        #expect(seen.visiblePlaylists.isEmpty, "the list showed Y-IPTV")
        #expect(seen.enabledPlaylists.isEmpty, "Live and catalog played Y-IPTV")

        // The old profile still sees its list — it lies on the device.
        var ledger = ProfileBook.read(from: a.ledger)
        ledger.switchTo(zu: old)
        ledger.write(in: a.ledger)
        #expect(seen.visiblePlaylists.map(\.id) == ["xtream|provider.example|y"])
        #expect(a.state.channelLists.map(\.id) == ["xtream|provider.example|y"])
    }

    @Test("A profile without portals gets no portal source, one with portals does")
    func portalsOnlyOnRequest() {
        let (a, old, _) = setup()
        let bridge = PortalSource(
            bridge: PortalBridge(basis: URL(string: "http://bridge.invalid:8100")!, trait: nil))

        #expect(
            SourceAssembly.portalSourceForProfile(state: a.state, environment: [:], source: { bridge })
                == nil,
            "the new profile saw the old profile's portal titles")

        var ledger = ProfileBook.read(from: a.ledger)
        ledger.switchTo(zu: old)
        ledger.write(in: a.ledger)
        #expect(
            SourceAssembly.portalSourceForProfile(state: a.state, environment: [:], source: { bridge })
                === bridge)
    }
}
