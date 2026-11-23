import Core
import Flows
import Foundation
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// The schedule: three sections, two filters, a star — and the difference between
/// "no sports today" and "nobody has looked".
@Suite("Schedule")
struct ScheduleBehaviorTests {

    private static func event(
        _ title: String, kind: SportKind = .football, start: Date, duration: TimeInterval = 7200,
        channels: [String] = ["epg1"], competition: String? = nil
    ) -> SportEvent {
        SportEvent(
            id: "\(kind.rawValue)-\(title)-\(start.timeIntervalSince1970)", kind: kind,
            competition: competition, title: title, start: start,
            end: start.addingTimeInterval(duration), epgIDs: channels)
    }

    private static func model(
        _ events: [SportEvent], watchlist: SportReminderListStore? = nil,
        names: @escaping @MainActor (String) -> String = { $0 }
    ) async -> SportModel {
        await MainActor.run {
            SportModel(
                source: ScheduleSource(events: events, broadcasts: 100),
                noteStore: watchlist ?? Self.noteStore(), names: names)
        }
    }

    /// The note pad **in working memory** — the default would read the file store and the
    /// Keychain of the machine, and taking it over would clean up there.
    private static func noteStore(
        _ store: any KeyValueStore = InMemoryStore()
    )
        -> SportReminderListStore
    {
        SportReminderListStore(store: store, profile: { nil }, keychain: nil, old: nil)
    }

    // MARK: - Die drei Abschnitte

    @Test("Now, soon and later are kept apart")
    @MainActor
    func threeSections() async {
        let now = Date()
        let model = await Self.model([
            Self.event("Running", start: now.addingTimeInterval(-1800)),
            Self.event("Soon", start: now.addingTimeInterval(1800)),
            Self.event("Later", start: now.addingTimeInterval(4 * 3600)),
        ])
        await model.load(um: now)

        let segments = model.segments(um: now)
        #expect(segments.map(\.kind) == [.runningNow, .equal, .later])
        #expect(segments.allSatisfy { $0.count == 1 })
    }

    /// A heading over nothing is not information but a construction site.
    @Test("An empty section does not appear at all")
    @MainActor
    func emptySectionsDropOut() async {
        let now = Date()
        let model = await Self.model([
            Self.event("Later", start: now.addingTimeInterval(5 * 3600))
        ])
        await model.load(um: now)
        #expect(model.segments(um: now).map(\.kind) == [.later])
    }

    /// The schedule is a question about this evening, not a chronicle.
    @Test("What is over appears in no section")
    @MainActor
    func pastDropsOut() async {
        let now = Date()
        let model = await Self.model([
            Self.event("Over", start: now.addingTimeInterval(-4 * 3600), duration: 3600)
        ])
        await model.load(um: now)
        #expect(model.segments(um: now).isEmpty)
    }

    // MARK: - Leer ist nicht gleich leer

    /// **The core of the package.** Without a fetched guide there can be no schedule;
    /// "no live broadcast today" would then be a claim about the day although
    /// nobody has looked.
    @Test("Without a programme store the request is shown, not the information")
    @MainActor
    func withoutDownloadsIsAJob() async {
        let model = SportModel(source: ScheduleSource(events: [], broadcasts: 0))
        await model.load()
        #expect(model.state == .withoutBacklog)
    }

    @Test("With a store and without sport the information about the day is shown")
    @MainActor
    func withDownloadsWithoutSports() async {
        let model = SportModel(source: ScheduleSource(events: [], broadcasts: 26433))
        await model.load()
        #expect(model.state == .empty)
    }

    // MARK: - Filter

    /// A chip with a number that has less behind it is false information.
    @Test("Each chip row counts across the respective other filter")
    @MainActor
    func chipsCountAcrossOtherFilter() async {
        let now = Date()
        let model = await Self.model(
            [
                Self.event("Football at A", kind: .football, start: now, channels: ["a"]),
                Self.event("Football at B", kind: .football, start: now, channels: ["b"]),
                Self.event("Tennis at A", kind: .tennis, start: now, channels: ["a"]),
            ])
        await model.load(um: now)

        #expect(model.sports.first { $0.kind == .football }?.count == 2)

        model.select(channels: "a")
        // On channel A one football match is on, not two.
        #expect(model.sports.first { $0.kind == .football }?.count == 1)
        #expect(model.filtered.count == 2)
    }

    @Test("A second press on the same chip lifts the filter")
    @MainActor
    func secondPressCancels() async {
        let now = Date()
        let model = await Self.model([Self.event("Game", start: now)])
        await model.load(um: now)

        model.select(sportKind: .football)
        #expect(model.sportKind == .football)
        model.select(sportKind: .football)
        #expect(model.sportKind == nil)
    }

