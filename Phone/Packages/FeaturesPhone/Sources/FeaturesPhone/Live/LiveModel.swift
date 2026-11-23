import Core
import Diagnose
import Flows
import Foundation
import Observation
import ParentalControls
import PlaylistKit

/// Channels, groups and what is currently playing.
///
/// **What lives here and what does not.** The rules on which something really depends — which
/// channels are visible, how groups are named, how a search key is folded — live
/// in the shared packages (`LivePreferences.isVisible`, `LiveLibrary.groups`,
/// `ChannelName.searchKey`) and are **called here, not rebuilt**. That is the
/// one rule the TV model writes down at the same place: whoever rebuilds one half
/// does not apply the other.
@MainActor
@Observable
public final class LiveModel {

    public enum Situation: Sendable, Equatable {
        case isLoading
        case settled
        /// Nothing to show. **Why** is told by ``isEverythingHidden`` — it makes a
        /// difference whether no list is stored or everything was hidden.
        case empty
        case disrupted(PlaybackPhase)
    }

    public private(set) var state: Situation = .isLoading

    /// All loaded channels, unfiltered.
    ///
    /// The filter runs when structuring — so a changed setting takes effect without a new
    /// fetch, and the raw catalog stays available for the honest count.
    private var catalog: [Channel] = []

    /// The groups of the **visible** channels, in the provider's order.
    public private(set) var groups: [ChannelGroup] = []

    /// Which group is shown — `nil` means all.
    public private(set) var chosen: String?

    /// What the channel list is searched for.
    ///
    /// **The search key was ready and used nowhere.** `Channel.searchKey`
    /// folds the decorative characters, throws away the provider's prefix ("DE:", "PERLE:") and
    /// resolves accents — without it 1,313 channels begin with "DE" and every search for
    /// "HD" comes up empty, because there stands `ᴴᴰ`.
    public var searchTerm = "" {
        didSet { if searchTerm != oldValue { outline() } }
    }

    /// The visible channels — **computed once and held.**
    ///
    /// **Before, this was a computed property**, and it ran four times on every redraw:
    /// for the number in the segment, for the "All" chip, for the rows and for the
    /// count of those without a program. With 7,746 channels that is around 31,000 steps for
    /// a list that changes only when someone flips a switch.
    private var visible: [Channel] = []

    /// The rows of the list, folded and split — **also computed once.**
    public private(set) var withGuide: [ChannelBundle] = []
    public private(set) var withoutGuide: [ChannelBundle] = []

    /// What played last, and what is saved.
    ///
    /// **Both stand only above the unfiltered list.** Whoever has chosen a group
    /// or is searching has asked a question; two sections that do not answer it
    /// would then stand between them and the answer.
    public private(set) var recent: [ChannelBundle] = []
    public private(set) var favorites: [ChannelBundle] = []

    /// The program per channel identifier. A **missing** entry means "not yet
    /// asked", an **empty** one means "asked, there is none".
    private var programs: [String: [Programme]] = [:]

    public private(set) var status: ProgrammeState = .empty

    /// Counts how often the catalog or the program cache stands anew — **after every ``load()`` and
    /// every ``fresh()``** (Live check, finding 8, 2026-09-27). The iPad's grid
    /// hangs on it; until then it redrew only on a group and a search term, and showed after
    /// refreshing the old state.
    public private(set) var gridRevision = 0

    /// Which channel lists did **not** answer on the last load.
    ///
    /// **With two credentials, one of which stalls, one wants both**: to see the channels of the
    /// other **and** to know that one is missing. Otherwise the viewer counts half a
    /// list and takes it for the whole.
    public private(set) var silentLists: [String] = []

    /// Is a reconciliation running? Then the refresh button is a spinner.
    public private(set) var isRefreshing = false

    private let source: (any ChannelListingSource)?
    private var preferences: LivePreferences
    private let loadPreferences: @Sendable () -> LivePreferences
    private let history: ChannelHistory

    /// - Parameter vorliebenLaden: Where the settings come from. **Until 2026-09-06 they came
    ///   from nowhere**: `LivePreferences.load(from:)` stood not once in the whole phone project,
    ///   and every switch in `Settings → Live` was gone again at the latest
    ///   at the next launch — including the hidden groups, which with 96
    ///   groups are the most important lever of all.
    ///
    ///   **A handle and not a value**, so that ``load()`` reads them fresh every time: whoever flips
    ///   something in Settings and goes back to the tab should see it, and
    ///   not have to restart the app. The default returns the factory setting —
    ///   for checks that have no Keychain.
    public init(
        source: (any ChannelListingSource)? = nil, preferences: LivePreferences = LivePreferences(),
        loadPreferences: (@Sendable () -> LivePreferences)? = nil,
        history: ChannelHistory = ChannelHistory()
    ) {
        self.source = source
        self.preferences = preferences
        self.loadPreferences = loadPreferences ?? { preferences }
        self.history = history
    }

