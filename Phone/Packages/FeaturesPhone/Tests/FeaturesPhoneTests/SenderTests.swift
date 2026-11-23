import Core
import Foundation
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// The channel list: visible counts, three program states, and a name that keeps its tag.
@Suite("Channels")
struct ChannelTests {

    private static func channels(
        _ name: String, group: String? = "Deutschland", epg: String? = "epg",
        archive: Int? = nil
    ) -> Channel {
        Channel(
            id: name, name: name,
            streamURL: URL(string: "http://example.invalid/\(name)")!,
            playlistID: "probe", group: group, epgID: epg, archiveDays: archive)
    }

    private static func broadcast(
        _ title: String, from: Date, until: Date, channels: String = "epg"
    ) -> Programme {
        Programme(
            id: "\(channels)-\(title)", channelID: channels, title: title, start: from, end: until)
    }

    // MARK: - The number above the list counts the list

    /// **Finding M2 of 2026-09-05 as a check.** The draft showed two counters at 5.389 while the
    /// list below them was 2.055 entries long. Both numbers were correct on their own and
    /// meant different things — which is exactly why something like this goes unnoticed.
    @Test("The visible count is not the raw catalog")
    @MainActor
    func visibleCountIsNotRawCatalog() async {
        var preferences = LivePreferences()
        preferences.setVisible(false, group: "Türkei")
        let model = LiveModel(
            source: ProbeSource(
                channels: [
                    Self.channels("Das Nordlicht", group: "Deutschland"),
                    Self.channels("ZINNE", group: "Deutschland"),
                    Self.channels("TELVE 1", group: "Türkei"),
                ]), preferences: preferences)

        await model.load()

        #expect(model.rawCatalogCount == 3)
        #expect(model.visibleCount == 2)
        #expect(model.isSomethingHidden)
        #expect(!model.isEverythingHidden)
    }

    /// "You switched something off" is not "you set nothing up".
    @Test("Everything hidden is a case of its own")
    @MainActor
    func isEverythingHidden() async {
        var preferences = LivePreferences()
        preferences.setVisible(false, group: "Deutschland")
        let model = LiveModel(
            source: ProbeSource(channels: [Self.channels("Das Nordlicht")]), preferences: preferences)

        await model.load()

        #expect(model.isEverythingHidden)
        #expect(model.state == .empty)
    }

    @Test("Without channels the task is shown, not an empty list")
    @MainActor
    func withoutChannels() async {
        let model = LiveModel(source: ProbeSource(channels: []))
        await model.load()
        #expect(model.state == .disrupted(.emptyLiveWithoutList))
    }

    // MARK: - Three program situations

    /// **The core of the package.** 4.779 of 5.389 channels carry no program; "asked,
    /// there is none" must stay distinguishable from "not asked yet", otherwise every second
    /// channel shows either an empty row or an endless spinner.
    @Test("Asked and nothing found is not the same as not yet asked")
    @MainActor
    func threeSituations() async {
        let withGuide = Self.channels("Das Nordlicht", epg: "epg")
        let withoutGuide = Self.channels("TELVE 1", epg: nil)
        let now = Date()
        let model = LiveModel(
            source: ProbeSource(
                channels: [withGuide, withoutGuide],
                program: [
                    withGuide.id: [
                        Self.broadcast(
                            "Spätfunke", from: now.addingTimeInterval(-600),
                            until: now.addingTimeInterval(600))
                    ]
                ]))

        // Before loading, nothing has been asked.
        #expect(model.program(zu: withGuide) == .pending)

        await model.load()

        #expect(model.isRunning(to: withGuide, um: now)?.title == "Spätfunke")
        #expect(model.program(zu: withoutGuide) == .none)
    }

    // MARK: - Remaining time and progress

    /// **Rounded up, and that is the point.** Rounded down, the last minute would read
    /// "0 min left" — a number that looks as if the show were over.
    @Test("The last minute reads one minute, not zero")
    func remainingTimeRoundsUp() {
        let now = Date()
        let isRunning = Self.broadcast(
            "Krimireihe", from: now.addingTimeInterval(-3570), until: now.addingTimeInterval(20))
        #expect(LiveModel.remainingMinutes(isRunning, um: now) == 1)
    }

