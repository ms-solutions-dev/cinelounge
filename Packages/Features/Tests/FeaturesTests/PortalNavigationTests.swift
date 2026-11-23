import Core
import Foundation
import JellyfinKit
import SwiftUI
import Testing

@testable import Features

/// **The navigation of the portal area, stated as a claim about values.**
///
/// The reason has to be recorded explicitly: the attempt of 2026-08-27 went onto the device
/// unchecked and did not hold — the way back lived in a closure, and a closure cannot be
/// queried. What stands here is therefore not an extra but the condition for the fix
/// to hold.
@Suite("Portals: navigation")
/// On the main actor, because the rules under test live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct PortalNavigationTests {

    typealias Spot = MainView.Spot

    // MARK: - The stairs out (defect 1)

    /// **The step that was missing.** The staircase of the provider library knows
    /// only start of list and sidebar; a portal leads arbitrarily deep.
    @Test("The portal staircase has exactly one step more than the provider's")
    func portalLadderHasOneMoreStep() {
        #expect(FocusRules.portalLadder == [.topOfList, .level, .sidebar])
        // And at this position: after the start of the list, before the
        // sidebar. First unwind the path, and only when the path is empty
        // leave the area.
        #expect(FocusRules.vodLadder == [.topOfList, .sidebar])
    }

    /// **The finding as reported** (2026-08-27): the viewer could not get back out of "Most Watched".
    /// Whoever is at the top of the list and has a level below them
    /// gets that level — not the sidebar.
    @Test("From depth the press leads one level back, not into the bar")
    func deepLevelStepsBackOneLevel() {
        let ids = ["a", "b", "c"]
        let pending = LibraryView.pendingExitSteps(focus: "a", ids: ids, hasLevel: true)

        #expect(FocusRules.stepOut(along: FocusRules.portalLadder, pending: pending) == .level)
    }

    /// At the root level there is nothing to unwind — there the sidebar is next.
    /// A press that "shortens" the empty path looks like a dead
    /// button on a TV.
    @Test("On the root level the press leads into the sidebar")
    func rootLevelGoesToSidebar() {
        let pending = LibraryView.pendingExitSteps(
            focus: "a", ids: ["a", "b"], hasLevel: false)

        #expect(FocusRules.stepOut(along: FocusRules.portalLadder, pending: pending) == .sidebar)
    }

    /// The first step stays the first: whoever is in the middle of a long list
    /// comes to its start first — even if a level lies below.
    @Test("In the middle of the list, the top of the list comes before the level")
    func topOfListComesFirst() {
        let pending = LibraryView.pendingExitSteps(
            focus: "c", ids: ["a", "b", "c"], hasLevel: true)

        #expect(
            FocusRules.stepOut(along: FocusRules.portalLadder, pending: pending) == .topOfList)
    }

    /// The three presses in order, as they arrive on the device: start of the
    /// list, one level back, sidebar.
    @Test("Three presses, three steps")
    func threePressesThreeSteps() {
        let ids = ["a", "b", "c"]

        var slots: [FocusRules.ExitStep?] = []
        slots.append(
            FocusRules.stepOut(
                along: FocusRules.portalLadder,
                pending: LibraryView.pendingExitSteps(focus: "c", ids: ids, hasLevel: true)))
        slots.append(
            FocusRules.stepOut(
                along: FocusRules.portalLadder,
                pending: LibraryView.pendingExitSteps(focus: "a", ids: ids, hasLevel: true)))
        slots.append(
            FocusRules.stepOut(
                along: FocusRules.portalLadder,
                pending: LibraryView.pendingExitSteps(focus: "a", ids: ids, hasLevel: false)))

        #expect(slots == [.topOfList, .level, .sidebar])
    }

    /// **The staircase of the provider library does not know the step** — and
    /// skips it instead of choking on it. That is exactly why the
    /// staircase is a value and not a chain of `if`s.
    @Test("Whoever does not offer the step skips it")
    func laddersWithoutTheStepSkipIt() {
        let pending = LibraryView.pendingExitSteps(
            focus: "a", ids: ["a"], hasLevel: true)

        #expect(FocusRules.stepOut(along: FocusRules.vodLadder, pending: pending) == .sidebar)
    }

    // MARK: - The path belongs to the place (defect 4)

    /// **Every destination has a place.** The version of 2026-08-26 returned `nil` for Live, Search,
    /// Favorites, Sports and Settings — and the reset, which
    /// needed two places, therefore did not fire on any path across one of these
    /// areas.
    @Test("Every sidebar destination has a place")
    func everyDestinationHasAPlace() {
        #expect(MainView.location(of: .portalProvider("serieshub")).area == .portals)
        #expect(MainView.location(of: .portals).area == .portals)
        #expect(MainView.location(of: .vodProvider("liste1")).area == .vod)
        #expect(MainView.location(of: .search) == .search)
        // And the areas that keep no path of their own land on the path of the
        // library — instead of on none.
        #expect(MainView.location(of: .live) == .media)
        #expect(MainView.location(of: .liveProvider("p")) == .media)
        #expect(MainView.location(of: .favorites) == .media)
        #expect(MainView.location(of: .sport) == .media)
        #expect(MainView.location(of: .settings) == .media)
        #expect(MainView.location(of: .media) == .media)
    }

    /// Two portals are two places in the same area — otherwise they would share
    /// one path, and the levels of one would lie above the root of the other.
    @Test("Two portals share the section but not the path")
    func twoPortalsAreTwoPlaces() {
        let serieshub = MainView.location(of: .portalProvider("serieshub"))
        let animehub = MainView.location(of: .portalProvider("animehub"))

        #expect(serieshub.area == animehub.area)
        #expect(serieshub != animehub)
    }

    /// **The finding of 2026-08-27 as a calculation** (when switching to another view
    /// in Portals, the right-hand side stays stuck): the path
    /// of one portal must not lie above the root of the other when switching.
    @Test("A portal switch shows the new portal's path, not the old one")
    func switchingPortalsSwitchesThePath() {
        var routes: [Spot: [MediaItem]] = [:]
        let serieshub = MainView.location(of: .portalProvider("serieshub"))
        let animehub = MainView.location(of: .portalProvider("animehub"))

        routes[serieshub] = [Self.entry("beliebte"), Self.entry("action")]

        #expect(routes[animehub, default: []].isEmpty)
        #expect(routes[serieshub]?.count == 2)
    }

    /// **And exactly that is what the reset could not do** (bug 4): It required
    /// that both destinations have a place. Serieshub three levels deep → Live →
    /// Animehub left the old path standing. With one path per place, the
    /// way back survives the excursion — and still does not disturb the neighbor.
    @Test("A trip to Live leaves each portal its own way back")
    func adetourThroughLiveKeepsEveryPath() {
        var routes: [Spot: [MediaItem]] = [:]
        let serieshub = MainView.location(of: .portalProvider("serieshub"))
        let animehub = MainView.location(of: .portalProvider("animehub"))

        routes[serieshub] = [Self.entry("a"), Self.entry("b"), Self.entry("c")]
        // The excursion: Live keeps no path of its own and does not touch that of the portals.
        let live = MainView.location(of: .live)
        routes[live, default: []].append(Self.entry("sender"))

        #expect(routes[animehub, default: []].isEmpty)
        #expect(routes[serieshub]?.count == 3)
    }

    private static func entry(_ id: String) -> MediaItem {
        MediaItem(id: id, kind: .folder, title: id)
    }

    // MARK: - The kind filter (defect 2)

    /// A portal level delivers episodes, movies, seasons and folders
    /// side by side. Any kind filter would be a claim about a list that is
    /// not ours — and as long as `.series` was in there, nothing was left of "New Episodes".
    @Test("A portal level filters no kind out")
    func portalLevelFiltersNoKind() {
        #expect(HomeModel.kinds(for: .portalLevel).isEmpty)
        // The other kinds stay as they were.
        #expect(HomeModel.kinds(for: .series) == [.series])
        #expect(HomeModel.kinds(for: .movies) == [.movie])
    }

    /// Both calculations must yield the same thing — one warms the downloads, the
    /// other draws the view. If they diverged, the downloads would sit under
    /// a foreign key and be silently ineffective.
    @Test("Prefetch and view calculate the same for portal levels too")
    func prewarmAndViewAgree() {
        #expect(
            JellyfinSource.itemKinds(for: .portalLevel) == HomeModel.kinds(for: .portalLevel))
    }

    // MARK: - The order (defect 3)

    /// **The finding as reported** (2026-08-27): the bridge delivers Ironbell,
    /// Hollins, President Varga; the app showed Sturmopfer, Club der stillen
    /// Fenster, Ironbell.
    @Test("A portal level resolves in its own order")
    func portalLevelOpensInSourceOrder() {
        let defaultOrder = LibraryModel.SortOrder.standard(for: .portalLevel)

        #expect(defaultOrder.sorting == .natural)
        #expect(defaultOrder.isExplicit == false)
        #expect(defaultOrder.sorting.filter == .natural)
        // And the other areas stay as they were.
        #expect(LibraryModel.SortOrder.standard(for: .movies).sorting == .title)
        #expect(LibraryModel.SortOrder.standard(for: .homeVideos).sorting == .recorded)
    }

    /// The default is a default and not a rule: three
    /// presses on "Title" cycle through A–Z, Z–A and back to the order
    /// of the source.
    @Test("Three presses on Title lead back to the source's order")
    func threeTapsReturnToSourceOrder() {
        let start = LibraryModel.SortOrder.standard(for: .portalLevel)

        let first = LibraryModel.next(after: start, tapping: .title, in: .portalLevel)
        #expect(first.sorting == .title)
        #expect(first.ascending)
        #expect(first.isExplicit)

        let second = LibraryModel.next(after: first, tapping: .title, in: .portalLevel)
        #expect(second.sorting == .title)
        #expect(second.ascending == false)

        let third = LibraryModel.next(after: second, tapping: .title, in: .portalLevel)
        #expect(third == start)
    }

    /// **No button for the default.** It is the state in which nothing is
    /// chosen; a button for it would need a language key that nobody
    /// would ever see. **And no date** — no portal delivers one
    /// (measured 2026-09-13).
    @Test("A portal level's filter row knows title and rating, no date")
    func portalLevelOffersTitleAndRating() {
        #expect(LibraryModel.Sorting.choices(for: .portalLevel) == [.title, .rating])
        #expect(LibraryModel.Sorting.natural.titleKey == nil)
        #expect(LibraryModel.Sorting.title.titleKey == "sort.title")
    }

    /// **"Rating" is only there if the level carries ratings** (2026-09-13).
    /// Animehub delivers them, Serieshub and Ahorn do not — there the button would be one
    /// without effect. Before loading, the full list applies, so that a remembered choice does not
    /// fail on the order of row and data.
    @Test("The rating button depends on the loaded catalog")
    func ratingChoiceFollowsTheItems() async {
        let level = Core.Library(id: "animehub||/beliebt", name: "Beliebt", kind: .portalLevel)
        let withRating = LibraryModel(
            source: LevelSource(title: [
                MediaItem(id: "a|k|1", kind: .series, title: "A", ratings: Ratings(community: 8)),
                MediaItem(id: "a|k|2", kind: .series, title: "B"),
            ]),
            library: level, store: InMemoryStore())
        #expect(withRating.sortingChoices == [.title, .rating])
        await withRating.load()
        #expect(withRating.sortingChoices == [.title, .rating])

        let without = LibraryModel(
            source: LevelSource(title: [MediaItem(id: "s|k|1", kind: .series, title: "A")]),
            library: level, store: InMemoryStore())
        await without.load()
        #expect(without.sortingChoices == [.title])
    }

    /// A level that delivers exactly the titles passed in.
    struct LevelSource: ContentSource {
        let title: [MediaItem]
        nonisolated var displayName: String { "Ebene" }
        nonisolated var canStartAtOffset: Bool { false }
        /// **A test double keeps its own state** — nobody should wrap it.
        nonisolated var tracksStateItself: Bool { true }
        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        )
            -> URL?
        { nil }
        func libraries() async throws -> [Core.Library] { [] }
        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            title
        }
        func item(id: String) async throws -> MediaItem { throw Missing.nothing }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw Missing.nothing
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
        enum Missing: Error { case nothing }
    }

    /// Whatever ``LibraryModel/Sorting/choices(for:)`` does not list counts as never
    /// remembered — otherwise a sort by rating would be active with no
    /// matching button in the filter row.
    @Test("A remembered order that does not exist here counts as never remembered")
    func storedOrdersAreCheckedAgainstTheChoices() {
        let store = InMemoryStore()
        let level = Core.Library(id: "serieshub|beliebte", name: "Beliebt", kind: .portalLevel)

        // `.dateAdded` does not exist for a portal level — `.rating` does, since
        // 2026-09-13.
        LibraryModel.saveOrder(
            LibraryModel.SortOrder(sorting: .dateAdded, ascending: false, isExplicit: true),
            for: Core.Library(id: "serieshub|beliebte", name: "Beliebt", kind: .movies),
            to: store
        )

        #expect(
            LibraryModel.loadOrder(for: level, from: store)
                == LibraryModel.SortOrder.standard(for: .portalLevel))
    }
}

