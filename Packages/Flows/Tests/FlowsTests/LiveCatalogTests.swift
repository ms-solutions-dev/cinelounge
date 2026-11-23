import Core
import Foundation
import ParentalControls
import Testing

@testable import Flows

/// **Visibility, search and favorites comparison — one rule for both live models**
/// (AP58 R5, finding L1).
@Suite("Live catalog")
struct LiveCatalogTests {

    private static func channels(
        _ id: String, _ name: String, group: String? = nil, adult: Bool = false
    ) -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://x/\(id)")!, playlistID: "list",
            group: group, isAdult: adult)
    }

    // MARK: - Visibility

    @Test("Separator rows, hidden groups and adult channels drop out")
    func isVisible() {
        var preferences = LivePreferences()
        preferences.setVisible(false, group: "WEG")
        let catalog = [
            Self.channels("a", "Eins", group: "DE"),
            Self.channels("t", "##### SOLA #####", group: "DE"),
            Self.channels("w", "Zwei", group: "WEG"),
            Self.channels("x", "Drei", group: "DE", adult: true),
        ]
        #expect(LiveCatalog.isVisible(catalog, preferences: preferences).map(\.id) == ["a"])
    }

    // MARK: - Search

    @Test("Search starts at two characters")
    func minimumLength() {
        let catalog = [Self.channels("a", "Avena")]
        #expect(LiveCatalog.search("a", in: catalog) == nil)
        #expect(LiveCatalog.search("av", in: catalog)?.channels.map(\.id) == ["a"])
    }

    @Test("At most two hundred hits, but the full count")
    func capping() {
        let catalog = (0..<250).map { Self.channels("s\($0)", "Sport \($0)") }
        let match = LiveCatalog.search("sport", in: catalog)
        #expect(match?.channels.count == LiveCatalog.maxMatches)
        #expect(match?.count == 250)
    }

    @Test("The provider prefix and superscript characters do not interfere")
    func key() {
        let catalog = [Self.channels("a", "DE: SOLA CINEMA ᴴᴰ")]
        #expect(LiveCatalog.search("cinema hd", in: catalog)?.count == 1)
        #expect(LiveCatalog.search("de", in: catalog)?.count == 0)
    }

    // MARK: - Favorites

    @Test("The same favorite in a different spelling comes along, another version does not")
    func favorite() {
        var catalog = [
            Self.channels("a", "Das Nordlicht HD"), Self.channels("b", "DAS NORDLICHT | HD"),
            Self.channels("c", "Das Nordlicht UHD"),
        ]
        LiveCatalog.setFavorite(true, for: catalog[0], in: &catalog)
        #expect(catalog.map(\.isFavorite) == [true, true, false])
        #expect(LiveCatalog.isSameFavorite(catalog[0], catalog[1]))
        #expect(!LiveCatalog.isSameFavorite(catalog[0], catalog[2]))
    }

    // MARK: - Remaining time

    @Test("The last minute counts as one minute")
    func remainingMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let broadcast = Programme(
            id: "p", channelID: "a", title: "T", start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(20))
        #expect(LiveCatalog.remainingMinutes(broadcast, um: now) == 1)
        #expect(LiveCatalog.remainingMinutes(broadcast, um: now.addingTimeInterval(30)) == nil)
    }
}
