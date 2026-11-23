import Core
import Diagnose
import Flows
import Foundation
import Observation
import PortalKit

/// Which portal, which entry point, which state.
///
/// **The portal choice is the navigation.** Unlike the library's catalogs
/// there is no shared level above it: two portals lead to different catalogs
/// with different entry points, and a combined catalog of both would be a list in which
/// nobody knows any more where a title comes from — and what it costs to fetch it.
@MainActor
@Observable
public final class PortalsModel {

    public enum Situation: Sendable, Equatable {
        case isLoading
        case settled
        /// The portal is there but not usable — the state says why.
        case locked(PortalState)
        case empty
        case disrupted(PlaybackPhase)
    }

    public private(set) var state: Situation = .isLoading
    public private(set) var portals: [PortalInfo] = []
    public private(set) var chosen: PortalInfo?
    /// The path one is standing on — **the root is the first place.**
    ///
    /// Direction K3a of 2026-09-06: A catalog is flat and gets sorted, a portal is
    /// a tree and gets walked through.
    public private(set) var stack: [PortalLayer] = []

    /// Whether a follow-up page is currently on its way.
    ///
    /// **It is not a loading state of the view.** What is already there stays; at the bottom
    /// a spinner stands. A full loading screen over a list one is
    /// paging through would take away the paging's place.
    public private(set) var isLoadingMore = false

    /// How many entries the CL-Server has already collected for the sorted level —
    /// set while it collects (AP60). The view shows the number.
    public private(set) var preparedCount: Int?

    /// The sort order per level — **only what is explicitly chosen.**
    ///
    /// Until AP60 portal levels stayed unsorted on the phone, on purpose: "New episodes"
    /// means newest first, and a sort on the device would only have ordered the loaded
    /// pages. Now the CL-Server sorts across all pages, and the default
    /// remains the order of the source. Per level, so that the way back shows each one as
    /// it was left.
    private var choices: [String: OrderChoice] = [:]

    /// "Nothing chosen" — the order of the source.
    static let noChoice = OrderChoice(sorting: .title, ascending: true, explicit: false)

    /// The sort order of the open level.
    public var choice: OrderChoice {
        stack.last.flatMap { choices[$0.identifier] } ?? Self.noChoice
    }

    /// Title always, rating only where a loaded entry carries one — the same rule
    /// as on the TV (``Features/LibraryModel/sortingChoices``).
    public var availableOrders: [Sorting] {
        let hasRatings = stack.last?.entries.contains { $0.rating != nil } ?? false
        return hasRatings ? [.title, .rating] : [.title]
    }

    nonisolated static func sorting(forItem choice: OrderChoice) -> PortalSorting? {
        guard choice.explicit else { return nil }
        switch choice.sorting {
        case .title: return PortalSorting(kind: .title, descending: !choice.ascending)
        case .rating: return PortalSorting(kind: .rating, descending: !choice.ascending)
        case .fresh: return nil
        }
    }

    private func sorting(forItem identifier: String) -> PortalSorting? {
        Self.sorting(forItem: choices[identifier] ?? Self.noChoice)
    }

    /// Which door is currently opening — the identifier of the tapped entry.
    ///
    /// **Finding of 2026-09-09: below the root there was no feedback at all.**
    /// ``enter(_:title:)`` sets ``Situation/isLoading`` only on the root (`if stack.isEmpty`);
    /// one level deeper the screen stood unchanged until the answer was there. With
    /// flatone a step takes one to two seconds — a tap thus looked like
    /// a dead button, and whoever taps twice descends twice.
    ///
    /// **And explicitly not ``Situation/isLoading``.** That would take the list away; the reasoning
    /// for that is at ``isLoadingMore``. The feedback belongs on the **one** row that was
    /// pressed, and nowhere else.
    public private(set) var opens: String?