    // MARK: - Der Merkzettel

    /// **Bookmarked items stand at the top of their section** — and not in a section of their own: A
    /// bookmarked match that is running would otherwise appear twice on the same screen.
    @Test("Bookmarked items sit at the top of their section")
    @MainActor
    func bookmarkedStaysOnTop() async {
        let now = Date()
        let early = Self.event("Early", start: now.addingTimeInterval(2 * 3600))
        let late = Self.event("Late", start: now.addingTimeInterval(4 * 3600))

        let model = await Self.model([early, late])
        await model.load(um: now)
        model.toggleMatch(late)

        let later = model.segments(um: now).first { $0.kind == .later }
        #expect(later?.events.map(\.title) == ["Late", "Early"])
    }

    /// A star that expires on exit promises something and does not keep it. It is read
    /// on load, not on construction (check Live, finding 4).
    @Test("The reminder list survives the programme run")
    @MainActor
    func watchlistStays() async {
        let now = Date()
        let match = Self.event("Derby", start: now.addingTimeInterval(3600))
        let store = InMemoryStore()
        let first = await Self.model([match], watchlist: Self.noteStore(store))
        first.toggleMatch(match)

        let second = await Self.model([match], watchlist: Self.noteStore(store))
        await second.load(um: now)
        #expect(second.isBookmarked(match))
    }

    /// **The most common state of this area must not delete the note pad** — an
    /// empty schedule cleans up nothing, a filled one removes what is no longer in it.
    @Test("Clean-up only runs against a populated schedule")
    @MainActor
    func cleanUp() async {
        let now = Date()
        let today = Self.event("Today", start: now.addingTimeInterval(3600))
        let store = Self.noteStore()
        var watchlist = SportReminderList()
        watchlist.toggleMatch("yesterday")
        watchlist.toggleMatch(today.id)
        store.write(watchlist)

        let empty = await Self.model([], watchlist: store)
        await empty.load(um: now)
        #expect(empty.watchlist.matches == ["yesterday", today.id])

        let full = await Self.model([today], watchlist: store)
        await full.load(um: now)
        #expect(full.watchlist.matches == [today.id])
    }

    /// **Following a club, as on the TV** (B5, 2026-09-26) — all its matches are
    /// thereby remembered, and the "Bookmarked" filter shows them; "Occupied" only what the
    /// online source occupies (B6).
    @Test("Follow club, Bookmarked and Occupied filter like on the TV")
    @MainActor
    func followingAndFiltering() async {
        let now = Date()
        var taken = Self.event("Kalesaray - Demirbahçe", start: now.addingTimeInterval(3600))
        taken.isVerified = true
        let secondOne = Self.event("Demirbahçe - Yeşiltaş", start: now.addingTimeInterval(7200))
        let other = Self.event("Bergland - Erzfeld", start: now.addingTimeInterval(7200))
        let model = await Self.model([taken, secondOne, other])
        await model.load(um: now)

        model.episode(club: "DEMIRBAHCE")
        #expect(model.isBookmarked(taken) && model.isBookmarked(secondOne))
        #expect(!model.isBookmarked(other))
        #expect(model.count(.bookmarked) == 2)
        #expect(model.count(.taken) == 1)

        model.select(rememberFilter: .bookmarked)
        #expect(Set(model.filtered.map(\.id)) == [taken.id, secondOne.id])
        model.select(rememberFilter: .taken)
        #expect(model.filtered.map(\.id) == [taken.id])
        model.select(rememberFilter: .taken)
        #expect(model.rememberFilter == .all)
        #expect(model.filtered.count == 3)
    }

    // MARK: - Fassungen

    /// Eleven "channels" are usually one channel in eleven versions — one row, not eleven.
    @Test("Further versions are counted, not listed")
    func otherVersions() {
        let now = Date()
        let multiple = Self.event(
            "Derby", start: now, channels: ["a", "b", "c", "d"])
        #expect(SportModel.otherVersions(multiple) == 3)
        #expect(SportModel.otherVersions(Self.event("Single", start: now)) == 0)
    }

    // MARK: - Das Fenster (AP58 R5, Befund L4: das des Fernsehers)

