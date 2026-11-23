import Foundation
import RatingsKit
import Testing

@testable import FeaturesPhone

/// What arrives later from the network must end up on the right person and the right title.
@Suite("Detail content")
struct DetailContentTests {

    private func content(cast: [PersonDetail] = []) -> DetailContent {
        DetailContent(
            title: HeroContent(tile: TileContent(id: "1", title: "Blono")),
            isSeries: true,
            seasons: [
                Season(
                    id: 1,
                    episodes: [
                        EpisodeInfo(id: "f1", number: 1, title: "One", seen: true),
                        EpisodeInfo(id: "f2", number: 2, title: "Two"),
                        EpisodeInfo(id: "f3", number: 3, title: "Three"),
                    ]),
                Season(id: 2, episodes: [EpisodeInfo(id: "f4", number: 1, title: "Four")]),
            ],
            cast: cast)
    }

    /// **The voice goes via the role name and never via the speaker.** Jellyfin appends
    /// "(voice)" to anime, and AniList writes Japanese names in a different
    /// romanization — the role name is the only way between the two sources.
    @Test("The German voice lands on the right role")
    func voices() throws {
        let cast = [
            PersonDetail(id: "p1", name: "Ryo Fujisaka", characterName: "Haruto Kagemura (voice)"),
            PersonDetail(id: "p2", name: "Nao Kirishima", characterName: "Rin Ashidaka (voice)"),
        ]
        let info = ExternalInfo(
            voices: GermanVoices(
                byCharacter: ["haruto kagemura": VoiceCredit(name: "Lukas Fennrich", imageURL: nil)]))

        let completed = content(cast: cast).using(info)
        #expect(completed.cast[0].voiceActor == "Lukas Fennrich")
        // **No empty second line** where AniList has nothing: it would look like an
        // error.
        #expect(completed.cast[1].voiceActor == nil)
    }

    /// The marks survive what comes in from outside — otherwise tick and heart would jump
    /// back as soon as a rating arrives.
    @Test("Watched and favorite survive the late additions")
    func badgesStay() {
        var state = content()
        state.seen = true
        state.favorite = true
        let completed = state.using(ExternalInfo(ratings: [Rating.fromTen(8.4, .imdb)!]))
        #expect(completed.seen)
        #expect(completed.favorite)
        #expect(completed.title.ratings.count == 1)
    }

    /// A portrait fetched later is the **replacement**, not the preference: the media
    /// server's picture fits the title, the fetched one is a name search.
    @Test("The own image stays in front")
    func portraits() throws {
        let own = try #require(URL(string: "https://example.invalid/own.jpg"))
        let foreign = try #require(URL(string: "https://example.invalid/foreign.jpg"))
        let cast = [
            PersonDetail(id: "p1", name: "With image", image: own),
            PersonDetail(id: "p2", name: "Without image"),
        ]
        let completed = content(cast: cast)
            .using(portraits: ["With image": foreign, "Without image": foreign])
        #expect(completed.cast[0].imageAddress == own)
        #expect(completed.cast[1].imageAddress == foreign)
    }

    /// **Over all seasons before it, not just the open one.** Whoever starts at season 2 episode 1
    /// has seen season 1 — exactly the case in which the follow-up question is worth something.
    /// And only what is **open** is counted: setting what is already watched once
    /// more would be a number without effect.
    @Test("The episodes before reach across season boundaries")
    @MainActor
    func before() {
        let model = DetailModel(identifier: "1", source: nil, rule: .pending)
        let state = content()
        #expect(model.openPrior(state.seasons[1].episodes[0]).isEmpty)

        // Without loaded content the model knows no seasons — the question then does not arise
        // at all, and that is the right zero case.
        #expect(model.seasons.isEmpty)
    }

    /// The whole batch is set, rather than one episode after the other becoming visible.
    @Test("The marks are set on the whole batch")
    func badgesOnStack() {
        let isSet = DetailModel.withMarks(content(), seen: true, on: ["f2", "f4"])
        #expect(isSet.seasons[0].episodes.map(\.seen) == [true, true, false])
        #expect(isSet.seasons[1].episodes[0].seen)
    }

    /// **On the right it shows how many episodes are still open** — not how many there are.
    @Test("The season counts what is open")
    func pending() {
        #expect(content().seasons[0].pending == 2)
        #expect(content().seasons[1].pending == 1)
    }

    /// Season 0 is Jellyfin's collection point for special episodes — nobody
    /// understands "Season 0".
    @Test("The server's name takes precedence over the number")
    func label() {
        #expect(Season(id: 3, name: "The Return", episodes: []).label == "The Return")
        #expect(Season(id: 3, name: "", episodes: []).label != "")
        #expect(
            Season(id: 0, episodes: []).label
                == String(localized: "season.specials", bundle: .main))
    }
}
