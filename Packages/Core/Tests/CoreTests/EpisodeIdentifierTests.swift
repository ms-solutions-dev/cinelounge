import Foundation
import SourceProbe
import Testing

@testable import Core

/// **"S1 F3" in the app's language** — finding B3 of the review of 2026-09-27.
@Suite("Episode identifier")
struct EpisodeIdentifierTests {

    @Test(
        "The episode abbreviation follows the language",
        arguments: [("de", "S1 F3"), ("en", "S1 E3"), ("tr", "S1 B3")])
    func language(language: String, expected: String) {
        #expect(EpisodeIdentifier.text(season: 1, episode: 3, language: language) == expected)
    }

    @Test("Without season or episode there is no identifier")
    func withoutDetails() {
        var title = MediaItem(id: "1", kind: .episode, title: "Folge")
        title.seasonNumber = 1
        #expect(title.episodeIdentifier == nil)
        title.episodeNumber = 4
        #expect(title.episodeIdentifier == EpisodeIdentifier.text(season: 1, episode: 4))
    }

    /// **The guard:** No source file of either program assembles the label itself.
    /// Five places did until 2026-09-27, each with the German "F".
    @Test("Nobody assembles 'S… F…' by hand")
    func noOwnIdentifier() throws {
        let pattern = try Regex(#"S\\\([^)]*\)[ ·]*[FE]\\\("#)
        let files =
            try SourceText.files(in: .packets) + SourceText.files(in: .phonePackages)
            + SourceText.files(in: .tvApp) + SourceText.files(in: .phoneApp)
        let match =
            files
            .filter { !$0.path.contains("/Tests/") }
            .filter { SourceText.strippingCommentLines($0.content).contains(pattern) }
            .map(\.path)
        #expect(!files.isEmpty)
        #expect(match.isEmpty, "EpisodeIdentifier.text instead of custom formatting: \(match)")
    }
}
