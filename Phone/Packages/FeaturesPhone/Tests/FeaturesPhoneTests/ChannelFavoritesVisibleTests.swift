import Core
import Foundation
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// **Favorite channels show only what the Live tab shows** (start check F4,
/// 2026-09-27). A tag stays with the provider even if the adult switch is
/// off afterwards or the group is hidden.
@MainActor
@Suite("Channel favorites: visible only")
struct ChannelFavoritesVisibleTests {

    struct ProbeSource: ChannelListingSource {
        let channels: [Channel]
        func channels() async -> ChannelCatalog { ChannelCatalog(channels: channels) }
        func program(forItem channels: [Channel]) async -> [String: [Programme]] { [:] }
        func freshProgramme() async -> Int { 0 }
        func downloadsState() async -> ProgrammeState { .empty }
        func sport(from: Date, until: Date) async -> [SportEvent] { [] }
    }

    static let night = Channel(
        id: "nacht", name: "Nacht", streamURL: URL(string: "http://x/nacht")!,
        playlistID: "l1", group: "ADULT", isFavorite: true, isAdult: true)
    static let sport = Channel(
        id: "sport", name: "Sport", streamURL: URL(string: "http://x/sport")!,
        playlistID: "l1", group: "WEG", isFavorite: true)
    static let ahorn = Channel(
        id: "ahorn", name: "AHORN", streamURL: URL(string: "http://x/ahorn")!,
        playlistID: "l1", group: "DE", isFavorite: true)

    @Test("A saved adult channel does not appear while the switch is off")
    func adultChannelInFavorites() async {
        #expect(LivePreferences().showsAdultChannels == false)
        let sharedStore = await ChannelFavorites(source: ProbeSource(channels: [Self.night])).favorites()
        #expect(sharedStore.title.isEmpty)
    }

    @Test("A favorite from a hidden group does not appear")
    func hiddenGroup() async {
        var preferences = LivePreferences()
        preferences.setVisible(false, group: "WEG")
        let pinned = preferences
        let sharedStore = await ChannelFavorites(
            source: ProbeSource(channels: [Self.sport, Self.ahorn]), preferences: { pinned }
        ).favorites()
        #expect(sharedStore.title.map(\.id) == ["ahorn"])
    }
}