    /// Where one stood on a level — per ``PortalLayer/identifier``, not per view.
    ///
    /// **Finding of 2026-09-09:** Going into clips and then back,
    /// the list always jumps straight to the top. Nothing is reloaded in the process —
    /// ``back()`` only takes the topmost place off the stack, the previous level lies below it with
    /// its entries. What got lost was the state of the **scroll area**: the root
    /// of flatone is a pure folder list (recounted at the bridge on 2026-09-09:
    /// **277 entry points**, "Clips" at position 62), Clips below it is mixed
    /// (24 films, 3 folders) — on descending `PortalsView` switches the `if` branch, SwiftUI
    /// tears down the `ScrollView`, and with it the position it kept.
    ///
    /// **On the model and not in the view**, because the view is exactly what disappears.
    /// The key is the same identifier that ``loadMore()`` already uses as the identity of a level;
    /// the value is the identifier of the topmost visible row.
    ///
    /// **A string and not a `ScrollPosition`** — corrected on 2026-09-09
    /// in the afternoon. The morning version stored `ScrollPosition` here and returned a bare `ScrollPosition()` for
    /// an unknown level. According to the
    /// SDK interface that is `init(idType: Never.self)`, and `viewID` supplies an instance
    /// of exactly this type — `Never` has none. A position built that way could **never**
    /// name a row, only carry an offset, and an offset does not survive the teardown
    /// of the area. The full reasoning is at ``ScrollSurface/location``.
    ///
    /// **Excluded from observation, on purpose.** The scroll area writes here
    /// while the thumb swipes; if `@Observable` counted that, the whole
    /// portal page would rebuild on every jolt. It is read only when a level is built, and
    /// that needs no notification.
    @ObservationIgnored private var scrollAnchors: [String: String] = [:]

    /// What the chosen portal keeps in **its own area**.
    ///
    /// **The requirement of 2026-09-07:** a setting in Settings
    /// that lets portals assign their own favorites and Continue Watching to their
    /// own area. The switch is in the portal settings
    /// (``PortalPreferences``); what stands here is the area itself.
    ///
    /// **Empty as long as the portal counts in the shared shelves** — then its
    /// in-progress items stand on the Home screen and its saved ones in the favorites tab, and a
    /// second version underneath would be the same information in two places.
    ///
    /// **Only on the portal's root.** One level deeper one is in a folder, and
    /// two shelves above a folder's content visibly would not belong.
    public private(set) var ownHistory: [TileContent] = []
    public private(set) var ownFavorites: [TileContent] = []

    private let source: (any PortalContentSource)?
    private let memory: PortalMemory
    private let preferences: @Sendable () -> PortalPreferences
    private let width: Int

    /// - Parameter vorlieben: Which portals stay on their own. **A handle and not a
    ///   value**, so that flipping the switch takes effect on coming back — the same
    ///   agreement as with ``StartModel``.
    /// - Parameter breite: The image width of the tiles in the own area.
    public init(
        source: (any PortalContentSource)? = nil, memory: PortalMemory = .init(),
        preferences: (@Sendable () -> PortalPreferences)? = nil, width: Int = 0
    ) {
        self.source = source
        self.memory = memory
        self.preferences = preferences ?? { .preset }
        self.width = width
    }

    /// Whether the chosen portal's own area stands above its root.
    public var showsOwnArea: Bool {
        !hasWayBack && !(ownHistory.isEmpty && ownFavorites.isEmpty)
    }

    /// Fetches the in-progress and saved items of **this one** portal.
    ///
    /// **Two sources, and only one costs the network.** The in-progress items lie in the own
    /// ``History`` on disk; the favorites are kept by the bridge. Without an own area
    /// nothing is asked at all — a request to a foreign service for a shelf that does not
    /// appear would be the most expensive idle run of this view.
    private func loadOwnArea() async {
        ownHistory = []
        ownFavorites = []
        guard let portal = chosen?.id, !preferences().countsTogether(portal) else { return }

        guard let source else { return }
        // **The server state, not the local history** (AP77, 2026-10-11). The TV has read
        // `resumable` here since AP59, the phone its own store — what was started on the
        // TV was missing from the phone's own area. One source, the same row, the same
        // filters against switched-off portals.
        let started = await source.continueWatching(atMost: 50)
        ownHistory = started.filter { PortalPreferences.portal(zu: $0.id) == portal }
        let remembered = (try? await source.favorites(width: width)) ?? []
        ownFavorites = remembered.filter { PortalPreferences.portal(zu: $0.id) == portal }
        Diagnose.step(
            .network,
            "Portals: own area \(portal) — \(ownHistory.count) started, "
                + "\(ownFavorites.count) saved")
    }

