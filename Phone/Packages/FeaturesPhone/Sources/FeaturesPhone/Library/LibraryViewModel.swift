import DesignSystemPhone
import Diagnose
import Flows
import Foundation
import Observation

/// Which catalog is shown and what is in it.
@MainActor
@Observable
public final class LibraryViewModel {

    public enum Situation: Sendable, Equatable {
        case isLoading
        case settled
        case empty
        case disrupted(PlaybackPhase)
    }

    public private(set) var state: Situation = .isLoading
    public private(set) var catalogs: CatalogState = .empty
    /// The whole catalog, unfiltered.
    private var allTiles: [TileContent] = [] {
        didSet { catalogRevision &+= 1 }
    }

    /// Counts every change to the catalog.
    ///
    /// **It is explicitly observed and not ``ObservationIgnored``** — the whole
    /// memoization in ``order`` hangs on it. Whoever caches the ordered list reads
    /// ``allTiles`` **no longer** on the next rebuild; SwiftUI would then no longer register
    /// the view for ``allTiles``, and a freshly loaded category would appear only at the
    /// next occasion. This number is read instead, changes with every
    /// assignment — and thereby keeps the registration alive.
    private var catalogRevision = 0

    /// What was ordered last, and from what.
    ///
    /// **``ObservationIgnored``, because writes happen during the view rebuild here.** An
    /// observed memo would report to every reader a change that is none — and thereby
    /// trigger exactly the rebuild it is meant to save.
    @ObservationIgnored
    private var rememberedOrder: (revision: Int, slice: CatalogSlice?, choice: OrderChoice, result: Order)?

    /// What has already been fetched once — **per catalog and per category.**
    ///
    /// **User finding of 2026-09-05: why does something like this always have to reload and
    /// cannot be kept in caches?** The images had long been on disk (measured:
    /// 859 files, 29 MB); the **title lists** were not. Every switch back to "Movies"
    /// fetched 102 titles anew, and the screen said "taking longer than usual".
    ///
    /// **In working memory and not on disk.** A title list is not an image: It
    /// carries progress, watched mark and favorites, and those change while you use
    /// the app — also from another device. Kept across a launch it would show
    /// yesterday's state, and nobody would see that. For a session it is right; beyond
    /// that it would be an assertion.
    ///
    /// **Shown immediately, fetched anyway.** Whoever switches back sees the old
    /// list without waiting; what the server reports in the meantime replaces it
    /// silently. A loading state over a list that is already there is an impediment
    /// without use.
    private var kept: [Catalog.Identifier: [TileContent]] = [:]
    private var keptPerCategory: [String: [TileContent]] = [:]

    /// The ordered list including jump marks — **once per catalog, not per rebuild.**
    ///
    /// **The finding, recalculated:** This line re-sorted the 4,211 titles of the largest
    /// category on **every** rebuild — when scrolling, when opening a sheet, on
    /// every press of a chip. Nothing new was being computed: Neither the catalog
    /// nor the cut-out nor the order choice had changed.
    ///
    /// **Remembered by three quantities and not by the list itself.** Comparing
    /// 4,211 tiles cost more than sorting; ``catalogRevision`` answers
    /// the same question with a number.
    public var order: Order {
        let revision = catalogRevision
        if let remembered = rememberedOrder, remembered.revision == revision,
            remembered.slice == slice, remembered.choice == choice
        {
            return remembered.result
        }
        let fresh = choice.sorting.arrange(
            title, ascending: choice.ascending, explicit: choice.explicit)
        rememberedOrder = (revision, slice, choice, fresh)
        return fresh
    }

    /// What is shown — the cut-out from ``allTiles``.
    ///
    /// **Filtering happens in memory, not on the server.** Seen on screen: Every
    /// press of a chip threw the list away, fetched the catalog state including six
    /// counts anew and loaded the catalog a second time — for a question that can be
    /// answered from what is already there. Four seconds later it said "Taking longer
    /// than usual".
    ///
    /// *This paragraph stood above ``order`` until 2026-09-10 and described something
    /// different from what stands beneath it — noticed while building the memo.*
    public var title: [TileContent] {
        guard let slice else { return allTiles }
        return allTiles.filter { tile in
            switch slice {
            // **By state and not by progress or checkmark** — finding of
            // 2026-09-05: Jellyfin keeps both only on episodes and movies. With twenty-three
            // series, "Started" therefore stayed empty, and "Unwatched" would have shown all of
            // them, including those completely watched. See ``WatchState``.
            case .started: tile.state == .started
            case .unwatched: tile.state == .untouched
            case .favorites: tile.favorite
            }
        }
    }

