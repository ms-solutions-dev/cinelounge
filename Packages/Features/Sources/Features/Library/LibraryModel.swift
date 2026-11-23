import Core
import DesignSystem
import Flows
import Foundation
import JellyfinKit
import ParentalControls
import PortalKit
import RatingsKit
import SwiftUI

/// Loads a library as a grid and manages sorting and jump marks.
public final class LibraryModel: ObservableObject {

    public enum State: Equatable {
        case loading
        case ready([MediaItem])
        case failed(String)
        case empty

        /// Siehe ``HomeModel/State/isFailed``.
        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// How sorting works. Deliberately few options: on a TV every
    /// additional choice is another click with the remote.
    public nonisolated enum Sorting: String, CaseIterable, Identifiable, Sendable {
        case title
        case dateAdded
        case rating
        /// When recorded — offered only for home videos, where it is the
        /// default.
        case recorded
        /// **As the source delivers.** The default of the portal levels —
        /// reasoning at ``Core/ItemFilter/SortBy/natural``.
        case natural

        public var id: String { rawValue }

        /// The label of the sort button — `nil` if this order has no
        /// button.
        ///
        /// **`.natural` has none**, and that is not an oversight: it is the
        /// state in which nothing at all is chosen (see ``choices(for:)``),
        /// and therefore appears in no filter row. A language key for it
        /// would be one nobody ever gets to see.
        public var titleKey: String? {
            switch self {
            case .title: "sort.title"
            case .dateAdded: "sort.dateAdded"
            case .rating: "sort.rating"
            case .recorded: "sort.recorded"
            case .natural: nil
            }
        }

        var filter: Core.ItemFilter.SortBy {
            switch self {
            case .title: .title
            case .dateAdded: .dateAdded
            case .rating: .rating
            case .recorded: .dateCreated
            case .natural: .natural
            }
        }

        /// Ascending for titles, descending for date and rating — that is
        /// in each case the direction one expects.
        ///
        /// `.natural` does not sort; for it ascending means "as
        /// delivered" — the direction in which ``PortalSource/filtered(_:after:)``
        /// leaves the list as is.
        var ascending: Bool { self == .title || self == .natural }

        /// Which orders are offered for this kind of library.
        ///
        /// For home videos rating is pointless — they have none — and the
        /// title says nothing for `Video_017`. Conversely, a recording date
        /// does not help with series.
        ///
        /// **A portal level offers "Title" and "Rating"**, both as a choice
        /// against its own order; the default `.natural` needs no
        /// button — the third press restores it (``next(after:tapping:in:)``).
        ///
        /// **No date**, and that is measured (2026-09-13, on the bridge): no
        /// entry of a portal carries one. "New" there is an entry point of its own
        /// ("New episodes"), and its order is exactly `.natural`.
        ///
        /// **Not every portal delivers a rating** — Animehub for 43 of 45,
        /// Serieshub and ARD for none. Whether the button appears in the row
        /// is therefore decided by ``LibraryModel/sortingChoices`` on the loaded catalog;
        /// here is what the store may accept.
        static func choices(for kind: Core.Library.Kind) -> [Sorting] {
            switch kind {
            case .homeVideos: [.recorded, .title]
            case .portalLevel: [.title, .rating]
            default: [.title, .dateAdded, .rating]
            }
        }
    }

    @Published public private(set) var state: State = .loading
    /// How sorting currently works — see ``SortOrder``.
    @Published public private(set) var order: SortOrder = .standard(for: .movies)

    /// The chosen order, for views that only need it.
    public var sorting: Sorting { order.sorting }
    /// Which slice is shown — `nil` means the whole library.
    ///
    /// **The same chips as on the phone** (decision 27, C6): "Started", "Unwatched",
    /// "Favorites", one at a time, filtered by the title's state
    /// (``Flows/CatalogSlice``). Until 2026-09-26 there was only "Unwatched" here as
    /// a switch of its own, and it let started films and every series through.
    @Published public private(set) var slice: CatalogSlice?

    /// Which slices this library knows — **gone instead of greyed out**: the
    /// provider catalog and the portals keep no state, so the row is omitted there.
    public var availableSlices: [CatalogSlice] {
        CatalogSlice.forItem(
            kind: library.kind,
            tracksState: Origin.forItem(library: library.id) == .jellyfin)
    }

