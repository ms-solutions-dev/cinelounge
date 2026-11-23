import Core
import Foundation
import Testing

@testable import RatingsKit

/// What is tested is the parsing of the OMDb field "Awards" — against the forms that
/// actually appear there. Every sentence form in this file was seen in real queries of
/// 75 titles: films with and without Oscars, series, silent films, world cinema and
/// trivia. The figures in them are invented: a real combination of wins and nominations
/// names its title as surely as the title itself.
///
/// The yardstick is not to recognise as much as possible, but to claim nothing false.
/// An invented award is noticed at first glance and destroys trust in
/// all the other information next to it.
@Suite("Awards from OMDb")
struct AwardsTests {

    // MARK: - The two sentence forms

    @Test("A won Oscar is counted as a win and not as a nomination")
    func oscarsWon() throws {
        // A film with several Oscars. The most common case of all and the only one for which the
        // user asked for the display. If it failed, the whole extension
        // would have no purpose.
        let awards = try #require(Awards.parse("Won 3 Oscars. 140 wins & 205 nominations total"))

        #expect(awards.oscarsWon == 3)
        #expect(awards.hasOscar)
        #expect(awards.oscarNominations == 0, "OMDb names only one of the two clauses")
        #expect(awards.totalWins == 140)
        #expect(awards.totalNominations == 205)
    }

    @Test("An Oscar nomination does not become a won Oscar")
    func oscarsOnlyNominated() throws {
        // A nominated film. The difference between nominated and awarded
        // is the whole point of the display: A badge on a film that
        // went home empty-handed would be a false claim.
        let awards = try #require(
            Awards.parse("Nominated for 6 Oscars. 19 wins & 37 nominations total")
        )