/// **An item belongs to its place — and the identifier says which.**
///
/// The same bug has occurred four times (2026-08-15, 2026-08-23, 2026-08-28 twice):
/// an item was opened at the wrong place, the detail page asked the
/// media server for `serieshub|bowline:2014|…`, and the TV showed "The
/// server reports a fault" — while the same title opened fine through its portal.
/// The fourth time, the rule got a test.
@MainActor
@Suite("An entry finds its place")
struct PortalSpotTests {

    @Test("A portal entry leads into its portal")
    func portalEntryFindsItsPortal() {
        let item = MediaItem(
            id: "serieshub|serieshub:bowline:2014|f=showSeasons&sUrl=x",
            kind: .series,
            title: "Bowline"
        )
        // Without `#require`: the compiler says the expression is never `nil`,
        // so the guard could not possibly trigger (AP15,
        // 2026-09-02, found by the warning gate). The two assertions
        // below carry the case on their own anyway.
        let location = MainView.location(forItem: item)
        #expect(location?.area == .portals)
        #expect(location?.id == "serieshub")
    }

    /// The counter-check, and it is the more important one: a title from the media server
    /// must **not** end up at a portal. Without it the rule would be a
    /// trap in the other direction.
    @Test(
        "What belongs to no portal stays in the library",
        arguments: [
            "a1b2c3d4e5f60718293a4b5c6d7e8f90",
            "",
            "nur|zwei",
            // Xtream has the same shape as a portal (diagnosis F-056, 2026-10-01).
            "xtream|iptvhost.example|maxdoe#movie#343792#mp4",
        ])
    func foreignStaysInLibrary(_ identifier: String) {
        let item = MediaItem(id: identifier, kind: .series, title: "Irgendwas")
        #expect(MainView.location(forItem: item) == nil)
    }
}

