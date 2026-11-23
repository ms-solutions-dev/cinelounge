import Core
import Flows
import Foundation
import PlaylistKit
import SwiftUI

/// The schedule: the live sports broadcasts of the next few days.
///
/// Everything comes from the programme prefetch (``LiveLibrary/sportEvents(from:to:)``)
/// — the section opens from the database, without a network and without a second
/// connection to the provider. If the prefetch is empty, the state says so honestly:
/// the programme guide depends on the sync, not on this section.
public final class SportModel: ObservableObject {

    public enum State: Equatable {
        case loading
        /// The programme prefetch is empty — fetch the guide first.
        case noGuide
        /// The prefetch carries broadcasts, but none in the window.
        ///
        /// **The case that used to look like "no prefetch".** The provider EPG reaches, as
        /// measured, only about +24 h; once it is a few days old, the section has a full
        /// prefetch and still nothing in the window.
        case noWindow
        /// Broadcasts in the window, but none of them is live sport.
        ///
        /// This is the information that blames the filter instead of the prefetch — and until
        /// 2026-08-29 it could not be told apart from the other two.
        case noSport
        case ready
    }

    /// What the prefetch says about itself — for the status line in the header.
    @Published public private(set) var fetchStatus: LiveLibrary.DownloadsState?
    /// Is a sync running that the viewer triggered?
    @Published public private(set) var isFetching = false

    /// What the filter bar is currently showing.
    public enum Filter: Equatable {
        case all
        /// Only bookmarked items — individual matches and everything from clubs and
        /// competitions that one follows (``Flows/SportsSchedule/BookmarkFilter/bookmarked``).
        case marked
        /// Only events whose kickoff the online source confirms — the watertight live view
        /// (requirement 2026-08-16: Sport should show live broadcasts).
        case verified
        case kind(SportKind)
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var events: [SportEvent] = []
    /// The channels per programme identifier — for channel bars and the jump-off.
    @Published public private(set) var channelsByEPG: [String: [Channel]] = [:]
    /// The **bundled** channels per event — one station, not its feeds
    /// (``ChannelVariants``).
    ///
    /// **Calculated on reading and not on drawing** (lesson from E5): The view asks for
    /// them in every row and on every focus step; bundling at this point would therefore
    /// run a hundred times per key press.
    @Published public private(set) var channelsByEvent: [String: [ChannelVariants.VariantGroup]] = [:]
    @Published public var filter: Filter = .all {
        didSet { if filter != oldValue { updateView() } }
    }
    /// The watch list — **the same as on the phone** (decision 27, B5): follow clubs and
    /// competitions **and** bookmark individual matches, per profile.
    @Published public private(set) var memory: SportReminderList

    /// The events after filtering — bookmarked items at the top, then by kickoff.
    ///
    /// **Stored instead of calculated on every read** (E5, 2026-08-29). This used to be a
    /// computed property, and the view reads it in two places: in the empty case
    /// (`shown.isEmpty`) and in the list itself. SwiftUI redraws the section on **every**
    /// focus step — so on every key press a filter pass with a subsequent sort over all
    /// rows ran twice, and ``availableKinds`` next to it went to the Keychain each time.
    /// Now it is calculated exactly when something changes that determines the result: the
    /// events, the filter, the watch list.
    @Published public private(set) var shown: [SportEvent] = []

    /// The sports that exist on this day — only those appear as filters, and only those
    /// that the viewer has not switched off (Settings → Live → Schedule filter).
    @Published public private(set) var availableKinds: [SportKind] = []

    /// The filter choice from the Keychain — **once per load**.
    ///
    /// It used to live in ``availableKinds`` and was therefore reread on every focus step.
    /// The section is loaded on entering (the view's `.task`), and one gets back from the
    /// settings only by entering again — a change there therefore takes effect just as
    /// immediately as before.
    private var filterSelection = SportFilterSettings()