        #expect(awards.oscarsWon == 0)
        #expect(!awards.hasOscar)
        #expect(awards.oscarNominations == 6)
        #expect(awards.totalWins == 19, "the film won other things, just no Oscar")
    }

    @Test("A single Oscar in the singular is recognized")
    func singleOscar() throws {
        // A film with one Oscar. OMDb writes "Oscar" without an s as soon as there is just one.
        // Whoever checks only for the plural loses exactly the titles for
        // which the single Oscar is the noteworthy thing.
        let awards = try #require(Awards.parse("Won 1 Oscar. 23 wins & 29 nominations total"))

        #expect(awards.oscarsWon == 1)
        #expect(awards.totalWins == 23)
    }

    @Test("An Oscar nomination in the singular is recognized")
    func singleOscarNomination() throws {
        // A film with one nomination. The same trap as with the win, only in the other sentence.
        let awards = try #require(
            Awards.parse("Nominated for 1 Oscar. 66 wins & 118 nominations total")
        )

        #expect(awards.oscarNominations == 1)
        #expect(awards.oscarsWon == 0)
    }

    // MARK: - Other awards must not become Oscars

    @Test("Emmys are not counted as Oscars")
    func emmysAreNotOscars() throws {
        // A drama series. Series carry the same sentence form with a different prize.
        // A parser that reads only "Won N " credits the series with fourteen
        // Oscars — a series cannot get any at all.
        let awards = try #require(
            Awards.parse("Won 14 Primetime Emmys. 158 wins & 281 nominations total")
        )

        #expect(awards.oscarsWon == 0)
        #expect(awards.oscarNominations == 0)
        #expect(awards.emmysWon == 14)
    }

    @Test("An Emmy in the singular counts as one")
    func singleEmmy() throws {
        // An animated series.
        let awards = try #require(
            Awards.parse("Won 1 Primetime Emmy. 11 wins & 6 nominations total")
        )

        #expect(awards.emmysWon == 1)
    }

    @Test("An Emmy without the Primetime qualifier counts anyway")
    func emmyWithoutPrimetime() throws {
        // OMDb leaves out the addition for some titles. The prize is the same.
        #expect(Awards.parse("Won 2 Emmys. 4 wins & 12 nominations total")?.emmysWon == 2)
    }

    @Test("A BAFTA win makes neither an Oscar nor an Emmy")
    func baftaIsNeither() throws {
        // A British film. British films carry the BAFTA in the same
        // position as others carry the Oscar — the only difference in the sentence is
        // the name of the prize.
        let awards = try #require(Awards.parse("Won 1 BAFTA Award. 12 wins & 8 nominations total"))

        #expect(awards.oscarsWon == 0)
        #expect(awards.emmysWon == 0)
        #expect(awards.totalWins == 12, "the win itself is included in the total")
    }

    @Test("Emmy nominations are deliberately not evaluated")
    func emmyNominationsAreIgnored() throws {
        // A crime series. There is no field for Emmy nominations, and therefore the
        // three must not land anywhere else either — least of all among the wins.
        let awards = try #require(
            Awards.parse("Nominated for 3 Primetime Emmys. 9 wins & 19 nominations total")
        )

        #expect(awards.emmysWon == 0)
        #expect(awards.oscarsWon == 0)
        #expect(awards.totalNominations == 19)
    }

    // MARK: - Faulty sentences from the real world

    @Test("If the period between the two sentences is missing, the totals are not lost")
    func missingSeparator() throws {
        // A comedy — this is how the form comes literally from OMDb, without a
        // separator between prize and total. If one checks the number for a
        // word boundary before it, zero instead of six wins comes out here, because the six
        // sticks to the word "Award".
        let awards = try #require(Awards.parse("Won 1 BAFTA Award6 wins & 15 nominations total"))

        #expect(awards.totalWins == 6)
        #expect(awards.totalNominations == 15)
        #expect(awards.oscarsWon == 0)
    }

    @Test("A mangled sentence with a single nomination stays readable")
    func missingSeparatorSingleNomination() throws {
        // A period drama. No period, no wins, singular for the nomination —
        // three traps in one string, and all three occur for real.
        let awards = try #require(Awards.parse("Nominated for 1 BAFTA Award1 nomination total"))

        #expect(awards.totalNominations == 1)
        #expect(awards.totalWins == 0)
        #expect(awards.oscarsWon == 0)
        #expect(awards.oscarNominations == 0, "the BAFTA is not an Oscar")
    }

    // MARK: - Totals only

    @Test("Without a prize in the first sentence only the totals remain")
    func totalsOnly() throws {
        // A silent film. By far the most common case in an ordinary library:
        // The title has won something, but none of the well-known prizes.
        let awards = try #require(Awards.parse("5 wins & 8 nominations total"))

        #expect(awards.oscarsWon == 0)
        #expect(awards.totalWins == 5)
        #expect(awards.totalNominations == 8)
    }

    @Test("A single win and a single nomination are counted")
    func singularTotals() throws {
        // An animated film and a silent comedy. "1 win" and "1 nomination" without an s are
        // forms of their own; whoever stubbornly checks for the plural shows zero for these
        // titles although something is there.
        #expect(Awards.parse("1 win & 12 nominations total")?.totalWins == 1)
        #expect(Awards.parse("4 wins & 1 nomination total")?.totalNominations == 1)
    }

    @Test("If the sentence about wins is missing, nominations count alone")
    func nominationsOnly() throws {
        // A thriller. Never won, only nominated — then OMDb leaves out the first part.
        // Zero wins are the truth here and no parsing error.
        let awards = try #require(Awards.parse("13 nominations total"))

        #expect(awards.totalWins == 0)
        #expect(awards.totalNominations == 13)
    }

    @Test("If the sentence about nominations is missing, wins count alone")
    func winsOnly() throws {
        // Another silent film. The reverse case, and both occur.
        let awards = try #require(Awards.parse("5 wins total"))

        #expect(awards.totalWins == 5)
        #expect(awards.totalNominations == 0)
    }

    // MARK: - Nothing usable

    @Test("If N/A is in the field, there is no information")
    func notAvailable() {
        // A cult comedy. "N/A" is the rule at OMDb and not the
        // exception. If a structure of zeros came back here, the display would
        // take it for information and write "0 wins" on the film.
        #expect(Awards.parse("N/A") == nil)
    }

    @Test("If the field is missing entirely, there is no information")
    func missingField() {
        // In the title search OMDb returns only identifier, year and poster. The field
        // is then missing completely.
        #expect(Awards.parse(nil) == nil)
    }

    @Test("Whitespace alone gives no information")
    func blank() {
        #expect(Awards.parse("") == nil)
        #expect(Awards.parse("   \n ") == nil)
    }

    @Test("Text without any number gives no information")
    func noNumbers() {
        // Honorary awards appear at OMDb without a count. Without a number there is nothing to
        // count, and nothing is guessed.
        #expect(Awards.parse("Honorary Award") == nil)
        #expect(Awards.parse("Won an Oscar") == nil)
    }

    // MARK: - Nonsensical server data

    @Test("An implausibly high Oscar number is discarded instead of shown")
    func implausibleOscarCount() throws {
        // No film has ever won more than eleven Oscars. If one day the total
        // number of wins stood here in place of the prize — because OMDb changes the
        // wording —, 140 Oscars on the screen would be the worst
        // of all outcomes. Better no award then.
        let awards = try #require(Awards.parse("Won 140 Oscars. 140 wins & 205 nominations total"))

        #expect(awards.oscarsWon == 0)
        #expect(awards.totalWins == 140, "the total stays plausible")
    }

    @Test("A number outside the value range leads to no claim")
    func numberOverflow() {
        // A digit sequence that fits no integer must not end in a
        // crash or in a wrapped-around negative number.
        #expect(Awards.parse("Won 99999999999999999999 Oscars.") == nil)
    }

    @Test("A minus sign before the number is not read as a win")
    func negativeCount() throws {
        // There are no negative values at OMDb, but a rebuilt field or
        // a third-party service can supply them. Minus four Oscars are not four.
        let awards = try #require(Awards.parse("Won -4 Oscars. 3 wins & 2 nominations total"))

        #expect(awards.oscarsWon == 0)
        #expect(awards.totalWins == 3)
    }

    @Test("Without a second sentence the totals do not contradict the Oscars")
    func totalsAreAtLeastTheNamedAwards() throws {
        // If the total is missing, three Oscars would otherwise stand next to zero wins —
        // the display would contradict itself and look like an error.
        let won = try #require(Awards.parse("Won 3 Oscars."))
        #expect(won.totalWins == 3)
        #expect(won.totalNominations == 0, "a win does not additionally count as a nomination")

        let nominated = try #require(Awards.parse("Nominated for 6 Oscars."))
        #expect(nominated.totalNominations == 6)
        #expect(nominated.totalWins == 0)
    }

    // MARK: - All real forms at once

    @Test(
        "No form without an Oscar sentence is credited with an Oscar",
        arguments: [
            "Won 14 Primetime Emmys. 158 wins & 281 nominations total",
            "Won 87 Primetime Emmys. 231 wins & 602 nominations total",
            "Won 33 Primetime Emmys. 176 wins & 349 nominations total",
            "Won 24 Primetime Emmys. 119 wins & 287 nominations total",
            "Won 1 Primetime Emmy. 7 wins & 10 nominations total",
            "Nominated for 2 Primetime Emmys. 21 wins & 16 nominations total",
            "Won 1 BAFTA Award. 12 wins & 8 nominations total",
            "Won 1 BAFTA Award6 wins & 15 nominations total",
            "Nominated for 1 BAFTA Award9 wins & 36 nominations total",
            "Nominated for 1 BAFTA Award1 nomination total",
            "5 wins & 8 nominations total",
            "1 win & 12 nominations total",
            "4 wins & 1 nomination total",
            "5 wins total",
            "3 wins total",
            "13 nominations total",
            "2 nominations total",
            "57 wins & 34 nominations total",
            "7 wins & 26 nominations total",
            "N/A",
        ]
    )
    func noOscarInvented(raw: String) {
        // The collective check over everything in the library in the way of forms.
        // A single wrong Oscar here means a wrong badge in
        // live operation — and that can no longer be caught.
        #expect(Awards.parse(raw)?.oscarsWon ?? 0 == 0)
        #expect(Awards.parse(raw)?.oscarNominations ?? 0 == 0)
    }

    @Test(
        "The Oscar numbers of the real forms are taken over exactly",
        arguments: [
            ("Won 3 Oscars. 140 wins & 205 nominations total", 3, 0),
            ("Won 3 Oscars. 28 wins & 33 nominations total", 3, 0),
            ("Won 1 Oscar. 18 wins & 11 nominations total", 1, 0),
            ("Won 2 Oscars. 109 wins & 226 nominations total", 2, 0),
            ("Nominated for 6 Oscars. 19 wins & 37 nominations total", 0, 6),
            ("Nominated for 1 Oscar. 7 wins & 20 nominations total", 0, 1),
            ("Nominated for 8 Oscars. 11 wins & 12 nominations total", 0, 8),
            ("Nominated for 4 Oscars. 12 wins & 13 nominations total", 0, 4),
        ]
    )
    func oscarCountsAreExact(raw: String, won: Int, nominated: Int) throws {
        // Not just "an Oscar is there", but the right count: The display
        // writes the number out, and a wrong number is as good as invented.
        let awards = try #require(Awards.parse(raw))

        #expect(awards.oscarsWon == won)
        #expect(awards.oscarNominations == nominated)
    }

    // MARK: - Store

    @Test("Awards survive encoding for the store")
    func codable() throws {
        let original = Awards(
            oscarsWon: 3, oscarNominations: 0, emmysWon: 0, totalWins: 140, totalNominations: 205
        )
        let restored = try JSONDecoder().decode(Awards.self, from: JSONEncoder().encode(original))

        #expect(restored == original)
    }

    @Test("A stored entry without the new fields stays readable")
    func decodingToleratesMissingFields() throws {
        // If a field is added later, all entries already stored are
        // written without this field. If it were required on reading, all ratings would be gone
        // after one program start — and the
        // daily quota would be due again.
        let awards = try JSONDecoder().decode(
            Awards.self, from: Data(#"{"oscarsWon": 3, "totalWins": 140}"#.utf8)
        )

        #expect(awards.oscarsWon == 3)
        #expect(awards.totalWins == 140)
        #expect(awards.emmysWon == 0)
        #expect(awards.totalNominations == 0)
    }

    // MARK: - Interplay with OMDb

    @Test("From the OMDb response the awards end up with the ratings")
    func ratingsCarryAwards() throws {
        // The shape of a real response, shortened, with invented figures. The free text is in the same
        // response as the rating — that is what makes the display cost no additional
        // query.
        let json = """
            {
              "Response": "True",
              "imdbRating": "8.1",
              "Awards": "Won 3 Oscars. 140 wins & 205 nominations total",
              "Ratings": [{ "Source": "Rotten Tomatoes", "Value": "79%" }]
            }
            """
        let payload = try JSONDecoder().decode(OMDbClient.Response.self, from: Data(json.utf8))
        let ratings = OMDbClient.parse(payload)

        #expect(ratings.awards?.oscarsWon == 3)
        #expect(ratings.hasAwards)
        #expect(ratings.imdb == 8.1, "the score must not be lost through the new field")
    }

    @Test("A response without the Awards field leads to no empty award")
    func ratingsWithoutAwards() throws {
        let json = """
            { "Response": "True", "imdbRating": "7.2", "Ratings": [] }
            """
        let payload = try JSONDecoder().decode(OMDbClient.Response.self, from: Data(json.utf8))
        let ratings = OMDbClient.parse(payload)

        #expect(ratings.awards == nil)
        #expect(!ratings.hasAwards)
        #expect(!ratings.isEmpty, "the score is present")
    }

    @Test("Awards do not count as a rating")
    func awardsAreNoRating() {
        // isEmpty decides in several places whether the row with the
        // rating badges is built at all. If awards counted,
        // an empty row would appear for a title without any rating.
        let ratings = ExternalRatings(awards: Awards(oscarsWon: 1))

        #expect(ratings.isEmpty)
        #expect(ratings.hasAwards)
    }

    @Test("An old store entry without awards is kept on reading")
    func legacyCacheSurvives() async throws {
        // The most expensive conceivable error of this extension: The new field makes
        // the stored JSON unreadable, and at the next start all
        // ratings have vanished. With 1000 queries a day that cannot
        // be made up.
        let store = InMemoryStore()
        try store.set(
            #"{"tt3723945":{"imdb":7.9,"rottenTomatoes":81},"tt8363015":{"imdb":8.1}}"#,
            for: OMDbClient.cacheKey
        )

        let client = OMDbClient(apiKey: "unbenutzt", store: store)

        #expect(await client.cachedCount == 2)
        // A hit in the store answers without a network — here no
        // access to OMDb is available, and the call may still succeed.
        let cached = try await client.ratings(forIMDbID: "tt3723945")
        #expect(cached.imdb == 7.9)
        #expect(cached.awards == nil, "the old entry knows nothing about awards")
    }

    @Test("An unusable entry in the store does not drag the others down")
    func brokenCacheEntryIsSkipped() async throws {
        // A single damaged entry used to discard the whole store. For
        // a library with a few hundred titles that means: start over.
        let store = InMemoryStore()
        try store.set(
            #"{"tt3723945":{"imdb":7.9},"tt0000001":{"imdb":"kaputt"}}"#,
            for: OMDbClient.cacheKey
        )

        let client = OMDbClient(apiKey: "unbenutzt", store: store)

        #expect(await client.cachedCount == 1)
        #expect(try await client.ratings(forIMDbID: "tt3723945").imdb == 7.9)
    }
}