    @Test("After the end no remaining time is shown")
    func remainingTimeEnds() {
        let now = Date()
        let over = Self.broadcast(
            "Krimireihe", from: now.addingTimeInterval(-7200), until: now.addingTimeInterval(-1))
        #expect(LiveModel.remainingMinutes(over, um: now) == nil)
        #expect(LiveModel.progress(over, um: now) == nil)
    }

    @Test("Progress stays between zero and one")
    func progressStaysInRange() {
        let now = Date()
        let half = Self.broadcast(
            "Heute", from: now.addingTimeInterval(-900), until: now.addingTimeInterval(900))
        let portion = LiveModel.progress(half, um: now)
        #expect(portion != nil)
        #expect((portion ?? 0) > 0.45 && (portion ?? 0) < 0.55)
    }

    // MARK: - Special cases

    @Test("Archive and missing program do not exclude each other")
    func specialCasesSideBySide() {
        let channels = Self.channels("ZINNE", archive: 3)
        let cases = SpecialCase.forItem(channels, program: .none)
        #expect(cases.contains(.archive(days: 3)))
        #expect(cases.contains(.withoutGuide))
    }

    /// "Not asked yet" is a statement about us and not about the channel.
    @Test("Pending is no special case")
    func openIsNoSpecialCase() {
        #expect(SpecialCase.forItem(Self.channels("Das Nordlicht"), program: .pending).isEmpty)
    }

    // MARK: - The name keeps its tag

    /// **Separated and not deleted.** For a provider that lists the same channel four times,
    /// the tag is the only distinction.
    @Test("The quality tag moves to its place instead of disappearing")
    func markIsPreserved() {
        let name = ChannelDisplayName("Das Nordlicht HD")
        #expect(name.name == "Das Nordlicht")
        #expect(name.tag == "HD")
    }

    /// **Only at the end and only known words.** A pattern over the whole string would
    /// match `4K Entertainment`, and a channel name would turn into a tag without a channel.
    @Test("A tag word at the start is not a tag")
    func markOnlyAtEnd() {
        let name = ChannelDisplayName("4K Entertainment")
        #expect(name.name == "4K Entertainment")
        #expect(name.tag == nil)
    }

    @Test("A name that consists only of a tag stays")
    func markAloneStaysName() {
        let name = ChannelDisplayName("HD")
        #expect(name.name == "HD")
        #expect(name.tag == nil)
    }

    // MARK: - Groups

    /// The provider's order is information and not chance — same reasoning as for the catalogs.
    @Test("Groups carry their count and follow the provider order")
    @MainActor
    func groupsCountAndOrder() async {
        let model = LiveModel(
            source: ProbeSource(
                channels: [
                    Self.channels("Das Nordlicht", group: "Deutschland"),
                    Self.channels("TELVE 1", group: "Türkei"),
                    Self.channels("ZINNE", group: "Deutschland"),
                ]))
        await model.load()

        #expect(model.groups.map(\.name) == ["Deutschland", "Türkei"])
        #expect(model.groups.first?.count == 2)
    }

    @Test("A chosen group narrows the list, a second press lifts it")
    @MainActor
    func groupChoice() async {
        let model = LiveModel(
            source: ProbeSource(
                channels: [
                    Self.channels("Das Nordlicht", group: "Deutschland"),
                    Self.channels("TELVE 1", group: "Türkei"),
                ]))
        await model.load()

        model.select(group: "Türkei")
        #expect(model.rows.map(\.name) == ["TELVE 1"])

        model.select(group: "Türkei")
        #expect(model.rows.count == 2)
    }

    // MARK: - Search and favorites (AP58 R5, finding L1: the TV rules)

    /// **From two characters and across all groups** (``Flows/LiveCatalog/search(_:in:)``).
    /// Until 2026-09-26 the phone searched from one character and only in the selected
    /// group — anyone standing in "Türkei" and typing "Das" found nothing.
    @Test("Search starts at two characters and spans all groups; choosing a group ends the search")
    @MainActor
    func searchLikeOnTV() async {
        let model = LiveModel(
            source: ProbeSource(
                channels: [
                    Self.channels("Das Nordlicht", group: "Deutschland"),
                    Self.channels("TELVE 1", group: "Türkei"),
                ]))
        await model.load()
        model.select(group: "Türkei")

        model.searchTerm = "d"
        #expect(!model.isSearching)
        #expect(model.rows.map(\.name) == ["TELVE 1"], "one character does not search")

        model.searchTerm = "das"
        #expect(model.rows.map(\.name) == ["Das Nordlicht"], "search spans all groups")

        model.select(group: "Deutschland")
        #expect(model.searchTerm.isEmpty)
        #expect(model.rows.map(\.name) == ["Das Nordlicht"])
    }

