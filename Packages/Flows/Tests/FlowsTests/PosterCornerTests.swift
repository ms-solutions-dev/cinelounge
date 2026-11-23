import Core
import Testing

@testable import Flows

/// The poster corners on TV and phone (2026-09-29): open episodes at the top right,
/// otherwise the rating — by one rule for both.
@Suite("Poster corner")
struct PosterCornerTests {

    private func series(pending: Int?, total: Int?) -> MediaItem {
        var title = MediaItem(id: "s", kind: .series, title: "Serie")
        title.unplayedCount = pending
        title.episodeCount = total
        return title
    }

    @Test("Open episodes only if started and not finished")
    func remainingEpisodes() {
        #expect(PosterCorner.remainingEpisodes(series(pending: 3, total: 10)) == 3)
        #expect(PosterCorner.remainingEpisodes(series(pending: 10, total: 10)) == nil)
        #expect(PosterCorner.remainingEpisodes(series(pending: 0, total: 10)) == nil)
        #expect(PosterCorner.remainingEpisodes(series(pending: 3, total: nil)) == nil)
    }

    private func film(_ languages: [String]?) -> MediaItem {
        var title = MediaItem(id: "f", kind: .movie, title: "Die Seereise des Kalon")
        title.languages = languages
        return title
    }

    /// AP84: "Die Seereise des Kalon" appeared at Filmhub only with `(EN)` — one noticed it by the audio.
    @Test("Language corner only without German audio")
    func audioBadge() {
        #expect(PosterCorner.audioBadge(film(["EN"])) == .language("EN"))
        #expect(PosterCorner.audioBadge(film(["DE", "EN"])) == nil)
        #expect(PosterCorner.audioBadge(film(["de"])) == nil)
        #expect(PosterCorner.audioBadge(film(["Ger-Sub", "EN"])) == .originalWithSubtitles)
        #expect(PosterCorner.audioBadge(film(["FR"]))?.short == "FR")
    }

    @Test("Unknown is not German, but not a badge either")
    func audioBadgeUnknown() {
        #expect(PosterCorner.audioBadge(film(nil)) == nil)
        #expect(PosterCorner.audioBadge(film([])) == nil)
        #expect(PosterCorner.audioBadge(film([""])) == nil)
    }

    @Test("IMDb before the community before the critics")
    func rating() {
        var title = MediaItem(id: "f", kind: .movie, title: "Film")
        title.ratings.community = 7.2
        title.ratings.critic = 91
        #expect(Rating.forItem(title)?.origin == .community)
        title.ratings.imdb = 8.0
        #expect(Rating.forItem(title)?.origin == .imdb)
        #expect(Rating.forItem(MediaItem(id: "x", kind: .movie, title: "Ohne")) == nil)
    }
}
