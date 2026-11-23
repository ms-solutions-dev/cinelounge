import Core

extension LibraryModel {

    /// How things are currently sorted — order, direction and whether it was chosen.
    ///
    /// **The third value carries more than it looks like.** Without it there would be no
    /// difference between "this is how the library arrives" and "I want the
    /// alphabet" — and exactly that is needed: the default may sort more
    /// cleverly than the alphabet (see ``ordered(_:)``), the explicit
    /// choice must stay literal.
    public nonisolated struct SortOrder: Equatable, Sendable {
        public var sorting: Sorting
        public var ascending: Bool
        /// Whether the viewer explicitly chose this order.
        public var isExplicit: Bool

        public init(sorting: Sorting, ascending: Bool, isExplicit: Bool) {
            self.sorting = sorting
            self.ascending = ascending
            self.isExplicit = isExplicit
        }

        /// The order a library opens with.
        ///
        /// **A portal level opens in its own order** (finding
        /// 2026-08-27): For "Most watched right now" the bridge delivered Skiplu,
        /// Kuntreiwou, Geissabrel Zari — the app showed Kuflot, Kipaiveik spegougrun skekliogo
        /// Slople, Skiplu, because here everything except home videos had `.title`.
        /// A list called "most watched" loses its meaning that way;
        /// see ``Core/ItemFilter/SortBy/natural``.
        public nonisolated static func standard(for kind: Core.Library.Kind) -> SortOrder {
            let sorting: Sorting
            switch kind {
            case .homeVideos: sorting = .recorded
            case .portalLevel: sorting = .natural
            default: sorting = .title
            }
            return SortOrder(sorting: sorting, ascending: sorting.ascending, isExplicit: false)
        }
    }

    /// What a press on a sort button yields — **three states.**
    ///
    /// One press sorts, the second reverses, the third switches off and
    /// restores the default. The proposal comes from the viewer, and it
    /// is a good one: it needs no additional button, and the third state is
    /// the way back that such bars otherwise never have.
    ///
    /// **The first direction is not always ascending.** For titles one expects
    /// A–Z, for date and rating the newest and best first — see
    /// ``Sorting/ascending``. Whoever starts rigidly ascending here shows the
    /// worst films on the first press on "Rating".
    ///
    /// **And the default itself has only two states**, not three: for
    /// it "switch off" and "restore" are the same thing. A third press that
    /// changes nothing would look like a stuck button.
    ///
    /// **The rule has lived in ``Core/SortChoice/next(pressOn:naturalAscending:preset:)``**
    /// since AP58 R6 — the same as on the phone.
    public nonisolated static func next(
        after current: SortOrder, tapping sorting: Sorting, in kind: Core.Library.Kind
    ) -> SortOrder {
        let standard = SortOrder.standard(for: kind)
        let choice = SortChoice(
            kind: current.sorting, ascending: current.ascending, explicit: current.isExplicit)
        let next = choice.next(
            pressOn: sorting, naturalAscending: \.ascending,
            preset: SortChoice(
                kind: standard.sorting, ascending: standard.ascending,
                explicit: standard.isExplicit))
        return SortOrder(
            sorting: next.kind, ascending: next.ascending,
            isExplicit: next.explicit)
    }

    /// Puts the titles in the order the default means.
    ///
    /// **Within a series, release order counts, not the alphabet.** "Floupruk
    /// Saisjo kaingifre kriamaus Baifo" is from 2005, "der Poplubo plounfak Lumiok" from 2001 —
    /// alphabetically the fourth part comes before the first. This is
    /// verified against the catalog: for Floupruk Saisjo and for Skeitbuwol cofrel klonjaska Skeigria the series
    /// is jumbled today.
    ///
    /// **Only for the default.** Whoever explicitly chooses "A–Z" gets the
    /// strict alphabet — the default is the smarter one, the choice the
    /// literal one.
    ///
    /// The series stay in place: sorting happens **within** the
    /// group, its position in the list is still determined by its first title.
    ///
    /// **The series rule has lived in ``Core/SortRule/seriesByYear(_:title:year:)``** since AP58 R6.
    public nonisolated static func ordered(_ items: [MediaItem], by order: SortOrder) -> [MediaItem] {
        guard !order.isExplicit, order.sorting == .title, order.ascending else { return items }
        return SortRule.seriesByYear(items, title: \.title, year: \.year)
    }