    private let library: LiveLibrary
    private let store: KeyValueStore
    private let noteStore: SportReminderListStore
    private let calendar: Calendar
    /// The clock — injected, not taken.
    ///
    /// **The reason is a gap, not a preference** (E3, 2026-08-29): The model read the time at
    /// three places directly from `Date()`, and with that the day cut — the calculation in
    /// which the finding "only one entry for today" lives — could not be recalculated. A
    /// test would have measured something different at midnight than at noon. With the
    /// injected clock every number in ``SportModelTests`` is fixed, and on the TV nothing
    /// changes: the default value is `Date()`.
    private let clock: @Sendable () -> Date

    /// - Parameter zettelablage: where the watch list lives — in the app the Keychain per
    ///   profile (``Core/SportReminderListStore/tv(profile:)``: the file store falls
    ///   back to `Caches` on the TV), in the tests one in working memory.
    public init(
        library: LiveLibrary,
        store: KeyValueStore = SecureStore(),
        noteStore: SportReminderListStore = .tv(),
        calendar: Calendar = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.store = store
        self.noteStore = noteStore
        self.calendar = calendar
        self.clock = clock
        readAt = clock()
        span = SportsSchedule.window(now: readAt)
        memory = noteStore.read()
        filterSelection = SportFilterSettings.load(from: store)
    }

    /// The section's window — the one place where "now" becomes a time span.
    ///
    /// **Stored, not recalculated each time** (acceptance 2026-08-29): It first stood here as a
    /// computed property with `clock()` in it, and with that the view calculated against a
    /// different window than the cut that let the row in.
    private(set) var span: SportWindow.Span

    /// The clock reading with which it was last read.
    ///
    /// **The time reference calculates against it and not against the running clock.**
    /// The difference becomes visible as soon as the section stays open while midnight
    /// passes: The list is still the one from before, a freshly read clock would already
    /// be from today — and then a row at 18:30 would suddenly carry a "yesterday" that the
    /// list refutes. Measured in ``SportModelTests`` ("The time reference calculates
    /// against the reading that let the row in").
    private(set) var readAt: Date

    /// Fetches the guide, on demand.
    ///
    /// **The second trigger at all.** Until 2026-08-29. `syncGuide()` had exactly one in the
    /// whole project: the refresh button of a single channel list under Settings. Anyone
    /// who found the schedule empty had no way to fill it — except through a place that
    /// nobody would suspect from here.
    public func fetch() async {
        guard !isFetching else { return }
        isFetching = true
        let count = await library.syncGuide()
        Diagnostics.probe("Schedule: guide fetched on demand — \(count) broadcasts stored")
        isFetching = false
        await load()
    }

    public func load() async {
        loadOperation?.cancel()
        let operation = Task { [weak self] in
            await self?.read()
            return ()
        }
        loadOperation = operation
        await operation.value
    }

    /// The running load — cancellable when a second one is triggered.
    private var loadOperation: Task<Void, Never>?

