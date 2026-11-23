import Core
import Flows
import Foundation
import Observation
import PlaylistKit

/// The calculated schedule — **three sections, three filters, one watchlist.**
///
/// **A schedule and not a filtered channel list.** The difference is the whole job: Eleven
/// "channels" are usually one channel in eleven variants. As a channel list that would be
/// eleven rows for one match; as a schedule it is one row with the addendum "10 more
/// variants". This is calculated in `SportPlan` and `ScheduleCalculator` — both shared,
/// both adopted unchanged.
@MainActor
@Observable
public final class SportModel {

    public enum Situation: Sendable, Equatable {
        case isLoading
        case settled
        /// No programme in the cache — **not** "no sport today".
        case withoutBacklog
        case empty
    }

    public private(set) var state: Situation = .isLoading
    public private(set) var all: [SportEvent] = []

    /// Filtered by sport — `nil` means all.
    public private(set) var sportKind: SportKind?
    /// Filtered by channel — `nil` means all.
    public private(set) var channels: String?
    /// "Marked" or "Busy" — **the same filters as on the TV** (decision 27, B6,
    /// ``Flows/SportsSchedule/BookmarkFilter``). Until 2026-09-26 the phone filtered only by sport
    /// and channel.
    public private(set) var rememberFilter: SportsSchedule.BookmarkFilter = .all

    private let source: (any ChannelListingSource)?
    private let names: @MainActor (String) -> String?

    /// The watchlist — **the same as on the TV** (decision 27, B5): mark single matches
    /// **and** follow clubs and competitions, per profile (``Core/SportReminderList``). Until
    /// 2026-09-26 the phone kept its own one, which knew only matches.
    public private(set) var watchlist: SportReminderList
    private let noteStore: SportReminderListStore

    /// Which sports the schedule shows — the setting "Schedule filter".
    ///
    /// **Until 2026-09-26 nobody read it** (AP58, finding L4): The settings wrote
    /// `live.hiddenSports`, and the chip bar showed every sport anyway. **Since R5 it is the
    /// TV's key** (``Core/SportFilterSettings``), and as there it filters the list and not
    /// just the chips. It is read on every ``load(um:)``, so a change applies on the next
    /// opening.
    private var choice: SportFilterSettings
    private let loadSelection: @MainActor () -> SportFilterSettings

    /// - Parameter wahlLaden: Where the filter selection comes from. The default is the empty
    ///   selection — for tests without a Keychain; the view passes the store in.
    ///
    /// **The watchlist is read only in ``load(um:)``, not here** (check Live, finding 4):
    /// SwiftUI evaluates `State(initialValue:)` on every rebuild of the wrapper, and each time
    /// this setup read a file whose result was thrown away.
    public init(
        source: (any ChannelListingSource)? = nil,
        noteStore: SportReminderListStore = SportReminderListStore(),
        names: @escaping @MainActor (String) -> String? = { $0 },
        loadSelection: @escaping @MainActor () -> SportFilterSettings = { SportFilterSettings() }
    ) {
        self.source = source
        self.noteStore = noteStore
        self.watchlist = SportReminderList()
        self.names = names
        self.loadSelection = loadSelection
        self.choice = loadSelection()
    }

    // MARK: - Loading

    /// Whether a calculation is already running.
    ///
    /// **Finding of 2026-09-06 from the recording:** "Schedule requested" appeared twice, with the
    /// same time marker and two rows — SwiftUI builds the view more than once, and each
    /// instance started its own calculation. The result was the same, the work doubled; on a
    /// phone double work means double power. The second asker now gets nothing to do.
    private var isComputing = false

    /// Reads the schedule — **in the TV's window** (``Flows/SportsSchedule``, AP58 R5).
    ///
    /// Until 2026-09-26 the phone read from two hours back until five in the morning. Without
    /// the look back of two days the first broadcast was missing, and the repeat of a Friday
    /// match appeared on Sunday as a new broadcast.
    public func load(um now: Date = Date()) async {
        guard let source else {
            state = .withoutBacklog
            return
        }
        guard !isComputing else { return }
        isComputing = true
        defer { isComputing = false }
        choice = loadSelection()
        if let chosen = sportKind, !choice.isEnabled(chosen) { sportKind = nil }
        if all.isEmpty { state = .isLoading }

        let span = SportsSchedule.window(now: now)
        let read = await source.sport(from: span.readAlongFrom, until: span.readUntil)
        let found = SportsSchedule.inWindow(read, span: span, now: now)
        all = SportsSchedule.filtered(found, choice: choice)
        watchlist = noteStore.read()
        var watchItems = watchlist
        if watchItems.cleanUp(to: Set(found.map(\.id))) {
            noteStore.write(watchItems)
            watchlist = watchItems
        }

        // **Empty is not the same as empty.** Without a fetched schedule there can be no
        // programme; that is information about us. With a filled cache and still nothing found
        // it is information about the day.
        if all.isEmpty {
            let backlog = await source.downloadsState()
            state = backlog.broadcasts == 0 ? .withoutBacklog : .empty
        } else {
            state = .settled
        }
    }

    // MARK: - Filter

    public func select(sportKind incoming: SportKind?) {
        sportKind = sportKind == incoming ? nil : incoming
    }

    public func select(channels new: String?) {
        channels = channels == new ? nil : new
    }

    /// "Marked" and "Busy" toggle like the other chips; "All" clears both.
    public func select(rememberFilter new: SportsSchedule.BookmarkFilter) {
        rememberFilter = rememberFilter == new ? .all : new
    }

    // MARK: - Remembering

    /// Whether an event is remembered — marked, or via club and competition.
    public func isBookmarked(_ event: SportEvent) -> Bool { watchlist.marks(event) }

