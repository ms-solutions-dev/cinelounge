import Core
import Flows
import Foundation
import Testing

/// The Home rules from the check run of 2026-09-27 (findings A-S3, A-S9, F1) — shared, so
/// that TV and phone give the same answer.
struct HomeParityTests {

    // MARK: - A-S3: the header draws only from movies and series

    @Test("Header: only movie and series libraries, never mixed ones, home videos or unknown")
    func headerKinds() {
        #expect(HomeLayout.fillsHeader(.movies))
        #expect(HomeLayout.fillsHeader(.series))
        #expect(!HomeLayout.fillsHeader(.mixed))
        #expect(!HomeLayout.fillsHeader(.homeVideos))
        #expect(!HomeLayout.fillsHeader(nil))
    }

    // MARK: - A-S9: provider categories per credential

    @Test("Without a choice every credential gets its first categories — not just the first one")
    func perAccess() {
        let all = ["a|vod|1", "a|vod|2", "a|series|3", "b|vod|7", "b|series|8"]
        let chosen = HomeLayout.providerCategories(
            all, identifier: { $0 }, perProvider: 2, chosen: [])
        #expect(chosen == ["a|vod|1", "a|vod|2", "b|vod|7", "b|series|8"])
    }

    @Test("If all chosen categories have vanished, the default applies again")
    func vanishedChoice() {
        let all = ["a|vod|1", "a|vod|2", "a|series|3"]
        let chosen = HomeLayout.providerCategories(
            all, identifier: { $0 }, perProvider: 1, chosen: ["a|vod|99"])
        #expect(chosen == ["a|vod|1"])
    }

    @Test("A choice on one credential leaves the other its default")
    func choicePerAccess() {
        let all = ["a|vod|1", "a|vod|2", "b|vod|7", "b|vod|8"]
        let chosen = HomeLayout.providerCategories(
            all, identifier: { $0 }, perProvider: 1, chosen: ["a|vod|2"])
        #expect(chosen == ["a|vod|2", "b|vod|7"])
    }

    // MARK: - A-S9: collections in every language

    @Test("The collection library is recognized in every language of the app, not just the chosen one")
    func collectionsLanguageFree() {
        for name in ["Sammlungen", "Collections", "Koleksiyonlar", "collections"] {
            #expect(HomeLayout.isCollectionLibrary(name: name, kind: .mixed), "\(name)")
        }
        #expect(!HomeLayout.isCollectionLibrary(name: "Verzeichnisse", kind: .mixed))
        #expect(!HomeLayout.isCollectionLibrary(name: "Collections", kind: .movies))
    }

    // MARK: - F1: a series made of remembered episodes

    @Test("A series made of remembered episodes knows all its marks")
    func seriesKnowsItsEpisodes() {
        let pilot = MediaItem(id: "f1", kind: .episode, title: "Pilot", parentTitle: "Quill", seriesID: "s1")
        let two = MediaItem(id: "f2", kind: .episode, title: "Zwei", parentTitle: "Quill", seriesID: "s1")
        let series = FavoritesOrder.split([pilot, two]).allSeries.first
        #expect(series?.markedEpisodes.map(\.id) == ["f1", "f2"])
        #expect(series?.isMarkedItself == false)
    }
}
