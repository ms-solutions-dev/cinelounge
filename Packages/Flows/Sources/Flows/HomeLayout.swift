import Core
import Foundation

/// How the Home screen is built — **the rules both programs share** (AP58 R6,
/// St1).
///
/// **What is here and what is not.** Both programs load their Home screen in their own
/// ways: the TV through a ``Core/ContentSource`` into `MediaItem` shelves, the
/// phone through `StartSource` into tiles with an origin per catalog. These paths are
/// built too differently to merge them into one model in a single step, and that would be
/// a job of its own. **The rules** above them, however, were written twice at every
/// place and drifted apart — the limits, the choice of the header area, "Recently
/// Added", which library gets a shelf. They now live here, and both
/// models ask them.
///
/// **The shelf identifiers** live in ``Core/ShelfIdentifier``, because `Core` needs them for the store
/// (``Core/ShelfOrder``).
public nonisolated enum HomeLayout {

    // MARK: - Limits

    /// This many titles a shelf holds — **the same in both programs.**
    ///
    /// Twenty: nobody pages through more, and every further tile is an image that is
    /// loaded without ever being seen.
    public static let titlesPerShelf = 20

    /// This many libraries **per origin** are loaded for shelves.
    ///
    /// **Per origin and not across all** — counted across all, with six
    /// libraries and two provider rows, exactly the provider rows dropped out, because
    /// your own come first (finding on the phone on 2026-09-05, the same on the TV).
    public static let librariesPerOrigin = 8

    /// This many **filled** catalog shelves the phone shows per origin.
    ///
    /// **Deliberately on the phone only** — a matter of the screen and not of the rule: a
    /// shelf there is about 265 points high, and ten of them are 3.7 screen heights and
    /// 200 images through the tunnel. The TV shows what it loads
    /// (``librariesPerOrigin``). Report A names the dimensions explicitly as what stays
    /// per platform; the number is stated here anyway, so that both limits can be read
    /// side by side.
    public static let shownPerOriginPhone = 4

    /// This many titles "Recently Added" holds.
    ///
    /// **Twenty on both sides.** Until AP58 R6 the TV capped at twelve, the
    /// phone at twenty; the same shelf had two lengths.
    public static let maxRecent = titlesPerShelf

    /// This many titles are up for selection in the header area.
    public static let maxHeroes = 8

    /// How long a hero stays — short enough that a second one is seen while paging,
    /// long enough that nobody is surprised in the middle of reading.
    public static let heroRotation: Duration = .seconds(12)

    /// This many chosen portal folders get a shelf of their own.
    public static let maxPortalFolders = ShelfPreferences.maximumPortalFolders

    // MARK: - Which library a shelf gets

    /// Which kinds get **no** catalog shelf.
    ///
    /// * **Music**, because album covers are 1 : 1 and every shelf carries 2 : 3.
    /// * **Live**, because a channel list has no newest items but a schedule — the live shelf
    ///   exists for that.
    /// * **Portal levels**, because they are menu items of a third-party service — the portal
    ///   shelf and the chosen folders exist for that.
    ///
    /// The phone asks through its genres (`ShelvesPerCatalog.withoutShelf`); a check
    /// there keeps both boards together.
    public static let withoutShelf: Set<Library.Kind> = [.music, .liveTV, .portalLevel]

    /// Whether a library is the media server's **collections** — they already exist as a
    /// fixed shelf (``ShelfSequence/Slot/collections``) and get no second one.
    ///
    /// **Measured on 2026-09-13 on the TV:** the media server has a library
    /// `Sammlungen` with `CollectionType: boxsets`; it falls into `.mixed`, exactly like
    /// "Verzeichnisse", which do get a shelf. The name is therefore compared —
    /// a stopgap until ``Core/Library/Kind`` has a case of its own. Since the phone
    /// shows the collections shelf too (decision 27, C1), both ask here.
    ///
    /// **In every language of the app and not only the chosen one** (audit finding A-S9,
    /// 2026-09-27): the name comes from the server and not from the app. A library
    /// "Collections" with a German app otherwise got a second collections shelf.
    public static func isCollectionLibrary(name: String, kind: Library.Kind?) -> Bool {
        (kind == nil || kind == .mixed)
            && collectionNames.contains {
                name.compare($0, options: .caseInsensitive) == .orderedSame
            }
    }

    /// The languages of the catalogs — the same three in both programs.
    static let languages = ["de", "en", "tr"]

    /// "Collections" in every language of the app, looked up once.
    static let collectionNames: Set<String> = Set(
        languages.map { AppLanguageSetting.word("home.collections", language: $0) })

    /// **Which categories of the provider catalog get a shelf** — the same in both programs
    /// (decision 27, C2).
    ///
    /// The chosen ones, if a choice exists (``Core/ShelfPreferences/providerCategories``), in
    /// the order of the catalog; otherwise the first `perProvider` (default two). The media server
    /// is not affected — its libraries were created by the viewer, whereas the
    /// categories of a provider are that provider's sorting (finding of 2026-09-12 on the TV).
    ///
    /// **Decided per access** (audit finding A-S9, 2026-09-27). Until then "the first
    /// `perProvider`" took the first across **all** accesses — a second provider got
    /// nothing without a choice. And if all chosen categories had vanished at the provider, there was no
    /// provider shelf at all instead of the default. Now for each access: its chosen ones,
    /// if any of them is present, otherwise its first `perProvider`.
    ///
    /// - Parameter kategorien: The categories of **all** accesses, movies before series per access —
    ///   the order of `XtreamVODSource.libraries()`. The answer keeps this order.
    public static func providerCategories<Element>(
        _ categories: [Element], identifier: (Element) -> String, perProvider: Int,
        chosen: [String]
    ) -> [Element] {
        let choice = Set(chosen)
        var selectedAccesses = Set<String>()
        for category in categories where choice.contains(identifier(category)) {
            selectedAccesses.insert(credential(identifier(category)))
        }
        var counted: [String: Int] = [:]
        return categories.filter { category in
            let own = identifier(category)
            let credential = credential(own)
            if selectedAccesses.contains(credential) { return choice.contains(own) }
            let previous = counted[credential, default: 0]
            guard previous < perProvider else { return false }
            counted[credential] = previous + 1
            return true
        }
    }

    /// The access of a category — `list` from `list|vod|4711`.
    static func credential(_ identifier: String) -> String {
        for tag in ["|vod|", "|series|"] {
            if let location = identifier.range(of: tag) {
                return String(identifier[..<location.lowerBound])
            }
        }
        return identifier
    }

    // MARK: - Header

    /// Which kinds of libraries the header area may draw from — **movies and
    /// series, on both devices** (audit finding A-S3, 2026-09-27).
    ///
    /// Allow list instead of block list: a mixed or pure folder library can contain anything,
    /// including private material, and what cannot be assigned safely does not belong
    /// full-screen on the Home screen. If a new kind arrived tomorrow, it would stay out
    /// at first — the more harmless error. The TV has held it this way for a long time
    /// (`HomeModel.heroEligible`); the phone also took mixed libraries until 2026-09-27,
    /// and "all new ones" as a fallback.
    public static let headerKinds: Set<Library.Kind> = [.movies, .series]

    /// Whether a library of this kind may fill the header area. Without a kind: no.
    public static func fillsHeader(_ kind: Library.Kind?) -> Bool {
        kind.map(headerKinds.contains) ?? false
    }

    /// Who appears large at the top — **the same choice on both devices** (decision 25,
    /// 2026-09-26).
    ///
    /// * **Nothing in progress up front.** The phone has not done that since 2026-09-06.
    ///   (direction B for K4): "Continue Watching" sits directly below, and the same question
    ///   would be on the screen twice. Until 2026-09-26 the TV put the item started first
    ///   in first place; since decision 25 (the same feel on all
    ///   devices) the box asks "what is new" there too. The rule therefore
    ///   has no entry for items in progress any more — a device cannot bring them forward again without
    ///   changing this place.
    /// * **Round-robin through the libraries**, not library by library — otherwise a large
    ///   series library would produce a series eight times in a row.
    /// * **Only with a background image** (the box is 90 % image) and **no
    ///   home videos** (the automation recognises the kind of a library, not the intent).
    /// * **A series counts once** — two episodes of the same series would be two nearly identical
    ///   images.
    /// * **Shuffled**, so that the same episode does not play on every open.
    public static func heroes(
        libraries: [[MediaItem]], shuffle: Bool = true, atMost: Int = maxHeroes
    ) -> [MediaItem] {
        var seen = Set<String>()
        func take(_ title: MediaItem) -> Bool {
            guard title.artwork.backdropID != nil, title.kind != .homeVideo else { return false }
            return seen.insert(title.seriesID ?? title.id).inserted
        }

        var selection: [MediaItem] = []
        for location in 0..<(libraries.map(\.count).max() ?? 0) {
            for library in libraries where location < library.count {
                if take(library[location]) { selection.append(library[location]) }
            }
        }
        return Array((shuffle ? selection.shuffled() : selection).prefix(atMost))
    }

    // MARK: - Recently added

    /// "Recently Added" from the titles of the libraries.
    ///
    /// **By date, and whatever has none goes last** — a title without `addedAt` is
    /// not a novelty but a gap. **Stable**: with the same date the order
    /// of the libraries stays. **Duplicates drop out** — the same movie in the media server and in the
    /// provider catalog would look like an error side by side.
    public static func recent(
        from libraries: [[MediaItem]], atMost: Int = maxRecent
    ) -> [MediaItem] {
        let ordered = libraries.flatMap { $0 }.enumerated().sorted { links, right in
            switch (links.element.addedAt, right.element.addedAt) {
            case (let a?, let b?) where a != b: return a > b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return links.offset < right.offset
            }
        }.map(\.element)
        var seen = Set<String>()
        return Array(ordered.filter { seen.insert($0.id).inserted }.prefix(atMost))
    }
}