    /// The chosen category, or `nil` for all.
    ///
    /// **It sits next to the sorting, not instead of it** — that is the point of
    /// multiple filtering: whoever chooses "Anime" wants the anime *and* still wants to
    /// decide themselves whether they are ordered by title or by access, and wants to
    /// keep the jump marks. That is why none of the three settings is
    /// above the others.
    ///
    /// Explicitly **without** a new request: the library is fully present, and
    /// a category is a question about what is already there. A server call would be
    /// a wait for a selection that changes several times while trying it out.
    @Published public private(set) var category: String?
    /// Third-party ratings per title, for the column on the right. Only for the one
    /// currently in focus — fetching all in advance would be hundreds of requests.
    @Published public private(set) var externalRatings: [String: ExternalRatings] = [:]

    /// Readable because the detail page's image store needs it: ``DetailPrefetch``
    /// runs in the grid and has to arrive at **exactly the same** image addresses that
    /// the detail page draws later. Only the source is handed out, nothing
    /// beyond that — writing here still happens only from inside.
    ///
    /// **Filtered** (AP58 R1, finding K3): the source sits behind
    /// ``ParentalControls/FilteredSource``; the grid no longer asks for itself.
    public let source: any ContentSource

    /// The parental controls in force. Reasoning at ``HomeModel``.
    private let rule: ProtectionRule
    private let library: Core.Library
    private let anime: AnimeRating?
    private let omdb: OMDbClient?

    /// The viewer's bandwidth limit, read once and kept.
    ///
    /// It lives in the Keychain. An access to it on every starting trailer
    /// would be felt on the main thread, and it can only change in
    /// Settings — so not while a library is open.
    private var quality: StreamQuality?

    /// Where the chosen sorting lived **until AP58 R6** — the Keychain, from which
    /// ``loadOrder(for:from:keychain:)`` brings an old row over once.
    private let store: any KeyValueStore

    /// Where the chosen sorting lives — the shared board of both programs
    /// (``Core/SortStore``). From outside, so it can be tested without a file.
    private let sortStore: any KeyValueStore

    public init(
        source: any ContentSource,
        library: Core.Library,
        anime: AnimeRating? = nil,
        omdb: OMDbClient? = nil,
        rule: ProtectionRule = .pending,
        store: any KeyValueStore = SecureStore(),
        sortStore: (any KeyValueStore)? = nil
    ) {
        self.anime = anime
        self.omdb = omdb
        self.source = rule.about(source)
        self.rule = rule
        self.library = library
        self.store = store
        self.sortStore = sortStore ?? FileStore()
        // **In the initializer and not on load**: the first request has to
        // carry the remembered order already, otherwise a second one would follow it immediately.
        //
        // Without a memory the area's default — home videos begin
        // with the most recent date; ordered alphabetically `Video_001` from 2019 would stand
        // before the recording from last week.
        self.order = Self.loadOrder(for: library, from: self.sortStore, keychain: store)
    }

    public var libraryName: String { library.name }
    public var libraryKind: Core.Library.Kind { library.kind }

    /// Whether it is grouped by months instead of a continuous grid.
    public var usesDateGrouping: Bool { library.kind == .homeVideos && sorting == .recorded }

    /// The orders that appear in the filter row.
    ///
    /// **For a portal level only those that have an effect.** "Rating" above a
    /// list without ratings is a button without effect — the list would stay as it is,
    /// and the button would light up anyway. That is why it appears only when at least one
    /// loaded title carries one. As long as nothing is loaded, the full list applies: a
    /// remembered state must not fail because the row appears before the data.
    public var sortingChoices: [Sorting] {
        let all = Sorting.choices(for: library.kind)
        guard library.kind == .portalLevel, case .ready(let items) = state else { return all }
        let hasRatings = items.contains { $0.ratings.community != nil }
        return hasRatings ? all : all.filter { $0 != .rating }
    }

    /// Grouped by months. Empty if this grouping does not apply.
    public func groups(_ items: [MediaItem]) -> [DateGroup] {
        usesDateGrouping ? DateGroup.byMonth(items) : []
    }

    /// Whether a load has already succeeded once.
    ///
    /// Not the same as "the state is `.ready`": an empty library is also
    /// loaded, and it too should not be fetched again on coming back.
    private var didLoad = false

    /// **Which load run may write** (check 2026-09-27, D-S3). "Rating" pressed
    /// (server slow), right afterwards "Added" (fast): the later response of
    /// Rating overwrote the grid while the button showed "Added". Every run
    /// draws a mark; an older one writes nothing any more — not even an error.
    private var loadRun = 0