    /// From how many shared words on two titles count as one series.
    ///
    /// **Two**, and that is a compromise. One would be too few: "Der Fadono" and
    /// "Der Trailaut glintiorn Kimuskom" share "der" and are not a series. Three would be too
    /// many: "Griotru Cewuri: Episode IV" and "Griotru Cewuri: Episode V" share two.
    ///
    /// **What gets grouped wrongly is harmless.** "The Habauple Joubrespait" and
    /// "The Habauple Budrasa" count as a series this way and are sorted by year instead of
    /// alphabet — for these two it is the same order. The price of a
    /// misfire is two swapped rows; the price of doing nothing is
    /// a series you cannot watch in order.
    nonisolated static let seriesPrefixWords = SortRule.seriesWords

    /// How many words at the start two titles have in common.
    nonisolated static func sharedPrefixLength(_ left: String, _ right: String) -> Int {
        SortRule.sharedWords(left, right)
    }

    nonisolated static func words(in title: String) -> [String] {
        SortRule.words(in: title)
    }

    // MARK: - Store

    /// **The sorting outlasts the area** (roadmap AP3). Since AP58 R6 it lives in
    /// the shared board of both apps (``Core/SortStore``); this key
    /// is the prefix of the old Keychain rows, which carry over on first read.
    nonisolated static let sortStorageKey = "library.sort"

    /// The area a sorting applies to — ``Core/SortRule/area(forLibrary:)``.
    ///
    /// Separate per library ("by year" makes sense for films, not for home videos);
    /// the film genres of a provider share one area per list.
    nonisolated static func sortScope(forLibraryID id: String) -> String {
        SortRule.area(forLibrary: id)
    }

    /// The old Keychain row of an area — only for migration and checking.
    nonisolated static func sortStorageKey(for library: Core.Library) -> String {
        "\(sortStorageKey).\(sortScope(forLibraryID: library.id))"
    }

    /// The stored order — **checked against what this area offers.**
    ///
    /// What ``Sorting/choices(for:)`` does not list counts as never saved: a sorting
    /// by rating, read back for home videos, would be an active state without a button.
    ///
    /// - Parameters:
    ///   - store: the shared board (in the app, the ``Core/FileStore``).
    ///   - schluesselbund: where the row lived until AP58 R6; if omitted, `store` is asked.
    ///     An old row `title:to`/`title:from` carries over once — **`from` means
    ///     descending here** (``Core/SortStore``).
    nonisolated static func loadOrder(
        for library: Core.Library, from playlistStore: any KeyValueStore,
        keychain: (any KeyValueStore)? = nil
    ) -> SortOrder {
        let standard = SortOrder.standard(for: library.kind)
        let storeRef = SortStore(store: playlistStore, keychain: keychain ?? playlistStore)
        let isOffered = Sorting.choices(for: library.kind).compactMap {
            SortKind(rawValue: $0.rawValue)
        }
        guard
            let entry = storeRef.read(
                area: sortScope(forLibraryID: library.id), isOffered: isOffered),
            let sorting = Sorting(rawValue: entry.kind.rawValue),
            Sorting.choices(for: library.kind).contains(sorting)
        else { return standard }
        return SortOrder(sorting: sorting, ascending: entry.ascending, isExplicit: true)
    }

    /// **The default is deleted, not written** — otherwise "never
    /// set" could not be told apart from "default chosen".
    nonisolated static func saveOrder(
        _ order: SortOrder, for library: Core.Library, to store: any KeyValueStore,
        keychain: (any KeyValueStore)? = nil
    ) {
        let entry =
            order.isExplicit
            ? SortStore.ContentEntryRecord(
                kind: SortKind(rawValue: order.sorting.rawValue) ?? .title,
                ascending: order.ascending)
            : nil
        SortStore(store: store, keychain: keychain ?? store)
            .memorize(entry, area: sortScope(forLibraryID: library.id))
    }
}
