import Combine
import Core
import Flows
import Foundation
import ParentalControls
import Playback
import PlaylistKit

/// The Live area as a model — all the work that comes before the view.
///
/// **Why so much is here:** In the checked catalog of a real provider there are
/// 5389 channels in 79 groups. A flat list of them is not usable — at the
/// eight rows that fit in one screen height (``ChannelRow/height``), that would be 674
/// screen heights with the remote. Everything this model does serves the one
/// purpose of turning this quantity into a path of at most three steps:
///
/// 1. **Structure** by groups, favorites on top. The groups come in the
///    order of their first appearance — ``LiveLibrary/groups(from:)`` keeps it
///    that way, and that is intentional: providers put domestic before foreign and general
///    programming before specialty channels. Sorting alphabetically would throw this work away.
/// 2. **Filter** via ``LivePreferences/allows(group:isAdult:)``, at
///    **one** place for list and search together. A channel that shows up in search
///    but not in the list looks like an error.
/// 3. **Load with restraint.** The current program is fetched only after a dwell time,
///    not on every focus change — the same rule as with ``DetailColumn``
///    and for the same reason. Browsing through 5389 channels would otherwise cause
///    a flood of requests, and the provider allows exactly **one** connection.
///
/// **Testable without network.** Where the channels come from, how the program is fetched and
/// how a favorite is stored arrives from outside as a closure. That is no
/// convenience for the tests: the Live area depends on an account that
/// expires and on an address that can be blocked — a model that needs a
/// provider to be checked does not get checked.
public final class LiveModel: ObservableObject {

    // MARK: - What comes from outside

    /// What a load yields.
    ///
    /// A type of its own and not ``LiveLibrary/Result``: its construction is not
    /// reachable from outside, and a model that cannot be filled with channels in a check
    /// checks nothing. The caller does the translation in one line.
    public nonisolated struct Stock: Sendable, Equatable {
        public let channels: [Channel]
        /// Lists that did not answer. Delivered along instead of thrown — with four
        /// lists of which one stalls, you want to see the others **and** know
        /// that one is missing.
        public let failures: [Failure]

        public init(channels: [Channel], failures: [Failure] = []) {
            self.channels = channels
            self.failures = failures
        }
    }

    /// A list that did not answer.
    public nonisolated struct Failure: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// Key from the language file, not the text. The reason is documented at
        /// ``LiveLibrary/LoadIssue``.
        public let messageKey: String