    // MARK: - Numbers that tell the truth

    /// How many channels are **visible**.
    ///
    /// **Not the provider's raw catalog** — finding M2 of 2026-09-05 found exactly this
    /// error in two places of the draft: there stood 5,389 above a list
    /// that is 2,055 entries long.
    public var visibleCount: Int { visible.count }

    /// What the credential carries in total.
    public var rawCatalogCount: Int { catalog.count }

    /// Whether anything is hidden at all. Only then is the difference information.
    public var isSomethingHidden: Bool { rawCatalogCount > visibleCount }

    /// Whether **everything** is hidden — the difference from "nothing set up".
    public var isEverythingHidden: Bool { !catalog.isEmpty && visible.isEmpty }

    /// How many of the **shown** channels carry no program.
    ///
    /// **The error this property fixes was on screen on 2026-09-05:**
    /// it said "one of 7746 channels without a program guide" — but 7,746 is
    /// the whole catalog and not those without a program. A sentence with a number that counts something
    /// other than what it claims is exactly the error that the same
    /// area in the draft already had once (finding M2: raw catalog above a
    /// filtered list).
    ///
    /// It is counted over the rows that are there — after ``fetchProgram()`` it is known for each
    /// of them whether there is a program.
    /// **Carried forward and not counted.** Before, a filter ran here over all
    /// rows with one dictionary lookup each — with "All" that is 7,746 lookups per redraw,
    /// for a number that changes only when program is delivered later.
    public var withoutProgramCount: Int { withoutGuide.count }

    /// All loaded channels, **unfiltered** — not for playing: for that
    /// ``channels(forSport:)`` applies.
    public var allChannels: [Channel] { catalog }

    /// The channel for a broadcast in the schedule — **only from the visible catalog**
    /// (Live check, finding 6, 2026-09-27).
    ///
    /// Across all groups and not just the chosen one: a game can run on a channel
    /// that the chosen group does not carry. Until then the search fell back to the unfiltered
    /// catalog and also played a channel from a hidden group. If none
    /// is found, there is no playback. What is searched for is the EPG ID **and** the
    /// channel identifier — the League Pass stage of the reconciliation carries the latter
    /// (`LiveLibrary.channels(withEPGIDs:)`).
    public func channels(forSport event: SportEvent) -> Channel? {
        for identifier in event.epgIDs where !identifier.isEmpty {
            if let channel = visible.first(where: { $0.epgID == identifier || $0.id == identifier }) {
                return channel
            }
        }
        return nil
    }

    /// The list as it stands on screen — **in sections.**
    ///
    /// **Four intents, four sections, and their order is frequency:**
    /// "my channel" (last watched), "the one I saved", "what is on now",
    /// and finally the rest without a program — question 10, decided on 2026-09-06. **Since
    /// 2026-09-26 ``Flows/LiveOutline`` computes this**, and the TV shows the same
    /// sequence (decision 27, B9).
    public private(set) var segments: [ChannelSection] = []

    /// The most recently watched channel that is still visible — where "Live" without an overview
    /// jumps (C14, ``Flows/LiveEntry``).
    public var lastChannel: Channel? {
        let perName = Dictionary(
            visible.map { ($0.channelName, $0) }, uniquingKeysWith: { first, _ in first })
        return history.names.lazy.compactMap { perName[$0] }.first
    }

    /// The rows that stand in the list — both sections one after the other.
    ///
    /// For everything the list needs as a whole: fetching the program, the
    /// search for a channel from the schedule.
    public var rows: [ChannelBundle] { withGuide + withoutGuide }

    /// Whether the search currently applies — only then is an empty state one.
    ///
    /// **From two characters** (``Flows/LiveCatalog/minimumLength``, AP58 R5): until
    /// 2026-09-26 one character applied here, two on the TV. A single letter matches
    /// almost everything and says nothing.
    public var isSearching: Bool {
        LiveCatalog.searchKey(searchTerm) != nil
    }