    /// Which catalog is currently shown.
    ///
    /// **Persists beyond the program run, since 2026-09-09** "If I was at DE
    /// Kino, I land at DE Kino again" is an explicit product decision in the sister
    /// project, and there it is justified not as a convenience but as the
    /// navigation itself: With 27,558 titles, it is not the start view that decides whether
    /// the area is usable, but whether you come out again where you
    /// left off. Before, the same sentence applied only to the **session** — see
    /// ``CatalogMemory``.
    public private(set) var chosen: Catalog?

    /// Which cut-out — `nil` means the whole catalog.
    public private(set) var slice: CatalogSlice?

    /// What it is ordered by.
    ///
    /// **Remembered per catalog, not per category.** With 108 categories, 108 remembered
    /// orderings would be 108 surprises; the TV has already decided it this way.
    public private(set) var choice = OrderChoice.preset(forItem: .movies)
    /// **Beyond the program run, since 2026-09-06** Before, the choice lived only here in
    /// working memory: Whoever had sorted the movies by rating started alphabetically
    /// again at the next launch — and Home could not read it anyway.
    /// See ``SortMemory``.
    private let sortOrders: SortMemory

    /// Which orderings this catalog offers — for home videos, no rating.
    public var availableOrders: [Sorting] {
        Sorting.possible(forItem: chosen?.kind ?? .movies)
    }

    /// The categories of the chosen catalog. Empty means: There is no intermediate level.
    public private(set) var categories: [GenreCategory] = []

    /// Which category is open. `nil` where there is none.
    public private(set) var category: GenreCategory?

    private let source: (any CatalogSource)?
    private let memory = CategoryMemory()

    /// Which catalog was open last — **beyond the program launch.**
    ///
    /// The level above the other two memories; without it the remembered
    /// category and the remembered order lead nowhere, because you do not even land again
    /// at the catalog they belong to. See ``CatalogMemory``.
    private let catalogChoice = CatalogMemory()

    /// - Parameter sortierungen: where the chosen orderings live — in the program the
    ///   usual store, in checks one of their own.
    public init(
        source: (any CatalogSource)?, sortOrders: SortMemory = SortMemory()
    ) {
        self.source = source
        self.sortOrders = sortOrders
    }

    /// **Which load run may write** (review 2026-09-27, D-S2). "Movies" tapped
    /// (slow, over the tunnel), right after it "Series" (from the cache): The
    /// late movie answer overwrote the series, and under the heading "Series" stood
    /// movies. With 108 categories at the provider the same. Every run — catalog, category
    /// or refresh — draws a token; an older one writes nothing after its fetch.
    @ObservationIgnored private var loadRun = 0

    /// A catalog's order: **the remembered one, otherwise the default of its kind.**
    ///
    /// One place for both ways in (review 2026-09-27, D-S1): Until then only
    /// ``select(_:)`` read the store. On a cold start ``load()`` set the remembered
    /// catalog but left the order at the movies' default — the button showed "A–Z",
    /// although the store held "Rating", and home videos opened alphabetically. The
    /// TV reads the order in its model's creator.
    private func rememberedChoice(zu catalog: Catalog) -> OrderChoice {
        sortOrders.last(zu: catalog.id) ?? OrderChoice.preset(forItem: catalog.kind)
    }

    /// The name of the shown catalog — for the large title.
    public var titleLine: CaptionLabel? { chosen?.label }

    /// Which cut-outs this catalog knows.
    ///
    /// Empty means: no chip row. A switch with one side is no switch.
    public var availableSlices: [CatalogSlice] {
        guard let chosen else { return [] }
        return CatalogSlice.forItem(chosen.kind, origin: chosen.origin)
    }

    public func load() async {
        guard let source else {
            state = .disrupted(.notSetUpYet)
            return
        }
        loadRun &+= 1
        let tag = loadRun
        do {
            let newState = try await source.state()
            guard tag == loadRun else { return }
            catalogs = newState
            // **The remembered choice may have disappeared** — a provider rearranges its
            // catalog, an access is removed. Then fall back to the first one and
            // not to an empty screen.
            //
            // **And on a cold start it is not there at all.** Then it comes from
            // disk (``CatalogMemory``) — before, every restart fell back to the first
            // catalog in server order, no matter where you were last.
            if chosen == nil || !newState.catalogs.contains(where: { $0.id == chosen?.id }) {
                let remembered = catalogChoice.last
                chosen =
                    newState.catalogs.first { $0.id == remembered } ?? newState.catalogs.first
                if let fresh = chosen { choice = rememberedChoice(zu: fresh) }
            }
            guard let catalog = chosen else {
                state = .empty
                return
            }

            // **Categories first, then titles.** Where there are none, an empty
            // list comes back and the view shows no choice at all — the intermediate level
            // does not arise from the view knowing about it, but from the
            // source having something to choose.
            let foundCategories = (try? await source.categories(zu: catalog)) ?? []
            guard tag == loadRun else { return }
            categories = foundCategories
            if categories.isEmpty {
                category = nil
                let fetched = try await source.title(from: catalog, slice: nil)
                guard tag == loadRun else { return }
                allTiles = fetched
                kept[catalog.id] = allTiles
            } else {
                if category == nil || !categories.contains(where: { $0.id == category?.id }) {
                    // **Carry on where you left off.** With 108 categories
                    // it is not the start view that decides whether the area is usable,
                    // but whether you come out again where you were.
                    let remembered = memory.last(zu: catalog.id)
                    category = categories.first { $0.id == remembered } ?? categories.first
                }
                if let pending = category {
                    let fetched = try await source.title(from: pending)
                    guard tag == loadRun else { return }
                    allTiles = fetched
                    keptPerCategory[pending.id] = allTiles
                } else {
                    allTiles = []
                }
            }
            state = title.isEmpty ? .empty : .settled
        } catch {
            guard tag == loadRun else { return }
            Diagnose.error(.network, "Library not loaded", error)
            state = .disrupted(.networkJellyfin)
        }
    }

