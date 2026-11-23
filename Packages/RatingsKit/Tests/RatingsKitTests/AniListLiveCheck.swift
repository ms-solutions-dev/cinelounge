import Core
import Foundation
import Testing

@testable import RatingsKit

/// A tool for looking things up, not a test for everyday use.
///
/// Runs only when `CINELOUNGE_LIVE=1` is set. Tests must not depend on the network
/// — otherwise they fail on the train and nobody believes them any more. For
/// the question "is it our own code or the service?" a real retrieval
/// is nevertheless the only reliable means.
@Suite(
    "AniList against the real service",
    .enabled(if: ProcessInfo.processInfo.environment["CINELOUNGE_LIVE"] == "1"))
struct AniListLiveCheck {

    /// The numbers come from `CINELOUNGE_ANILIST_IDS` (comma separated), so the check names
    /// no titles of its own.
    @Test("The given AniList numbers deliver values")
    func realScores() async throws {
        let client = AniListClient()
        let ids = (ProcessInfo.processInfo.environment["CINELOUNGE_ANILIST_IDS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        try #require(!ids.isEmpty, "set CINELOUNGE_ANILIST_IDS")

        for id in ids {
            let score = try await client.score(forAniListID: id)
            print("  \(id): \(score) %")
            #expect(score > 0 && score <= 100)
        }
    }
}
