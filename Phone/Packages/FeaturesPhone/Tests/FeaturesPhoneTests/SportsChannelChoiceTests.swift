import Core
import Foundation
import PlaylistKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **A match from the schedule plays only via a visible channel and goes into
/// "Recently watched"** (check Live, finding 6, 2026-09-27).
@MainActor
@Suite("Schedule: channel choice")
struct SportsChannelChoiceTests {

    struct ProbeSource: ChannelListingSource {
        let channels: [Channel]
        func channels() async -> ChannelCatalog { ChannelCatalog(channels: channels) }
        func program(forItem channels: [Channel]) async -> [String: [Programme]] { [:] }
        func freshProgramme() async -> Int { 0 }
        func downloadsState() async -> ProgrammeState { .empty }
        func sport(from: Date, until: Date) async -> [SportEvent] { [] }
    }

    static func channel(_ id: String, group: String, epg: String?) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "http://x/\(id)")!, playlistID: "l",
            group: group, epgID: epg)
    }

    static func game(_ identifiers: [String]) -> SportEvent {
        SportEvent(
            id: "s", kind: .football, competition: nil, title: "A - B",
            start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600),
            epgIDs: identifiers)
    }

    static func model() async -> LiveModel {
        var preferences = LivePreferences()
        preferences.setVisible(false, group: "AWAY")
        let fixed = preferences
        let model = LiveModel(
            source: ProbeSource(channels: [
                channel("hidden", group: "AWAY", epg: "only-away"),
                channel("ahorn", group: "DE", epg: "ahorn-epg"),
                channel("pass", group: "DE", epg: nil),
            ]), loadPreferences: { fixed })
        await model.load()
        return model
    }

    @Test("A game only on a hidden channel does not play")
    func hiddenDoesNotPlay() async {
        #expect(await Self.model().channels(forSport: Self.game(["only-away"])) == nil)
    }

    @Test("A visible channel is found via its programme or channel identifier")
    func visibleFound() async {
        let model = await Self.model()
        #expect(model.channels(forSport: Self.game(["only-away", "ahorn-epg"]))?.id == "ahorn")
        #expect(model.channels(forSport: Self.game(["pass"]))?.id == "pass")
    }

    @Test("The tap plays via the filtered choice and remembers the channel")
    func wired() throws {
        let text = SourceText.strippingCommentLines(
            try SourceText.read("Live/LiveView.swift", in: .featuresPhone))
        let location = try #require(text.range(of: "private func playSport("))
        let bodyContent = text[location.upperBound...].prefix(300)
        #expect(bodyContent.contains("model.channels(forSport:"))
        #expect(bodyContent.contains("playAndRemember("))
        #expect(!bodyContent.contains("allChannels"))
    }
}
