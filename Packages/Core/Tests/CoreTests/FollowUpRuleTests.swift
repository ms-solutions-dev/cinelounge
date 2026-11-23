import Foundation
import Testing

@testable import Core

/// The continuation rule: Collection before similar titles.
@Suite("Continuation from the series")
struct FollowUpRuleTests {

    static func part(_ id: String, watched: Bool = false) -> MediaItem {
        MediaItem(
            id: id,
            kind: .movie,
            title: id,
            progress: watched
                ? PlaybackProgress(position: 7200, duration: 7200, isWatched: true)
                : nil
        )
    }

    static let row = [part("teil-1"), part("teil-2"), part("teil-3")]

    @Test("In the middle of the series the next part comes")
    func middlePartYieldsTheNext() {
        #expect(FollowUpRule.nextPart(after: "teil-1", in: Self.row)?.id == "teil-2")
        #expect(FollowUpRule.nextPart(after: "teil-2", in: Self.row)?.id == "teil-3")
    }

    @Test("Watched parts are skipped — but not at any price")
    func watchedPartsAreSkipped() {
        // Whoever has long known part 2 gets part 3 instead of a repeat.
        let mixed = [Self.part("teil-1"), Self.part("teil-2", watched: true), Self.part("teil-3")]
        #expect(FollowUpRule.nextPart(after: "teil-1", in: mixed)?.id == "teil-3")

        // If all following ones are watched, the immediately next one still applies:
        // continuing the series is the best guess even then, and
        // dismissing costs one tap.
        let allWatched = [
            Self.part("teil-1"),
            Self.part("teil-2", watched: true),
            Self.part("teil-3", watched: true),
        ]
        #expect(FollowUpRule.nextPart(after: "teil-1", in: allWatched)?.id == "teil-2")
    }

    @Test("At the end of the series and outside it stays empty")
    func lastPartAndStrangersYieldNothing() {
        // After the last part the Similar endpoint may guess — not this rule.
        #expect(FollowUpRule.nextPart(after: "teil-3", in: Self.row) == nil)
        // A title that is not in the series at all gets nothing here.
        #expect(FollowUpRule.nextPart(after: "fremd", in: Self.row) == nil)
    }
}
