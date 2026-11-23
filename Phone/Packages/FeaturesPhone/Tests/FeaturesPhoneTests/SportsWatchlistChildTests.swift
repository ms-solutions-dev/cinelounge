import Core
import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **A child profile reads and does not take over the note pad of the other profile** (check Live, finding 4,
/// 2026-09-27).
///
/// Until then the Live tab built the schedule model unconditionally, and its construction read
/// the note pad. If a child profile with a channel list opened the tab first after the update,
/// the old bookmarks went into its compartment and were deleted at the old places.
@MainActor
@Suite("Sports watchlist: not for children")
struct SportsWatchlistChildTests {

    @Test("Building the schedule model does not read the watchlist")
    func setupDoesNotRead() {
        let file = InMemoryStore()
        RecordSheet.write(["match-1"], under: ["live", "sportMarks"].joined(separator: "."), in: file)
        let store = SportReminderListStore(
            store: file, profile: { "kind" }, keychain: nil, old: nil)
        _ = SportModel(noteStore: store)
        #expect(
            RecordSheet.read([String].self, under: ["live", "sportMarks"].joined(separator: "."), from: file)
                == ["match-1"], "the old list is already adopted at build time")
        #expect(
            RecordSheet.read(SportReminderList.self, under: SportReminderList.key + ".kind", from: file)
                == nil)
    }

    @Test("The Live tab builds the schedule model only with the sports page")
    func onlyWithSports() throws {
        let text = SourceText.strippingCommentLines(
            try SourceText.read("Live/LiveView.swift", in: .featuresPhone))
        let setup = try #require(text.range(of: "_sport = State("))
        let model = try #require(text.range(of: "SportModel(", range: setup.upperBound..<text.endIndex))
        #expect(text[setup.upperBound..<model.lowerBound].contains("withSport"))
        #expect(text.components(separatedBy: "SportModel(").count == 2, "a second build")
    }
}