    /// How many entries the CL-Server has already collected for the sorted level —
    /// set while it is still collecting (AP60). The loading view shows the number.
    @Published public private(set) var preparedCount: Int?

    /// The marker of the next page of a portal level — `nil` when everything is there.
    ///
    /// **Until AP60 only page 1 arrived on the TV** (2026-09-30): Serieshub →
    /// Collections → "Anime Japan auf Deutsch" listed 900 entries and showed 24.
    private var next: String?
    private var isLoadingMore = false

    /// The filter used for fetching — the same for the first request and every following page.
    private var fetchFilter: Core.ItemFilter {
        Core.ItemFilter(
            kinds: HomeModel.kinds(for: library.kind),
            sortBy: order.sorting.filter,
            ascending: order.ascending
        )
    }

    /// The source, if it delivers page by page — asked only for portal levels.
    private var pageSource: (any PageSource)? {
        library.kind == .portalLevel ? source as? any PageSource : nil
    }

    /// Listens for silently swapped lists — reasoning at
    /// ``HomeModel``: the snapshot from startup needs someone to show the
    /// fresh data as well. The reload reads from the source's memory,
    /// without a network request, and replaces the content without a loading spinner.
    private var listObservation: Task<Void, Never>?

    private func observeListChanges() {
        guard listObservation == nil else { return }
        listObservation = Task { [weak self, source] in
            for await _ in await source.listChanges() {
                await self?.load(force: true)
            }
        }
    }

    deinit {
        listObservation?.cancel()
    }

    /// - Parameter force: Whether to fetch again despite existing data.
    ///
    ///   **Without this distinction every switch of the pill reloaded the library.**
    ///   From "Films" to "Series" and back means in SwiftUI: the view is
    ///   torn down and rebuilt, its `task` runs again, and the first line of
    ///   `load()` was `state = .loading` — so empty screen, spinner, new
    ///   request. That the source keeps the answer for two minutes did not help
    ///   against the spinner, and after two minutes it did not help at all.
    ///
    ///   Now it is fetched again only when there is a reason: a different sorting,
    ///   a changed filter, or a failure that waking up should
    ///   retry.
    public func load(force: Bool = false) async {
        observeListChanges()
        guard force || !didLoad else { return }

        // **The spinner only when nothing is there.** If something is already there, it
        // stays until the new data arrives — otherwise the screen blinks empty on every
        // change of sorting.
        if !didLoad { state = .loading }

        let filter = fetchFilter
        loadRun &+= 1
        let tag = loadRun
        defer { if tag == loadRun { preparedCount = nil } }

        do {
            // **Before any further selection.** What fails here must not
            // show up in a count, a register or a sorting either.
            var items: [MediaItem]
            if let pageSource {
                let piece = try await pageSource.page(
                    in: library.id, filter: filter, next: nil
                ) { [weak self] done in
                    await self?.notify(preparedCount: done, run: tag)
                }
                guard tag == loadRun else { return }
                items = piece.items
                next = piece.next
            } else {
                items = try await source.items(in: library.id, filter: filter)
                next = nil
            }
            guard tag == loadRun else { return }

            if let slice, availableSlices.contains(slice) {
                items = items.filter(slice.matches)
            }
            // A category that no longer exists after the reload would leave an
            // empty grid standing — and one with no way out:
            // the category list would then come from an empty catalog and offer
            // nothing any more, not even "All".
            if let category, !Self.categories(in: items).contains(category) {
                self.category = nil
            }
            // **Rows in sequence**, but only with the default — the
            // reasoning is at ``ordered(_:by:)``.
            state = items.isEmpty ? .empty : .ready(Self.ordered(items, by: order))
            didLoad = true
        } catch let failure as JellyfinSource.SourceFailure {
            guard tag == loadRun else { return }
            Diagnostics.defect(
                "Library not loaded: \(Diagnostics.explain(failure))", since: nil, area: "Oberfläche"
            )
            state = .failed(HomeModel.messageKey(for: failure))
        } catch is CancellationError {
            // Not an error but a cancellation — reasoning in ``HomeModel/load()``.
        } catch {
            Diagnostics.defect(
                "Library not loaded: \(Diagnostics.explain(error))", since: nil, area: "Oberfläche")
            // **What arrives here has often already said what it is missing** (AP39,
            // 2026-09-20). Until then `error.unreachable` stood at this place —
            // "No answer. Is the server running?". A rejection by the portal service
            // (`401 auth.profile_required`) thus became a question about the network,
            // and the viewer searched at the router while two clicks away
            // the profile selection stood. The interpretation knows the origin and says it more precisely;
            // where it knows nothing more specific, it returns the same sentence as before.
            guard tag == loadRun else { return }
            state = .failed(
                DisruptionInterpretation.rejection(forItem: error, origin: Origin.forItem(source: source)))
        }
    }