        public init(id: String, name: String, messageKey: String) {
            self.id = id
            self.name = name
            self.messageKey = messageKey
        }
    }

    // MARK: - State

    public enum State: Equatable {
        case loading
        case ready
        /// Nothing to show. Why, ``isEverythingHidden`` says — it makes a
        /// difference whether no list is stored or everything was hidden.
        case empty
    }

    /// What is known about the program of a channel.
    ///
    /// **Three cases and not two**, and a requirement hangs on it: of 5389
    /// channels, 980 carry a program identifier, and only 610 find an
    /// entry with it. For the rest neither an empty line nor a spinner may
    /// remain — so "not yet asked" must be distinguishable from "asked, there is none".
    /// With a plain `[Programme]` both would be empty.
    public enum Guide: Sendable, Equatable {
        /// Not yet asked. The view shows **nothing** for this — no placeholder,
        /// no spinner.
        case pending
        /// Asked, or not to be asked at all: there is no program.
        case none
        case listing([Programme])
    }

    @Published public private(set) var state: State = .loading
    /// Favorites first, then the groups in the provider's order.
    @Published public private(set) var sections: [LiveLibrary.Group] = []
    @Published public private(set) var failures: [Failure] = []
    @Published public private(set) var selectedSectionID: String?
    /// The channel the focus is on. The board on the right depends on it.
    @Published public private(set) var focused: Channel?
    @Published public private(set) var term: String = ""
    /// The search hits, capped — see ``maximumHits``.
    @Published public private(set) var hits: [Channel] = []
    /// How many there would be in total. Kept separate, so that the count tells the
    /// truth even when the list is capped.
    @Published public private(set) var hitCount = 0

    /// The selected group in sections — **the same order as on the phone** (decision
    /// 27, B9, ``Flows/LiveOutline``): for "All" first "Recently watched" and
    /// "Favorites", then the channels with a program and at the end those without.
    ///
    /// **Stored and not calculated on every draw** (lesson from E5): the view
    /// redraws on every focus step, and "All" is 5389 channels for this provider.
    /// Calculation happens when the catalog, choice, search or the program from the stock
    /// changes — **not** on the fetch for the channel in focus: a row that
    /// slides to the end under the focus would be a jump nobody triggered.
    @Published public private(set) var segments: [LiveOutline.Segment<Channel>] = []

    /// "All" — all visible channels, in the provider's order.
    ///
    /// **Not an entry in ``sections``**: the groups there are subsets that do not
    /// overlap, and counts and the sidebar rely on that.
    public private(set) var overview: LiveLibrary.Group?

    /// What was fetched, per channel identifier. An empty entry means **asked and
    /// nothing found**, a missing one means **not yet asked**.
    @Published private var guides: [String: [Programme]] = [:]

    public private(set) var preferences: LivePreferences

    /// All loaded channels, unfiltered. The filter runs during structuring — so
    /// a changed setting takes effect without a new fetch.
    private var stock: [Channel] = []

    /// The visible channels, built once — the base set of the search.
    ///
    /// The search key itself has lived ready-made on the channel since AP7 (``Channel/searchKey``);
    /// only what is searched over is kept here.
    private var index: [Channel] = []

    private let loadStock: @Sendable () async -> Stock
    private let loadGuide: @Sendable (Channel) async -> [Programme]
    /// The program of many channels at once — from the stock, without network.
    private let loadStoredGuides: @Sendable ([Channel]) async -> [String: [Programme]]
    private let persistFavorite: @MainActor (Channel, Bool) -> Void
    /// The wait time as a dependency: a check that sleeps for half a second
    /// is switched off at the first random failure and checks nothing afterwards.
    private let wait: @MainActor (TimeInterval) async -> Void
    /// The recently watched channels — ``Flows/ChannelHistory``, per profile, the same
    /// list as on the phone.
    private let lastWatched: @MainActor () -> [String]
    private var recentNames: [String] = []

    private var pending: Task<Void, Never>?

    // MARK: - Numbers

    /// How long a channel must stay in focus before its program is fetched.
    ///
    /// While the remote is held, the focus moves on several times per second.
    /// Half a second lies above that — whoever browses through triggers nothing — and
    /// stays below the threshold at which the row filling in
    /// is read as a delay. Shorter than the three seconds at ``TrailerPreferences``, because
    /// here a line of text appears and no sound starts.
    public static let dwell: TimeInterval = 0.5

    /// From how many characters on the search runs — ``Flows/LiveCatalog/minimumLength``,
    /// the same rule as on the phone (AP58 R5).
    public static let minimumTermLength = LiveCatalog.minimumLength

    /// At most this many hits — ``Flows/LiveCatalog/maxMatches``.
    public static let maximumHits = LiveCatalog.maxMatches

    /// The identifier of the favorites group, as ``LiveLibrary/favorites(from:)``
    /// assigns it. Kept here so the view does not scatter it around as a string.
    public static let favoritesSectionID = "favorites"

    /// The identifier of "All" (``overview``).
    public static let overviewSectionID = "overview"

    // MARK: - Setup

    public init(
        preferences: LivePreferences = LivePreferences(),
        stock: @escaping @Sendable () async -> Stock = { Stock(channels: []) },
        guide: @escaping @Sendable (Channel) async -> [Programme] = { _ in [] },
        /// The program of many channels at once, from the stock. Default empty,
        /// so checks get by without a database.
        storedGuides: @escaping @Sendable ([Channel]) async -> [String: [Programme]] = { _ in
            [:]
        },
        setFavorite: @escaping @MainActor (Channel, Bool) -> Void = { _, _ in },
        wait: @escaping @MainActor (TimeInterval) async -> Void = LiveModel.sleep,
        recent: @escaping @MainActor () -> [String] = { ChannelHistory().names }
    ) {
        self.preferences = preferences
        self.loadStock = stock
        self.loadGuide = guide
        self.loadStoredGuides = storedGuides
        self.persistFavorite = setFavorite
        self.wait = wait
        self.lastWatched = recent
    }

    /// The real wait time. Public, because it appears as a default in the initializer.
    public static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // No `deinit`. Teardown lives in ``stop()`` and is called when the
    // view disappears — a `deinit` that cancels a task is not permitted under strict
    // concurrency.

    // MARK: - Loading

    public func load() async {
        // **A second load shows no spinner** (on-device finding F-040,
        // 2026-09-04): a full-screen player takes the area underneath out of sight,
        // tvOS detaches it, and on coming back `.task` runs again —
        // that is, this load. If `.loading` stood here unconditionally, the
        // viewer saw the loading spinner first after every channel, and if
        // the refill stalled (provider throttles, storage busy),
        // the spinner stayed forever. Whoever already has a catalog keeps it
        // visible and gets the fresh one quietly swapped in.
        let firstTime = stock.isEmpty
        if firstTime { state = .loading }

        let loaded = await loadStock()
        recentNames = lastWatched()
        stock = loaded.channels
        failures = loaded.failures
        rebuild()

        state = sections.isEmpty ? .empty : .ready

        // The first time at the start of the area; afterwards the
        // channel the viewer came from stays in focus — as long as it still exists.
        if !firstTime, let current = focused,
            shownChannels.contains(where: { $0.id == current.id })
        {
            return
        }

        // The first channel goes straight into the board on the right. Without it a hint would stand there on
        // opening although the list next to it is already full — and that looks
        // as if the board were broken. The program fetch for it is one, not
        // 5389: it applies to the one channel that is also displayed.
        focus(selectedSection?.channels.first)
    }

    /// Takes over changed settings.
    ///
    /// Without a new fetch: the switch for adult channels and the hidden
    /// groups only change what of the loaded channels is visible. A reload
    /// for that would mean fetching 5389 channels a second time in order to show fewer.
    public func apply(_ preferences: LivePreferences) {
        guard preferences != self.preferences else { return }
        self.preferences = preferences
        rebuild()
        state = sections.isEmpty ? .empty : .ready
    }

    /// Restructures the loaded catalog.
    ///
    /// **Without its own channel block** (Live check, finding 1, 2026-09-27): the catalog has
    /// already been filtered by `LiveLibrary` (``Core/ChannelLock``), for this area as for
    /// every other path. The first rule comes from this model's preferences.
    private func rebuild() {
        let visible = Self.visibleChannels(stock, preferences: preferences)

        var built: [LiveLibrary.Group] = []
        // Favorites above all groups. With this quantity they are the actual
        // way into the list, not a convenience.
        if let favorites = LiveLibrary.favorites(from: visible) {
            built.append(favorites)
        }
        // In the viewer's order, where they have set one — the
        // favorites above remain untouched.
        let grouped = LiveLibrary.groups(from: visible)
        let orderedNames = preferences.ordered(grouped.map(\.name))
        built.append(
            contentsOf: orderedNames.compactMap { name in grouped.first { $0.name == name } }
        )
        sections = built
        overview =
            visible.isEmpty
            ? nil : LiveLibrary.Group(id: Self.overviewSectionID, name: "", channels: visible)

        index = visible

        // The selected group stays as long as it still exists. Otherwise the
        // view would jump back to the top on every favorite being set. **Without a selection, "All"**
        // (B9), as on the phone — with "Recently watched" and the favorites on top.
        if selectedSectionID == nil || !exists(selectedSectionID) {
            selectedSectionID = overview?.id ?? built.first?.id
        }

        // The search too: a channel whose group was just hidden must
        // also disappear from the hits.
        runSearch()

        outline()
        fillGuidesFromStore()
    }

    private func exists(_ sectionID: String?) -> Bool {
        sectionID == Self.overviewSectionID
            ? overview != nil : sections.contains { $0.id == sectionID }
    }

    /// Recalculates ``segments`` — the one place for it.
    private func outline() {
        segments = LiveOutline.outline(
            selectedSection?.channels ?? [],
            shelves: selectedSectionID == Self.overviewSectionID && !isSearching,
            recent: recentNames, name: \.channelName, istFavorit: \.isFavorite,
            program: programmeState(of:))
    }

    /// What is known about the program of a channel — **without a program identifier: none**,
    /// and that is certain without anyone having to ask.
    private func programmeState(of channel: Channel) -> LiveOutline.Guide {
        guard let epgID = channel.epgID, !epgID.isEmpty else { return .none }
        guard let listing = guides[channel.id] else { return .pending }
        return listing.isEmpty ? .none : .available
    }

    /// Fetches the program of **all visible channels** at once from the stock.
    ///
    /// **This is the difference between "loads when you move onto it" and "is
    /// there"** (viewer finding 2026-08-08). Until now only the focus filled the
    /// program line — in a group with a hundred channels, exactly
    /// those you had already been on showed their show. From the stock the
    /// question for all together costs one database query.
    ///
    /// What the stock does not know stays open: for these channels the
    /// single fetch on focus still applies.
    /// The running grab into the stock — **so that it can be awaited.**
    ///
    /// **For the check and not for operation** (AP50, 2026-09-23), and it fixes
    /// a test suite that had been flaky since 2026-08-27. It stood there without a handle: the
    /// test suite could only **poll** — first fifty milliseconds, then two seconds,
    /// then ten —, and each of these limits measured how busy the machine happens to be.
    /// With 661 checks sharing the same main actor, this task simply gets its turn
    /// later at times; once ten seconds were enough, on the next run they were not.
    ///
    /// **Raising a deadline is the wrong answer there** — it swaps a
    /// red test suite for a slow one that conceals the same thing. Whoever holds on to the task
    /// can **await** it, and that is no longer a time measurement.
    private(set) var downloadsRun: Task<Void, Never>?

    private func fillGuidesFromStore() {
        let channels = selectedSection?.channels ?? []
        guard !channels.isEmpty else { return }

        downloadsRun = Task { [weak self] in
            guard let self else { return }
            let stored = await self.loadStoredGuides(channels)
            guard !stored.isEmpty else { return }
            // **And the stock is the truth** (as in ``LiveLibrary/programmes(for:)``):
            // if it holds program but none for this channel, then it has none. Without this
            // line a channel without a show would stand under "with program" until the first focus.
            for channel in channels where stored[channel.id] == nil && self.guides[channel.id] == nil {
                self.guides[channel.id] = []
            }
            defer { self.outline() }
            for (channelID, listing) in stored {
                // **The stock beats an empty result.** Here stood
                // `guides[channelID] == nil`, that is "only fill where nothing
                // stands yet" — and that lost a race: the single fetch of the
                // focused channel also enters its result here,
                // and if it came back first and empty, the row stayed
                // empty forever although the stock knew the show.
                //
                // An entry with content, by contrast, remains untouched: it is
                // fresher than the stock, because it just came from the provider.
                let existing = self.guides[channelID]
                guard existing == nil || existing?.isEmpty == true else { continue }
                guard !listing.isEmpty else { continue }
                self.guides[channelID] = listing
            }
        }
    }

    /// What of a catalog comes into question at all — the rule lives in
    /// ``Flows/LiveCatalog/isVisible(_:preferences:)`` and applies on the phone just the same
    /// (AP58 R5, finding L1). Separator rows drop out, and so does whatever the settings
    /// hide.
    public static func visibleChannels(
        _ channels: [Channel], preferences: LivePreferences
    ) -> [Channel] {
        LiveCatalog.isVisible(channels, preferences: preferences)
    }

    // MARK: - Groups and selection

    public var selectedSection: LiveLibrary.Group? {
        if selectedSectionID == Self.overviewSectionID { return overview }
        return sections.first { $0.id == selectedSectionID }
    }

    /// What is in the list: the hits when searching, otherwise the selected group — **in
    /// the order of its sections and without the shortcuts above** (B9). The player
    /// switches onward from it; a channel from "Recently watched" would otherwise appear in it twice.
    public var shownChannels: [Channel] {
        isSearching ? hits : LiveOutline.mainList(segments)
    }

    public func select(_ sectionID: String) {
        defer { fillGuidesFromStore() }
        guard exists(sectionID) else { return }

        // A selected group ends the search. Without it the tab of the new
        // group would stand highlighted, its count in the header — and in the list still the
        // hits of the search, because ``shownChannels`` shows these while searching. The choice
        // would visibly have no effect, and from the sidebar that looks
        // like an entry that does nothing.
        if isSearching {
            term = ""
            runSearch()
        }

        selectedSectionID = sectionID
        outline()
        // A new group means a new first channel. Otherwise the board on the right would keep showing
        // the channel you left in the previous group.
        focus(selectedSection?.channels.first)

        // **And its program with it.** This line was missing, and a
        // finding hung on it that looked like a coincidence (2026-08-08: "on first opening,
        // the contents are not there yet; go in and out once, then everything is there").
        // The stock was only queried when the catalog was rebuilt — not on
        // a group switch. Whoever opens the app lands in their last group via the
        // remembered name, that is, exactly on this path:
        // the list was there, but without shows. Only the detour through
        // playback rebuilt the catalog — and then everything was there.
        fillGuidesFromStore()
    }

    /// Selects a group by its name — the path from the sidebar.
    ///
    /// For groups, identifier and name are the same; the redirection is still here
    /// so that the sidebar does not need to know anything about identifiers.
    public func selectGroup(named name: String) {
        select(name)
    }

    /// Puts the focus on the most recently watched channel — together with its group,
    /// if that is not currently shown (user request F-008: when a channel such as
    /// Kordel 1 is playing and the user goes to the preview, the cursor should be on Kordel 1).
    /// Returns whether the channel was found.
    @discardableResult
    public func focusRemembered(_ channelID: String?) -> Bool {
        guard let channelID, let channel = stock.first(where: { $0.id == channelID }) else {
            return false
        }
        if !shownChannels.contains(where: { $0.id == channel.id }) {
            if channel.isFavorite, sections.contains(where: { $0.id == Self.favoritesSectionID }) {
                select(Self.favoritesSectionID)
            } else if let group = channel.group {
                selectGroup(named: group)
            }
        }
        guard shownChannels.contains(where: { $0.id == channel.id }) else { return false }
        focus(channel)
        return true
    }

    /// The group names for the sidebar — without favorites and without the channels
    /// with no group. Both have no name to show there.
    public var groupNames: [String] {
        sections.filter { $0.id != Self.favoritesSectionID && !$0.id.isEmpty }.map(\.name)
    }

    /// What the group list shows: "All" first, then favorites and groups.
    public var groupRows: [LiveLibrary.Group] {
        (overview.map { [$0] } ?? []) + sections
    }

    /// Whether channels were loaded at all but none of them is visible.
    ///
    /// The difference matters for the message: "no channel list stored" sends
    /// to the settings, "everything hidden" to the filter. A shared
    /// message would send half of the users to the wrong place.
    public var isEverythingHidden: Bool {
        !stock.isEmpty && sections.isEmpty
    }

    // MARK: - Search

    /// Whether a search is currently running — then the list shows something different.
    public var isSearching: Bool { Self.normalized(term) != nil }

    public func search(_ text: String) {
        let wasSearching = isSearching
        term = text
        runSearch()
        if isSearching != wasSearching { outline() }
    }

    /// The entered text as a search key, or `nil` if it is too short —
    /// ``Flows/LiveCatalog/searchKey(_:)``.
    static func normalized(_ term: String) -> String? {
        LiveCatalog.searchKey(term)
    }

    /// Searches the whole filtered catalog and not the selected group —
    /// ``Flows/LiveCatalog/search(_:in:)``.
    private func runSearch() {
        let match = LiveCatalog.search(term, in: index)
        hitCount = match?.count ?? 0
        hits = match?.channels ?? []
    }

    // MARK: - Dwelling and programme

    /// A different channel is in focus — the clock starts over.
    public func focus(_ channel: Channel?) {
        pending?.cancel()
        pending = nil
        focused = channel

        guard let channel else { return }

        // Without a program identifier there is nothing to fetch from the provider: of 5389 channels
        // 980 carry one. For the other 4409 the fetch would be a request whose
        // answer is certainly empty — with a single allowed connection
        // that is no small matter.
        guard let epgID = channel.epgID, !epgID.isEmpty else {
            guides[channel.id] = []
            return
        }

        // Already asked: the empty result counts too. Otherwise every visit to
        // the same row asks again for a program that does not exist.
        guard guides[channel.id] == nil else { return }

        pending = Task { [weak self] in
            guard let self else { return }
            await self.wait(Self.dwell)

            // Cancelled means: the focus has moved on. The query must then
            // no longer go out — otherwise browsing produces exactly the
            // flood the dwell time is meant to prevent.
            guard !Task.isCancelled else { return }

            let listing = await self.loadGuide(channel)

            // Second check, because the query goes over the network: in this time
            // the focus can be twenty channels further.
            guard !Task.isCancelled else { return }
            self.guides[channel.id] = listing
        }
    }

    /// Stops the fetch. Needed when leaving the view, otherwise a request goes out
    /// for a view nobody sees any more.
    public func stop() {
        pending?.cancel()
        pending = nil
    }

    public func guide(for channel: Channel) -> Guide {
        guard let listing = guides[channel.id] else { return .pending }
        return listing.isEmpty ? .none : .listing(listing)
    }

    /// What is currently on the channel, if known.
    public func runningProgramme(for channel: Channel, at date: Date = Date()) -> Programme? {
        guard case .listing(let listing) = guide(for: channel) else { return nil }
        return listing.first { $0.isRunning(at: date) }
    }

    /// The remaining time of the current show in minutes, rounded up —
    /// ``Flows/LiveCatalog/remainingMinutes(_:um:)``, the same calculation as on the phone.
    public static func remainingMinutes(of programs: Programme?, at date: Date) -> Int? {
        LiveCatalog.remainingMinutes(programs, um: date)
    }

    // MARK: - Favorites

    /// Sets or removes a favorite.
    ///
    /// **All entries with the same favorite identifier move along** — since
    /// 2026-08-15 that means: the same version under a different spelling, not
    /// every quality tier any more (``PlaylistStore/favoriteKey(for:)``). If
    /// only the selected entry were switched here, the list would show a star
    /// and an entry of the same name none, until the next load — that looks
    /// like a lost favorite.
    public func toggleFavorite(_ channel: Channel) {
        let isFavorite = !channel.isFavorite
        persistFavorite(channel, isFavorite)

        LiveCatalog.setFavorite(isFavorite, for: channel, in: &stock)

        rebuild()
        // The channel in the board on the right is a copy and knows nothing of the
        // change — without updating it the button would keep its
        // label although it has taken effect.
        if let focused, focused.id == channel.id {
            self.focused = stock.first { $0.id == focused.id } ?? focused
        }
    }

    // MARK: - Playback

    /// The playback target for a channel.
    ///
    /// With ``PlaybackTarget/Kind/live``, and with that everything else is decided:
    /// ``PlaybackTarget/isSeekable`` is false and ``PlaybackTarget/tracksProgress``
    /// too. That is why none of these values is set here individually — they could be
    /// set contradictorily.
    public func target(for channel: Channel, at date: Date = Date()) -> PlaybackTarget {
        Self.target(for: channel, running: runningProgramme(for: channel, at: date))
    }

    public static func target(for channel: Channel, running: Programme? = nil) -> PlaybackTarget {
        // **Channels that have stayed blind once go raw right away** (see
        // ``RawStreamMemory``): the first time the app detects it itself and
        // switches over, the second time the picture is there immediately.
        let url = Self.streamURL(for: channel)
        return PlaybackTarget(
            // No identifier: there is nothing to remember for a running channel.
            // A progress of 40 percent on a channel would be meaningless, and on
            // the Home screen it would appear under "Continue Watching".
            itemID: nil,
            title: channel.cleanName,
            subtitle: running?.title,
            url: url,
            decision: decision(forURL: url),
            kind: .live
        )
    }

    /// The address under which a channel is fetched.
    ///
    /// **Two sources of information, and the second is new** (AP3 · V5, 2026-09-02):
    ///
    /// 1. ``RawStreamMemory`` knows **this** channel — it has stayed
    ///    blind once.
    /// 2. ``RawStreamRule`` knows **its kind** — remote end and trait.
    ///
    /// Without the second, every unknown channel started twice: the memo note
    /// remembers addresses and can therefore only help when it is too late.
    /// In the test run it grew from 104 to 155 channels — 51 times eight seconds of
    /// black and 51 surplus connections against an account with **one**
    /// connection slot.
    ///
    /// **Shared with the phone** (AP58 R4, ``Core/ChannelAddressChoice``); the store is open only
    /// for the check, so that both devices have guarded the same half.
    static func streamURL(
        for channel: Channel, store: any KeyValueStore = SecureStore()
    ) -> URL {
        ChannelAddressChoice.address(forItem: channel.streamURL, name: channel.name, store: store)
    }

    /// Engine and delivery path for a channel.
    ///
    /// **Without ``StreamQuality``, explicitly.** With Jellyfin the server transcodes
    /// down when the line is not enough; an IPTV provider cannot do that —
    /// it delivers the channel as it has it, measured at about 17 Mbit/s. Passing a
    /// limit would mean setting ``PlaybackDecision/delivery`` to `transcode` and
    /// thereby ordering a conversion nobody performs: the
    /// channel would still run at the full rate, only a
    /// limit that has no effect would be noted in the decision. That is worse than no limit, because
    /// it points in the wrong direction when hunting for the stutter.
    static func decision(for channel: Channel) -> PlaybackDecision {
        decision(forURL: streamURL(for: channel))
    }

    /// **The Live engine from the diagnosis** (2026-09-03): two paths for channels, and which
    /// one carries is decided by the TV — see ``LiveEngineChoice``. The rule itself lives
    /// shared in ``Core/ChannelAddressChoice/decision(forItem:canDecodeHEVC:motor:)``; HEVC and
    /// engine are open only for the check.
    static func decision(
        forURL url: URL, canDecodeHEVC: Bool = DeviceCodecs.hasHEVC,
        motor: LiveEngineChoice = LiveEngineChoice.load(from: SecureStore())
    ) -> PlaybackDecision {
        ChannelAddressChoice.decision(forItem: url, canDecodeHEVC: canDecodeHEVC, motor: motor)
    }
}
