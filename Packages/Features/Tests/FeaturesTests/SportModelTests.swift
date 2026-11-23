import Core
import Foundation
import PlaylistKit
import Testing

@testable import Features

/// The window cut of the schedule — on the real model, with an injected clock.
///
/// **Why this suite exists only since E3.** For ``SportModel`` and
/// ``SportView`` there was not a single test in the whole project, and exactly there
/// lives the viewer finding of 2026-08-29: cutting happened in the
/// view layer, with its own `Date()`, and what came out of it was
/// visible only on the TV. The probe in `PlaylistKit` measures the filters;
/// here what the **model** makes of them for its window is measured.
///
/// **Not simulated but calculated through:** The model gets a
/// real ``LiveLibrary`` over a database of its own in transient storage and reads
/// stored broadcasts through the real stretch — downloads, ``SportPlan``,
/// day window. A replicated library would test only the replica.
///
/// The clock is fixed to Saturday, 2026-08-29, 15:00 in Berlin — the same
/// point in time that the schedule probe calculates with.
@MainActor
@Suite("The window in the schedule model")
struct SportModelTests {

    /// The bookmark list **in memory** — the default would read the file store and the
    /// Keychain of the machine, and its takeover would clean up there.
    static func noteStore() -> SportReminderListStore {
        SportReminderListStore(store: InMemoryStore(), profile: { nil }, keychain: nil, old: nil)
    }

    // MARK: - The fixed clock

