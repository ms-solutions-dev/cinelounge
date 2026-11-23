import Core
import Foundation
import PlaylistKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The iPad's grid asks the replay over all feeds and redraws after
/// loading** (Live check, finding 8, 2026-09-27).
@MainActor
@Suite("Program grid: look-back and rebuild")
struct GridLookbackTests {

    struct ProbeSource: ChannelListingSource {
        let channels: [Channel]
        func channels() async -> ChannelCatalog { ChannelCatalog(channels: channels) }
        func program(forItem channels: [Channel]) async -> [String: [Programme]] { [:] }
        func freshProgramme() async -> Int { 0 }
        func downloadsState() async -> ProgrammeState { .empty }
        func sport(from: Date, until: Date) async -> [SportEvent] { [] }
    }

    static func channel(_ id: String, _ name: String, archive: Int?) -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://h/live/u/p/\(id).ts")!,
            playlistID: "l", group: "DE", epgID: "x-epg", archiveDays: archive)
    }

    static func model() async -> LiveModel {
        let model = LiveModel(
            source: ProbeSource(channels: [
                channel("1", "X FHD", archive: nil), channel("2", "X HD", archive: 3),
            ]))
        await model.load()
        return model
    }

    @Test("A past cell plays as a recording, even if only a secondary version has an archive")
    func secondaryVersionWithArchive() async throws {
        let model = await Self.model()
        let row = try #require(model.rows.first)
        #expect(row.feeds.count == 2)
        let now = Date()
        let chosen = model.catchUp(
            leader: row.leader, start: now.addingTimeInterval(-7200),
            end: now.addingTimeInterval(-3600), isGap: false, now: now)
        #expect(chosen?.id == "2")
    }

    @Test("A gap and a running cell play live")
    func gapAndNow() async throws {
        let model = await Self.model()
        let leader = try #require(model.rows.first?.leader)
        let now = Date()
        #expect(
            model.catchUp(
                leader: leader, start: now.addingTimeInterval(-7200),
                end: now.addingTimeInterval(-3600), isGap: true, now: now) == nil)
        #expect(
            model.catchUp(
                leader: leader, start: now.addingTimeInterval(600),
                end: now.addingTimeInterval(3600), isGap: false, now: now) == nil)
    }

    @Test("Loading and refreshing bump the grid revision, and the grid depends on it")
    func rebuild() async throws {
        let model = await Self.model()
        let afterLoading = model.gridRevision
        #expect(afterLoading > 0)
        await model.fresh()
        #expect(model.gridRevision > afterLoading)
        let text = SourceText.strippingCommentLines(
            try SourceText.read("Live/LiveView.swift", in: .featuresPhone))
        #expect(text.contains(".onChange(of: model.gridRevision) { _, _ in showGrid() }"))
        let tap = try #require(text.range(of: "private func playFromGrid("))
        #expect(text[tap.upperBound...].prefix(400).contains("model.catchUp("))
    }
}
