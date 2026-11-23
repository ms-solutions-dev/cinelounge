import Core
import Foundation
import Testing

@testable import RatingsKit

/// What is tested is the parsing of the responses — against the forms that OMDb
/// actually supplies. Their shape comes from real queries for titles of this
/// library and for a cinema film; the figures are invented.
@Suite("Ratings from OMDb")
struct OMDbTests {

    @Test("For a theatrical movie all three ratings arrive")
    func movieHasAllThree() throws {
        // The shape of a real response for a theatrical film.
        let json = """
            {
              "Response": "True",
              "imdbRating": "7.2",
              "Ratings": [
                { "Source": "Internet Movie Database", "Value": "7.2/10" },
                { "Source": "Rotten Tomatoes", "Value": "78%" },
                { "Source": "Metacritic", "Value": "63/100" }
              ]
            }
            """
        let payload = try JSONDecoder().decode(
            OMDbClient.Response.self, from: Data(json.utf8)
        )
        let ratings = OMDbClient.parse(payload)

        #expect(ratings.imdb == 7.2)
        #expect(ratings.rottenTomatoes == 78, "the percent sign must be removed")
        #expect(ratings.metacritic == 63, "the part after the slash does not belong")
    }

    @Test("For a series only the audience rating arrives — that is not an error")
    func seriesHasOnlyIMDb() throws {
        // The shape of a real response for an anime series. Rotten Tomatoes and Metacritic
        // do not cover anime; the fields stay empty and are not displayed.
        let json = """
            {
              "Response": "True",
              "imdbRating": "8.6",
              "Metascore": "N/A",
              "Ratings": [
                { "Source": "Internet Movie Database", "Value": "8.6/10" }
              ]
            }
            """
        let payload = try JSONDecoder().decode(
            OMDbClient.Response.self, from: Data(json.utf8)
        )
        let ratings = OMDbClient.parse(payload)

        #expect(ratings.imdb == 8.6)
        #expect(ratings.rottenTomatoes == nil)
        #expect(ratings.metacritic == nil)
        #expect(!ratings.isEmpty, "a rating is present")
    }

    @Test("An exhausted daily quota is recognized as such")
    func quotaIsDistinguished() throws {
        // OMDb reports this as an ordinary failure — recognisable only by the wording.
        // If one confuses it with "not found", one looks for the
        // error in the wrong place.
        let json = """
            { "Response": "False", "Error": "Request limit reached!" }
            """
        let payload = try JSONDecoder().decode(
            OMDbClient.Response.self, from: Data(json.utf8)
        )

        #expect(payload.response == "False")
        #expect(payload.error?.lowercased().contains("limit") == true)
    }

    @Test("If the rating is missing entirely, everything stays empty instead of null")
    func missingRatings() throws {
        let json = """
            { "Response": "True", "imdbRating": "N/A", "Ratings": [] }
            """
        let payload = try JSONDecoder().decode(
            OMDbClient.Response.self, from: Data(json.utf8)
        )
        let ratings = OMDbClient.parse(payload)

        // "N/A" must not pass as a number — otherwise 0.0 would stand on the
        // screen, which would look like a very bad rating.
        #expect(ratings.imdb == nil)
        #expect(ratings.isEmpty)
    }

    @Test("A comma as decimal separator is understood")
    func commaDecimal() throws {
        let json = """
            { "Response": "True", "imdbRating": "8,2", "Ratings": [] }
            """
        let payload = try JSONDecoder().decode(
            OMDbClient.Response.self, from: Data(json.utf8)
        )

        #expect(OMDbClient.parse(payload).imdb == 8.2)
    }

    @Test("Ratings survive encoding for the store")
    func codable() throws {
        let original = ExternalRatings(imdb: 8.7, rottenTomatoes: 94, metacritic: 82)
        let restored = try JSONDecoder().decode(
            ExternalRatings.self, from: JSONEncoder().encode(original)
        )

        #expect(restored == original)
    }

    // MARK: - Check 27.09.2026, D7: rejections with a body

    static func rejection(_ text: String) -> Data {
        Data(#"{"Response":"False","Error":"\#(text)"}"#.utf8)
    }

    @Test("401 with \"Request limit reached!\" is the daily quota, not the network")
    func quotaOn401() {
        #expect(throws: OMDbClient.Failure.quotaExceeded) {
            try OMDbClient.evaluate(status: 401, data: Self.rejection("Request limit reached!"))
        }
    }

    @Test("401 with \"Invalid API key!\" is a wrong key")
    func keyOn401() {
        #expect(throws: OMDbClient.Failure.invalidKey) {
            try OMDbClient.evaluate(status: 401, data: Self.rejection("Invalid API key!"))
        }
        #expect(OMDbClient.Failure.invalidKey.messageKey == "error.omdbInvalidKey")
    }

    @Test("An unknown title stays \"not listed\", a server error stays silent")
    func remainingCases() {
        #expect(throws: OMDbClient.Failure.notFound) {
            try OMDbClient.evaluate(status: 200, data: Self.rejection("Incorrect IMDb ID."))
        }
        #expect(throws: OMDbClient.Failure.unreachable) {
            try OMDbClient.evaluate(status: 500, data: Self.rejection("Request limit reached!"))
        }
        #expect(throws: OMDbClient.Failure.unreachable) {
            try OMDbClient.evaluate(status: 401, data: Data("kaputt".utf8))
        }
    }
}
