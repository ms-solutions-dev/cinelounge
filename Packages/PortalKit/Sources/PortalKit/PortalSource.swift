import Core
import Foundation

/// The portals as a ``ContentSource``.
///
/// **The third source the contract was built for.** The same library view that shows
/// Jellyfin and the provider catalog thereby shows Serieshub, Animehub and whatever
/// else sits in the bridge's folder — without a line of its own presentation.
///
/// Four peculiarities compared with the media server:
///
/// 1. **Entry points are libraries.** Each portal reports through `load()` which rows it
///    has — "New Episodes", "All Series", "Calendar". A fourth portal costs no line of
///    Swift.
/// 2. **The state lives at the bridge**, not in the app and not at a third-party server:
///    behind a portal there is often nobody who remembers where you were. Side
///    benefit — other clients could share the same state.
/// 3. **Images are foreign addresses.** By agreement they sit in `posterID`, and
///    ``imageURL`` passes them through instead of building them.
/// 4. **A portal script has no call for a single entry.** It can only do lists — hence
///    ``item(id:)`` works from what has already been fetched, and as a fallback via the
///    state and the portal search. See there.
public actor PortalSource: PageSource {

    public nonisolated let displayName = "Portale"

    /// A host delivers a finished file, not a stream from a requested position.
    /// The player seeks itself via partial requests — the same case as with the
    /// provider catalog, and explicitly provided for in the contract.
    public nonisolated var canStartAtOffset: Bool { false }

    /// **The bridge keeps it.** It knows the progress per title and returns it in the
    /// fact sheet; keeping it a second time here would mean Home and the detail page show
    /// different numbers, depending on who answered first.
    public nonisolated var tracksStateItself: Bool { true }

    private let bridge: PortalBridge

    /// Where the bridge is — for the settings.
    ///
    /// **To be shown even when it does not answer.** The status sits at the top of the
    /// settings, and "not reachable" without the address would be information nobody can
    /// do anything with.
    public nonisolated var bridgeAddress: String { bridge.basis.absoluteString }

    /// The profile this source names on every request (`X-CL-Profile`) — `nil` if there is
    /// none.
    ///
    /// **Readable because the wrapper has to know whether it is still correct** (thread G,
    /// 2026-09-25): the header is fixed when the bridge is built. If a profile switch changes
    /// it in the Keychain, the standing source keeps asking with the old one.
    public nonisolated var profileHeader: String? { bridge.profile }

    /// The attribute this source asks with — **since it is stored per profile, it changes
    /// on a profile switch**, and the standing source kept asking with the old one
    /// (test Apple TV, 2026-09-28).
    public nonisolated var trait: String? { bridge.trait }

    /// What has already passed over the table.
    ///
    /// **Not convenience but the regular path:** no portal script can do "give me this one entry"
    /// — it reads lists. The detail page, however, first asks ``item(id:)`` and right after
    /// that ``children(of:)``. What ``items(in:)`` and ``children(of:)`` fetched therefore
    /// stays here. Anything not found here costs a call to the state — see ``item(id:)``.
    private var seenItems: [String: MediaItem] = [:]

    /// Season or episode → the identifier of its series — see ``children(of:)``.
    private var seriesOf: [String: String] = [:]

    /// The portals as the service last reported them.
    private var portals: [BridgeReply.Portal] = []

    /// The same list for ``portalRows()`` in the neighbouring slice.
    ///
    /// **Do not make `portals` public:** these are the service's response models, and they
    /// should not leave the package — they speak the bridge's language, and anyone who reads
    /// them outside builds themselves onto exactly that language.
    var reportedPortals: [BridgeReply.Portal] { portals }

    /// The subtitle tracks of the most recently resolved stream.
    ///
    /// **Why here and not in the return value (stage 4, 2026-09-12):** the subtitles come
    /// from the same response as the video address, and the player fetches the video address
    /// via ``streamURL(for:decision:)`` — a contract method that returns a `URL` and nothing
    /// else. Three paths in the TV app call it (initial start, seek, preview), and rebuilding
    /// each one separately would mean making the same decision three times.
    ///
    /// **So the source remembers what it just answered**, and the player asks for it — the
    /// same pattern as ``LayerSlot``. The price is a side effect in
    /// ``stream(forItem:source:)``; the gain is that **every** current and future call path gets
    /// it without knowing.
    ///
    /// **Empty means "this portal supplies none", not "not loaded yet"** — it is set on
    /// every resolution, also to empty.
    public private(set) var lastSubtitles: [PortalSubtitle] = []

    /// The source that the last resolution actually uses — and whether the server deviated
    /// from the requested one to get it.
    ///
    /// **The same pattern as ``lastSubtitles``**, for the same reason:
    /// `stream(forItem:source:)` returns a tuple that two apps depend on. Since 2026-09-16 every
    /// resolution sends the title's address along, and the server goes through the other
    /// sources if the requested one does not hold up — the source choice in the player should
    /// then mark the one that is playing. `nil` for the old bridge, which does not say.
    public private(set) var lastSource: String?
    public private(set) var lastSourceSwitched = false
    /// Until when the most recently resolved address is valid — `nil` if the server names no
    /// deadline.
    ///
    /// **For the TV** (AP77): it starts via `streamURL` and dropped the deadline; the phone
    /// has carried it in its source sheet since AP58. An address from a portal source is valid
    /// for 300 s — anyone who resumes after a pause needs a new one.
    public private(set) var lastValidUntil: Date?

    /// The most recently fetched levels including failures — see ``LayerSlot``.
    ///
    /// **One fetch, two readers.** The same level is needed twice in quick succession: the
    /// view first has to know **whether** the level contains folders or titles, and then
    /// shows the titles. Without this slot that would mean, for "All Series", fetching and
    /// interpreting 10,862 entries twice — or running into the server's same 20 s deadline
    /// twice.
    private var layers = LayerSlot()

    /// Listeners for silently swapped lists.
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Who is actually being talked to — **asked once, then remembered.**
    ///
    /// `nil` as long as no request has run.
    private var probed: PortalBridge?

    /// What the server said about itself, if one answered.
    private var reportedVersion: ServerVersion?

    public init(bridge: PortalBridge) {
        self.bridge = bridge
    }

    // ── Who is being talked to ──────────────────────────────────────────────

    /// The connection that is used for asking — in the language of whoever answers.
    ///
    /// **Here and not at creation (2026-09-12).** The question "bridge or server" is answered
    /// by a request, and the two places where a ``PortalSource`` is created are **not**
    /// asynchronous in either app: on the TV `MainView.setPortalSource()` builds it when
    /// the view is set up, on the phone `SourceAssembly.portalSource()`. Carrying the probe
    /// there would mean making two call chains asynchronous to answer a question that belongs
    /// here.
    ///
    /// **Once per source.** The answer does not change as long as the address is the same —
    /// and if it does change, a new source is created anyway.
    ///
    /// **If the probe fails, the bridge applies.** That is not caution but the situation:
    /// whoever does not answer `/.well-known/cinelounge` with this information is the old
    /// bridge — and that is a perfectly usable service. If nothing answers at all, the next
    /// request fails anyway, and **then** a reason is attached that the viewer can do
    /// something with.
    private func service() async -> PortalBridge {
        if let probed { return probed }

        // **A failed attempt is NOT remembered** (finding of 2026-09-12, on device). The
        // assignment used to sit under both branches: if the probe failed a single time — a
        // network that is not up yet at startup, an address that is just changing —, from then
        // on the bridge applied permanently. The app then asked the CineLounge server for
        // `/portals`, got a 404 and showed "The portals bridge does not answer". The network log
        // showed `url: …:8100/portals` twice and **not a single** `/.well-known/cinelounge`: the
        // mistake was not the probe but its memory.
        //
        // **Only an answer is remembered, never an outage.** The next call asks again, and so
        // the source heals itself within one frame build — instead of speaking wrongly until the
        // app restarts.
        guard let (dialect, version) = try? await ServerVersion.probe(bridge.basis) else {
            Diagnostics.network.info(
                "Portal service \(self.bridge.basis.absoluteString): cannot be probed, asked as a bridge this time — asked again next time"
            )
            return bridge
        }
        reportedVersion = version
        let found = PortalBridge(
            basis: bridge.basis, dialect: dialect, trait: bridge.trait,
            profile: bridge.profile)
        probed = found
        // **One line in the log, and it paid for itself immediately on 2026-09-12** On the device it
        // said "The portals bridge does not answer", in the log `Portals: Not Found` — a 404 and
        // not a network failure. That a 404 here means "I take the service for the bridge and ask
        // `/portals`" was not visible from outside; every troubleshooting session started with
        // guessing. Which dialect applies and where it comes from is the first question for
        // anything that goes wrong afterwards.
        Diagnostics.network.info(
            "Portal service \(found.basis.absoluteString): \(found.dialect.rawValue), version \(self.reportedVersion?.version ?? "—"), credential \(found.trait == nil ? "missing" : "present")"
        )
        return found
    }

    /// What the service says about itself — for the settings.
    ///
    /// Triggers the probe if it has not run yet: at this point that is intended, because the
    /// settings screen asks exactly for that.
    public func version() async -> ServerVersion? {
        _ = await service()
        return reportedVersion
    }

    /// Which of the two services is being talked to.
    public func dialect() async -> PortalDialect {
        await service().dialect
    }

    // ── Bestand ──────────────────────────────────────────────────────────────

    /// Which portals the bridge offers — and which are broken.
    ///
    /// A broken portal is **delivered along**, not concealed: otherwise it is simply missing,
    /// and people search the app for something the server has long since recognised as
    /// broken.
    ///
    /// `state` is the service's raw state word — the apps' portal state is derived from it
    /// and not from `reason` (review 2026-09-27, portals B2).
    public func availablePortals() async throws -> [(
        id: String, name: String, ready: Bool, state: String, reason: String?
    )] {
        let reply: BridgeReply.Portals = try await service().fetch("portale")
        portals = reply.portals
        return reply.portals.map { ($0.id, $0.name, $0.isReady, $0.state, $0.reason) }
    }

    public func libraries() async throws -> [Library] {
        let reply: BridgeReply.Portals = try await service().fetch("portale")
        portals = reply.portals

        var found: [Library] = []
        var failed: [String] = []
        // **All menus at once** (AP70, 2026-10-11): eight portals one after another were, on the
        // TV, "portale took 3 s for libraries" (F-017) — and four times per start. The order of
        // the portals is kept, via the index.
        //
        // A portal that fails at the menu does not drag the others down — **but it is written
        // down.** Until 2026-09-12 a `try?` swallowed every reason, and Home reported "0 levels
        // reported" without a word about it.
        let ready = reply.portals.filter(\.isReady)
        var results: [(Int, Result<[Library], any Error>)] = []
        await withTaskGroup(of: (Int, Result<[Library], any Error>).self) { group in
            for (index, portal) in ready.enumerated() {
                group.addTask {
                    do {
                        let menu: BridgeReply.Menu = try await self.service().fetch("p/\(portal.id)/menu")
                        return (
                            index,
                            .success(
                                menu.entries.map { entry in
                                    Library(
                                        id: PortalLibraryID(portal: portal.id, entry: entry.id).identifier,
                                        name: entry.name,
                                        kind: .portalLevel,
                                        itemCount: entry.count)
                                })
                        )
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await result in group { results.append(result) }
        }
        for (index, result) in results.sorted(by: { $0.0 < $1.0 }) {
            switch result {
            case .success(let layers): found += layers
            case .failure(let error): failed.append("\(ready[index].id): \(error)")
            }
        }
        Diagnostics.network.info(
            """
            Portal levels: \(reply.portals.count) portals,             \(reply.portals.filter(\.isReady).count) ready, \(found.count) levels            \(failed.isEmpty ? "" : " — without menu: " + failed.joined(separator: "; "))
            """)
        return found
    }

    /// The **titles** of a level — without section headings.
    ///
    /// The contract promises entries, and a section heading is not one: in a poster grid
    /// "--- Insider Tips ---" would appear as a tile without an image. Anyone who needs the
    /// structure takes ``level(_:)`` — the folder list shows it as a heading.
    public func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
        try await page(in: library, filter: filter).items
    }

    /// One page of a level's titles — **sorted by the server, across all pages.**
    ///
    /// **The owner's requirement (2026-09-30, AP60):** sorted by rating, no 6 may appear on
    /// page 1 before an 8 from page 3. Sorting on the device meant exactly that, because until
    /// then only page 1 arrived. Title and rating therefore go to the CL-Server; it collects
    /// the level completely once and delivers it in pages. Until it is finished, this function
    /// polls and reports via `progress` how far along it is. The natural order stays as it
    /// was: page by page from the provider.
    /// - Parameter weiter: The marker from the previous page, unchanged.
    public func page(
        in library: Library.ID, filter: ItemFilter, next: String? = nil,
        progress: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> PageChunk {
        let sorting = PortalSorting(filter)
        let found = try await sortedLevel(
            library, next: next, sorting: sorting, progress: progress)
        let title = found.items.filter { $0.kind != .separator }
        // Already sorted: only search term and kind apply here.
        let ordered = sorting == nil ? filter : filter.withoutSorting
        return PageChunk(items: Self.filtered(title, after: ordered), next: found.next)
    }

    /// A level, **sorted by the CL-Server** — and polled until it has collected it. Without
    /// sorting the same as ``level(_:next:sorting:)``.
    ///
    /// Shared by TV (``page(in:filter:next:progress:)``) and phone, so that both wait
    /// equally long and give up equally.
    public func sortedLevel(
        _ library: Library.ID, next: String? = nil, sorting: PortalSorting?,
        progress: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> PortalTier {
        var rounds = 0
        while true {
            let found = try await level(library, next: next, sorting: sorting)
            guard let done = found.preparedCount else { return found }
            await progress(done)
            rounds += 1
            if rounds > Self.preparationRounds { throw URLError(.timedOut) }
            try await Task.sleep(for: Self.preparationInterval)
        }
    }

    /// How often a sorted level is polled before giving up — together with the interval six
    /// minutes, twice as long as the largest measured collection (900 entries, about three
    /// minutes fresh).
    static let preparationRounds = 180
    static let preparationInterval: Duration = .seconds(2)

    /// A level — from the slot if it has just been fetched.
    ///
    /// Unfiltered and unsorted: filtering and sorting happen separately in each reader, the
    /// fetch only once.
    /// - Parameter weiter: The marker of the next page, unchanged from
    ///   ``PortalTier/next``. **A follow-up page does not go through the slot** — neither
    ///   in nor out: the slot knows only the level's identifier, and that is the same for
    ///   page 1 and page 7. Anyone who put a follow-up page in would make the next fetch of
    ///   the level start at page 7.
    /// - Parameter sortierung: Title or rating, sorted across all pages by the CL-Server —
    ///   see ``page(in:filter:next:progress:)``. A sorted level does not go through the
    ///   slot, for the same reason as a follow-up page.
    public func level(
        _ library: Library.ID, next: String? = nil, sorting: PortalSorting? = nil
    ) async throws -> PortalTier {
        let isFirstPage = next == nil && sorting == nil
        if isFirstPage, let entry = layers.entry(forItem: library) {
            switch entry {
            case .level(let level): return level
            case .failure(let error): throw error
            }
        }
        guard let identifier = PortalLibraryID(library) else { return PortalTier(items: []) }

        let found: PortalTier
        do {
            found = try await fetch(identifier, next: next, sorting: sorting)
        } catch {
            // A cancellation is no verdict on the server — only an error from there is remembered.
            if isFirstPage, !(error is CancellationError) {
                layers.memorize(failure: error, forItem: library)
            }
            throw error
        }
        remember(found.items)
        // **Only the first page is remembered.** It is the one that makes up a level; storing a
        // follow-up page under the same identifier would make the next entry start in the middle
        // of the catalog.
        if isFirstPage { layers.memorize(found, forItem: library) }
        // **Anyone who goes deeper may change "Recently Used"** — the server remembers the opened
        // page. The remembered root would otherwise show the old order for twenty seconds,
        // exactly on the way back.
        if isFirstPage, !identifier.entry.isEmpty {
            layers.forget(PortalLibraryID(portal: identifier.portal, entry: "").identifier)
        }
        return found
    }

    /// The fetch of a level from the CL-Server — root or list.
    private func fetch(
        _ identifier: PortalLibraryID, next: String?, sorting: PortalSorting?
    ) async throws -> PortalTier {
        if identifier.entry.isEmpty {
            // **The root is a level like any other** (technical report 2026-08-27). Before, above the
            // entry points there was a separate area with a kind switcher and a genre window
            // (``VODArea``) — both questions that a portal does not know. And because all portals
            // shared one branch there, the view identity did not change when jumping from Serieshub
            // to Animehub: the area kept its state, and the old portal stayed on the right.
            let menu: BridgeReply.Menu = try await service().fetch("p/\(identifier.portal)/menu")
            return PortalTier(
                items: Self.entriesAsFolders(portal: identifier.portal, menu.entries))
        } else {
            // The input goes along only if there is one: an empty `input=` is the same as none for
            // the bridge, but it would be in every address and make the log unreadable.
            var asks = ["einstieg": identifier.entry]
            if !identifier.input.isEmpty { asks["eingabe"] = identifier.input }
            if let next { asks["weiter"] = next }
            if let sorting {
                asks["sortierung"] = sorting.kind.rawValue
                asks["richtung"] = sorting.descending ? "desc" : "asc"
            }
            let page: BridgeReply.Page = try await service().fetch(
                "p/\(identifier.portal)/liste", asks
            )
            return PortalTier(
                items: page.items.map { $0.asMediaItem(portal: identifier.portal) },
                hint: page.hint,
                query: page.needsInput,
                total: page.total,
                next: page.next,
                suggestion: page.inputSuggestion,
                followUpQuestion: page.followUpQuestion,
                preparedCount: page.preparation?.done,
                truncated: page.truncated ?? false
            )
        }
    }

    /// Which portals address a channel interface.
    ///
    /// **Only for the tie-break in the search.** If the same title is in a media library and at
    /// a portal script, the media library goes first; that is a statement about origin and not about
    /// quality. Empty as long as the portal list has not been asked for — then only the title
    /// match decides, and that is the less harmful order.
    var officialPortals: Set<String> {
        Set(portals.filter { $0.kind == "native" || $0.kind == "eigen" }.map(\.id))
    }

    /// The identifier of a portal's root level.
    ///
    /// An empty entry point means "the portal itself" — the same identifier form as every level
    /// below it, so that the navigation path needs no special case.
    public nonisolated static func rootID(portal: String) -> Library.ID {
        PortalLibraryID(portal: portal, entry: "").identifier
    }

    /// The same level, but with a search term — a **separate** library.
    ///
    /// It has to be a separate one because two readers use the same identifier: the folder list
    /// and the title grid. The full reasoning is at ``PortalLibraryID/input``.
    public nonisolated static func searchedID(
        forItem library: Library.ID, input: String
    )
        -> Library.ID?
    {
        guard let identifier = PortalLibraryID(library), !identifier.entry.isEmpty else { return nil }
        return PortalLibraryID(
            portal: identifier.portal, entry: identifier.entry, input: input
        ).identifier
    }

    /// A portal's entry points as folders.
    ///
    /// **An entry point is a folder and not a title**, and the whole way back depends on that:
    /// ``levelID(forItem:)`` reads the level below from the identifier, and the shared navigation
    /// path has carried the root as well ever since. The key stays empty — it serves for
    /// remembering progress, and a folder has none.
    nonisolated static func entriesAsFolders(
        portal: String, _ entries: [BridgeReply.EntryPoint]
    ) -> [MediaItem] {
        func folder(_ entry: BridgeReply.EntryPoint) -> MediaItem {
            MediaItem(
                id: PortalItemID(portal: portal, key: "", address: entry.id).identifier,
                kind: .folder,
                title: entry.name
            )
        }
        func separator(_ tag: String, _ title: String) -> MediaItem {
            MediaItem(
                id: PortalItemID(portal: portal, key: "", address: "trenner:" + tag).identifier,
                kind: .separator,
                title: title
            )
        }
        // **Three groups, as the server names them** (AP77, 2026-10-11): what the portal itself
        // keeps in areas (Vault, Favorite videos, collections) comes under "My Areas", its buttons
        // (Clear, Sort, Refresh) under "Tools", everything else stays as it came. A root with
        // neither stays without a separator.
        let recent = entries.filter { $0.group == "recent" }
        let mine = entries.filter { $0.group == "mine" }
        let tools = entries.filter { $0.group == "tools" }
        let grouped: Set<String> = ["recent", "mine", "tools"]
        var result: [MediaItem] = []
        // "Recently Used" first: the pages this person opened most recently, newest first, at most
        // five (the server remembers ten). Nothing disappears, the list follows below.
        if !recent.isEmpty {
            result.append(separator("zuletzt", PortalGroups.recentlyUsed))
            result.append(contentsOf: recent.map(folder))
            result.append(separator("alle", PortalGroups.all))
        }
        result.append(contentsOf: entries.filter { !grouped.contains($0.group) }.map(folder))
        if !mine.isEmpty {
            result.append(separator("meine", PortalGroups.myAreas))
            result.append(contentsOf: mine.map(folder))
        }
        if !tools.isEmpty {
            result.append(separator("werkzeuge", PortalGroups.tools))
            result.append(contentsOf: tools.map(folder))
        }
        return result
    }

    /// Which rows of a level stand under "Recently Used" — those between its separator and the
    /// "All" separator, in the order of ``entriesAsFolders(portal:_:)``.
    ///
    /// **From the position and not from a field on the entry** (2026-10-12): the long press
    /// "Remove from Recently Used" applies only there, and the group already sits in the list
    /// as a separator. A second attribute next to it could deviate from it.
    public nonisolated static func recentlyUsed(in identifiers: [String]) -> Set<String> {
        var contained = false
        var result: Set<String> = []
        for identifier in identifiers {
            if let part = PortalItemID(identifier), part.address.hasPrefix("trenner:") {
                if contained { break }
                contained = part.address == "trenner:zuletzt"
                continue
            }
            if contained { result.insert(identifier) }
        }
        return result
    }

    /// The identifier of the level behind an entry — or `nil` if it has none.
    ///
    /// **The one place where "leads deeper" is decided.** From outside, a folder is nothing
    /// other than another library: its address takes the place of the entry point. A title, by
    /// contrast, leads to its detail page, and `nil` comes back here for it.
    ///
    /// The check on the kind is **here** and not in the view: otherwise there would be two
    /// versions of the same decision, and one would stay put when the other changes.
    public nonisolated static func levelID(forItem entry: MediaItem) -> Library.ID? {
        guard entry.kind == .folder, let identifier = PortalItemID(entry.id) else { return nil }
        return PortalLibraryID(portal: identifier.portal, entry: identifier.address).identifier
    }

    /// Searching and sorting happen here, not at the portal.
    ///
    /// The portal scripts know no sorting other than the one they deliver anyway, and laying a search
    /// term over an already fetched list costs nothing. The **portal search** (`/search`) is
    /// something else: it asks the site, not the list — for that ``search(text:)``.
    static func filtered(_ items: [MediaItem], after filter: ItemFilter) -> [MediaItem] {
        var result = items

        if let word = filter.searchTerm?.trimmingCharacters(in: .whitespaces), !word.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(word) }
        }
        if !filter.kinds.isEmpty {
            result = result.filter { filter.kinds.contains($0.kind) }
        }

        switch filter.sortBy {
        case .title:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !filter.ascending { result.reverse() }
        case .rating:
            // **The direction applies here too** (2026-09-13). Before, the best was always on top and
            // `ascending` was ignored — the second press on "Rating" was thus a button without effect.
            // The same contract as with the media server: `false` means best first. **Unrated items
            // stand at the end, in both directions** — without a rating a title is not the worst, and
            // the bridge does not deliver one at all for some portals (measured: Animehub 43 of 45,
            // Serieshub and ARD 0).
            let hasRatings = result.filter { $0.ratings.community != nil }
                .sorted { $0.ratings.community! < $1.ratings.community! }
            let unrated = result.filter { $0.ratings.community == nil }
            result = (filter.ascending ? hasRatings : hasRatings.reversed()) + unrated
        case .dateAdded, .dateCreated, .natural:
            // A portal script does not give out a recording date. Its own order is exactly the one wanted for
            // "New Episodes" — re-sorting it would make it worse, not better. For `.natural` that is
            // the whole promise. **And the direction stays out:** a list that is called "as delivered"
            // has no reverse.
            break
        }
        if let limit = filter.limit {
            result = Array(result.prefix(limit))
        }
        return result
    }

    /// All episodes of a series — **across its seasons.**
    ///
    /// **The finding of 2026-09-06, seen by the client on device:** "Bloufeit" opened with image, blurb
    /// and rating — and **without a single episode**. The bridge delivered three seasons in
    /// 10 ms; nobody had asked. `ContentSource` gives an empty default for this path, and
    /// `PortalSource` had never overridden it: the detail page bundles its seasons from the
    /// **episodes**, and without episodes there is no season.
    ///
    /// **Two levels and not one.** A portal script keeps the seasons under a series and only under a
    /// season the episodes; `children(of:)` therefore returns seasons where the detail page
    /// expects episodes. Portals without a season concept hand out their episodes directly —
    /// then everything is already in the first response.
    ///
    /// **The season number is set here and not read from the response.** An episode does not
    /// know from its own response which season it is in — only whoever fetched it knows. If a
    /// season lacks a number, its position counts.
    ///
    /// **Fetched side by side.** For "Bloufeit" these are three calls of 0.4 s each; one after
    /// another that would be one and a half seconds of waiting for a page that is already there.
    public func episodes(of seriesID: String) async throws -> [MediaItem] {
        let childItems = try await children(of: seriesID)
        let seasons = childItems.filter { $0.kind == .season }
        guard !seasons.isEmpty else {
            // **A portal without a season concept.** Then the children are already the episodes, and
            // they all belong in one season — the detail page needs a number.
            return childItems.filter { $0.kind == .episode }.map { episodeItem in
                var using = episodeItem
                using.seasonNumber = 1
                return using
            }
        }

        let collected = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (slot, seasonItem) in seasons.enumerated() {
                let number = seasonItem.seasonNumber ?? (slot + 1)
                group.addTask { [self] in
                    let episodes = (try? await children(of: seasonItem.id)) ?? []
                    return (
                        number,
                        episodes.filter { $0.kind == .episode }.map { episodeItem in
                            var using = episodeItem
                            using.seasonNumber = number
                            return using
                        }
                    )
                }
            }
            var all: [(Int, [MediaItem])] = []
            for await part in group { all.append(part) }
            return all
        }
        // **Restore the order of the seasons.** Whoever answers first has nothing to do with the
        // order in which the series is told.
        return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }

    /// The episode after this one — **what the player offers in the credits** (AP85 #82).
    ///
    /// **The finding (2026-11-09, Max on the TV):** series from the CL server never jumped
    /// to the next episode. `ContentSource` answers `nil` by default, and `PortalSource` had
    /// never overridden it — the same gap as `episodes(of:)` on 2026-09-06.
    ///
    /// **Built from the episode list and not from a server path of its own.** The server
    /// knows no "next"; the list in story order is already there, and the detail page fetches
    /// the same one. Across the season boundary on purpose: after S1E10 comes S2E1, as with
    /// Jellyfin.
    ///
    /// **The series comes from browsing or from the state.** Whoever came in via the detail
    /// page left it in `seriesOf`; whoever came from Continue Watching has it in the item.
    /// Without either there is nothing to offer — no guess.
    public func nextEpisode(after itemID: String) async throws -> MediaItem? {
        let known = seriesOf[itemID]
        let series: String?
        if let known { series = known } else { series = (try? await item(id: itemID))?.seriesID }
        guard let series else { return nil }
        return Self.episode(after: itemID, in: try await episodes(of: series))
    }

    /// The entry after `itemID` in an episode list in story order.
    ///
    /// **Matched by key, not by the whole identifier.** The identifier carries the portal's
    /// address, and the same episode can come with a different address from Continue Watching
    /// than from the season list; the key names the episode itself. The whole identifier
    /// still wins where it matches.
    nonisolated static func episode(after itemID: String, in episodes: [MediaItem]) -> MediaItem? {
        let key = PortalItemID(itemID)?.key
        let position =
            episodes.firstIndex { $0.id == itemID }
            ?? key.flatMap { wanted in
                wanted.isEmpty ? nil : episodes.firstIndex { PortalItemID($0.id)?.key == wanted }
            }
        guard let position, episodes.indices.contains(position + 1) else { return nil }
        return episodes[position + 1]
    }

    /// An entry — from the memo, and as a fallback from the **state**.
    ///
    /// **The memo first, and it remains the rule.** Every list stores here what it hands out;
    /// the jump from the list to the detail page therefore costs no call. **Every list that
    /// hands out entries must keep storing them** — whoever neglects it pays for every title
    /// with a request, and what was never touched is then no longer reachable at all. That is
    /// exactly what the finding of 2026-08-28 hung on: ``favorites()`` and ``resumable()`` stored
    /// nothing, and the TV showed the detail page's catch-all error.
    ///
    /// **The finding of 2026-09-07, seen by the client on device:** "Bloufeit" was on the "Continue
    /// Watching" shelf and led to an error screen — "This entry is not available". Via the
    /// portals tab the same title opened fine. The difference was the memo: the tab had loaded
    /// the list, the phone's history has no list behind it. It carries only the identifier.
    ///
    /// **A portal script has no call for a single title — the state does.** What once played, was
    /// marked as watched or was remembered is at the bridge with title, kind and image;
    /// `GET /state` hands out exactly that row, and ``BridgeReply/ProgressRow`` is already
    /// translated into a `MediaItem` for ``favorites()`` and ``resumable()`` anyway. That makes
    /// every title the viewer has touched reachable — and those are exactly the ones that show
    /// up without a list behind them: history, favorites, header area.
    ///
    /// **The state knows only what was touched — hence a third path.** Measured on 2026-09-07 in
    /// the simulator: the **episode** `serieshub:1-mebik:` resolved because it had
    /// played once; the **series** `serieshub:bloufeit:` did not, because nobody ever started
    /// it. But it is exactly the target as soon as "Continue Watching" leads from the episode to
    /// the series. So lastly the **portal search** asks: its response carries title, kind,
    /// image, description, key and address — everything a detail page needs, in one call. See
    /// ``needle(_:)``.
    ///
    /// **The order is the statement.** Memo (nothing), state (the bridge, its own store,
    /// milliseconds), search (a third-party portal, tenths of seconds). Whoever moved the
    /// expensive stage forward would pay for every jump from the list to the detail page with a
    /// request to a site that runs a login.
    ///
    /// **What even the search does not find remains an error.** Building an empty placeholder
    /// would be worse than the refusal — the detail page would show a title without content,
    /// and nobody would know why.
    ///
    /// **A folder does not even ask.** Its key is empty; it serves for remembering progress, and
    /// a folder has none. Both ways back hang on the key, and without it their answer is already
    /// settled.
    ///
    /// **It is additionally stored under the requested identifier.** The response brings its
    /// own; if it deviated, the next call would ask a second time.
    public func item(id: String) async throws -> MediaItem {
        if let known = seenItems[id] { return known }
        guard let identifier = PortalItemID(id), !identifier.key.isEmpty else {
            throw Self.isUnavailable
        }
        let row: BridgeReply.ProgressRow? = try? await service().fetch(
            "stand", ["schluessel": identifier.key])
        if let row { return stored(row.asMediaItem(), under: id) }
        if let found = await needle(identifier) { return stored(found, under: id) }
        throw Self.isUnavailable
    }

    /// The refusal of ``item(id:)`` — **formulated once.**
    ///
    /// It stands at three exits of the same path; copied three times it would drift apart at the
    /// first rework, and the viewer would read something different about the same situation
    /// depending on the exit.
    ///
    /// **With a code and not as a sentence** (review 2026-09-27, design B2): a fixed German text
    /// would otherwise appear in every language. The app looks the sentence up
    /// (`error.portal.no_item` in `WordingKit`). The code is assembled so that `scripts/strings.py`
    /// does not read it as a language key.
    private static var isUnavailable: PortalBridge.TestError {
        .cancelled(status: 404, code: "portal" + ".no_item", values: [:])
    }

    /// Remembers the found entry — **under its own identifier and under the requested one.**
    ///
    /// Both are almost always the same. Almost: a portal may write its address differently
    /// between two responses, and then the next call would fall back onto the expensive path —
    /// for an entry that is long since there.
    private func stored(_ piece: MediaItem, under id: String) -> MediaItem {
        remember([piece])
        seenItems[id] = piece
        return piece
    }

    /// Find the entry via the **portal search** — the last path and the only one that costs a
    /// third-party portal.
    ///
    /// **Only that one portal is asked.** ``search(text:)`` goes over all at once; here it is
    /// known which one is meant, and `serieshub.example` runs a login — asking two uninvolved
    /// portals along would be traffic for nothing.
    ///
    /// **The hit is matched by the key, not by the name.** A search for "Bloufeit" can find three
    /// series; which one is meant is told only by the key that the bridge itself assigned. If
    /// none matches, `nil` comes back — then it stays at the refusal, and nobody lands on the
    /// wrong title.
    ///
    /// **The whole response is remembered.** It is there anyway, and whoever asks for a title
    /// from the same search gets it without a second call.
    private func needle(_ identifier: PortalItemID) async -> MediaItem? {
        let searchTerm = Self.searchTerm(for: identifier)
        guard !searchTerm.isEmpty else { return nil }

        struct Reply: Decodable {
            /// Stored keys keep their original (German) names — renaming them would
            /// make data written by earlier versions unreadable (AP85 B4).
            private enum CodingKeys: String, CodingKey {
                case match = "treffer"
            }
            let match: [String: [BridgeReply.ContentEntryRecord]]
        }
        guard
            let reply: Reply = try? await service().fetch(
                "suche", ["q": searchTerm, "portal": identifier.portal])
        else { return nil }

        let match = (reply.match[identifier.portal] ?? []).map {
            $0.asMediaItem(portal: identifier.portal)
        }
        remember(match)
        return match.first { PortalItemID($0.id)?.key == identifier.key }
    }

    /// What is searched for — **from the key and not from the address.**
    ///
    /// The address belongs to the portal script, and each one writes it differently: Serieshub
    /// carries the name as `sName=`, Animehub as `TVShowTitle=`, the ARD Mediathek not at all —
    /// it is a bare API address. Anyone who searched there for a name would write three portals
    /// into a package that explicitly knows none.
    ///
    /// **The key, by contrast, belongs to the bridge.** It forms it from the title
    /// (`serieshub:bloufeit:`, `ard:club-der-einsamen-herzen:`); turning the dashes back into
    /// spaces gives the search term. Measured on 2026-09-07 against all three portals: "bloufeit"
    /// hits, "100 sleeping princes the kingdom of dreams" hits, "club der einsamen herzen" hits
    /// among forty responses.
    ///
    /// **It remains an approximation, and that is planned for.** "Wuweise'm Liatdouza" becomes
    /// `wuweise-m-liatdouza` and is not found again — the apostrophe is no longer in the key. A
    /// failure here costs nothing but the refusal that would exist without this path anyway;
    /// taking a hit at random would be the worse trade.
    static func searchTerm(for identifier: PortalItemID) -> String {
        var rest = Substring(identifier.key)
        if rest.hasPrefix("\(identifier.portal):") {
            rest = rest.dropFirst(identifier.portal.count + 1)
        }
        return rest.split(whereSeparator: { $0 == ":" || $0 == "-" || $0 == "_" })
            .joined(separator: " ")
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        guard let identifier = PortalItemID(itemID) else { return [] }
        let reply: BridgeReply.Children = try await service().fetch(
            "p/\(identifier.portal)/kinder", ["adresse": identifier.address]
        )
        let found = reply.items.map { $0.asMediaItem(portal: identifier.portal) }
        remember(found)
        // **Which series is above** (2026-10-01): seasons of a series and episodes of a season
        // carry it on. Reporting the state takes it along, so that "Details" from Continue Watching
        // leads to the series and not to a page with one episode.
        let series = seriesOf[itemID] ?? (seenItems[itemID]?.kind == .series ? itemID : nil)
        if let series {
            for item in found where item.kind == .season || item.kind == .episode {
                seriesOf[item.id] = series
            }
        }
        return found
    }

    /// Across all portals at once — one pass per portal.
    public func search(text: String) async throws -> [MediaItem] {
        struct Reply: Decodable {
            /// Stored keys keep their original (German) names — renaming them would
            /// make data written by earlier versions unreadable (AP85 B4).
            private enum CodingKeys: String, CodingKey {
                case match = "treffer"
            }

            let match: [String: [BridgeReply.ContentEntryRecord]]
        }
        let reply: Reply = try await service().fetch("suche", ["q": text])
        // **No longer portal-alphabetical** (finding 2026-09-12). Here stood
        // `sorted(by: { $0.key < $1.key })` and a concatenation — but a portal's name is no
        // statement about the quality of a hit. For "arrow", 3sat and ARD together deliver
        // sixty-five news snippets in which the word occurs somewhere; the series *Haubla* from
        // Serieshub stood behind them and thus out of sight. The order is by title match —
        // ``SearchRank``.
        let flattened = reply.match.sorted { $0.key < $1.key }
            .flatMap { portal, entries in
                entries.map { (portal: portal, piece: $0.asMediaItem(portal: portal)) }
            }
        let found = SearchRank.ordered(flattened, needle: text, official: officialPortals)
        remember(found)
        return found
    }

    // ── Stand ────────────────────────────────────────────────────────────────

    public func resumable(limit: Int) async throws -> [MediaItem] {
        let reply: BridgeReply.ContinueWatching = try await service().fetch(
            "weiterschauen", ["grenze": String(limit)]
        )
        let found = Self.only(
            reply.continueWatching.map { $0.asMediaItem() }, from: try await visiblePortals())
        remember(found)
        return found
    }

    public func favorites() async throws -> [MediaItem] {
        let reply: BridgeReply.Favorites = try await service().fetch("favoriten")
        let found = Self.only(
            reply.favorites.map { $0.asMediaItem() }, from: try await visiblePortals())
        remember(found)
        return found
    }

    /// "Continue Watching" as finished entries for the Top Shelf — **with the timestamp**, so
    /// that the extension can mix with Jellyfin and IPTV by "last watched".
    ///
    /// **The finding (2026-09-28):** the shelf was supposed to show what the profile watched
    /// last, regardless of where from. But the app contributed only its own state, and that
    /// knows only IPTV — the CL-Server's state lives at the server. The same visibility rule as
    /// in ``resumable(limit:)``: what the person does not currently see is not on the shelf
    /// either.
    ///
    /// **And the favorites, when the shelf shows them** (2026-09-29): whoever chose "Favorites"
    /// saw only those from Jellyfin — the watch list at the CL-Server never arrived.
    public func shelfContributions(
        mode: TopShelfMode = .resume, atMost: Int = 8
    ) async throws -> [TopShelfEntry] {
        let rows: [BridgeReply.ProgressRow]
        switch mode {
        case .resume:
            let reply: BridgeReply.ContinueWatching = try await service().fetch(
                "weiterschauen", ["grenze": String(atMost * 2)])
            rows = reply.continueWatching
        case .favorites:
            let reply: BridgeReply.Favorites = try await service().fetch("favoriten")
            rows = reply.favorites
        case .latest, .off:
            return []
        }
        let isVisible = try await visiblePortals()
        let entries = rows.compactMap { row -> TopShelfEntry? in
            guard isVisible.contains(row.portal), !row.title.isEmpty else { return nil }
            let identifier = PortalItemID(
                portal: row.portal, key: row.key, address: row.address
            ).identifier
            return TopShelfEntry(
                id: identifier, title: row.title,
                image: row.image.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                recent: row.changed.map(Date.init(timeIntervalSince1970:)))
        }
        return Array(entries.prefix(atMost))
    }

    /// The portals that the server **currently** shows this person.
    ///
    /// **The finding (test Apple TV, 2026-09-28):** "Continue Watching" contained titles from
    /// a portal that was switched off at the server. The server delivers a
    /// person's state and favorites unfiltered — everything they ever watched —, but the portal
    /// list already by switch and visibility. Up to this point a switched-off portal thus
    /// counted as switched off, just not for what had been started in it.
    ///
    /// **A fault does not hide a title (AP90, owner 2026-11-16).** Since AP90 the server names
    /// the portals the person may keep titles from in `permitted`; a broken one is in there
    /// although it is missing from the list. Without the field everything stays as before.
    private func visiblePortals() async throws -> Set<String> {
        let reply: BridgeReply.Portals = try await service().fetch("portale")
        portals = reply.portals
        return reply.keepsTitles
    }

    /// Only titles from these portals — **an identifier without a readable portal drops out.**
    /// Whoever cannot say where a title comes from cannot say either that it may be shown.
    nonisolated static func only(_ title: [MediaItem], from portals: Set<String>) -> [MediaItem] {
        title.filter { PortalItemID($0.id).map { portals.contains($0.portal) } ?? false }
    }

    public func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {
        try await notify(itemID) {
            $0.positionSeconds = progress.position
            $0.durationSeconds = progress.duration
        }
    }

    /// **"Unwatched" also takes the position** — as with the media server (on-device finding
    /// 2026-10-01): "Reset progress" on the detail page goes through this path, and with a
    /// position left over the title stayed started.
    public func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {
        try await notify(itemID) {
            $0.seen = isPlayed
            if !isPlayed { $0.positionSeconds = 0 }
        }
    }

    /// The position to zero — the server keeps in "Continue Watching" only what is past the
    /// first seconds (`progress.resumable`). Favorite and watched stay.
    public func removeFromContinueWatching(_ itemID: String) async throws {
        try await notify(itemID) { $0.positionSeconds = 0 }
    }

    /// Take a page out of "Recently Used" — the long press on its row (2026-10-12).
    ///
    /// The server remembers ten and shows five; after removal the sixth moves up. Then fetch
    /// the level again, otherwise the row stays there until the next opening.
    public func forgetRecent(_ itemID: String) async throws {
        guard let identifier = PortalItemID(itemID) else { return }
        struct Body: Encodable, Sendable { let entry: String }
        struct Ignored: Decodable {}
        let _: Ignored = try await service().notify(
            "p/\(identifier.portal)/recent/forget", mainContent: Body(entry: identifier.address))
        layers.forget(PortalLibraryID(portal: identifier.portal, entry: "").identifier)
    }

    /// A further path of a portal — `p/{portal}/{path}` — for extensions.
    ///
    /// The core's own paths have their own methods. An extension that adds a route on the server
    /// asks it through here, with the same address, token and dialect as every other request; the
    /// connection stays private to this source.
    public func portalRequest<T: Decodable & Sendable>(
        _ portal: String, _ path: String, _ query: [String: String] = [:]
    ) async throws -> T {
        try await service().fetch("p/\(portal)/\(path)", query)
    }

    // MARK: - The language choice of a series

    /// In which languages this series can be watched.
    ///
    /// **A separate fetch, and it is expensive** — the bridge descends for it to the first
    /// episode of each of the first three seasons and reads their host list. It remembers the
    /// result; the second fetch costs nothing. That is why it is only made when someone also
    /// wants to see the choice, and not when opening every page.
    ///
    /// Empty means: there is nothing to choose here — a portal without series carries exactly
    /// one source per entry.
    public func languages(forItem itemID: String) async throws -> [String] {
        guard let identifier = PortalItemID(itemID) else { return [] }
        let reply: BridgeReply.Languages = try await service().fetch(
            "p/\(identifier.portal)/sprachen",
            ["adresse": identifier.address, "titel": seenItems[itemID]?.title ?? ""]
        )
        return reply.languages
    }

    /// The chosen language of this series — empty means: no preference.
    ///
    /// It is in the state, in the same row as the favorite mark and progress: it belongs to the
    /// viewer and not to the portal.
    public func language(forItem itemID: String) async throws -> String {
        guard let identifier = PortalItemID(itemID), !identifier.key.isEmpty else { return "" }
        struct Reply: Decodable {
            /// Stored keys keep their original (German) names — renaming them would
            /// make data written by earlier versions unreadable (AP85 B4).
            private enum CodingKeys: String, CodingKey {
                case language = "sprache"
            }
            let language: String?
        }
        do {
            let state: Reply = try await service().fetch("stand", ["schluessel": identifier.key])
            return state.language ?? ""
        } catch {
            Diagnostics.verbose("Series language not read: \(Diagnostics.explain(error))")
            // For a series that has never been touched, there is nothing —
            // and "nothing" here is not a failure but "no preference".
            return ""
        }
    }

    /// Set the language choice. An empty text withdraws it.
    public func setLanguage(_ word: String, forItem itemID: String) async throws {
        try await notify(itemID) { $0.language = word }
    }

    public func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {
        try await notify(itemID) { $0.favorite = isFavorite }
    }

    /// Reports **only** what was set.
    ///
    /// The bridge leaves alone what is not named, and `JSONEncoder` omits empty fields — both
    /// together make up the rule. This is not convenience here: the player reports its position
    /// every ten seconds, and a call that wrote the favorite mark along with it would silently
    /// empty the favorites.
    private func notify(_ itemID: String, _ set: (inout ProgressReport) -> Void) async throws {
        guard let identifier = PortalItemID(itemID) else { return }
        let binding = await service()
        var mainContent = ProgressReport(
            portal: identifier.portal, key: identifier.key, address: identifier.address)
        if let known = seenItems[itemID] {
            mainContent.title = known.title
            mainContent.year = known.year
            // **Kind and image too** (viewer finding 2026-08-28): favorites and Continue Watching are
            // answered from the state, not from the portal — a portal script has no call for a single entry.
            // What does not go along here is missing there for good: without the kind every series
            // became an episode and its detail page reported an error, without the image the frame
            // stayed empty.
            mainContent.kind = BridgeReply.ContentEntryRecord.kindName(
                forItem: known.kind, in: binding.dialect)
            mainContent.image = known.artwork.posterID
        }
        mainContent.series = seriesOf[itemID]
        set(&mainContent)

        struct Ignored: Decodable {}
        // **No detour since 2026-09-24.** Here stood a second attempt without the kind, because
        // `POST /state` threw a 500 when `kind` was set — the cause was a word at the server
        // (`kind` instead of `kind` in `progress.py`), fixed and measured on the running service
        // (`200 series`). The detour would have silently swallowed every **future** 500: the kind
        // gone, and in the log a reason that is no longer true.
        let _: Ignored = try await binding.notify("stand", mainContent: mainContent)
    }

    // ── Abspielen ────────────────────────────────────────────────────────────

    public func segments(for itemID: String) async throws -> [MediaSegment] { [] }

    /// The address at which the stream begins.
    ///
    /// **It is asked beforehand, not at playback** (changed on 2026-08-29). Until then the player
    /// got the `/play` address and followed its redirect itself. That had a reason — AVPlayer
    /// fetches every address twice, and whoever resolved beforehand burned the host's one-time
    /// token —, and the reason is gone: the bridge remembers the resolved address for five
    /// minutes and catches streams that open only once in its buffer.
    ///
    /// In return the path via JSON brings two things that a 302 cannot:
    ///
    /// * **A refusal with a reason.** The player turned every rejection into a
    ///   `NSURLErrorDomain -1008` ("resource unavailable") — four identical lines in the
    ///   diagnosis of 2026-08-29 that explained nothing, while the bridge had the sentence right
    ///   there.
    /// * **The headers.** A redirect does not carry them along; the player follows it with its
    ///   own.
    public func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        try await stream(forItem: itemID).address
    }

    /// The same address — **and until when it is valid.**
    ///
    /// **Separate from ``streamURL(for:decision:)`` and not in its place.** The `ContentSource`
    /// contract returns a `URL`, and both apps depend on it; writing a deadline into this
    /// return value would mean touching every caller to tell one place something. Whoever needs
    /// the deadline calls this path — whoever does not notices nothing of the addition.
    ///
    /// **What the deadline is for:** a host address is valid for five minutes, and five minutes
    /// is shorter than any interruption. Without it "expired" and "the host does not hand out
    /// the film" look the same — and one would have to resolve anew on **every** playback
    /// error.
    ///
    /// `validUntil` is `nil` if the bridge names no deadline. That does **not** mean "valid
    /// forever", but "unknown": whoever hits it does not fetch anew.
    /// - Parameter quelle: The identifier of a host from ``host(forItem:)``. `nil` means "take
    ///   the first usable one" — exactly the behavior this path always had, and that is why the
    ///   default sits here and not at the caller. It is set only by the source choice: whoever
    ///   sets it has seen what is on offer.
    public func stream(
        forItem itemID: String, source: String? = nil
    ) async throws -> (
        address: URL, validUntil: Date?, headers: [String: String]
    ) {
        guard let identifier = PortalItemID(itemID) else {
            throw PortalBridge.TestError.unreadable
        }
        let chosen: String
        if let source {
            chosen = source
        } else {
            let reply: BridgeReply.Sources = try await service().fetch(
                "p/\(identifier.portal)/quellen", ["adresse": identifier.address]
            )
            let usable = reply.sources.filter { !$0.locked }
            guard let first = usable.first else {
                throw PortalBridge.TestError.noHost
            }
            chosen = first.id
        }
        // **The title's address travels along** (2026-09-16): with it the server can, if the
        // requested source does not hold up, go through the title's other ones instead of aborting
        // with `stream.no_host` — the case from which the player had no way out. The old bridge
        // ignores the part.
        let resolved: BridgeReply.Playback = try await service().fetch(
            "play",
            [
                "portal": identifier.portal, "quelle": chosen, "adresse": identifier.address,
                "weiterleiten": "false",
            ]
        )
        guard let address = URL(string: resolved.address) else {
            throw PortalBridge.TestError.unreadable
        }
        rememberSource(resolved, desired: chosen)
        // **The headers travel along, since 2026-09-09** They arrived from `/play` already decoded and
        // were thrown away here — during playback this went unnoticed, because `AVPlayer` takes the
        // same path via the bridge. On **download** it is the difference between a file and a 403:
        // a host that demands a referer rejects the bare request before the first byte.
        //
        // **`passedThrough` decides whether they are needed at all.** If the stream runs through the
        // bridge, they are already set there; sending them a second time would mean claiming a
        // foreign origin to the buffer.
        let headers = resolved.passedThrough == true ? [:] : (resolved.headers ?? [:])
        // **Remembered here too** — see ``lastSubtitles``. With the old bridge the field is never
        // populated, and the list is then set to empty: otherwise a portal episode would carry the
        // traces of the previous one.
        lastSubtitles = (resolved.subtitles ?? []).compactMap(PortalSubtitle.init)
        let validUntil = resolved.validUntil.map(Date.init(timeIntervalSince1970:))
        lastValidUntil = validUntil
        return (address, validUntil, headers)
    }

    /// Record what the server says about the source, for ``lastSource``.
    ///
    /// The bridge names none — then the requested one counts as the running one, and `switched`
    /// stays false: it never switched, it cannot.
    private func rememberSource(_ resolved: BridgeReply.Playback, desired: String) {
        lastSource = resolved.source ?? desired
        lastSourceSwitched = resolved.switched ?? false
    }

    /// Which source is played — the named one, or the first usable one.
    ///
    /// **Factored out because two paths make the same choice**, and a choice made in two places
    /// will at some point turn out differently in one of them.
    private func chosenSource(
        _ identifier: PortalItemID, _ source: String?
    ) async throws
        -> String
    {
        if let source { return source }
        let reply: BridgeReply.Sources = try await service().fetch(
            "p/\(identifier.portal)/quellen", ["adresse": identifier.address]
        )
        // **Blocked ones are not eligible for the automatic choice** — but they do not disappear:
        // ``host(forItem:)`` delivers them with the reason, so that the UI can show them greyed out.
        // A portal with six dead hosts should not look like one without sources.
        guard let first = reply.sources.first(where: { !$0.locked }) else {
            throw PortalBridge.TestError.noHost
        }
        return first.id
    }

    /// Does this portal know seasons?
    ///
    /// **That decides whether a press plays or opens.** A portal without seasons has nothing a
    /// detail page could show: one source, no episodes, no cast. The user finding of 2026-08-29 named
    /// two such portals — the rule does not name them, it queries the capability. So it
    /// also applies to the next flat portal without anyone having to think of it.
    public func supportsSeasons(portal: String) -> Bool {
        Self.supportsSeasons(portal: portal, in: portals)
    }

    /// What each portal can do — `resolver`, `languages`, `seasons`, `login`, `search`.
    ///
    /// **The bridge reports this on every `portals` call anyway; until now only
    /// ``supportsSeasons(portal:)`` read from it, and only a single capability.** On the phone more
    /// depends on it: `resolver` says whether a portal plays immediately or first searches for
    /// the video source — that is the information that decides the portal choice when one wants to
    /// watch something quickly on the go.
    ///
    /// Empty as long as ``availablePortals()`` or ``libraries()`` have not been asked for: this
    /// place triggers no call. An answer that makes a request on the side is a storm on a screen
    /// that reads it on every frame build.
    public func capabilities() -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: portals.map { ($0.id, Set($0.capabilities)) })
    }

    /// The same rule without a bridge next to it — that is how it is testable.
    ///
    /// **When in doubt, not flat.** A portal that the bridge has not yet reported would otherwise
    /// lead to a press playing a series instead of showing its seasons. The detail page is the
    /// less harmful guess: it shows too much, not the wrong thing.
    static func supportsSeasons(portal: String, in portals: [BridgeReply.Portal]) -> Bool {
        can(.seasons, portal: portal, in: portals, ifUnknown: true)
    }

    /// Can this portal do that?
    ///
    /// **The generalised version of ``supportsSeasons(portal:)`` (2026-09-12).** Until here the app
    /// queried exactly one capability and compared it with a hard-coded string. That held as long
    /// as there was one service with one vocabulary; with two it no longer holds —
    /// ``PortalCapability`` knows both words.
    ///
    /// - Parameter wennUnbekannt: What applies as long as the portal has not yet been reported.
    ///   **That differs per capability and is therefore no fixed default:** for
    ///   ``PortalCapability/seasons`` "yes" is the less harmful guess — the detail page shows too
    ///   much instead of sending a press into the wrong episode. For ``PortalCapability/search``
    ///   "yes" would be a search field that grabs at nothing.
    public func can(
        _ capability: PortalCapability, portal: String, ifUnknown: Bool = false
    )
        -> Bool
    {
        Self.can(capability, portal: portal, in: portals, ifUnknown: ifUnknown)
    }

    /// The same rule without a service next to it — that is how it is testable.
    static func can(
        _ capability: PortalCapability, portal: String, in portals: [BridgeReply.Portal],
        ifUnknown: Bool
    ) -> Bool {
        guard let found = portals.first(where: { $0.id == portal }) else { return ifUnknown }
        return capability.settled(in: found.capabilities)
    }

    /// The hosts of an episode — for the choice behind the long press (S5).
    ///
    /// **Stays as it was and calls ``host(forItem:)``.** The same agreement as with
    /// ``streamURL(for:decision:)`` and ``stream(forItem:source:)``: two apps depend on this package,
    /// and a return value that changes touches every caller to tell one place something. Whoever
    /// needs the reason for a block calls the other path.
    public func sources(
        forItem itemID: String
    ) async throws -> [(id: String, name: String, language: String?, locked: Bool)] {
        try await host(forItem: itemID).map { ($0.id, $0.name, $0.language, $0.locked) }
    }

    /// The same hosts — **with the reason why one is blocked.**
    ///
    /// The bridge has always sent it along (`BridgeReply.Source.reason`), and until 2026-09-06 this
    /// very place threw it away. A dimmed row without a reason is the worst of three
    /// possibilities: it says "does not work" and conceals what would have to be done.
    public func host(forItem itemID: String) async throws -> [PortalFileHost] {
        guard let identifier = PortalItemID(itemID) else { return [] }
        let reply: BridgeReply.Sources = try await service().fetch(
            "p/\(identifier.portal)/quellen", ["adresse": identifier.address]
        )
        return reply.sources.map {
            PortalFileHost(
                id: $0.id, name: $0.name, language: $0.language, locked: $0.locked,
                reason: $0.reason)
        }
    }

    // ── Bilder ───────────────────────────────────────────────────────────────

    /// The foreign address is passed through, not built.
    ///
    /// A portal delivers addresses that belong to it — width and tag would have no meaning there.
    /// The same agreement as with the provider catalog: the full address is in the identifier.
    public nonisolated func imageURL(
        itemID: String, kind: ImageKind, width: Int, tag: String?
    ) -> URL? {
        guard kind == .primary || kind == .thumb else { return nil }
        // **An address without origin is none** (viewer finding 2026-08-28): some portals name as the
        // image a file in their own folder. The bridge turns that into `/p/…/image?path=…` — a path
        // without a host name, because it does not know its own and should not either: it is
        // reachable via a host name and via its number, and whoever hard-wired one of the two
        // names would break the other. It is resolved here, where the address is anyway.
        if itemID.hasPrefix("/") {
            return URL(string: itemID, relativeTo: bridge.basis)?.absoluteURL
        }
        return URL(string: itemID)
    }

    // ── Lists that change ──────────────────────────────────────────────

    public func listChanges() async -> AsyncStream<Void> {
        let identifier = UUID()
        return AsyncStream { continuation in
            listeners[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.signOut(identifier) }
            }
        }
    }

    private func signOut(_ identifier: UUID) {
        listeners[identifier] = nil
    }

    public func refreshAfterPlayback(ids: [String]) async {
        // The state lives at the bridge; here only the memo has to be discarded, so that the detail
        // page does not read the new progress from an old entry.
        for id in ids { seenItems[id] = nil }
        layers.forget()
        for (_, continuation) in listeners { continuation.yield() }
    }

    private func remember(_ items: [MediaItem]) {
        for item in items { seenItems[item.id] = item }
        if seriesOf.count > 4000 { seriesOf.removeAll(keepingCapacity: true) }
        // A portal script delivers more than ten thousand entries for "All Series"; keeping them all would
        // be memory for nothing. The memo serves the jump from the list to the detail page, and for
        // that the most recently seen is enough.
        if seenItems.count > 4000 { seenItems.removeAll(keepingCapacity: true) }
    }
}
