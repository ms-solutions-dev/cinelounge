import Core
import ParentalControls
import SwiftUI
import Testing

@testable import Features

/// A provider's own section on the TV (AP60 item 5, 2026-09-30).
///
/// **The product requirement:** two portals are switched off, and once
/// their titles showed up in "Continue Watching" anyway — this must definitely not happen.
/// The rows here take only what belongs to exactly this provider.
@Suite("Own section on the TV")
@MainActor
struct OwnSectionTests {

    private static func title(
        _ portal: String, _ name: String, approval: String? = nil
    ) -> MediaItem {
        var item = MediaItem(id: "\(portal)|\(portal):\(name):|/\(name)", kind: .series, title: name)
        item.ageRating = approval
        return item
    }

    private let own = PortalPreferences(ownSection: ["serieshub"])

    @Test("Without an own section there are no rows")
    func withoutOwnSection() {
        let area = OwnArea.forItem(
            portal: "serieshub", preferences: PortalPreferences(), rule: .pending,
            continueWatching: [Self.title("serieshub", "elvaran")], favorites: [])
        #expect(area == nil)
    }

    @Test("Titles from other providers never get in — not even switched-off ones")
    func onlyThisProvider() throws {
        let area = try #require(
            OwnArea.forItem(
                portal: "serieshub", preferences: own, rule: .pending,
                continueWatching: [
                    Self.title("flatone", "aus"),
                    Self.title("serieshub", "elvaran"),
                    Self.title("flattwo", "aus"),
                ],
                favorites: [Self.title("flatone", "fav"), Self.title("serieshub", "veldmoor")]))
        #expect(area.continueWatching.map(\.title) == ["elvaran"])
        #expect(area.favorites.map(\.title) == ["veldmoor"])
    }

    @Test("An identifier without a readable provider drops out")
    func unreadableIdentifier() {
        let foreign = MediaItem(id: "ohne-trenner", kind: .movie, title: "fremd")
        let area = OwnArea.forItem(
            portal: "serieshub", preferences: own, rule: .pending,
            continueWatching: [foreign], favorites: [])
        #expect(area == nil)
    }

    @Test("Parental controls filter as on Home")
    func childProtection() throws {
        let kind = ProtectionRule(
            deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from12)
        let area = try #require(
            OwnArea.forItem(
                portal: "serieshub", preferences: own, rule: kind,
                continueWatching: [
                    Self.title("serieshub", "aot", approval: "FSK-16"),
                    Self.title("serieshub", "fussball", approval: "FSK-6"),
                ],
                favorites: [Self.title("serieshub", "aot", approval: "FSK-16")]))
        #expect(area.continueWatching.map(\.title) == ["fussball"])
        #expect(area.favorites.isEmpty)
    }

    @Test("Both rows empty: no section, the provider looks as before")
    func empty() {
        let area = OwnArea.forItem(
            portal: "serieshub", preferences: own, rule: .pending,
            continueWatching: [Self.title("animehub", "x")], favorites: [])
        #expect(area == nil)
    }

    @Test("A tile's focus carries its row")
    func focusIdentifier() {
        let item = Self.title("serieshub", "elvaran")
        #expect(
            PortalLevel<EmptyView>.tileFocus(.continueWatching, item)
                != PortalLevel<EmptyView>.tileFocus(.favorites, item))
    }
}