    // MARK: - Loading

    public func load() async {
        guard let source else {
            state = .disrupted(.networkPortals)
            return
        }
        if portals.isEmpty { state = .isLoading }

        do {
            portals = try await source.portals()
        } catch {
            Diagnose.error(.network, "Portals: \(error.localizedDescription)")
            state = .disrupted(Self.disruption(error))
            return
        }

        guard !portals.isEmpty else {
            state = .disrupted(.networkPortals)
            return
        }

        // **A choice that holds is not replaced** — the same rule as in
        // ``LibraryViewModel``, where a new choice is made only if the old one has disappeared from
        // the state.
        //
        // **Finding of 2026-09-09:** Selecting a content item in flatone opens the
        // detail view; tapping back there jumps out completely instead of
        // going back just one step. The arrow was innocent. `PortalsView` hangs this
        // call on `.task`, and `.task` hangs on the lifetime of the view: in the
        // `NavigationStack` the root disappears on going in and reappears on
        // coming back, so `load()` ran **again** and chose the same portal
        // a second time — and ``select(_:)`` threw away the whole level stack.
        // The arrow cleared one level, `.task` in the same breath everything below.
        //
        // **The same line hit the tab switch:** Portals → Live → Portals reset the
        // stack, although ``Navigator`` promises that each tab keeps its own.
        //
        // What is still done afterwards is the **fresh status** for the same portal: the
        // state may have changed, and the mark next to it is meant to show it.
        if let settled = chosen.flatMap({ old in portals.first { $0.id == old.id } }),
            settled.state.isSelectable
        {
            await adopt(settled)
            return
        }

        // **The last used portal first** — the same rule as for the library
        // catalog. If it is gone or has gone silent, the choice takes the first
        // usable one; only when none holds any more does it stay on the first and show
        // its state.
        let remembered = memory.last.flatMap { name in portals.first { $0.id == name } }
        await adopt(
            remembered?.state.isSelectable == true
                ? remembered! : (portals.first(where: { $0.state.isSelectable }) ?? portals[0]))
    }

    /// Choose a portal — **and throw the level stack away only on a real switch.**
    ///
    /// **Throwing away is the exception, not the opening move.** Until 2026-09-09. `stack = []`
    /// stood unconditionally at the start; so every call of this place was an exit from the tree,
    /// even one that switched nothing. The consequences are at ``load()``.
    ///
    /// **If the same portal is already open, the path stays** and nothing is
    /// fetched again: the own area is loaded, the level lies in the stack, and a
    /// second request for the same information would be traffic without effect.
    ///
    /// **On an empty stack it still enters.** That way a portal that was silent on the
    /// first try still finds its way in the next time the view appears
    /// — without the viewer having to choose it from the sheet again.
    public func select(_ portal: PortalInfo) async {
        memory.memorize(portal.id)
        await adopt(portal)
    }

    /// Open a portal, **without storing it as the choice.**
    ///
    /// **The difference was added on 2026-09-09**, and the rule for it already stood
    /// next door: ``LibraryViewModel/select(_:)`` remembers the catalog explicitly there
    /// and not in ``LibraryViewModel/load()``, because the **fallback** to the
    /// first catalog is also set there — "remembering that would mean storing a stopgap as
    /// the choice". Here `memory.memorize` stood in the shared body until then, and
    /// so the rule was: whoever uses Animehub and finds it silent one evening was assigned
    /// the ARD — **permanently**, even after Animehub answered again. The
    /// memory overwrote exactly the choice it was supposed to protect.
    private func adopt(_ portal: PortalInfo) async {
        let staysPut = chosen?.id == portal.id && !stack.isEmpty
        chosen = portal
        guard !staysPut else { return }
        stack = []
        scrollAnchors = [:]

        guard portal.state.isReady else {
            state = .locked(portal.state)
            ownHistory = []
            ownFavorites = []
            return
        }
        guard let source else { return }
        await enter(source.root(zu: portal.id), title: portal.name)
        await restorePath()
        // **After entering and not before.** The own area stands above the
        // root level; whoever fetched it first would make the viewer wait for two shelves on the
        // level he actually cares about.
        await loadOwnArea()
    }