    /// **The same favorite spelled differently moves along** — compared via the store's
    /// key, as on the TV. Before, the phone compared the raw name.
    @Test("A favorite also matches the other spelling of the same channel")
    @MainActor
    func favoriteFollowsSpelling() async {
        let catalog = [
            Self.channels("Das Nordlicht HD"), Self.channels("DAS NORDLICHT | HD"),
            Self.channels("Das Nordlicht UHD"),
        ]
        let model = LiveModel(source: ProbeSource(channels: catalog))
        await model.load()

        await model.setEnabled(favorite: catalog[0])

        #expect(model.allChannels.map(\.isFavorite) == [true, true, false])
    }

    // MARK: - Ask only what is missing or expired

    /// **The finding of 2026-09-06: every chip tap started twenty full requests.**
    ///
    /// The check goes through two ``LiveModel/load()`` calls instead of a chip tap, on
    /// purpose: ``LiveModel/select(group:)`` hands the reload to a `Task` whose end cannot
    /// be awaited from outside. The question is asked at the same place —
    /// ``LiveModel/fetchProgram()`` — and the three cases are the same.
    ///
    /// **And both halves of the condition are in here.** Without the expiry condition the
    /// expired channel would stay unasked, and after hours the app would write
    /// "nothing is on" over a row whose show is long since a different one.
    @Test("A second fetch gets only what is missing or expired")
    @MainActor
    func secondFetchDoesNotQueryEverythingAgain() async {
        let now = Date()
        let transcript = Transcript()
        let model = LiveModel(
            source: ProbeSource(
                channels: [
                    Self.channels("running", epg: "running"),
                    Self.channels("expired", epg: "expired"),
                    Self.channels("without", epg: nil),
                ],
                program: [
                    "running": [
                        Self.broadcast(
                            "Tagesfunke", from: now - 600, until: now + 600, channels: "running")
                    ],
                    "expired": [
                        Self.broadcast(
                            "Von gestern", from: now - 7200, until: now - 3600,
                            channels: "expired")
                    ],
                ],
                transcript: transcript))

        await model.load()
        await model.load()

        let queries = await transcript.queries
        #expect(queries.count == 2)
        #expect(queries.first?.sorted() == ["expired", "running", "without"])
        // The running one has a valid program, the channel without an entry has an
        // **empty** one — "asked, there is none" — and is not asked again.
        #expect(queries.last == ["expired"])
    }
}

/// What the source was really asked — one row per request.
private actor Transcript {
    private(set) var queries: [[String]] = []

    func note(_ identifiers: [String]) {
        queries.append(identifiers)
    }
}

/// A source that requests nothing.
///
/// **Counts how often the program was fetched.** That is exactly the point of this
/// area: one request per row would be a connection storm on an account with one allowed
/// connection — the check should notice if someone loosens the rule.
private struct ProbeSource: ChannelListingSource {
    let channels: [Channel]
    var program: [String: [Programme]] = [:]
    var events: [SportEvent] = []
    /// Wer sie mitgibt, bekommt jede Abfrage aufgeschrieben.
    var transcript: Transcript?

    func channels() async -> ChannelCatalog { ChannelCatalog(channels: channels) }

    func program(forItem channels: [Channel]) async -> [String: [Programme]] {
        await transcript?.note(channels.map(\.id))
        return program.filter { key, _ in channels.contains { $0.id == key } }
    }

    func freshProgramme() async -> Int { program.values.reduce(0) { $0 + $1.count } }

    func sport(from: Date, until: Date) async -> [SportEvent] { events }

    func downloadsState() async -> ProgrammeState {
        ProgrammeState(broadcasts: program.values.reduce(0) { $0 + $1.count }, recent: Date())
    }

    /// Switches as the store would.
    func setEnabled(favorite channels: Channel) async -> Bool { !channels.isFavorite }
}
