import Core
@_spi(Check) import Flows
import Foundation
import JellyfinKit
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// **The immediate failures from AP58, wave 1** (2026-09-26) — server move, server search,
/// invitation and the Live shelf. The others sit with their topic
/// (`PlayerNextEpisodeTests`, `FortsetzstelleTests`, `ScheduleBehaviorTests`,
/// `HistoryProfileTests`, `ChildTargetsPhoneTests`).
@Suite("Instant errors on the phone")
struct InstantErrorPhoneTests {

    // MARK: - Server migration (finding E2)

    /// `URL(string:)` liest `jellyfin.example:8096` als Schema ohne Rechner.
    @Test("The migration reads an address without a scheme as on the TV")
    func moveWithoutScheme() throws {
        let target = try #require(ServerMigrationFlow.target(from: " jellyfin.example:8096 "))
        #expect(target.scheme == "http")
        #expect(target.host() == "jellyfin.example")
        #expect(target.port == 8096)
        #expect(
            ServerMigrationFlow.target(from: "https://vault.example/") == URL(string: "https://vault.example")
        )
        #expect(ServerMigrationFlow.target(from: "   ") == nil)
    }

    // MARK: - Server search (finding E1)

    /// **Through the setup model and the shared flow** (AP58 R7): The rule
    /// has lived in ``Flows/LoginFlow/searchServers()`` since then; what is checked here is that
    /// the phone uses it.
    @Test("A find the phone cannot reach is noted and stays listed")
    @MainActor
    func serverSearchNoted() async throws {
        let reachable = ServerDiscovery.Found(
            id: "a", name: "House", address: try #require(URL(string: "http://192.0.2.184:8096")))
        let foreign = ServerDiscovery.Found(
            id: "b", name: "Lab", address: try #require(URL(string: "http://jellyfin.example:8096")))
        let name = "test.\(UUID().uuidString)"
        let model = SourceFormModel(
            state: SetupState(
                keychain: SecureStore(service: name),
                listen: PlaylistStore(
                    store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
                store: UserDefaults(suiteName: name) ?? .standard,
                ledgerStore: InMemoryStore()),
            services: .mock(
                broadcast: [reachable], probed: [foreign],
                reached: { $0.host() != "jellyfin.example" }),
            deviceID: "test")

        await model.searchServers()

        #expect(model.found.map(\.id) == ["a", "b"], "stays listed")
        #expect(model.unreachable == ["b"])
    }

    // MARK: - Invitation (finding E4)

    @Test("An invitation accepts http and https, nothing else")
    func invitationWithHttps() throws {
        #expect(
            PortalSettingsModel.suitsInvitation(try #require(URL(string: "http://cl.example:8100"))))
        #expect(
            PortalSettingsModel.suitsInvitation(
                try #require(URL(string: "https://cl.example.test"))))
        #expect(!PortalSettingsModel.suitsInvitation(try #require(URL(string: "ftp://cl.example"))))
        #expect(
            !PortalSettingsModel.suitsInvitation(try #require(URL(string: "https:/no-host"))))
    }

    // MARK: - Live shelf (decision 21)

    /// A channel source with a fixed catalog.
    private struct FixedCatalog: ChannelListingSource {
        let channels: [Channel]
        func channels() async -> ChannelCatalog { ChannelCatalog(channels: channels) }
        func program(forItem channels: [Channel]) async -> [String: [Programme]] { [:] }
        func freshProgramme() async -> Int { 0 }
        func downloadsState() async -> ProgrammeState { .empty }
        func sport(from: Date, until: Date) async -> [SportEvent] { [] }
    }

    /// **`ShelfOrder.liveChannel` carries the channel name on the phone** (decision 21):
    /// What is written is the ``ChannelDisplayName``, not the channel ID. Reading is checked by
    /// `HomeScreenTests.nameInsteadOfIdentifier`. Since AP58 R6 the shelf order is per profile;
    /// the pointer is saved for the check so that another test cannot change it.
    @Test("The choice in the Live shelf stores the channel name, not the identifier")
    @MainActor
    func liveShelfStoresNames() async throws {
        let raw = "DE: Sportfeld HD"
        let channels = Channel(
            id: "4711", name: raw,
            streamURL: try #require(URL(string: "https://example.test/4711")),
            playlistID: "test", group: "DE | SPORT")
        let shelves = InMemoryStore()
        let model = HomeViewModel(
            state: CatalogState.fromAccesses(channelList: true),
            channelSource: FixedCatalog(channels: [channels]), store: InMemoryStore(),
            shelfStore: shelves)
        await model.load()
        let row = try #require(model.remainingChannels.first)

        let stored = ProfilePointer.als(nil) {
            model.setEnabled(channels: row.name)
            return StartPreferences.load(from: shelves, forItem: ProfilePointer.active).liveChannel
        }
        #expect(stored == [ChannelDisplayName(raw).name])
        #expect(!stored.contains("4711"))
    }
}
