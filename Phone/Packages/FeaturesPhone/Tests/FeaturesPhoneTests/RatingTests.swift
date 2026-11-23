import Core
import Testing

@testable import FeaturesPhone

/// Four services, four scales — and one number that ends up on the screen.
@Suite("Rating")
struct RatingTests {

    /// For a title nobody has voted on, all four services return a
    /// zero. Displayed, "0.0" would look like a devastating verdict.
    @Test("Zero and values outside the scale give no rating")
    func limits() {
        #expect(Rating.fromTen(0, .imdb) == nil)
        #expect(Rating.fromTen(nil, .imdb) == nil)
        #expect(Rating.fromTen(-1, .imdb) == nil)
        // Above ten can only be a misunderstanding about the scale.
        #expect(Rating.fromTen(88, .imdb) == nil)

        #expect(Rating.fromHundred(0, .critics) == nil)
        #expect(Rating.fromHundred(nil, .critics) == nil)
        #expect(Rating.fromHundred(101, .critics) == nil)
        #expect(Rating.fromTen(0, .mal) == nil)
    }

    /// Comparison is done by proportion, because four scales otherwise cannot be compared
    /// — what is shown is the number of the respective service.
    @Test("The portion unites both scales")
    func portion() {
        // To a thousandth and not to the bit value: 8.4 / 10 is 0.8400000000000001 in
        // floating point, and a proportion that decides on the boundary between two
        // ratings needs no sixteenth digit.
        let fromTen = try? #require(Rating.fromTen(8.4, .imdb)?.portion)
        let fromHundred = try? #require(Rating.fromHundred(84, .critics)?.portion)
        #expect(abs((fromTen ?? 0) - 0.84) < 0.001)
        #expect(abs((fromHundred ?? 0) - 0.84) < 0.001)
    }

    /// A ten-point scale carries one decimal place, a percentage scale none — "88.0 %"
    /// claims a precision that nobody delivers. MyAnimeList carries two places, as on
    /// myanimelist.net (AP68).
    @Test("The scale is part of the format")
    func format() {
        let ten = Rating.fromTen(8.4, .imdb)
        #expect(ten?.text.contains("8") == true)
        #expect(ten?.text.count == 3)

        let percent = Rating.fromHundred(88, .critics)
        #expect(percent?.text.contains("88") == true)
        #expect(percent?.text != "88")

        let mal = Rating.fromTen(9.25, .mal)
        #expect(mal?.text.contains("25") == true)
        #expect(mal?.text.count == 4)
    }

    /// That a MAL number exists at all means: the title is anime — and there
    /// critic portals have nothing and IMDb few votes.
    @Test("MyAnimeList beats IMDb, IMDb beats the community rating")
    func ranking() {
        let all = [
            Rating.fromTen(6.0, .community),
            Rating.fromTen(7.0, .imdb),
            Rating.fromTen(8.8, .mal),
            Rating.fromHundred(50, .critics),
        ]
        #expect(Rating.best(from: all)?.origin == .mal)
        #expect(Rating.best(from: Array(all.prefix(2)))?.origin == .imdb)
        #expect(Rating.best(from: [all[0], all[3]])?.origin == .community)
        #expect(Rating.best(from: [nil, nil]) == nil)
    }

    /// On an anime's poster the MAL rating comes before the server's (AP68) —
    /// "Crypt Seeker Lord" carried 8.6 at TMDb from few votes, 6.78 at MAL.
    @Test("On the poster, MAL beats the server's rating")
    func posterWithMAL() {
        var title = MediaItem(id: "t", kind: .series, title: "Crypt Seeker Lord")
        title.ratings.community = 8.6
        #expect(Rating.forItem(title)?.origin == .community)
        #expect(Rating.forItem(title, mal: 6.78)?.origin == .mal)
        #expect(Rating.forItem(title, mal: 6.78)?.text.contains("78") == true)
    }

    /// The ranking decides by origin and **not** by height: showing the highest of
    /// four numbers would be no information but advertising.
    @Test("The higher number does not win")
    func notTheHighest() {
        let lowIMDb = Rating.fromTen(4.1, .imdb)
        let highCommunity = Rating.fromTen(9.9, .community)
        #expect(Rating.best(from: [highCommunity, lowIMDb])?.origin == .imdb)
    }

    /// Every origin must be nameable — the screen reader reads the name out,
    /// because the format is missing as a hint.
    @Test("Every origin carries a language key")
    func languageKey() {
        for origin in Rating.Origin.allCases {
            let rating = Rating(origin: origin, portion: 0.5, text: "5")
            #expect(rating.originKey.hasPrefix("rating."))
        }
    }
}