    private func read() async {
        state = events.isEmpty ? .loading : state
        filterSelection = SportFilterSettings.load(from: store)
        memory = noteStore.read()
        let now = clock()
        // The window comes from ``SportWindow`` — the same calculation that the probe
        // measures and ``SportModelTests`` recalculates. The two-day lookback is built in:
        // the first broadcast has to be read along, so that it swallows its repeats.
        let window = SportsSchedule.window(now: now)

        // **Five numbers instead of two, and always.**
        //
        // The previous line hung behind ``Diagnostics/verbose`` — that is, behind the debug
        // switch — and derived its verdict "prefetch empty or carrying" from the number of
        // *results*. That made an empty prefetch indistinguishable from a filter that eats
        // everything. Exactly this confusion already sent a troubleshooting session in the
        // wrong direction once on 2026-08-16. ("61,026 in the prefetch").
        //
        // Now the line asks the prefetch itself and states: what it holds in total, how much
        // of that lies in the window, how many sports events resulted, how many of those are
        // still upcoming — and when the guide was last fetched. That way it separates, in one
        // line, the three cases that used to look alike.
        let downloads = await library.downloadsState(from: window.readAlongFrom, to: window.readUntil)
        // From here on every result belongs to the window that applied when it was triggered.
        // If the operation is cancelled, a different one has long been on screen.
        if Task.isCancelled { return }
        fetchStatus = downloads

        // From here the window is fixed — and with it the clock reading against which the
        // time column later calculates its time reference.
        span = window
        readAt = now

        let found = await library.sportEvents(from: window.readAlongFrom, to: window.readUntil)
        if Task.isCancelled { return }

        // Past items and the lookback drop out; what is running right now stays in by itself.
        // The rule is stated at ``SportWindow/list(_:span:now:)``.
        let upcoming = SportsSchedule.inWindow(found, span: window, now: now)

        var channels: [String: [Channel]] = [:]
        let ids = Array(Set(upcoming.flatMap(\.epgIDs)))
        let foundChannels = await library.channels(withEPGIDs: ids)
        if Task.isCancelled { return }
        for channel in foundChannels {
            // League Pass channels have no programme identifier — their event carries the channel
            // identifier, so it is filed under that.
            if let epg = channel.epgID, !epg.isEmpty {
                channels[epg, default: []].append(channel)
            } else {
                channels[channel.id, default: []].append(channel)
            }
        }

        // Bookmarked matches that are no longer in the window drop off the list — otherwise it
        // grows forever (``Core/SportReminderList/cleanUp(to:)``).
        var watchlist = memory
        if watchlist.cleanUp(to: Set(upcoming.map(\.id))) {
            noteStore.write(watchlist)
            memory = watchlist
        }
        events = upcoming
        channelsByEPG = channels
        channelsByEvent = Self.groupByEvent(upcoming, channels: channels)
        updateView()

        state = Self.state(downloads: downloads, sportsEvents: found.count, inWindow: upcoming.count)

        // **The sealed rows are included** (on-device finding 2026-08-29: no content at all in the
        // "confirmed" filter). Without this number it could not be decided from the submitted
        // diagnostics whether the filter ran empty or the viewer had not chosen it at all —
        // the filter choice itself appears nowhere in the trace. It is cheap: a count over a
        // list that has just been built anyway.
        let verifiedCount = upcoming.count(where: \.isVerified)
        let row =
            "Schedule 24 h: downloads \(downloads.broadcasts) broadcasts, "
            + "\(downloads.inWindow) in window, \(found.count) sports events, "
            + "\(upcoming.count) upcoming in window, of which \(verifiedCount) verified · "
            + "span \(Self.stockSpan(downloads)) · "
            + "guide \(Self.alter(downloads.lastFetched, now: now))"
        if upcoming.isEmpty {
            // **As a defect, not as a note.** An empty schedule is exactly the case the line was
            // built for — and without the debug switch `probe` stores nothing.
            Diagnostics.playbackProblem(row, since: nil)
        } else {
            Diagnostics.probe(row)
        }
    }

    /// The bundled channels per event — as a pure calculation so that it can be tested.
    ///
    /// The bundling itself lives in ``ChannelVariants``; here things are only assigned.
    /// Kept separate because the assignment has its own trap: an event carries **several**
    /// programme identifiers, and the channels from them belong together in **one**
    /// bundle — otherwise the same station would appear twice in the row because it is
    /// listed under two identifiers.
    static func groupByEvent(
        _ events: [SportEvent], channels: [String: [Channel]]
    ) -> [String: [ChannelVariants.VariantGroup]] {
        Dictionary(
            uniqueKeysWithValues: events.map { event in
                (event.id, ChannelVariants.bundles(event.epgIDs.flatMap { channels[$0] ?? [] }))
            })
    }

    /// Which of the four states applies — as a pure calculation so that it can be tested.
    ///
    /// **The order is the statement.** It runs from cause to effect: first no prefetch at
    /// all, then a prefetch without this window, then a window without sport. Whoever
    /// reverses it blames the filter for an empty prefetch — and exactly this confusion
    /// was behind "only one entry for today" on 2026-08-29.
    static func state(
        downloads: LiveLibrary.DownloadsState, sportsEvents: Int, inWindow: Int
    ) -> State {
        if downloads.isEmpty { return .noGuide }
        if downloads.inWindow == 0 { return .noWindow }
        if sportsEvents == 0 || inWindow == 0 { return .noSport }
        return .ready
    }