    /// Fetch the own area again — after a command from the long press.
    public func refreshOwnArea() async {
        await loadOwnArea()
    }

    // MARK: - The level stack

    /// A portal failure — **through the one interpretation and not past it.**
    ///
    /// **Until 2026-09-26 every error here became ``PlaybackPhase/networkPortals``** (report A,
    /// finding S5): also a service that had answered and named a reason, and a
    /// device that needs a person or a new sign-in. The TV did exactly the
    /// opposite — there everything became "not resolvable". Now ``DisruptionInterpretation``
    /// decides, the same on both devices.
    nonisolated static func disruption(_ error: any Error) -> PlaybackPhase {
        DisruptionInterpretation.state(forItem: error, origin: .portals)
    }

    /// Open a level and put it on the stack.
    ///
    /// **The root is a level like any other.** Until 2026-09-06 it was a
    /// special case: a chip row of "entry points" above a grid. So there was no
    /// stack, and from a folder no way led back — four of eight
    /// Serieshub entry points are pure folder lists.
    private func enter(_ identifier: String, title: String) async {
        guard let source else { return }
        if stack.isEmpty { state = .isLoading }
        do {
            let fetched = try await source.level(zu: identifier, title: title)
            stack.append(fetched)
            state = fetched.entries.isEmpty ? .empty : .settled
        } catch {
            Diagnose.error(.network, "Portals: level \(title) — \(error.localizedDescription)")
            state = .disrupted(Self.disruption(error))
        }
    }

    /// **Fetch this level once more** — for pull to refresh.
    ///
    /// **The finding (E40): The Portals tab did not get the gesture**, because ``load()`` re-enters at
    /// the portal's root. Whoever pulls three levels deep in a folder
    /// would end up at the top afterwards — and that is worse than no gesture: it looks
    /// like "refresh" and does "start over".
    ///
    /// **Replace instead of append.** ``enter(_:title:)`` puts a level **onto** the
    /// stack; here the topmost one is swapped. Otherwise the stack would grow with every
    /// pull by a level that looks exactly like the one below, and the way back
    /// would lead through nothing but copies.
    ///
    /// **Without a stack the old answer applies.** On the portal choice there is no
    /// level to refresh — there "start over" is exactly right.
    public func refreshLevel() async {
        guard let source, let top = stack.last else {
            await load()
            return
        }
        do {
            let fetched = try await source.level(
                zu: top.identifier, title: top.title, next: nil,
                sorting: sorting(forItem: top.identifier), progress: { _ in })
            stack[stack.count - 1] = fetched
            state = fetched.entries.isEmpty ? .empty : .settled
        } catch {
            Diagnose.error(
                .network, "Portals: refresh level \(top.title) — \(error.localizedDescription)")
            // **The old level stays.** A failed refresh must not
            // take away what is already there — otherwise a gesture that was meant to achieve nothing
            // costs the whole screen.
            state = .settled
        }
    }

    /// Which rows of the open level stand under "Recently Used" — the same rule
    /// as on the TV (``PortalSource/recentlyUsed(in:)``).
    public var recentlyUsed: Set<String> {
        PortalSource.recentlyUsed(in: stack.last?.entries.map(\.id) ?? [])
    }

    /// Take one page out of "Recently Used" and fetch the level again (2026-10-12): The
    /// server remembers ten, shows five, and the next one moves up.
    public func forgetRecent(_ entry: PortalEntry) async {
        guard let source else { return }
        do {
            try await source.forgetRecent(entry.id)
        } catch {
            Diagnose.error(.network, "Portals: recently used — \(error.localizedDescription)")
        }
        await refreshLevel()
    }

    /// Open an entry — **one level deeper or onto the detail page.**
    ///
    /// Which of the two is decided by the entry and not by this place:
    /// ``PortalEntry/leadsDeeper`` comes from the shared package.
    public func open(_ entry: PortalEntry) async {
        guard let deeper = entry.leadsDeeper else { return }
        // **The pressed row says that it was pressed.** Why that is the feedback
        // and not a loading screen is at ``opens``.
        opens = entry.id
        defer { opens = nil }
        await enter(deeper, title: entry.title)
        rememberPath()
    }

