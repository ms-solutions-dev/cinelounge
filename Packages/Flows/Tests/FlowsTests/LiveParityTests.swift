import Core
import Foundation
import ParentalControls
import Testing

@testable import Flows

/// **Parity of Live, Sports, Search** (decision 27): the rules that TV and
/// phone have shared since 2026-09-26 — structure of the channel list (B9), catch-up (A2),
/// channels in the search (B4), "Continue Watching" with channels (C5), the entry into Live (C14)
/// and the schedule filters (B6).
@Suite("Parity Live")
struct LiveParityTests {

    private static func channels(
        _ id: String, _ name: String, group: String? = nil, favorite: Bool = false,
        adult: Bool = false, archive: Int? = nil
    ) -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://host/live/u/p/\(id).ts")!,
            playlistID: "list", group: group, isFavorite: favorite, isAdult: adult,
            archiveDays: archive)
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - B9 · Outline

    @Test("Recently watched, favorites, with and without programme — in this order")
    func outline() throws {
        let list = [
            Self.channels("a", "Avena"), Self.channels("b", "BX", favorite: true),
            Self.channels("c", "Comedy"), Self.channels("d", "DRAKO"),
        ]
        let segments = LiveOutline.outline(
            list, shelves: true, recent: ["DRAKO", "Gibt es nicht", "Avena"], name: \.name,
            istFavorit: \.isFavorite, program: { $0.id == "c" ? .none : .pending })
        try #require(segments.map(\.kind) == [.recent, .favorites, .withGuide, .withoutGuide])
        #expect(segments[0].entries.map(\.id) == ["d", "a"])
        #expect(segments[1].entries.map(\.id) == ["b"])
        #expect(segments[2].entries.map(\.id) == ["a", "b", "d"])
        #expect(segments[3].entries.map(\.id) == ["c"])
        #expect(LiveOutline.mainList(segments).map(\.id) == ["a", "b", "d", "c"])
    }

    @Test("Without shelves and without empty sections — over a group or a search")
    func outlineFiltered() {
        let list = [Self.channels("a", "Avena", favorite: true)]
        let segments = LiveOutline.outline(
            list, shelves: false, recent: ["Avena"], name: \.name, istFavorit: \.isFavorite,
            program: { _ in .available })
        #expect(segments.map(\.kind) == [.withGuide])
    }

    // MARK: - A2 · Look back

    @Test("A past broadcast in the archive plays as a recording")
    func catchUp() throws {
        let archive = Self.channels("7", "Das Nordlicht", archive: 3)
        let start = Self.now.addingTimeInterval(-7200)
        let end = Self.now.addingTimeInterval(-3600)
        let address = try #require(
            CatchUpSelection.recording(channels: archive, start: start, end: end, now: Self.now))
        #expect(address.path.hasPrefix("/timeshift/u/p/60/"))
        #expect(address.lastPathComponent == "7.m3u8")
    }

    @Test("Without archive, future, too old or gap: the channel itself")
    func noCatchUp() {
        let without = Self.channels("1", "Ohne")
        let archive = Self.channels("7", "Das Nordlicht", archive: 1)
        let yesterday = Self.now.addingTimeInterval(-3600)
        #expect(
            CatchUpSelection.recording(
                channels: without, start: yesterday, end: Self.now, now: Self.now) == nil)
        #expect(
            CatchUpSelection.recording(
                channels: archive, start: Self.now.addingTimeInterval(60),
                end: Self.now.addingTimeInterval(3600), now: Self.now) == nil)
        #expect(
            CatchUpSelection.recording(
                channels: archive, start: Self.now.addingTimeInterval(-2 * 86_400),
                end: Self.now.addingTimeInterval(-2 * 86_400 + 3600), now: Self.now) == nil)
        #expect(
            CatchUpSelection.recording(
                channels: archive, start: yesterday, end: Self.now, isGap: true,
                now: Self.now) == nil)
    }

    @Test("The first feed with archive yields the recording")
    func catchUpDelivery() {
        let sd = Self.channels("sd", "Das Nordlicht SD")
        let hd = Self.channels("hd", "Das Nordlicht HD", archive: 3)
        let broadcast = Programme(
            id: "s", channelID: "hd", title: "Tagesfunke",
            start: Self.now.addingTimeInterval(-3600), end: Self.now.addingTimeInterval(-1800))
        #expect(
            CatchUpSelection.recording(
                feeds: [sd, hd], start: broadcast.start, end: broadcast.end,
                now: Self.now)?.channels.id == "hd")
        #expect(CatchUpSelection.catchUpAvailable(feeds: [sd, hd], broadcast: broadcast, now: Self.now))
        #expect(!CatchUpSelection.catchUpAvailable(feeds: [sd], broadcast: broadcast, now: Self.now))
    }

    // MARK: - B4 · Channels in the search

    /// The channel block has already been applied by the catalog (`LiveLibrary`,
    /// `ChannelSourceFilterTests` in PlaylistKit).
    @Test("The search filters like the Live area")
    func channelSearchFilters() {
        var preferences = LivePreferences()
        preferences.setVisible(false, group: "WEG")
        let catalog = [
            Self.channels("a", "Sport 1", group: "DE"),
            Self.channels("b", "Sport 2", group: "WEG"),
            Self.channels("c", "Sport Adult", group: "DE", adult: true),
            Self.channels("d", "Sport Blue", group: "DE"),
        ]
        let result = ChannelSearch.search(
            "sport", in: catalog, preferences: preferences, atMost: 20)
        #expect(result.match.map { $0.map(\.id) } == [["a"], ["d"]])
        #expect(result.searched == 2)
    }

    @Test("Versions of a station appear once, and one character does not search")
    func channelSearchFolds() {
        let catalog = [
            Self.channels("1", "ZENIT 1 HD", group: "DE"), Self.channels("2", "ZENIT 1 SD", group: "DE"),
            Self.channels("3", "ZENIT 2", group: "DE"),
        ]
        let result = ChannelSearch.search(
            "zenit", in: catalog, preferences: LivePreferences(), atMost: 20)
        #expect(result.match.map { $0.map(\.id) } == [["1", "2"], ["3"]])
        #expect(
            ChannelSearch.search("z", in: catalog, preferences: LivePreferences(), atMost: 20)
                .match.isEmpty)
    }

    // MARK: - C5 · Continue Watching

    @Test("Only channels of the last six hours are in \"Continue Watching\"")
    func recentlyUsed() {
        let history = ChannelHistory(store: InMemoryStore(), profile: { "p" }, legacy: nil)
        history.memorize("Avena", um: Self.now.addingTimeInterval(-7 * 3600))
        history.memorize("ZINNE", um: Self.now.addingTimeInterval(-3600))
        #expect(history.names == ["ZINNE", "Avena"])
        #expect(history.recentlyUsed(now: Self.now) == ["ZINNE"])
    }

    @Test("A name list from before stays readable, but does not apply to \"Continue Watching\"")
    func oldList() {
        let store = InMemoryStore()
        RecordSheet.write(["Avena"], under: "live.recentChannels.p", in: store)
        let history = ChannelHistory(store: store, profile: { "p" }, legacy: nil)
        #expect(history.names == ["Avena"])
        #expect(history.recentlyUsed(now: Self.now).isEmpty)
        history.memorize("ZINNE", um: Self.now)
        #expect(history.names == ["ZINNE", "Avena"])
    }

    // MARK: - C14 · Entry

    @Test("The entry jumps only once, only without overview and only with a remembered channel")
    func entry() {
        #expect(
            LiveEntry.jumpsDirectly(
                failed: false, jumped: false, isPlaying: false, overview: false,
                remembered: true))
        #expect(
            !LiveEntry.jumpsDirectly(
                failed: false, jumped: false, isPlaying: false, overview: true,
                remembered: true))
        #expect(
            !LiveEntry.jumpsDirectly(
                failed: false, jumped: false, isPlaying: false, overview: false,
                remembered: false))
        #expect(
            !LiveEntry.jumpsDirectly(
                failed: false, jumped: true, isPlaying: false, overview: false,
                remembered: true))
        #expect(
            !LiveEntry.jumpsDirectly(
                failed: true, jumped: false, isPlaying: false, overview: false,
                remembered: true))
    }

    // MARK: - B6 · Filter

    @Test("\"Reminded\" takes match and club, \"Occupied\" only sealed rows")
    func rememberFilter() {
        func match(_ id: String, _ title: String, taken: Bool = false) -> SportEvent {
            SportEvent(
                id: id, kind: .football, competition: nil, title: title, start: Self.now,
                end: Self.now.addingTimeInterval(7200), epgIDs: [], isVerified: taken)
        }
        var watchlist = SportReminderList()
        watchlist.toggleMatch("a")
        watchlist.toggleTeam("Bergland")
        let a = match("a", "X - Y")
        let b = match("b", "Bergland - Z", taken: true)
        let c = match("c", "Q - R")
        #expect(
            [a, b, c].filter { SportsSchedule.matches($0, .bookmarked, watchlist: watchlist) }.map(\.id) == [
                "a", "b",
            ])
        #expect(
            [a, b, c].filter { SportsSchedule.matches($0, .taken, watchlist: watchlist) }.map(\.id) == ["b"])
        #expect([a, b, c].filter { SportsSchedule.matches($0, .all, watchlist: watchlist) }.count == 3)
    }
}
