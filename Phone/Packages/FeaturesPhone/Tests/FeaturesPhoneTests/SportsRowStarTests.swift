import Core
import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The star of the sports row shows what it switches** (check Live, finding 2, 2026-09-27).
///
/// Until then icon and VoiceOver text followed `marks` (bookmarked **or**
/// followed), but the tap switched only the bookmark. After "Follow Demirbahçe" the
/// star was filled on every match, and two taps changed nothing visible.
@MainActor
@Suite("Sports row: star")
struct SportsRowStarTests {

    static let game = SportEvent(
        id: "s1", kind: .football, competition: "Göl Ligi",
        title: "Demirbahçe - Kalesaray",
        start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 7_000),
        epgIDs: ["epg"])

    static func row(_ watchlist: SportReminderList) -> SportRow {
        SportRow(
            event: game, channelName: nil, watchlist: watchlist, now: Date(timeIntervalSince1970: 0),
            matches: {}, memorize: {}, followClub: { _ in }, followCompetition: { _ in })
    }

    @Test("Followed club: the star is empty, the marker beside it shows the following")
    func isFollowed() {
        var watchlist = SportReminderList()
        watchlist.toggleTeam("Demirbahçe")
        #expect(watchlist.marks(Self.game), "the row is marked — order and filter stay")
        #expect(!Self.row(watchlist).bookmarked, "star filled, label \"Remove bookmark\"")
        #expect(Self.row(watchlist).isFollowed)
    }

    @Test("A tap on the star fills it, the second empties it again")
    func starToggles() {
        var watchlist = SportReminderList()
        watchlist.toggleTeam("Demirbahçe")
        watchlist.toggleMatch(Self.game.id)  // what the tap does
        #expect(Self.row(watchlist).bookmarked, "star stays empty after the tap")
        watchlist.toggleMatch(Self.game.id)  // second tap
        #expect(!Self.row(watchlist).bookmarked, "star stays filled after the second tap")
    }

    @Test("The star button reads the bookmark, not `marks`")
    func wired() throws {
        let text = SourceText.strippingCommentLines(
            try SourceText.read("SportRow.swift", in: .featuresPhone))
        let star = try #require(text.range(of: "private var star: some View"))
        let bodyContent = text[star.upperBound...].prefix(600)
        #expect(bodyContent.contains("active: bookmarked"))
        #expect(bodyContent.contains("bookmarked ? \"sport.unmark\""))
        #expect(!bodyContent.contains("marks("))
    }
}