    /// Fetch the next page and append it to the open level.
    ///
    /// **Why this path exists at all.** Measured at the bridge on 2026-09-06: the nine
    /// entry points of the ARD Mediathek deliver **2 to 25** titles per page and each names
    /// a marker — without this path fifteen films were reachable there and the rest
    /// not at all. Animehub and Serieshub name none and deliver everything at once;
    /// for them this place does nothing, and that is right.
    ///
    /// **The 10,869 of Serieshub it explicitly does not solve.** The reader hands them out
    /// in one piece (4.2 MB in 1.5 s on the home network), and a page number that does not exist at
    /// the portal cannot be invented by the bridge. Whoever wanted to page here would have to
    /// cut the list up in the bridge — that would be a decision of its own and not a
    /// line here.
    ///
    /// **Two guards, both needed:** no second request while one is running (the view
    /// reports the end of the list several times while it draws it), and none without a
    /// marker.
    public func loadMore() async {
        guard !isLoadingMore, let source, let pending = stack.last, let marker = pending.next
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await source.level(
                zu: pending.identifier, title: pending.title, next: marker,
                sorting: sorting(forItem: pending.identifier), progress: { _ in })
            // **Checked against the level that is open now.** Whoever goes one level
            // deeper during the request would otherwise get the continuation of the previous one attached to his
            // new list.
            guard stack.last?.identifier == pending.identifier else { return }
            stack[stack.count - 1] = pending.using(page: next)
        } catch {
            // **A notice and not a failure screen.** What is already loaded stays
            // usable; an error while loading more must not take the list away.
            Diagnose.hint(.network, "Portals: next page not fetched", error)
        }
    }

    /// **One press sorts, the second reverses, the third switches off** — the same
    /// sequence as in the library (``OrderChoice/next(after:pressOn:kind:)``).
    ///
    /// After that the CL-Server fetches the open level sorted across all pages. The first
    /// time it collects it first; until then the old list stays and
    /// ``preparedCount`` gives the progress.
    public func tap(_ tapped: Sorting) async {
        guard let source, let top = stack.last else { return }
        let identifier = top.identifier
        choices[identifier] = OrderChoice.next(after: choice, pressOn: tapped, kind: .movies)
        let wanted = sorting(forItem: identifier)
        defer { if stack.last?.identifier == identifier { preparedCount = nil } }
        do {
            let fetched = try await source.level(
                zu: identifier, title: top.title, next: nil, sorting: wanted
            ) { [weak self] done in
                await self?.notify(preparedCount: done, forItem: identifier)
            }
            // Only if the level is still open **and** was not chosen differently in the meantime
            // — a quick second press would otherwise get the older answer.
            guard stack.last?.identifier == identifier, sorting(forItem: identifier) == wanted
            else { return }
            stack[stack.count - 1] = fetched
            state = fetched.entries.isEmpty ? .empty : .settled
        } catch {
            Diagnose.hint(.network, "Portals: level not sorted", error)
        }
    }

    private func notify(preparedCount done: Int, forItem identifier: String) {
        guard stack.last?.identifier == identifier else { return }
        preparedCount = done
    }

    /// One step back. On the root there is none.
    ///
    /// **The level that is left gives up its scroll position.** It is read from the start
    /// the next time it is entered — whoever reopens a folder wants to start at the top and not
    /// where he left off last time. Only what lies **below** one is kept:
    /// the path one is standing on.
    ///
    /// **Back on the root it is fetched again** (2026-10-12): There "Recently
    /// Used" stands, and the page just opened belongs at the top. The remembered root showed
    /// the old order until someone pulled to refresh.
    public func back() {
        guard stack.count > 1 else { return }
        let leave = stack.removeLast()
        scrollAnchors[leave.identifier] = nil
        state = (stack.last?.entries.isEmpty ?? true) ? .empty : .settled
        rememberPath()
        if stack.count == 1 { Task { await refreshLevel() } }
    }

    // MARK: - The remembered path beyond the program run

    /// How deep a remembered path is restored at most.
    ///
    /// **Two, and that is a timing calculation and not a matter of taste.** Measured on 2026-09-09 at the
    /// bridge: a `list` request for `flatone › Clips` takes **0.93
    /// to 0.95 seconds** (two runs, 17 kB). Every place on the path is exactly one
    /// such request, and it runs **before** the first image — with three places that would be
    /// three seconds of loading indicator on a cold start, for a spot one perhaps did not
    /// want to return to at all.
    ///
    /// **The reported case needs one** (`flatone › Clips`); the second is
    /// the reserve for "portal › area › category".
    private static let maxDepth = 2

    /// Reopen the remembered path below the root.
    ///
    /// **Requirement of 2026-09-09:** the fix in the library for the last
    /// opened view works … can the same be done in portals? The
    /// most recently chosen **portal** already stood (``PortalMemory/last``); what was missing
    /// was the counterpart to the library's remembered category — the most recently open **level
    /// within it**. The same reasoning as at ``CategoryMemory``: with 277 areas
    /// it is not the start view that decides whether the tab is usable, but whether
    /// one comes out again where one was.
    ///
    /// **A place that no longer opens ends the path — it does not overturn it.** A
    /// portal rearranges its entry points, a folder disappears; then the last
    /// level that answered stands, and when in doubt the root. A failure screen would be
    /// the wrong information here: the portal is not broken, only a bookmark is old.
    ///
    /// **The loading indicator stays over the whole path.** ``enter(_:title:)`` sets it
    /// only on the root; without this line the root list would stand there for a second and
    /// jump away from under the viewer's thumb.
    private func restorePath() async {
        guard state == .settled, stack.count == 1, let portal = chosen?.id else { return }
        let route = memory.route(zu: portal).prefix(Self.maxDepth)
        guard !route.isEmpty else { return }

        state = .isLoading
        for slot in route {
            let previous = stack.count
            await enter(slot.identifier, title: slot.title)
            guard stack.count > previous, stack.last?.entries.isEmpty == false else {
                // **The partial path stays.** Whoever got as far as "Clips" and
                // only grasps at nothing below that should land at Clips and not
                // at 277 entry points again.
                stack = Array(stack.prefix(previous))
                break
            }
        }
        state = (stack.last?.entries.isEmpty ?? true) ? .empty : .settled
        Diagnose.step(.network, "Portals: path restored — \(path)")
    }

    /// Store the path one is currently standing on.
    ///
    /// **Only after an explicit movement** — folder open, folder closed, search
    /// submitted —, just as ``LibraryViewModel/select(category:)`` remembers its category only on
    /// a real choice. Nothing is written while restoring; otherwise
    /// an aborted path would store itself as the new state.
    private func rememberPath() {
        guard let portal = chosen?.id else { return }
        memory.memorize(route: openPath, zu: portal)
    }

    /// The path below the root — **without open questions.**
    ///
    /// **A question is not a place where one has been.** Two kinds stop here:
    ///
    /// - ``PortalLayer/followUpQuestion`` — "Clear Search History" delivers an empty level with
    ///   the sentence "Confirm: Are you sure you want to clear the search history?". Waking up
    ///   on a cold start in front of a safety question that this app cannot yet
    ///   answer would be the most unfriendly start view the tab has
    ///   to offer.
    /// - ``PortalLayer/query`` — "New Search" asks for an input. The view shows
    ///   no list there on purpose (see ``PortalsView/unanswered``); as a
    ///   start screen that would be an empty field and nothing else. And the request would cost
    ///   a second for it.
    ///
    /// **The answered search is very much remembered:** ``answer(_:)`` creates it as
    /// a level **of its own**, and that one no longer carries a question.
    private var openPath: [PortalWaypoint] {
        var route: [PortalWaypoint] = []
        for level in stack.dropFirst().prefix(Self.maxDepth) {
            guard level.followUpQuestion == nil, level.query == nil else { break }
            route.append(PortalWaypoint(identifier: level.identifier, title: level.title))
        }
        return route
    }

    // MARK: - The remembered scroll position

    /// Where one last stood on this level — for a freshly built scroll area.
    ///
    /// `nil` means "start at the top": a level that nobody has left yet has no
    /// position, and an invented one would be a jump that nobody asked for.
    public func scrollAnchor(forItem identifier: String) -> String? {
        scrollAnchors[identifier]
    }

    /// Store the position of a level. Called by the scroll area while swiping.
    public func memorize(scrollAnchor: String?, forItem identifier: String) {
        scrollAnchors[identifier] = scrollAnchor
    }

    /// The answer to a level's question — **as a level of its own.**
    ///
    /// The entry point "Search" answers with `braucht_eingabe` and until 2026-09-06 had no
    /// place where anyone could enter something; it landed in the empty state "Nothing
    /// here". The answer replaces the asking level instead of laying itself over it: whoever
    /// searches twice would otherwise have two stack places for one question. **Which term
    /// applies is told by ``PortalKit/PortalSearch``** (AP58 R7): submitted, that is from one character,
    /// without margin.
    public func answer(_ input: String) async {
        guard let term = PortalSearch.term(input, whileTyping: false),
            let source = source as? BridgePortalSource, let pending = stack.last,
            let needle = source.needle(in: pending.identifier, after: term)
        else { return }
        stack.removeLast()
        scrollAnchors[pending.identifier] = nil
        await enter(needle, title: pending.title)
        rememberPath()
    }

    // MARK: - What the view reads

    /// The level that is currently open.
    public var pending: PortalLayer? { stack.last }

    /// Whether there is a way back — **not on the root.**
    ///
    /// An arrow that leads nowhere claims a place that does not exist; that was
    /// the reasoning with which the old version had **none at all**. It held for a
    /// flat view and was wrong for a tree.
    public var hasWayBack: Bool { stack.count > 1 }

    /// The path as a line — "Serieshub › Beliebte Serien › Action".
    public var path: String {
        stack.map(\.title).joined(separator: " › ")
    }

    /// The ordered list for the grid.
    ///
    /// **Left unordered and not sorted.** For a portal the order
    /// is information: "New episodes" means newest first, and whoever sorted it alphabetically
    /// turned the entry point into a different one. The jump bar therefore does not appear here —
    /// it presupposes an alphabetical order.
    public var order: Order {
        Order(entries: pending?.tiles ?? [], marks: [], targets: [:])
    }
}