    static func stockSpan(_ downloads: LiveLibrary.DownloadsState) -> String {
        guard let old = downloads.oldest, let youngest = downloads.newest else { return "leer" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        return "\(f.string(from: old)) – \(f.string(from: youngest))"
    }

    static func alter(_ timestamp: Date?, now: Date = Date()) -> String {
        guard let timestamp else { return "nie geholt" }
        let hours = Int(now.timeIntervalSince(timestamp) / 3600)
        if hours < 1 { return "vor weniger als einer Stunde" }
        if hours < 48 { return "vor \(hours) h" }
        return "vor \(hours / 24) Tagen"
    }

    /// Recalculates ``shown`` and ``availableKinds`` — the one place where that happens.
    ///
    /// It is called by the three events that determine the result: a new list
    /// (``load()``), a different filter (`didSet` on ``filter``) and a changed watch list
    /// (``toggleTeam(_:)``, ``toggleCompetition(_:)``). Whoever adds a fourth source has
    /// to register it here — otherwise the TV shows a list that does not match its filter.
    /// The rules themselves are unchanged.
    ///
    /// **Filter from the settings, ordering and sports are calculated by ``Flows/SportsSchedule``**
    /// (AP58 R5, finding L4) — the same rules as on the phone. The schedule filter filters
    /// the list and not just the chips (open decision 4 of the concept, 2026-09-02).
    private func updateView() {
        let filtered = SportsSchedule.filtered(events, choice: filterSelection).filter { event in
            switch filter {
            case .all: true
            case .marked: SportsSchedule.matches(event, .bookmarked, watchlist: memory)
            case .verified: SportsSchedule.matches(event, .taken, watchlist: memory)
            case .kind(let kind): event.kind == kind
            }
        }
        shown = SportsSchedule.arrange(filtered) { memory.marks($0) }
        availableKinds = SportsSchedule.sports(in: events, choice: filterSelection)
    }

    /// What the time of a row refers to — today, tomorrow, yesterday or earlier.
    ///
    /// The view only looks up its words for this; the calculation happens here, against
    /// exactly the clock reading that let the row in (``readAt``, stored on reading).
    /// A `Date()` of its own in the view — and likewise a clock freshly read here — could
    /// pass a different verdict over midnight than the cut.
    public func timeRelation(of event: SportEvent) -> SportWindow.TimeRelation {
        SportWindow.timeRelation(start: event.start, now: readAt, calendar: calendar)
    }

    /// The channels of an event, in the order of its identifiers.
    public func channels(of event: SportEvent) -> [Channel] {
        event.epgIDs.flatMap { channelsByEPG[$0] ?? [] }
    }

    /// The channels of an event as stations — several feeds of the same channel are
    /// **one** entry (viewer finding 2026-08-29: for Waubedaut–Kafausko, 10 channels are shown).
    public func sportChannels(of event: SportEvent) -> [ChannelVariants.VariantGroup] {
        channelsByEvent[event.id] ?? []
    }

    // MARK: - Remembering

    /// The watch list orders the list: bookmarked items stand at the top within their
    /// section, and the "Bookmarked" filter lives entirely off it.
    public func toggleTeam(_ name: String) {
        update { $0.toggleTeam(name) }
    }

    public func toggleCompetition(_ name: String) {
        update { $0.toggleCompetition(name) }
    }

    /// Bookmark a single match — **which until 2026-09-26 only the phone could do**
    /// (B5).
    public func toggleMatch(_ event: SportEvent) {
        update { $0.toggleMatch(event.id) }
    }

    private func update(_ mutate: (inout SportReminderList) -> Void) {
        var fresh = noteStore.read()
        mutate(&fresh)
        noteStore.write(fresh)
        memory = fresh
        updateView()
    }
}

/// Keeps the schedule model alive across section changes.
///
/// **Visible load time only on first opening** (requirement 2026-08-16): Changing section
/// tears the view down, and a new model would start at "loading" every time. With the
/// kept model the list is there immediately on return — `load()` then refreshes it in
/// the background, and the state stays `ready` as long as events are present.
public final class SportKeeper: ObservableObject {

    private var kept: SportModel?

    public init() {}

    /// The one model — built on the first call, reused afterwards.
    public func model(for library: LiveLibrary) -> SportModel {
        if let kept { return kept }
        let model = SportModel(library: library)
        kept = model
        return model
    }
}