    private func notify(preparedCount done: Int, run: Int) {
        guard run == loadRun else { return }
        preparedCount = done
    }

    /// Append the next page of a portal level — **called when the grid
    /// reaches its end.**
    ///
    /// One at a time; a new load run (different sorting, different slice) makes
    /// a still-running follow-up page worthless, and it then writes nothing any more. An error
    /// leaves what is there: the first 48 titles have not become wrong just because
    /// the next ones did not arrive.
    public func loadMore() async {
        guard let tag = next, !isLoadingMore, let pageSource,
            case .ready(let previous) = state
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let run = loadRun
        do {
            let piece = try await pageSource.page(
                in: library.id, filter: fetchFilter, next: tag, progress: { _ in })
            guard run == loadRun else { return }
            next = piece.next
            let known = Set(previous.map(\.id))
            var fresh = piece.items.filter { !known.contains($0.id) }
            if let slice, availableSlices.contains(slice) {
                fresh = fresh.filter(slice.matches)
            }
            guard !fresh.isEmpty else { return }
            state = .ready(Self.ordered(previous + fresh, by: order))
        } catch {
            Diagnostics.defect(
                "Next page not loaded: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
        }
    }

    // MARK: - Watched and favorite

    /// Toggles a title's watched mark — directly from the grid.
    ///
    /// Before, the only way led through the detail page: open the card, move right across the
    /// button row, press, menu back — six to seven
    /// presses per title. For a tidy-up action in series ("I've seen those
    /// three") that is too deep; the long-press menu on the card makes it
    /// two.
    ///
    /// **The display goes first, the server follows** — the same trade-off as on
    /// the detail page: feedback only after the server's response is noticeable as a delay on
    /// the TV. If it fails, the old state comes back; a mark that is there and
    /// gone at the next opening is worse than one that never appears.
    public func toggleWatched(for item: MediaItem) async {
        let wanted = !item.isWatched
        replace(Self.marking(item, watched: wanted))
        do {
            try await source.setPlayed(wanted, for: item.id)
        } catch {
            Diagnostics.defect(
                "Watched mark not set: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
            replace(await (try? source.item(id: item.id)) ?? item)
        }
    }

    /// Resets the progress of a started title (user request
    /// 2026-08-15: long press instead of detail page).
    ///
    /// **Via the unwatched mark, not via a path of its own:** both
    /// sources — media server and provider — also reset the position when marking as unwatched; a separate
    /// "delete only the position" path is known to neither. A second contract point just for the same
    /// effect would be a branch without a difference.
    public func resetProgress(for item: MediaItem) async {
        var cleared = Self.marking(item, watched: false)
        cleared.progress = nil
        replace(cleared)
        do {
            try await source.setPlayed(false, for: item.id)
        } catch {
            Diagnostics.defect(
                "Progress not reset: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
            replace(await (try? source.item(id: item.id)) ?? item)
        }
    }

    public func toggleFavorite(for item: MediaItem) async {
        var updated = item
        updated.isFavorite = !item.isFavorite
        replace(updated)
        do {
            try await source.setFavorite(updated.isFavorite, for: item.id)
        } catch {
            Diagnostics.defect(
                "Favorite not set: \(Diagnostics.explain(error))", since: nil, area: "Oberfläche")
            replace(item)
        }
    }

    /// The title with its watched mark switched — as a pure calculation, so it
    /// can be tested without a server.
    ///
    /// For series the number of unwatched episodes is switched along: it is the
    /// information from which ``MediaItem/isWatched`` reads a series' state —
    /// if it stayed as it was, the card would keep showing the old state although the server
    /// had long since switched.
    static func marking(_ item: MediaItem, watched: Bool) -> MediaItem {
        var updated = item
        updated.progress = PlaybackProgress(
            position: watched ? (item.runtime ?? 0) : 0,
            duration: item.runtime ?? item.progress?.duration ?? 0,
            isWatched: watched
        )
        if item.kind == .series {
            updated.unplayedCount = watched ? 0 : (item.episodeCount ?? 1)
        }
        return updated
    }

    /// Replaces a title in the loaded catalog without reloading.
    ///
    /// Deliberately not `load(force:)`: that would fetch the whole library over the network
    /// while the long-press menu is still open — and over a thin line
    /// the feedback would stand still exactly when one is looking at it.
    private func replace(_ item: MediaItem) {
        guard case .ready(var items) = state,
            let index = items.firstIndex(where: { $0.id == item.id })
        else { return }
        items[index] = item
        state = .ready(items)
    }

    public func choose(category: String?) {
        self.category = category
    }

    /// Selects the category — or clears it if it was already selected.
    ///
    /// The rule lives here and not in the view because it is a rule: without
    /// the clearing, the way back to "All" would lead across the whole row, and
    /// on the remote that is the longest way for the most frequent undo.
    public func toggle(category name: String) {
        self.category = category == name ? nil : name
    }

    /// Which categories actually occur in this catalog, the most frequent first.
    ///
    /// **Derived from the catalog and not asked of the server.** The server knows
    /// its genres, but it does not know those of this library after the other
    /// filters — a list that offers categories under which nothing then appears
    /// is worse than none.
    ///
    /// Ordered by frequency, because on the remote every place further right
    /// is one more key press. With equal frequency alphabetical, so the order
    /// does not jump between two calls.
    ///
    /// - Parameter minimum: From how many titles a category is offered. Two,
    ///   not one: a genre with a single title is not an order but a
    ///   second way to the same title — and it is exactly these that make the list long
    ///   and unusable.
    public static func categories(in items: [MediaItem], minimum: Int = 2) -> [String] {
        var counts: [String: Int] = [:]
        for item in items {
            for genre in item.genres {
                counts[genre, default: 0] += 1
            }
        }
        return
            counts
            .filter { $0.value >= minimum }
            .sorted { left, right in
                left.value == right.value ? left.key < right.key : left.value > right.value
            }
            .map(\.key)
    }

    /// What remains after the category.
    ///
    /// A calculation of its own and not an already filtered state: the category list
    /// has to come from the **unfiltered** catalog, otherwise after the first choice
    /// only this one category would remain — and one could not get out again.
    public func visible(_ items: [MediaItem]) -> [MediaItem] {
        guard let category else { return items }
        return items.filter { $0.genres.contains(category) }
    }

    /// **One press sorts, the second reverses, the third switches off.**
    /// Which state follows is stated in ``LibraryModel/next(after:tapping:in:)``
    /// — here it is only applied.
    public func choose(_ sorting: Sorting) async {
        let next = Self.next(after: order, tapping: sorting, in: library.kind)
        guard next != order else { return }
        order = next
        Self.saveOrder(next, for: library, to: sortStore, keychain: store)
        // Forced: a different sorting is a reason to fetch again — unlike
        // a switch of the pill, where nothing has changed.
        await load(force: true)
    }

    /// A chip selects its slice, **a second press on the same one takes it
    /// back** — as on the phone.
    public func select(slice new: CatalogSlice) async {
        slice = slice == new ? nil : new
        await load(force: true)
    }

    // MARK: - Jump marks

    /// The initial letters under which there actually are titles.
    ///
    /// Without jump marks a large library cannot be managed with the remote
    /// — one would have to click through tile by tile. That is
    /// the second most frequent complaint about comparable apps.
    ///
    /// Only occupied letters are offered: a jump into nothing would be
    /// worse than no jump.
    public func initials(for items: [MediaItem]) -> [String] {
        let letters = Set(items.map(Self.initial))
        // Digits and special characters collect under one character.
        let sorted = letters.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            // Language-aware instead of by character number: `Ç` belongs next to `C`,
            // `Ö` next to `O` — as raw values both sorted after `Z`
            // (finding 2026-08-07 on a Turkish section).
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return sorted
    }

    /// The first title that sits under this letter.
    public func firstItem(startingWith initial: String, in items: [MediaItem]) -> MediaItem? {
        items.first { Self.initial($0) == initial }
    }

    static func initial(_ item: MediaItem) -> String {
        // Articles at the beginning would pile everything under "D" and "T".
        let stripped = Self.withoutLeadingArticle(item.title)
        guard let first = stripped.first else { return "#" }
        let upper = String(first).uppercased()
        return upper.rangeOfCharacter(from: .letters) != nil ? upper : "#"
    }

    static func withoutLeadingArticle(_ title: String) -> String {
        let articles = ["der ", "die ", "das ", "the ", "a ", "an ", "ein ", "eine "]
        let lower = title.lowercased()
        for article in articles where lower.hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }

    /// The default is calculated from the display size — see ``ImageSizing``. A number
    /// at this place does not say what it refers to, and here there was one that
    /// did not fit.
    public nonisolated func posterURL(
        for item: MediaItem,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.poster.width)
    ) -> URL? {
        PosterAddress.url(for: item, from: source, width: width)
    }

    /// The image from which the accent color is derived.
    ///
    /// The **background image**, not the poster: posters are often photographed
    /// covers whose packaging border wins any evaluation — a series turned
    /// blue instead of orange that way. Only if none is available does the poster have to do.
    ///
    /// Deliberately requested tiny — the reasoning is at
    /// `AccentExtractor.sourceWidth`.
    /// **With `tag`:** only it gives the response a `max-age`, and only
    /// with that does `URLCache` take effect — without it every focus change fetched the color image
    /// again over the network and stole one of the three image fetch slots.
    public nonisolated func accentSourceURL(for item: MediaItem) -> URL? {
        if let backdrop = item.artwork.backdropID {
            return source.imageURL(
                itemID: backdrop, kind: .backdrop, width: AccentExtractor.sourceWidth,
                tag: item.artwork.backdropTag)
        }
        return source.imageURL(
            itemID: item.artwork.posterID ?? item.id, kind: .primary,
            width: AccentExtractor.sourceWidth, tag: item.artwork.posterTag)
    }

    /// Fetches the third-party ratings for a title afterwards.
    ///
    /// Called on focus change, not on load. A grid with
    /// three hundred titles would otherwise yield three hundred requests for numbers of which
    /// one reads two.
    /// Fetches a title's full details afterwards when the list
    /// did not bring them along.
    ///
    /// A Xtream panel's film list carries no plot — only the
    /// single request delivers it (finding 2026-08-07: empty descriptions in the
    /// IPTV library). With the media server the plot comes with the list,
    /// **but not the people**: director and cast are in Jellyfin only in the
    /// single request. Until 2026-10-12 this path fetched only when the plot was missing,
    /// and the detail column (AP80) showed neither director nor
    /// cast for Jellyfin titles — reported during on-device testing: "they are not visible". Now it is enough
    /// that the people are missing. At most once per title, even with an empty
    /// result — otherwise every focus change would ask again.
    public func loadDetails(for item: MediaItem) async {
        let isMissing = item.overview?.isEmpty != false || (item.cast.isEmpty && item.directors == nil)
        guard isMissing, !detailFetched.contains(item.id) else { return }
        detailFetched.insert(item.id)
        guard let full = try? await source.item(id: item.id) else { return }
        replace(Self.merged(full, using: current(item.id) ?? item))
    }

    /// The list title as it now stands in the list — after everything that has been
    /// incorporated in the meantime.
    private func current(_ id: String) -> MediaItem? {
        guard case .ready(let items) = state else { return nil }
        return items.first { $0.id == id }
    }

    /// The full title, but **without loss**: what the list knows in the meantime and the
    /// single request does not deliver stays.
    ///
    /// **2026-10-12, on-device testing:** "still no genre or cast visible for Gluzuhind" — although ``loadExternalRatings(for:)`` had
    /// just incorporated both from TMDb. The portal source answers the single request from its memory with
    /// the same lean list row (``PortalSource/item(id:)``), and `replace(full)`
    /// put it over the enriched one — the column was full for half a second
    /// and then empty again. The detail page does not have the problem because it first fetches the
    /// title and asks TMDb afterwards. Here the order is reversed, and both
    /// paths have to fit together in either order.
    nonisolated static func merged(_ full: MediaItem, using previous: MediaItem) -> MediaItem {
        var fresh = full
        if fresh.overview?.isEmpty ?? true { fresh.overview = previous.overview }
        if fresh.genres.isEmpty { fresh.genres = previous.genres }
        if fresh.cast.isEmpty { fresh.cast = previous.cast }
        if fresh.directors?.isEmpty ?? true { fresh.directors = previous.directors }
        if fresh.ratings.community == nil { fresh.ratings.community = previous.ratings.community }
        if fresh.ratings.imdbID == nil { fresh.ratings.imdbID = previous.ratings.imdbID }
        if fresh.year == nil { fresh.year = previous.year }
        return fresh
    }

    /// For which titles the single request has already run.
    private var detailFetched: Set<String> = []

    /// External ratings and, where the source has nothing, genres, rating and
    /// cast from TMDb — **the same path as the detail page** (``ExternalLookup``).
    ///
    /// **2026-10-12, on-device testing:** "for Gluzuhind in Serieshub → Popular no
    /// genre is shown, but when I open Gluzuhind all the information is there, even
    /// more". The detail page asked TMDb by title and year, the column asked only OMDb via
    /// the IMDb ID — and a portal title has none. Now the column fetches the same
    /// state and works it into the list row like ``DetailModel``: genres,
    /// community rating, IMDb ID and cast, each only where the source has
    /// nothing. The TMDb response is kept for 14 days; the detail page then costs
    /// no second request.
    public func loadExternalRatings(for item: MediaItem) async {
        guard externalRatings[item.id] == nil else { return }

        let state = await ExternalLookup.fetch(
            imdb: item.ratings.imdbID, anilist: item.ratings.anilistID, omdb: omdb,
            anilistClient: nil, tmdb: item.ratings.tmdbID, tmdbClient: tmdb,
            search: DetailModel.titleSearch(forItem: item), tvdb: AnimeRating.tvdb(item),
            anime: anime)
        var combined = (try? state.omdb?.get()) ?? ExternalRatings()
        combined.mal = (try? state.mal?.get())??.score
        // An empty result is kept as well: otherwise every focus change asks
        // again for numbers that do not exist.
        externalRatings[item.id] = combined
        if let info = try? state.tmdb?.get() { complete(item, from: info) }
    }

    /// What TMDb knows and the source does not — into the list row so the column shows it.
    /// The same four fields as ``DetailModel/complete(from:)``; the column does not need the cast
    /// images, it only names names.
    private func complete(_ item: MediaItem, from info: TitleInfo) {
        guard case .ready(let items) = state,
            var fresh = items.first(where: { $0.id == item.id })
        else { return }
        if fresh.overview?.isEmpty ?? true, let text = info.description { fresh.overview = text }
        if fresh.genres.isEmpty, !info.genres.isEmpty { fresh.genres = info.genres }
        if fresh.ratings.community == nil { fresh.ratings.community = info.rating }
        if fresh.ratings.imdbID == nil { fresh.ratings.imdbID = info.imdbID }
        if fresh.cast.isEmpty, !info.cast.isEmpty {
            fresh.cast = info.cast.map { person in
                Person(
                    id: "tmdb:" + person.name, name: person.name, role: person.role,
                    character: person.characterName, hasImage: person.image != nil)
            }
        }
        replace(fresh)
    }

    // MARK: - Trailer

    /// The playback target for a title's trailer.
    ///
    /// **Called only after the dwell time has elapsed, not on focus change.**
    /// The reason is at ``DetailColumn``: with a library of three hundred
    /// titles, scrolling through would otherwise produce one request per step onward. The
    /// timing for it is handled by ``TrailerAutostart``, not this model — here only
    /// what is asked is answered.
    ///
    /// Without a cache, and that is deliberate: it is asked only for the one
    /// title on which the focus stayed, and a second time for
    /// the same one only when it has stood in focus long enough again.
    public func trailerTarget(for item: MediaItem) async -> PlaybackTarget? {
        await TrailerPlayback.target(for: item, from: source, quality: streamQuality(), tmdb: tmdb)
    }

    /// The registered providers' details for the title in focus (``TitleExtras``) — only for
    /// portals. Jellyfin and IPTV never ask, and without a provider nobody is asked at all.
    func extras(for item: MediaItem) async -> TitleExtras? {
        let portal =
            (source as? PortalSource) ?? ((source as? FilteredSource)?.source as? PortalSource)
        return await portal?.extras(forItem: item.id, title: item.title)
    }

    /// The TMDb access for trailers from YouTube (AP78) — set by the shell, because it hangs on the
    /// key in Settings and changes with it. Without it, it stays with
    /// the catalog's own file.
    public var tmdb: TMDbClient?

    private func streamQuality() -> StreamQuality {
        if let quality { return quality }
        let loaded = StreamQuality.load(from: SecureStore())
        quality = loaded
        return loaded
    }
}