    /// **The phone reads what the TV reads** — ``Core/SportWindow`` via
    /// ``Flows/SportsSchedule``. Until 2026-09-26 it read from two hours back until five
    /// a.m.; without the two days of lookback the first broadcast was missing, by which the
    /// reruns are recognized.
    @Test("Reading happens in the TV's window, with two days of lookback")
    @MainActor
    func windowOfTheTV() async throws {
        let now = try #require(Self.time(tag: 6, hour: 12))
        let source = ScheduleSource(events: [], broadcasts: 100)
        let model = SportModel(source: source)
        await model.load(um: now)

        let span = SportsSchedule.window(now: now)
        let asked = await source.ledger.asked
        #expect(asked?.from == span.readAlongFrom)
        #expect(asked?.until == span.readUntil)
        #expect(span.readAlongFrom <= now.addingTimeInterval(-SportWindow.lookback))
    }

    /// **Twenty-four hours and not "until five a.m.".** At 12 noon the
    /// phone's old window ended after seventeen hours; an early match the next morning
    /// was missing although the TV showed it.
    @Test("A kick-off in twenty hours is in the plan, the lookback is not")
    @MainActor
    func twentyFourHours() async throws {
        let now = try #require(Self.time(tag: 6, hour: 12))
        let model = SportModel(
            source: ScheduleSource(
                events: [
                    Self.event("Early game", start: now.addingTimeInterval(20 * 3600)),
                    Self.event("Two days ago", start: now.addingTimeInterval(-40 * 3600)),
                    Self.event("Day after tomorrow", start: now.addingTimeInterval(30 * 3600)),
                ], broadcasts: 100))
        await model.load(um: now)
        #expect(model.filtered.map(\.title) == ["Early game"])
    }

    /// **It is re-read on the full hour** — the beat at which the reading window jumps.
    @Test("The read cadence is the full hour")
    func readInterval() throws {
        let half = try #require(Self.time(tag: 6, hour: 12)).addingTimeInterval(1800)
        #expect(SportsSchedule.readInterval(um: half) == Self.time(tag: 6, hour: 12))
    }

    // MARK: - Die Einstellung „Spielplan-Filter" (AP58, Befund L4)

    /// **The setting takes effect.** Until 2026-09-26 the settings wrote
    /// `live.hiddenSports`, and the schedule never read it. Checked via the same store
    /// that ``LiveSettingsModel`` writes to.
    ///
    /// **Since AP58 R5 it filters the list** as on the TV (decision 4 of the
    /// sports concept, 2026-09-02) — before, the sport was missing only in the chip bar.
    @Test("A disabled sport is missing from the chip bar and from the list")
    @MainActor
    func settingTakesEffect() async {
        let bucket = Self.freshStore()
        LiveSettingsModel(keychain: bucket).setEnabled(sport: .tennis)
        let now = Date()
        let model = SportModel(
            source: ScheduleSource(
                events: [
                    Self.event("Game", kind: .football, start: now.addingTimeInterval(600)),
                    Self.event("Match", kind: .tennis, start: now.addingTimeInterval(900)),
                ], broadcasts: 100),
            loadSelection: { SportFilterSettings.load(from: bucket) })
        model.select(sportKind: .tennis)
        await model.load(um: now)

        #expect(model.sports.map(\.kind) == [.football])
        #expect(model.sportKind == nil, "a disabled choice drops out")
        #expect(model.filtered.map(\.title) == ["Game"], "and the row too")
    }

    private static func time(tag: Int, hour: Int) -> Date? {
        Calendar.current.date(
            from: DateComponents(year: 2026, month: 9, day: tag, hour: hour))
    }

    /// Every check gets its own store — otherwise it sees the stars of the previous one.
    /// **Since AP40 a file store and not user defaults.** For the check
    /// a compartment in working memory is enough — it fulfils the same contract.
    private static func freshStore() -> any KeyValueStore {
        InMemoryStore()
    }
}

/// A source that yields a finished schedule — **and remembers what was asked
/// for.**
private struct ScheduleSource: ChannelListingSource {
    let events: [SportEvent]
    let broadcasts: Int
    let ledger = QueryLedger()

    actor QueryLedger {
        var asked: (from: Date, until: Date)?
        func note(_ from: Date, _ until: Date) { asked = (from, until) }
    }

    func channels() async -> ChannelCatalog { .empty }
    func program(forItem channels: [Channel]) async -> [String: [Programme]] { [:] }
    func freshProgramme() async -> Int { broadcasts }
    func sport(from: Date, until: Date) async -> [SportEvent] {
        await ledger.note(from, until)
        return events
    }
    func downloadsState() async -> ProgrammeState {
        ProgrammeState(broadcasts: broadcasts, recent: broadcasts > 0 ? Date() : nil)
    }
}
