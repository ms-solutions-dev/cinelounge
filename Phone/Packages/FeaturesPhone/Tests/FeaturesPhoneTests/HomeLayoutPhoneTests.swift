import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// **The phone asks the same start rules as the TV** (AP58 R6).
struct HomeLayoutPhoneTests {

    /// The phone asks via genres, the TV via library types — both
    /// boards must exclude the same types.
    @Test(
        "No catalog shelf for the same kinds as on the TV",
        arguments: [
            Library.Kind.movies, .series, .homeVideos, .music, .liveTV, .mixed, .portalLevel,
        ])
    func withoutShelf(kind: Library.Kind) {
        #expect(
            ShelvesPerCatalog.withoutShelf.contains(Genre(kind)) == HomeLayout.withoutShelf.contains(kind))
    }

    /// **If everything is watched, the last season** — the TV's rule
    /// (``Core/ContinueWatching/startSeason(in:pending:)``). Until R6 the phone played the
    /// first episode of the series.
    @Test("Everything watched: the first episode of the last season")
    func allWatched() {
        let watched = PlaybackProgress(position: 100, duration: 100, isWatched: true)
        var episodes: [MediaItem] = []
        for season in [1, 2] {
            for number in [1, 2, 3] {
                episodes.append(
                    MediaItem(
                        id: "s\(season)e\(number)", kind: .episode, title: "",
                        seasonNumber: season, progress: watched))
            }
        }
        #expect(JellyfinDetailSource.next(from: episodes)?.id == "s2e1")
    }

    @MainActor
    @Test("Limits come from the Home layout")
    func limits() {
        #expect(StartModel.perShelf == HomeLayout.titlesPerShelf)
        #expect(ShelvesPerCatalog.atMost == HomeLayout.shownPerOriginPhone)
        #expect(ShelvesPerCatalog.maxLoaded == HomeLayout.librariesPerOrigin)
    }
}