    // MARK: - Loading

    public func load() async {
        guard let source else {
            state = .disrupted(.emptyLiveWithoutList)
            return
        }
        // **A second load shows no spinner.** Whoever comes back from the player
        // triggers `.task` again; if `.isLoading` stood here unconditionally, the list that
        // was just there would disappear for the duration of one fetch.
        if catalog.isEmpty { state = .isLoading }
        preferences = loadPreferences()

        let loaded = await source.channels()
        catalog = loaded.channels
        silentLists = loaded.silent

        guard !catalog.isEmpty else {
            // **Two different pieces of information, and until 2026-09-06 the same.**
            // ``ChannelCatalog/silent`` carries the lists that did not answer —
            // written by ``ProviderChannelSource``, read by nobody. "No
            // channel list set up yet" above a credential that is merely not
            // answering at the moment sends the viewer to repeat a setup that stands.
            state = .disrupted(loaded.silent.isEmpty ? .emptyLiveWithoutList : .networkXtream)
            return
        }

        outline()
        state = isEverythingHidden ? .empty : .settled

        // Program and cache state **delivered later**: the list stands with what the
        // provider supplies. Without a program, one line per channel is missing, not the row.
        await fetchProgram()
        status = await source.downloadsState()
        gridRevision += 1
    }

    /// The channel name for an EPG ID — **built once, not searched.**
    ///
    /// The schedule names its broadcasts with the EPG ID; the screen
    /// is meant to show the channel name. With 7,746 channels, a search per row and
    /// redraw would be one over the whole list — the board is therefore built when structuring.
    /// **`nil` if no channel is known for it — and not the identifier.**
    ///
    /// Finding of 2026-09-06 on screen: in the schedule's channel row there stood a chip
    /// "xtream#xtream#205387 16". That is the EPG ID, and it answers no
    /// question anyone asks. It arises when an event runs on a channel
    /// that the channel list does not carry — hidden group, another list, or an
    /// identifier that occurs only in the guide. Falling back to the identifier turns
    /// "I do not know" into information that is none.
    public func channelName(forEpg identifier: String) -> String? {
        namesPerEPG[identifier]
    }

    private var namesPerEPG: [String: String] = [:]

    /// The one place where the catalog becomes what is on screen.
    ///
    /// **Visible, groups, bundles and the two sections arise here** — and
    /// nowhere else. Before, they were computed properties that ran anew over 7,746 channels
    /// on every redraw; now it runs when the catalog,
    /// a setting, the group choice, the search term or the program changes.
    ///
    /// **Visibility is computed by ``Flows/LiveCatalog/isVisible(_:preferences:)``** (AP58 R5)
    /// — the same calculation as on the TV. The second rule about adult channels
    /// ("hide unmarked ones") the catalog has already behind it: `LiveLibrary`
    /// filters every delivery (``Core/ChannelLock``, Live check, finding 1).
    private func outline() {
        visible = LiveCatalog.isVisible(catalog, preferences: preferences)
        let isVisible = visible
        namesPerEPG = [:]
        for channels in isVisible {
            guard let epg = channels.epgID, !epg.isEmpty, namesPerEPG[epg] == nil else { continue }
            namesPerEPG[epg] = channels.channelName
        }
        var tally: [String: Int] = [:]
        var order: [String] = []
        for channels in isVisible {
            let name = channels.group ?? ChannelGroup.unnamed
            if tally[name] == nil { order.append(name) }
            tally[name, default: 0] += 1
        }
        // **The provider's order**, not alphabetical: whoever has sorted their groups
        // has thereby said what matters to them — the same reasoning as
        // for ``CatalogState/catalogs``.
        groups = preferences.ordered(order).compactMap { name in
            guard let count = tally[name] else { return nil }
            return ChannelGroup(name: name, count: count)
        }
        if let chosen, !groups.contains(where: { $0.name == chosen }) {
            self.chosen = nil
        }
        bundle()
    }

