import Core
import Testing

@testable import Features

/// Which name is on an episode tile is a rule and not a matter of taste per view: In
/// "Continue Watching" the tile carries the series, on the detail page the episode — there
/// the series is already the heading, and on every card of the row it would be the same line
/// once more.
@Suite("Folgen-Kacheln")
@MainActor
struct EpisodeCardTests {

    private func episode(number: Int? = 3) -> MediaItem {
        MediaItem(
            id: "folge",
            kind: .episode,
            title: "Der Fall von Kerrbach",
            parentTitle: "Siege on Corvane",
            seasonNumber: 1,
            episodeNumber: number
        )
    }

    @Test("On the shelves the series is shown, on the detail page the numbered episode")
    func titleFollowsMode() {
        let item = episode()

        #expect(EpisodeCard.title(for: item, mode: .series) == "Siege on Corvane")
        #expect(EpisodeCard.title(for: item, mode: .episode) == "3. Der Fall von Kerrbach")
    }

    @Test("Without a series and without a number the own title remains")
    func fallbacks() {
        // A home video in "Continue Watching" has no series — the tile must then not stay empty.
        // And an episode without a number gets no dot put in front of it with nothing behind it.
        let loose = MediaItem(id: "clip", kind: .homeVideo, title: "Sommer 2019")
        #expect(EpisodeCard.title(for: loose, mode: .series) == "Sommer 2019")

        let unnumbered = episode(number: nil)
        #expect(EpisodeCard.title(for: unnumbered, mode: .episode) == "Der Fall von Kerrbach")
    }
}