/// **What is shown when nothing is shown.**
///
/// The reason is an error pattern that was none (viewer finding 2026-08-28): on the
/// TV it said "list: RuntimeError" for an empty list — red
/// and like a defect — while simply no title of this category was on
/// this page. An empty folder is a normal case for a portal; the bridge
/// has answered with an empty level since then, and this page says what that
/// means. Both are statements, and they are different.
@MainActor
@Suite("Portals: an empty level is not an error")
struct PortalEmptyTests {

    // What is tested is the **distinction**, not the wording: that is in the
    // language file, and `scripts/strings.py` checks that it is there. In the
    // check run the app bundle does not exist at all — an assertion on
    // "Nothing here." would only check here that a key is passed through
    // untranslated.

    @Test("Two cases, two messages")
    func twoCases() {
        let emptyText = PortalList.emptyText(needle: "")
        let withoutMatches = PortalList.emptyText(needle: "milf")
        #expect(
            emptyText != withoutMatches, "\"nothing here\" and \"nothing found\" are two different things")
    }

    @Test("After a search the term is named")
    func termNamed() {
        let text = PortalList.emptyText(needle: "milf")
        #expect(text.contains("milf"), "without the term it stays unclear what was searched for")
    }

    @Test("Without a search no term appears")
    func noTermWithoutSearch() {
        let text = PortalList.emptyText(needle: "")
        #expect(!text.contains("%@"), "the placeholder must not leak through")
    }
}

/// **Who remembers what.**
///
/// "Portals" leads back to where one last stood — but only when one comes from
/// **outside**. Whoever goes to "Portals" from within a portal wants
/// the overview and must not be thrown back; without this
/// distinction the selection would be unreachable.
@MainActor
@Suite("Portals: the way back into the last opened")
struct PortalFamilyTests {

    @Test(
        "What belongs to the portal family",
        arguments: [
            (AppSidebar.Destination.portals, true),
            (AppSidebar.Destination.portalProvider("animehub"), true),
            (AppSidebar.Destination.media, false),
            (AppSidebar.Destination.search, false),
            (AppSidebar.Destination.vodProvider("x"), false),
        ])
    func family(_ scenario: (AppSidebar.Destination, Bool)) {
        #expect(MainView.isPortalFamily(scenario.0) == scenario.1)
    }
}