    /// Fold, search, and split into the two sections.
    ///
    /// **The order matters.** First the group or the search, then folding, then the
    /// cut by program. Whoever folded first and then searched would search the leader's name
    /// instead of all feeds — "Zenit 1 SD" would no longer be found via "SD".
    ///
    /// **The search runs over all visible channels and not over the chosen group**
    /// (``Flows/LiveCatalog/search(_:in:)``, AP58 R5) — whoever searches usually does not know
    /// which group the provider put the channel in.
    private func bundle() {
        var selected = visible
        if let match = LiveCatalog.search(searchTerm, in: visible) {
            selected = match.channels
        } else if let chosen {
            selected = selected.filter { ($0.group ?? ChannelGroup.unnamed) == chosen }
        }
        let folded = ChannelBundle.fold(selected)
        // **The cut by question 10** (decided on 2026-09-06) and the two shelves
        // above it — only above the unfiltered list. The rule lives in
        // ``Flows/LiveOutline`` and applies on the TV just the same.
        segments = LiveOutline.outline(
            folded, shelves: chosen == nil && !isSearching, recent: history.names,
            name: \.name, istFavorit: { $0.feeds.contains(where: \.isFavorite) },
            program: { bundles in
                switch program(zu: bundles) {
                case .pending: .pending
                case .none: .none
                case .list: .available
                }
            })
        let part = { (kind: LiveOutline.Kind) in
            self.segments.first { $0.kind == kind }?.entries ?? []
        }
        recent = part(.recent)
        favorites = part(.favorites)
        withGuide = part(.withGuide)
        withoutGuide = part(.withoutGuide)
    }

    /// The program of the **shown** channels, in one go from the cache.
    ///
    /// **Not per row and not while scrolling** — the reasoning is at
    /// ``ChannelListingSource``: one fetch per visible row would be a connection storm on an account with one
    /// permitted connection, and that ends in an IP throttle that
    /// also blocks the API.
    private func fetchProgram() async {
        guard let source else { return }
        let asked = toAsk(um: Date())
        guard !asked.isEmpty else { return }
        let found = await source.program(forItem: asked)
        // **Every channel asked gets an entry**, even an empty one. Otherwise
        // "asked, there is none" would be indistinguishable from "not yet asked" — and the
        // row would not know whether it may write "No program stored" or
        // better nothing.
        for channels in asked {
            programs[channels.id] = found[channels.id] ?? []
        }
        // **Only now is the cut settled.** Before, the rows were "not yet
        // asked"; which ones belong at the end is known after this answer.
        bundle()
    }

    // MARK: - Controls

    /// Which of the rows that stand are really worth a query.
    ///
    /// **Two cases and not all.** Until 2026-09-06 every chip press asked for the program of
    /// **all** rows anew — twenty full queries for a group one only
    /// opens to see what is in it. From here on it asks only where nothing stands
    /// or where the last thing that stood has expired.
    ///
    /// **The expiry condition is half of it.** Without it a program fetched once would
    /// stay forever, and after a few hours the app would write
    /// "nothing on" above a row whose broadcast is long a different one.
    ///
    /// **An empty entry is not asked again.** It means "asked, there is none"
    /// (see ``program(zu:)``) and has no last entry that could expire;
    /// whoever wants to renew it presses Refresh — ``fresh()`` clears the board.
    private func toAsk(um time: Date) -> [Channel] {
        rows.flatMap(\.feeds).filter { channels in
            guard let list = programs[channels.id] else { return true }
            guard let lastEnd = list.map(\.end).max() else { return false }
            return lastEnd <= time
        }
    }

    /// Save a channel or remove it from the saved ones.
    ///
    /// **The catalog is changed in place and not reloaded.** A new
    /// fetch for a checkmark would be, on an account with **one** permitted connection,
    /// the same error that ``ChannelListingSource`` describes elsewhere.
    ///
    /// **All entries that are the same favorite at once** — via the store's key
    /// (``Flows/LiveCatalog/setFavorite(_:for:in:)``, AP58 R5). Until
    /// 2026-09-26 a raw name comparison stood here, and with a different spelling
    /// an entry of the same name lacked its star until the next load.
    public func setEnabled(favorite channels: Channel) async {
        guard let source else { return }
        let new = await source.setEnabled(favorite: channels)
        LiveCatalog.setFavorite(new, for: channels, in: &catalog)
        outline()
    }

    /// A channel was selected — **it is saved by the player**, after 20 s
    /// (``Flows/ChannelDwell``, 2026-09-28), as on the TV. Until then only
    /// this tab wrote, and immediately; Home, favorites, search and switching in the
    /// player were missing from the history. Here it only restructures.
    public func note(_ channels: Channel) {
        outline()
    }

    /// Choose a group — **and thereby end the search.**
    ///
    /// Since the search covers all groups (AP58 R5), a group choice during the
    /// search would have no visible effect: the chip would stand highlighted, the list would
    /// keep showing the hits. The same rule as on the TV.
    public func select(group: String?) {
        if isSearching { searchTerm = "" }
        chosen = chosen == group ? nil : group
        bundle()
        Task { await fetchProgram() }
    }

