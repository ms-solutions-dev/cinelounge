import Core
import Flows
import Foundation
import ParentalControls
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// **Live parity on the phone** (decision 27): replay in the daily schedule (A2), the
/// jump to the last watched channel (C14), the iPad's grid (B10) and the
/// switches under Settings → Live (B6, C14).
@Suite("Live parity on the phone")
@MainActor
struct LiveParityPhoneTests {

    private static func channelFixture(
        _ id: String, _ name: String, archive: Int? = nil, epg: String? = nil
    )
        -> Channel
    {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://host/live/u/p/\(id).ts")!,
            playlistID: "l", group: "DE", epgID: epg, archiveDays: archive)
    }

    private static func broadcast(
        _ title: String, start: Date, minutes: Double, channel: String = "1"
    )
        -> Programme
    {
        Programme(
            id: title, channelID: channel, title: title, start: start,
            end: start.addingTimeInterval(minutes * 60))
    }

    // MARK: - A2 · Catch-up in the daily program

    @Test("Under “Now”, a channel with an archive also lists the catch-up programmes")
    func dayScheduleWithLookback() async {
        let now = Date()
        let earlier = Self.broadcast("Vorhin", start: now.addingTimeInterval(-7200), minutes: 60)
        let isRunning = Self.broadcast("Läuft", start: now.addingTimeInterval(-1800), minutes: 60)
        let later = Self.broadcast("Später", start: now.addingTimeInterval(1800), minutes: 60)
        func isVisible(_ archive: Int?) async -> [String] {
            let channel = Self.channelFixture("1", "Das Nordlicht", archive: archive, epg: "ahorn")
            let source = DaySource(channels: [channel], broadcasts: [earlier, isRunning, later])
            let model = ChannelDetailModel(
                bundles: ChannelBundle(name: "Das Nordlicht", feeds: [channel]), source: source)
            await model.load()
            return model.isVisible.map(\.title)
        }
        #expect(await isVisible(3) == ["Vorhin", "Läuft", "Später"])
        #expect(await isVisible(nil) == ["Läuft", "Später"])
    }

    @Test("A recording plays as a movie, not as a channel, and does not enter the history")
    func recordingAsMovie() async throws {
        let channel = Self.channelFixture("7", "Das Nordlicht", archive: 3)
        let source = ChannelPlayerSource(source: DaySource(channels: [channel], broadcasts: []))
        let start = Date().addingTimeInterval(-7200)
        let job = PlaybackJob(
            identifier: "7", origin: .channelList,
            catchUp: .init(start: start, end: start.addingTimeInterval(3600), title: "Krimireihe"))

        let target = try await source.target(zu: job)
        #expect(target.kind == .recording)
        #expect(target.address.path.hasPrefix("/timeshift/u/p/60/"))
        #expect(target.title == "Krimireihe")
        #expect(!target.belongsInHistory)

        let live = try await source.target(zu: PlaybackJob(identifier: "7", origin: .channelList))
        #expect(live.kind == .live)
    }

    /// **Without an archive no recording — and through the filter:** A channel that the filtered
    /// source does not carry is also not found as a recording.
    @Test("Without an archive or behind the filter there is no recording")
    func noRecording() async {
        let without = Self.channelFixture("1", "Ohne")
        let start = Date().addingTimeInterval(-7200)
        let request = PlaybackJob.CatchUpRequest(
            start: start, end: start.addingTimeInterval(3600), title: "X")
        let source = ChannelPlayerSource(source: DaySource(channels: [without], broadcasts: []))
        await #expect(throws: ChannelPlayerSource.Missing.recording) {
            try await source.target(
                zu: PlaybackJob(identifier: "1", origin: .channelList, catchUp: request))
        }
        let empty = ChannelPlayerSource(source: DaySource(channels: [], broadcasts: []))
        await #expect(throws: ChannelPlayerSource.Missing.channels) {
            try await empty.target(
                zu: PlaybackJob(identifier: "1", origin: .channelList, catchUp: request))
        }
    }

    // MARK: - C14 · Einstieg

    @Test("The last watched channel is the one that is still visible")
    func lastChannel() async {
        let history = ChannelHistory(store: InMemoryStore(), profile: { "p" }, legacy: nil)
        history.memorize("Gibt es nicht mehr")
        history.memorize("Avena")
        history.memorize("Weg")
        let model = LiveModel(
            source: DaySource(
                channels: [Self.channelFixture("1", "Das Nordlicht"), Self.channelFixture("2", "Avena")],
                broadcasts: []),
            history: history)
        await model.load()
        #expect(model.lastChannel?.id == "2")
    }

    @Test("The switches under Settings → Live write the TV's keys")
    func toggle() {
        let bucket = InMemoryStore()
        let model = LiveSettingsModel(keychain: bucket, tabStore: InMemoryStore())
        #expect(!model.showsOverview, "out of the box, Live jumps ahead, as on the TV")
        model.set(overview: true)
        #expect(LivePreferences.load(from: bucket).showsBrowseArea)
        #expect(model.sync.isEnabled)
        model.set(sync: false)
        #expect(!SportSyncSettings.load(from: bucket).isEnabled)
    }

    // MARK: - B10 · Raster auf dem iPad

    @Test("The grid asks per programme ID, and the child's filter applies too")
    func gridProgramme() async {
        let now = Date()
        let children = Channel(
            id: "k", name: "KiMO", streamURL: URL(string: "http://x/k")!, playlistID: "l",
            group: "DE| Kinder", epgID: "kimo")
        let news = Channel(
            id: "n", name: "News", streamURL: URL(string: "http://x/n")!, playlistID: "l",
            group: "DE| News", epgID: "news")
        let source = DaySource(
            channels: [children, news],
            broadcasts: [
                Self.broadcast("Maus", start: now, minutes: 30, channel: "k"),
                Self.broadcast("Tagesfunke", start: now, minutes: 15, channel: "n"),
            ])
        let pending = await source.gridProgramme(
            forItem: [children, news], from: now, until: now.addingTimeInterval(7200))
        #expect(Set(pending.keys) == ["kimo", "news"])

        let filtered = KidsChannelSource(
            source: source,
            approval: ChannelApproval(groups: [ChannelApproval.Group(list: "l", name: "DE| Kinder")]))
        let forChild = await filtered.gridProgramme(
            forItem: [children, news], from: now, until: now.addingTimeInterval(7200))
        #expect(Set(forChild.keys) == ["kimo"])
    }
}

/// A source with a fixed daily schedule — the programs sit under the ID they
/// carry themselves.
private struct DaySource: ChannelListingSource {
    let channels: [Channel]
    let broadcasts: [Programme]

    func channels() async -> ChannelCatalog { ChannelCatalog(channels: channels) }

    func program(forItem channels: [Channel]) async -> [String: [Programme]] {
        Dictionary(grouping: broadcasts, by: \.channelID)
            .filter { key, _ in channels.contains { $0.id == key } }
    }

    func freshProgramme() async -> Int { broadcasts.count }
    func sport(from: Date, until: Date) async -> [SportEvent] { [] }
    func downloadsState() async -> ProgrammeState {
        ProgrammeState(broadcasts: broadcasts.count, recent: Date())
    }
}