    public func select(_ catalog: Catalog) async {
        guard catalog.id != chosen?.id else { return }
        chosen = catalog
        // **Remembered here and not in ``load()``.** The fallback to the
        // first catalog is also set there — remembering that would mean storing a makeshift as a choice.
        catalogChoice.memorize(catalog.id)
        // The category belonged to the previous catalog. Taking it along would mean looking
        // in the series for a movie category.
        category = nil
        categories = []
        // The cut-out applies to the catalog in which it was set. Taking it along
        // would mean filtering a collections library by "Started".
        slice = nil
        // The order belongs to the catalog — whoever sorted the movies by rating
        // finds it there again and not at the series. And where nothing has been chosen
        // yet, the default **of the kind** applies: Home videos open by
        // recording date, not alphabetically — they are called "Video_010".
        choice = rememberedChoice(zu: catalog)
        // **What was there once is immediately there again.** Only where nothing is stored is
        // there a loading state — otherwise it would be an impediment over a list you
        // could long since read.
        allTiles = kept[catalog.id] ?? []
        state = allTiles.isEmpty ? .isLoading : .settled
        await load()
    }

    /// Switches the category.
    ///
    /// **This reloads, unlike the cut-out** — and the difference is
    /// no accident: A cut-out is a question to what is already there; a category
    /// is a different catalog. The provider delivers its titles per category, and no
    /// filtering in memory can fetch titles that were never fetched.
    public func select(category incoming: GenreCategory) async {
        guard incoming.id != category?.id, let source else { return }
        category = incoming
        if let catalog = chosen { memory.memorize(incoming.id, zu: catalog.id) }
        slice = nil
        allTiles = keptPerCategory[incoming.id] ?? []
        state = allTiles.isEmpty ? .isLoading : .settled
        loadRun &+= 1
        let tag = loadRun
        do {
            let fetched = try await source.title(from: incoming)
            guard tag == loadRun else { return }
            allTiles = fetched
            keptPerCategory[incoming.id] = allTiles
            state = title.isEmpty ? .empty : .settled
        } catch {
            guard tag == loadRun else { return }
            Diagnose.error(.network, "Category not loaded", error)
            // **The old state stays if there is one.** An error message
            // over a list you could still read a moment ago takes away more than it
            // explains.
            state = allTiles.isEmpty ? .disrupted(.networkJellyfin) : .settled
        }
    }

    /// Switches the order — **without reloading.**
    ///
    /// The titles are already there, and each of the three orders reads only fields that
    /// sit on the tile. A round trip for that would be dearly paid for with a provider
    /// account with one permitted connection, for a calculation that takes milliseconds.
    /// **One press sorts, the second reverses, the third restores the default**
    /// — the TV's cycling logic; see ``OrderChoice/next(after:pressOn:kind:)``.
    public func tap(_ tapped: Sorting) {
        guard let catalog = chosen else { return }
        choice = OrderChoice.next(
            after: choice, pressOn: tapped, kind: catalog.kind)
        // **The default is not remembered.** It is not a state but the
        // absence of a state; storing it would mean saving "I chose nothing" and
        // reading it as a choice at the next opening. ``SortMemory``
        // therefore deletes the entry itself.
        sortOrders.memorize(choice, zu: catalog.id)
    }

    /// Switches the cut-out — **without reloading.**
    ///
    /// The titles are already there; which of them are started or unwatched is on the
    /// tile. A load for that would be a round trip for a question the store
    /// answers — and a second one when switching back to "All".
    public func select(slice new: CatalogSlice?) {
        slice = new == slice ? nil : new
    }
}