    public func toggleMatch(_ event: SportEvent) {
        update { $0.toggleMatch(event.id) }
    }

    public func episode(club name: String) {
        update { $0.toggleTeam(name) }
    }

    public func episode(competition name: String) {
        update { $0.toggleCompetition(name) }
    }

    /// **Read fresh, change, write back** — the same rule as in the settings.
    private func update(_ mutate: (inout SportReminderList) -> Void) {
        var fresh = noteStore.read()
        mutate(&fresh)
        noteStore.write(fresh)
        watchlist = fresh
    }

    /// How many events per sport — **counted across the respective other filter.**
    ///
    /// Anyone who has filtered by "Arena" and then looks at the sports wants to know how much
    /// football is running **on Arena**. If the row counted across the whole catalog, the
    /// numbers would promise more than a press on them delivers — and a chip with a number
    /// that has less behind it is false information.
    ///
    /// **Disabled sports are missing here and in the list** — they already dropped out on
    /// loading (``Flows/SportsSchedule/filtered(_:choice:)``).
    public var sports: [(kind: SportKind, count: Int)] {
        let baseSet = all.filter { matches(matchingChannel: $0) && matches(matchingBookmarkFilter: $0) }
        var tally: [SportKind: Int] = [:]
        for event in baseSet { tally[event.kind, default: 0] += 1 }
        return tally.sorted {
            $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value
        }
        .map { (kind: $0.key, count: $0.value) }
    }

    public var channelRow: [(name: String, count: Int)] {
        let baseSet = all.filter { matches(matchingSport: $0) && matches(matchingBookmarkFilter: $0) }
        var tally: [String: Int] = [:]
        for event in baseSet {
            // **Without a known channel no chip.** A filter whose label nobody can read is none; the
            // events themselves stay under "All".
            guard let first = event.epgIDs.first, let name = names(first) else { continue }
            tally[name, default: 0] += 1
        }
        return tally.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        .map { (name: $0.key, count: $0.value) }
    }

    /// How many events stand under "Marked" and "Busy" — counted across the two other
    /// filters, for the same reason as ``sports``.
    public func count(_ filter: SportsSchedule.BookmarkFilter) -> Int {
        all.count {
            matches(matchingSport: $0) && matches(matchingChannel: $0)
                && SportsSchedule.matches($0, filter, watchlist: watchlist)
        }
    }

    private func matches(matchingBookmarkFilter event: SportEvent) -> Bool {
        SportsSchedule.matches(event, rememberFilter, watchlist: watchlist)
    }

    private func matches(matchingSport event: SportEvent) -> Bool {
        sportKind == nil || event.kind == sportKind
    }

    private func matches(matchingChannel event: SportEvent) -> Bool {
        guard let channels else { return true }
        return event.epgIDs.first.flatMap(names) == channels
    }

    public var filtered: [SportEvent] {
        all.filter {
            matches(matchingSport: $0) && matches(matchingChannel: $0) && matches(matchingBookmarkFilter: $0)
        }
    }

    // MARK: - The three sections

    /// A section of the schedule.
    public struct Segment: Identifiable, Sendable, Equatable {
        public let kind: Kind
        public let events: [SportEvent]

        public var id: String { kind.rawValue }
        public var count: Int { events.count }

        public enum Kind: String, Sendable, CaseIterable {
            case runningNow = "laeuftJetzt"
            case equal = "gleich"
            case later = "spaeter"

            public var titleKey: String {
                switch self {
                case .runningNow: "sport.now"
                case .equal: "sport.soon"
                case .later: "sport.later"
                }
            }
        }
    }

    /// **Three pinned sections, and empty ones drop out.**
    ///
    /// A heading above nothing is not information but a building site — the same rule as for
    /// the shelves of the Home screen.
    ///
    /// **Marked items stand at the top within their section**, otherwise by start time.
    /// Why there is no section of its own "Remembered": A marked match that is running right
    /// now would then appear twice on the same screen — once at the top and once under
    /// "Running now". Anyone who wants to see only remembered items has the "Marked" filter.
    public func segments(um now: Date = Date()) -> [Segment] {
        let sameUntil = now.addingTimeInterval(3600)
        var buckets: [Segment.Kind: [SportEvent]] = [:]

        for event in filtered {
            let kind: Segment.Kind
            if event.isRunning(at: now) {
                kind = .runningNow
            } else if event.start > now && event.start <= sameUntil {
                kind = .equal
            } else if event.start > sameUntil {
                kind = .later
            } else {
                // Over. The schedule is a question about this evening, not a chronicle.
                continue
            }
            buckets[kind, default: []].append(event)
        }

        return Segment.Kind.allCases.compactMap { kind in
            guard let events = buckets[kind], !events.isEmpty else { return nil }
            return Segment(kind: kind, events: sorted(events))
        }
    }

    /// The order from ``Flows/SportsSchedule/arrange(_:remembered:)`` — the same as on the TV.
    private func sorted(_ events: [SportEvent]) -> [SportEvent] {
        SportsSchedule.arrange(events) { watchlist.marks($0) }
    }

    /// The name of the channel on which an event runs.
    public func channelName(_ event: SportEvent) -> String? {
        event.epgIDs.first.flatMap(names)
    }

    /// How many **further** variants there are.
    ///
    /// Eleven "channels" are usually one channel in eleven variants. As a number in the row
    /// that is information; as eleven rows it would be a list that carries the same match
    /// eleven times.
    public nonisolated static func otherVersions(_ event: SportEvent) -> Int {
        max(0, event.epgIDs.count - 1)
    }
}
