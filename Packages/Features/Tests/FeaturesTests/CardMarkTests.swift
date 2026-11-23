import Core
import Testing

@testable import Features

/// Watched mark and favorite badge directly from the grid.
///
/// The long-press menu switches the display **before** the server has answered — so the
/// calculation for it must be right without a server: What the card shows after the press
/// is exactly what these checks pin down. The worst error would be a card that still looks
/// unwatched after "watched" — then you press again and set the mark back.
@Suite("Watched and favorite from the grid")
@MainActor
struct CardMarkTests {

    @Test("A film counts as watched after the mark — and no longer after it is taken back")
    func movieMarkRoundTrip() {
        let movie = MediaItem(id: "m", kind: .movie, title: "Film", runtime: 5400)

        let watched = LibraryModel.marking(movie, watched: true)
        #expect(watched.isWatched)
        // The position is at the end, not at zero: A "watched" movie with position zero would
        // otherwise offer itself everywhere as "resume from the start".
        #expect(watched.progress?.position == 5400)

        let unwatched = LibraryModel.marking(watched, watched: false)
        #expect(!unwatched.isWatched)
        #expect(unwatched.progress?.position == 0)
    }

    @Test("For a series the number of unwatched episodes counts")
    func seriesCountsUnplayed() {
        // The server tracks the state of a series through the unwatched episodes — the more
        // reliable information than the mark on the series entry itself. The calculation must use
        // the same quantity, otherwise the card keeps showing the old state after the press.
        let series = MediaItem(
            id: "s", kind: .series, title: "Serie",
            episodeCount: 24, unplayedCount: 7
        )
        #expect(!series.isWatched)

        let watched = LibraryModel.marking(series, watched: true)
        #expect(watched.unplayedCount == 0)
        #expect(watched.isWatched)

        // Once undone, all episodes are open again — only the server knows the real number, but
        // "all" is the honest approximation: It safely shows "unwatched" instead of randomly
        // "almost finished".
        let unwatched = LibraryModel.marking(watched, watched: false)
        #expect(unwatched.unplayedCount == 24)
        #expect(!unwatched.isWatched)
    }

    @Test("A series without episode information falls back to its own mark")
    func seriesWithoutCountsUsesOwnProgress() {
        let series = MediaItem(id: "s", kind: .series, title: "Serie")

        #expect(!series.isWatched)
        #expect(LibraryModel.marking(series, watched: true).isWatched)
    }

    @Test("An episode counts as watched through its own mark")
    func episodeUsesOwnProgress() {
        // The episode tile shows the checkmark through the same rule as the poster — on the
        // episode list it was missing at first, although the server had long tracked the episode
        // as watched.
        let fresh = MediaItem(id: "f", kind: .episode, title: "Folge")
        #expect(!fresh.isWatched)

        let seen = MediaItem(
            id: "f", kind: .episode, title: "Folge",
            progress: PlaybackProgress(position: 0, duration: 1440, isWatched: true)
        )
        #expect(seen.isWatched)
    }
}