/// Which portal was open last.
///
/// **Beyond the app run**, like the library's category: whoever watches anime
/// watches anime — sending them back to the ARD at every start would be an imposition that
/// is paid daily.
public final class PortalMemory: @unchecked Sendable {

    private static let key = "portal.lastPortal"

    /// Where one last stood **within** a portal — one path per portal.
    ///
    /// **A dictionary and not a single value**, unlike for the portal itself and
    /// unlike ``CatalogMemory``: the question "which portal?" has one
    /// answer, the question "where within it?" has one per portal. That is the same split as
    /// between ``CatalogMemory`` and ``CategoryMemory``.
    private static let pathKey = "portal.lastPath"

    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    public var last: String? { store.string(forKey: Self.key) }

    public func memorize(_ portal: String) {
        store.set(portal, forKey: Self.key)
    }

    /// The remembered path below the root — empty on first launch and after a way back
    /// all the way up.
    public func route(zu portal: String) -> [PortalWaypoint] {
        routes[portal] ?? []
    }

    /// Store a path. An empty path **deletes** the entry instead of storing an empty list
    /// — whoever went back to the root has no bookmark any more.
    public func memorize(route: [PortalWaypoint], zu portal: String) {
        var all = routes
        all[portal] = route.isEmpty ? nil : route
        guard let raw = try? JSONEncoder().encode(all) else { return }
        store.set(raw, forKey: Self.pathKey)
    }

    /// **As JSON and not as a dictionary of strings.** A waypoint has two
    /// fields, and folding those into one string would mean thinking up a separator
    /// that occurs in no portal identifier — a bet that is lost exactly once.
    private var routes: [String: [PortalWaypoint]] {
        guard let raw = store.data(forKey: Self.pathKey),
            let read = try? JSONDecoder().decode([String: [PortalWaypoint]].self, from: raw)
        else { return [:] }
        return read
    }
}

/// A place on the path through a portal — **identifier and title, nothing more.**
///
/// The identifier reopens the level, the title stands in the path row until the
/// answer is there. The entries are explicitly **not** remembered: they last
/// only seconds, and a portal that has changed its list should show the new one
/// and not yesterday's.
public struct PortalWaypoint: Codable, Sendable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case identifier = "kennung"
        case title = "titel"
    }

    public let identifier: String
    public let title: String

    public init(identifier: String, title: String) {
        self.identifier = identifier
        self.title = title
    }
}