    /// Fetch the program again — **on press and only on press**.
    public func fresh() async {
        guard let source, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await source.freshProgramme()
        programs.removeAll()
        await fetchProgram()
        status = await source.downloadsState()
        gridRevision += 1
    }

    /// What a tap on a past cell of the grid plays — **the feed with an
    /// archive, or `nil` for live** (Live check, finding 8).
    ///
    /// The grid shows the leader for each channel. Until then it asked about the catch-up only for
    /// it: if "X HD" had an archive and the leader "X FHD" did not, the
    /// daily program played the broadcast as a recording and the grid the same cell live.
    /// Now both ask all feeds of the bundle
    /// (``Flows/CatchUpSelection/recording(feeds:start:end:now:)``).
    public func catchUp(
        leader: Channel, start: Date, end: Date, isGap: Bool, now: Date
    ) -> Channel? {
        guard !isGap else { return nil }
        let feeds =
            rows.first { $0.leader.id == leader.id }?.feeds ?? [leader]
        return CatchUpSelection.recording(
            feeds: feeds, start: start, end: end, now: now)?.channels
    }

    // MARK: - What is running on a channel

    /// What is known about the program of a channel.
    ///
    /// **Three cases and not two.** Of 5,389 channels in the provider list, 980 carry an
    /// EPG ID and only 610 find an entry with it. For the remaining 4,779 neither
    /// an empty row nor a spinner may stay on screen — so "not yet
    /// asked" must be distinguishable from "asked, there is none". With a plain
    /// `[Programme]` both would be empty.
    public func program(zu channels: Channel) -> ProgramState {
        guard let list = programs[channels.id] else { return .pending }
        return list.isEmpty ? .none : .list(list)
    }

    /// The program of a bundle — **that of the leader.**
    ///
    /// The feeds of a channel show the same picture; their program is the same.
    /// At the provider, however, often only one of them carries an EPG ID — so
    /// it is not only the leader that is asked, but the first one that knows something.
    public func program(zu bundles: ChannelBundle) -> ProgramState {
        var asked = false
        for zuspielung in bundles.feeds {
            switch program(zu: zuspielung) {
            case .list(let list): return .list(list)
            case .none: asked = true
            case .pending: break
            }
        }
        return asked ? .none : .pending
    }

    public func isRunning(to channels: Channel, um time: Date = Date()) -> Programme? {
        guard case .list(let list) = program(zu: channels) else { return nil }
        return list.first { $0.isRunning(at: time) }
    }

    public func following(to channels: Channel, um time: Date = Date()) -> Programme? {
        guard case .list(let list) = program(zu: channels) else { return nil }
        return list.filter { $0.start > time }.min { $0.start < $1.start }
    }

    /// The remaining time of the running broadcast in minutes — ``Flows/LiveCatalog/remainingMinutes(_:um:)``.
    public nonisolated static func remainingMinutes(_ broadcast: Programme?, um time: Date) -> Int? {
        LiveCatalog.remainingMinutes(broadcast, um: time)
    }

    /// How far the running broadcast has progressed — ``Flows/LiveCatalog/progress(_:um:)``.
    public nonisolated static func progress(_ broadcast: Programme?, um time: Date) -> Double? {
        LiveCatalog.progress(broadcast, um: time)
    }
}

/// A section of the channel list — ``Flows/LiveOutline/Segment`` over folded
/// bundles.
public typealias ChannelSection = LiveOutline.Segment<ChannelBundle>

/// A channel group with its count.
///
/// **Here the chip carries a number — unlike in the library.** There it is
/// deliberately not shown, because "Unwatched 47" only arises once the whole list is
/// there. A live catalog is completely loaded as soon as it is there; the group count is
/// a `count` over a field in memory and never arrives late. The rule
/// "numbers belong to the catalog" still holds — here it **does** belong to it.
public struct ChannelGroup: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int

    public var id: String { name }

    /// What a channel without a group gets.
    public static let unnamed = "—"

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// What is known about the program of a channel.
public enum ProgramState: Sendable, Equatable {
    /// Not yet asked. The row shows **nothing** for it — no placeholder, no
    /// spinner.
    case pending
    /// Asked, or not to be asked at all: there is no program.
    case none
    case list([Programme])
}
