import Core
import Foundation
import Testing

@testable import Features

/// The merging of the favorites — since 2026-08-15 with the provider library as the fourth
/// section.
///
/// The trigger is an on-device finding: favorites in VOD exist but are not listed there. The
/// marks were in the local memory, but the source answered the favorites question with a
/// hard-wired empty list — and this model never got to see them.
@MainActor
@Suite("Favorites from all sources")
struct FavoritesModelTests {

    private func movie(_ id: String) -> MediaItem {
        MediaItem(id: id, kind: .movie, title: id)
    }

    private func channel(_ id: String) -> Channel {
        Channel(
            id: id,
            name: "Sender " + id,
            streamURL: URL(string: "http://host/live/u/p/\(id).m3u8")!,
            playlistID: "liste"
        )
    }

    /// **The same finding, one source later** (2026-08-28): An item marked as a favorite at
    /// Serieshub does not show up under the favorites. The mark was on the bridge — but this
    /// view asks every source individually, and a new one does not register by itself.
    @Test("Portal titles get their own section — between provider and channels")
    func portalsGetTheirOwnSection() {
        let sections = FavoritesModel.arrange(
            items: [movie("Kaltfront")],
            channels: [channel("1")],
            vodItems: [movie("Der Pakuro")],
            portalItems: [MediaItem(id: "serieshub||f=x", kind: .series, title: "Bowline")]
        )

        #expect(sections.map(\.id) == [.movies, .vod, .portals, .channels])
        #expect(sections.first { $0.id == .portals }?.items.map(\.title) == ["Bowline"])
    }

    /// **A portal series does not play, it leads to its page.** At the provider every marked
    /// title is a file and is therefore started immediately; a portal entry can be a series. A
    /// press on it would then have to play a series — there is nothing to play.
    @Test("A portal entry does not start directly")
    func portalsDoNotPlayDirectly() {
        let sections = FavoritesModel.arrange(
            items: [], channels: [],
            portalItems: [MediaItem(id: "serieshub||f=x", kind: .series, title: "Bowline")]
        )
        let entry = sections.first { $0.id == .portals }?.items.first
        #expect(entry?.playsDirectly == false)
    }

    @Test("Provider titles get their own section — before the channels")
    func vodGetsItsOwnSection() {
        let sections = FavoritesModel.arrange(
            items: [movie("Kaltfront")],
            channels: [channel("1")],
            vodItems: [movie("Der Pakuro")]
        )

        #expect(sections.map(\.id) == [.movies, .vod, .channels])
    }

    @Test("A provider title plays directly — it has no detail page")
    func vodEntriesPlayDirectly() {
        let sections = FavoritesModel.arrange(
            items: [], channels: [], vodItems: [movie("Der Pakuro")]
        )

        let entry = sections.first?.items.first
        #expect(entry?.playsDirectly == true)
        #expect(entry?.item != nil)
        // The counter-check: Titles of the media server still open their page.
        let media = FavoritesModel.arrange(items: [movie("Kaltfront")], channels: [])
        #expect(media.first?.items.first?.playsDirectly == false)
    }

    @Test("Without provider marks the section is omitted")
    func emptyVODLeavesNoSection() {
        let sections = FavoritesModel.arrange(
            items: [movie("Kaltfront")], channels: [], vodItems: []
        )

        #expect(sections.map(\.id) == [.movies])
    }

    @Test("Provider titles are sorted by name")
    func vodEntriesAreSortedByTitle() {
        let sections = FavoritesModel.arrange(
            items: [], channels: [],
            vodItems: [movie("Zelwig"), movie("Ambra"), movie("Lattice")]
        )

        #expect(sections.first?.items.map(\.title) == ["Ambra", "Lattice", "Zelwig"])
    }
}
