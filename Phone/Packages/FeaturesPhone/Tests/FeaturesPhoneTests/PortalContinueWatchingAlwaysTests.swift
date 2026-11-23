import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// iPhone, 2026-09-29: Osaka Ledger was in "Continue Watching" on the TV, not on the iPhone.
/// The CL-Server state only came along if a chosen folder returned something; a 404 at the
/// root discarded the whole contribution.
@Suite("CL-Server: Continue Watching always appears")
struct PortalContinueWatchingAlwaysTests {

    private static let continueWatching = Shelf.Identifier.fixed(ShelfIdentifier.continueWatching)

    @Test("Without a choice and with a failing root")
    func withoutChoice() async throws {
        let content = try await Self.home(StartPreferences())
        #expect(content.tiles[Self.continueWatching]?.map(\.id) == ["animehub|osaka-ledger"])
        #expect(content.portals == ["animehub"])
    }

    @Test("With a choice whose folders fail")
    func choiceFails() async throws {
        let content = try await Self.home(
            StartPreferences(portalFolders: [.init(identifier: "animehub||beliebt", name: "Beliebt")]))
        #expect(content.tiles[Self.continueWatching]?.map(\.id) == ["animehub|osaka-ledger"])
    }

    private static func home(_ preferences: StartPreferences) async throws -> StartContent {
        try await FromPortals(
            source: BrokenBridge(),
            memory: PortalMemory(
                store: UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard),
            preferences: { preferences }
        ).home(perShelf: 20)
    }
}

/// A CL-Server whose levels all answer with 404 — but the state does not.
private struct BrokenBridge: PortalContentSource {
    struct NotFound: Error {}

    func portals() async throws -> [PortalInfo] {
        [PortalInfo(id: "animehub", name: "Animehub", state: .ready, capabilities: [])]
    }
    func root(zu portal: String) -> String { "\(portal)||" }
    func level(zu identifier: String, title: String, next: String?) async throws -> PortalLayer {
        throw NotFound()
    }
    func languages(zu identifier: String) async throws -> [String] { [] }
    func select(language: String, forItem identifier: String) async throws {}
    func host(zu identifier: String) async throws -> [PortalHost] { [] }
    func continueWatching(atMost: Int) async -> [TileContent] {
        [TileContent(id: "animehub|osaka-ledger", title: "Osaka Ledger")]
    }
}
