import Core
import Foundation
import Testing

@testable import RatingsKit

/// What is tested is the parsing, not the network access — that does not belong in a
/// test that runs on every build.
@Suite("AniList ratings")
struct AniListClientTests {

    @Test("The query fetches only the one number that is needed")
    func queryIsMinimal() {
        // With a query language the scope can be specified. Fetching description
        // and images along would be a waste, because both come from the Jellyfin server
        // and are available there in German.
        #expect(AniListClient.query.contains("averageScore"))
        #expect(AniListClient.query.contains("type: ANIME"))
        #expect(!AniListClient.query.contains("description"))
        #expect(!AniListClient.query.contains("coverImage"))
    }

    @Test("A response without a rating counts as not found")
    func missingScore() throws {
        // Entries with too few votes have no rating. That is not an
        // error — there is just nothing to display.
        let json = #"{"data":{"Media":{"averageScore":null}}}"#
        let decoded = try JSONDecoder().decode(
            AniListClient.Response.self,
            from: Data(json.utf8)
        )

        #expect(decoded.data?.media?.averageScore == nil)
    }

    @Test("A rating is read as an integer out of a hundred")
    func parsesScore() throws {
        let json = #"{"data":{"Media":{"averageScore":79}}}"#
        let decoded = try JSONDecoder().decode(
            AniListClient.Response.self,
            from: Data(json.utf8)
        )

        #expect(decoded.data?.media?.averageScore == 79)
    }

    @Test("A non-numeric identifier does not lead to a request")
    func rejectsNonNumericID() async {
        // AniList expects a number. An identifier like "tt2991826" would be a
        // mixed-up IMDb identifier — that should be noticed, not go out onto the network.
        let client = AniListClient()

        await #expect(throws: AniListClient.Failure.notFound) {
            try await client.score(forAniListID: "tt2991826")
        }
    }

    @Test("The failures are named distinguishably")
    func distinctMessages() {
        // When the cap is reached a later attempt is worthwhile, with a
        // missing entry it is not. A shared text would be worthless.
        let keys = [
            AniListClient.Failure.notFound.messageKey,
            AniListClient.Failure.rateLimited.messageKey,
            AniListClient.Failure.unreachable.messageKey,
        ]

        #expect(Set(keys).count == 3)
    }

    @Test("A MAL rating alone does not make the ratings empty")
    func notEmptyWithMALOnly() {
        // For anime this is the normal case: Critic portals do not cover them,
        // so often only this one number remains. It must still be displayed.
        var ratings = ExternalRatings()
        #expect(ratings.isEmpty)

        ratings.mal = 8.8
        #expect(!ratings.isEmpty)
    }
}
