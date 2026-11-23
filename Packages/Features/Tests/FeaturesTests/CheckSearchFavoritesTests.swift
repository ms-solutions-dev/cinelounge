import Core
import Foundation
import Testing

@testable import Features

/// Check finding F1: a series of which only episodes are remembered is a dead tile on the TV.
@MainActor
struct CheckSearchFavoritesTests {

    @Test("Only episodes saved: the series entry opens something and has an image")
    func seriesOnlyFromEpisodes() {
        let episode = MediaItem(
            id: "f1", kind: .episode, title: "Pilot", parentTitle: "Bowline", seriesID: "s1")
        let sections = FavoritesModel.arrange(
            items: [episode], channels: [], imageURL: { URL(string: "http://bild/\($0.id)") })
        let entry = sections.first { $0.id == .series }?.items.first
        #expect(entry != nil)
        // `FavoritesView.tile` does nothing when `item == nil` and `channel == nil`.
        #expect(entry?.item != nil)
        #expect(entry?.imageURL != nil)
        // The poster of the series, not the still frame of the episode.
        #expect(entry?.imageURL?.absoluteString == "http://bild/s1")
        // "No longer a favorite" releases the remembered episode.
        #expect(entry?.toResolve.compactMap(\.item?.id) == ["f1"])

        // Two remembered episodes: both markers are released, otherwise the tile would stay.
        let second = MediaItem(
            id: "f2", kind: .episode, title: "Zwei", parentTitle: "Bowline", seriesID: "s1")
        let both = FavoritesModel.arrange(items: [episode, second], channels: [])
            .first { $0.id == .series }?.items.first
        #expect(both?.toResolve.compactMap(\.item?.id) == ["f1", "f2"])
    }
}