    static let timeZone = TimeZone(identifier: "Europe/Berlin")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func moment(_ tag: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: timeZone, year: 2026, month: 8, day: tag, hour: hour, minute: minute))!
    }

    static let now = moment(29, 15)

    // MARK: - The setup

    /// A database of its own per test — transient and with its own
    /// identifier. Without that all tests would share the app's downloads.
    static func downloads() -> LiveCache {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinelounge-spielplan-\(UUID().uuidString)")
        return LiveCache(directory: folder)
    }

    static func broadcast(
        _ title: String, from: Date, until: Date, channels: String = "sportwelt.de"
    ) -> Programme {
        Programme(
            id: "\(channels)#\(Int(from.timeIntervalSince1970))", channelID: channels, title: title,
            start: from, end: until)
    }

    /// A broadcast day as the recording shows it: a running game, a
    /// later one the same evening, a tomorrow early game and a tomorrow
    /// evening game, one from yesterday, and a tournament that reaches over midnight
    /// into today.
    ///
    /// **The two tomorrow ones are the test subject of the window** (2026-09-02):
    /// With the clock fixed at 15:00 the early game is in and the
    /// evening game is not — with day tabs both stood on the same tab
    /// and neither in the list.
    static func broadcastDay() -> [Programme] {
        [
            broadcast(
                "Fussball: Bergland Muenchen - Erzfeld", from: moment(29, 14, 30), until: moment(29, 16, 30)),
            broadcast("Fussball: Fenwold - Brookmere", from: moment(29, 18, 30), until: moment(29, 20, 30)),
            broadcast(
                "Fussball: Grachtwijk - Maasoever", from: moment(30, 12, 30), until: moment(30, 14, 30)),
            broadcast("Fussball: Aurelia - Tiberina", from: moment(30, 17, 30), until: moment(30, 19, 30)),
            broadcast(
                "Fussball: Grachtwijk - Lichtstad", from: moment(28, 20, 30), until: moment(28, 22, 30)),
            broadcast("Tennis: Lindmar Open", from: moment(28, 22), until: moment(29, 16)),
        ]
    }

    /// A clock that can be advanced.
    ///
    /// The fixed clock does not show the one case that
    /// ``zeitbezugBleibtBeimGeladenenTag()`` is about: the area stays open
    /// while midnight passes. Locked, because the closure
    /// is `@Sendable`.
    final class SettableClock: @unchecked Sendable {
        private var state: Date
        private let lock = NSLock()

        init(_ state: Date) { self.state = state }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return state
        }

        func location(to fresh: Date) {
            lock.lock()
            defer { lock.unlock() }
            state = fresh
        }
    }

    static func model(_ broadcasts: [Programme], clock: SettableClock? = nil) async -> SportModel {
        let downloads = downloads()
        await downloads.save(programmes: broadcasts)
        let library = LiveLibrary(
            store: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            cache: downloads)
        // The fixed clock is lifted into the closure as a value, not as
        // access to the test class — otherwise the clock would hang on the main actor.
        let state = now
        let spec = clock
        return SportModel(
            library: library, store: InMemoryStore(), noteStore: Self.noteStore(),
            calendar: calendar, clock: { spec?.now ?? state })
    }

    private func title(_ model: SportModel) -> Set<String> {
        Set(model.events.map(\.title))
    }

    // MARK: - The window

    /// The list carries what is running and what kicks off in the next 24 hours
    /// — across midnight and without tabs in between.
    @Test("The window shows what is running and upcoming, not yesterday's")
    func window() async {
        let model = await Self.model(Self.broadcastDay())

        await model.load()

        #expect(model.state == .ready)
        #expect(
            title(model) == [
                "Bergland Muenchen - Erzfeld", "Fenwold - Brookmere", "Lindmar Open",
                "Grachtwijk - Maasoever",
            ])
    }

    /// **The gain over the day tabs** (user decision 2026-09-02).
    /// Tomorrow's early game at 12:30 is closer at 15:00 than any second row
    /// of tonight; it still stood on another tab. Tomorrow's
    /// evening game at 17:30 lies beyond the 24 hours and stays
    /// out — otherwise the window would be a multi-day view again.
    @Test("Tomorrow's early match is in the same list, the evening match is not")
    func tomorrowInTheWindow() async {
        let model = await Self.model(Self.broadcastDay())

        await model.load()

        #expect(title(model).contains("Grachtwijk - Maasoever"))
        #expect(!title(model).contains("Aurelia - Tiberina"))
    }

    /// The look-back of two days is reading material for the first-wins rule,
    /// not a display. Yesterday evening's game is over and stays gone.
    @Test("The look-back is read and not shown")
    func lookbackStaysOut() async {
        let model = await Self.model(Self.broadcastDay())

        await model.load()

        #expect(!title(model).contains("Grachtwijk - Lichtstad"))
    }

    // MARK: - The time reference of the row

    /// **The date belongs in the row.** The tournament began yesterday at 22:00
    /// and is still running; without this hint the row claims, with "22:00",
    /// a kickoff on the day shown.
    @Test("What has run since yesterday carries its yesterday in the row")
    func timeRelation() async {
        let model = await Self.model(Self.broadcastDay())

        await model.load()

        let tournament = model.events.first { $0.title == "Lindmar Open" }
        let today = model.events.first { $0.title == "Fenwold - Brookmere" }

        #expect(tournament.map { model.timeRelation(of: $0) } == .yesterday)
        #expect(today.map { model.timeRelation(of: $0) } == .today)
        // And the early game carries its "Tomorrow" — the new row that, with the
        // day cut, would never have made it this far.
        let early = model.events.first { $0.title == "Grachtwijk - Maasoever" }
        #expect(early.map { model.timeRelation(of: $0) } == .tomorrow)
    }

    /// **The time reference belongs to the read state, not to the running clock**
    /// (acceptance 2026-08-29).
    ///
    /// The window first stood as a computed property in the model and took
    /// the clock on every access. As long as nobody reloads, however, the list
    /// is the one from before — if midnight passes in the meantime, the
    /// view judges against a state that the rows never saw: the
    /// evening game of 18:30 stood in the list and suddenly carried
    /// "yesterday" next to it. With the state stored at read time it stays
    /// `.today` until it is really read again.
    @Test("The time reference computes against the snapshot that let the row in")
    func timeReferenceStaysWithLoadedState() async {
        let clock = SettableClock(Self.now)
        let model = await Self.model(Self.broadcastDay(), clock: clock)

        await model.load()
        let today = model.events.first { $0.title == "Fenwold - Brookmere" }
        #expect(today.map { model.timeRelation(of: $0) } == .today)

        // Midnight passes without anyone reloading the area.
        clock.location(to: Self.moment(30, 0, 30))

        #expect(today.map { model.timeRelation(of: $0) } == .today)
    }

    // MARK: - The states

    /// An empty downloads store blames the downloads and not the filter.
    @Test("Without a store the hint about the programme guide is shown")
    func withoutBacklog() async {
        let model = await Self.model([])

        await model.load()

        #expect(model.state == .noGuide)
    }

    // MARK: - What E5 changed about the view

    /// **The filter recalculates the list without loading again.**
    ///
    /// ``SportModel/shown`` was a computed property and has been
    /// stored since E5 — so that the view does not recalculate it twice on every focus step.
    /// The price of a stored value is that someone has to
    /// update it; exactly that this row tests. Without the updater on the
    /// filter the old list would stand here, and the chip would do nothing.
    @Test("Pressing a chip sorts the list without reloading")
    func filterUpdatesTheList() async {
        let model = await Self.model(Self.broadcastDay())
        await model.load()
        #expect(model.shown.count == 4)

        model.filter = .kind(.tennis)
        #expect(model.shown.map(\.title) == ["Lindmar Open"])

        model.filter = .all
        #expect(model.shown.count == 4)
    }

    /// And the bookmark list likewise: bookmarked items stand on top, immediately.
    @Test("The reminder list reorders the list immediately")
    func watchlistUpdatesTheList() async {
        let model = await Self.model(Self.broadcastDay())
        await model.load()
        // Without a bookmark list, what has the earliest kickoff stands on top — the
        // tournament that has been running since yesterday evening.
        #expect(model.shown.first?.title == "Lindmar Open")

        model.toggleTeam("Brookmere")
        #expect(model.shown.first?.title.contains("Brookmere") == true)

        model.toggleTeam("Brookmere")
        #expect(model.shown.first?.title == "Lindmar Open")
    }

    /// **Bookmarking a single game, as on the phone** (B5, 2026-09-26): it moves to
    /// the top, and the filter "Bookmarked" shows exactly that one — not the other games of the
    /// club.
    @Test("A bookmarked match is on top and alone under “Bookmarked”")
    func bookmarkGame() async throws {
        let model = await Self.model(Self.broadcastDay())
        await model.load()
        let brookmere = try #require(model.shown.first { $0.title.contains("Brookmere") })

        model.toggleMatch(brookmere)
        #expect(model.shown.first?.id == brookmere.id)
        model.filter = .marked
        #expect(model.shown.map(\.id) == [brookmere.id])

        model.toggleMatch(brookmere)
        #expect(model.shown.isEmpty)
    }

    /// The chip row asks the Keychain once per load since E5
    /// instead of once per focus step. That it still asks at all stands
    /// here: a disabled sport must not get a chip.
    @Test("A disabled sport is not in the chip row")
    func disabledSportHasNoChip() async {
        let store = InMemoryStore()
        var choice = SportFilterSettings()
        choice.toggle(.tennis)
        choice.save(to: store)

        let downloads = Self.downloads()
        await downloads.save(programmes: Self.broadcastDay())
        let library = LiveLibrary(
            store: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            cache: downloads)
        let state = Self.now
        let model = SportModel(
            library: library, store: store, noteStore: Self.noteStore(),
            calendar: Self.calendar, clock: { state })

        await model.load()

        #expect(model.availableKinds.contains(.football))
        #expect(!model.availableKinds.contains(.tennis))
        // The row itself stays in the list — the chip is switched off,
        // not the event.
        #expect(model.events.contains { $0.kind == .tennis })
    }

    /// **A second load cancels the first** (E5, adapted 2026-09-02).
    ///
    /// The cancellation stems from the day switch: two simultaneous processes
    /// knew nothing of each other, and the slower one could overwrite the faster.
    /// The tabs are gone, the case is not — the
    /// refresh button and entering the area trigger the same
    /// `load()`. What is tested is that two attempts yield one list and
    /// not two.
    @Test("Two loads in a row leave one list")
    func secondLoad() async {
        let model = await Self.model(Self.broadcastDay())

        async let first: Void = model.load()
        async let second: Void = model.load()
        _ = await (first, second)

        #expect(model.state == .ready)
        #expect(model.shown.count == 4)
        #expect(Set(model.shown.map(\.id)).count == model.shown.count)
    }
    // MARK: - The channels of a row

    static func channels(_ id: String, _ name: String, epg: String) -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: "http://x/\(id)")!, playlistID: "gold",
            epgID: epg)
    }

    static func event(_ id: String, identifiers: [String]) -> SportEvent {
        SportEvent(
            id: id, kind: .football, competition: nil, title: id,
            start: moment(29, 18), end: moment(29, 20), epgIDs: identifiers)
    }

    /// **The finding of 2026-08-29** ("for Varlo–Pendrick 10 channels
    /// are shown"). Four entries of the same station under the same
    /// program identifier become one entry — the bundling itself is tested by
    /// ``ChannelVersionsTests``, here the mapping is tested.
    @Test("Four feeds of a station are one channel of the row")
    func oneChannelInsteadOfFour() {
        let bundles = SportModel.groupByEvent(
            [Self.event("spiel", identifiers: ["ArenaSpor1.tr"])],
            channels: [
                "ArenaSpor1.tr": [
                    Self.channels("1", "KIES: ARENA SPOR 1 RAW", epg: "ArenaSpor1.tr"),
                    Self.channels("2", "KIES: ARENA SPOR 1 RAW", epg: "ArenaSpor1.tr"),
                    Self.channels("3", "KIES: ARENA SPOR 1 ᵁᴴᴰ 3840P", epg: "ArenaSpor1.tr"),
                    Self.channels("4", "KIES: ARENA SPOR 1 MOBIL", epg: "ArenaSpor1.tr"),
                ]
            ])

        #expect(bundles["spiel"]?.count == 1)
        #expect(bundles["spiel"]?.first?.count == 4)
        // And the best version starts playing, not the first in the list — the
        // MOBIL version was previously preselected if it happened to be at the top.
        #expect(bundles["spiel"]?.first?.best.id == "3")
    }

    /// **The trap of the mapping, and that is why it stands in a calculation of
    /// its own.** An event carries several program identifiers. If bundled per
    /// identifier, a station would stand twice in the row as soon as the
    /// provider lists it under two identifiers.
    @Test("Two identifiers with two stations yield two channels")
    func twoIdentifiersTwoChannels() {
        let bundles = SportModel.groupByEvent(
            [Self.event("spiel", identifiers: ["a.tr", "b.tr"])],
            channels: [
                "a.tr": [Self.channels("1", "A RAW", epg: "a.tr")],
                "b.tr": [Self.channels("2", "B RAW", epg: "b.tr")],
            ])

        #expect(bundles["spiel"]?.map(\.name) == ["A", "B"])
    }

    // MARK: - The schedule filter from the settings

    /// **It filters the list, not only the chip row** (open decision 4
    /// of the concept, decided 2026-09-02). Whoever disabled tennis so far got
    /// no tennis chip — and still all tennis rows. A filter that
    /// leaves the filtering to the view would more honestly be called "which chips".
    @Test("A disabled sport is not in the list")
    func disabledSportIsMissingFromList() async {
        let store = InMemoryStore()
        var choice = SportFilterSettings()
        choice.toggle(.tennis)
        choice.save(to: store)

        let downloads = Self.downloads()
        await downloads.save(programmes: Self.broadcastDay())
        let library = LiveLibrary(
            store: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            cache: downloads)
        let state = Self.now
        let model = SportModel(
            library: library, store: store, noteStore: Self.noteStore(),
            calendar: Self.calendar, clock: { state })

        await model.load()

        #expect(!model.shown.contains { $0.kind == .tennis })
        #expect(model.shown.contains { $0.kind == .football })
        // The downloads themselves stay untouched — disabled is the
        // display, not the detection.
        #expect(model.events.contains { $0.kind == .tennis })
    }
}
