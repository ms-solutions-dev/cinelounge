import Core
import Foundation

/// What the user has decided about their Home.
///
/// **On the TV this has long existed** — `HomePreferences.allows(_:)` decides there
/// which libraries may fill the header area. On the phone the switch was missing, and
/// Home was therefore the only view of the app that nobody could
/// change: `Presentation → Regale isArranging` led to the placeholder.
///
/// **What deviates is stored** — empty fields mean "as generated". The same
/// consideration as for `LivePreferences.hiddenGroups`: if a library is added, it is
/// included without further ado. With an allow list it would be silently invisible, and
/// you would look for the bug in the app.
public struct StartPreferences: Sendable, Equatable {

    /// The order of the shelves. Empty means "as generated".
    public private(set) var order: [Shelf.Identifier]

    /// Shelves that do not appear.
    ///
    /// **"Continue Watching" is not in it, and it does not get in** — see
    /// ``immovable``.
    public private(set) var hidden: Set<Shelf.Identifier>

    /// Which shelves may fill the header area. **Empty means: all.**
    ///
    /// Since 2026-09-06 the box shows new items instead of ones in progress (direction B for K4); whoever
    /// does not want their children's films large on Home removes them here.
    public private(set) var heroShelves: Set<Shelf.Identifier>

    /// The channels for "Live today", in the chosen order. **Empty means: the
    /// most recently watched.**
    ///
    /// What is remembered is the name with brand (`Channel.favoriteName`) and not the ID —
    /// the same rule as for the favorites of the shared store, and for the same
    /// reason: an Xtream ID changes when the provider rebuilds its list.
    public private(set) var liveChannel: [String]

    /// A chosen folder **per portal** for "From the portals". **Empty means: as
    /// before, automatic.**
    ///
    /// **From one it became one per portal** (decision of the product owner of 2026-09-07:
    /// one from each portal … provided something is selected at all for the others).
    /// Until then a single ID was stored here, and whoever chose Animehub
    /// thereby lost Serieshub — although both could have filled the same shelf.
    ///
    /// **An ID that carries portal and folder in one word.** A portal level is called
    /// `portal|search term|entry` (`PortalLibraryID`), and the start of every ID
    /// of a portal is its root ID — so **both** are in every entry,
    /// and ``FromPortals`` needs no second store for "which portal was that
    /// again". The rule "one per portal" is therefore a rule about prefixes, and
    /// it lives in ``set(portalFolders:under:atMost:)``.
    ///
    /// **Empty remains the normal case**, and that is the same rule as for ``liveChannel``:
    /// whoever has chosen nothing gets the automatic selection — for the portals that is
    /// the most recently opened one and in it the recommended entry.
    public private(set) var portalFolders: [PortalChoice]

    /// A chosen portal folder — **the ID that fetches it and the name that appears on
    /// the shelf.**
    ///
    /// **The name is written along because otherwise nobody knows it anymore.** The bridge
    /// answers a level request with entries, not with a heading — the
    /// title of a ``PortalLayer`` is the one the caller passed in. Whoever stores only
    /// the ID can later only call a shelf "Serieshub" and not
    /// "Serieshub · Popular series"; and that addition is the information, because
    /// "Popular series" exists at two of the three portals.
    public struct PortalChoice: Sendable, Equatable {

        /// The level ID — `portal|search term|entry`.
        public let identifier: String

        /// What the folder was called when it was chosen. **Empty is allowed** and means: the
        /// shelf carries only the name of the portal — the case of a choice from the time
        /// before 2026-09-07, see ``StartPreferences/load(from:forItem:)``.
        public let name: String

        public init(identifier: String, name: String = "") {
            self.identifier = identifier
            self.name = name
        }
    }

    /// **The one shelf that stays where it is.**
    ///
    /// Decision 1 of 2026-09-06: "Continue Watching fixed, the rest reorderable." It answers
    /// the most common reason to open the app; a user who accidentally pushes it
    /// down has made their own Home worse without noticing.
    public static let immovable = Shelf.Identifier.fixed(ShelfIdentifier.continueWatching)

    /// The fixed shelf whose place and switch the portal shelves inherit.
    ///
    /// **Otherwise the per-portal choice would be a downgrade for anyone who has already
    /// ordered.** Whoever pulled "From the portals" to the top or switched it off said so
    /// about **the portals** and not about an ID. The chosen folders, however, produce
    /// new IDs (``ShelvesPerPortalFolder``), and a stored order does not know them: without this
    /// inheritance they would fall, by the rule "what the order does not know goes to
    /// the back", below all library shelves — and a hidden portal shelf would
    /// come back by itself on the first choice.
    static let portalSlot = Shelf.Identifier.fixed(ShelfIdentifier.portals)

    /// Whether this shelf arose from a chosen portal folder.
    ///
    /// **By the form of the ID** (``Core/ShelfIdentifier/isPortalFolder(_:)``): since AP58 R6
    /// a portal shelf is named like its level (`portal|search term|entry`) and no longer
    /// `fresh:portals:portalLevel:…`. The TV asks the same question of the same ID.
    static func isPortalShelf(_ shelf: Shelf.Identifier) -> Bool {
        ShelfIdentifier.isPortalFolder(shelf.rawValue)
    }

    public static let preset = StartPreferences()

    public init(
        order: [Shelf.Identifier] = [], hidden: Set<Shelf.Identifier> = [],
        heroShelves: Set<Shelf.Identifier> = [], liveChannel: [String] = [],
        portalFolders: [PortalChoice] = []
    ) {
        self.order = order
        self.hidden = hidden.subtracting([Self.immovable])
        self.heroShelves = heroShelves
        self.liveChannel = liveChannel
        self.portalFolders = portalFolders
    }

    // MARK: - Queries

    /// Whether this shelf is on Home.
    ///
    /// **The own ID wins, the collective statement is the fallback** (2026-09-12) —
    /// the same rule as for the order in ``arrange(_:)``. Whoever switched off "From the portals"
    /// said so about **the portals**; as long as no single portal shelf has been touched,
    /// that continues to apply to all of them.
    ///
    /// **Since 2026-09-27 the rule lives in ``Core/ShelfView``** — the TV asks
    /// the same one (check finding A-S7). Before, it only checked its own ID, and the same
    /// `shelves.json` produced two different Home screens.
    public func shows(_ shelf: Shelf.Identifier) -> Bool {
        ShelfView.shows(shelf.rawValue, hidden: Set(hidden.map(\.rawValue)))
    }

    /// Under which ID this shelf is ordered and switched.
    ///
    /// For all but the portal shelves and the provider's category shelves that is the
    /// shelf's own — see ``portalSlot`` and ``registerShelf(zu:)``.
    private func representative(_ shelf: Shelf.Identifier) -> Shelf.Identifier {
        ShelfView.proxy(shelf.rawValue).map(Shelf.Identifier.init(rawValue:)) ?? shelf
    }

    /// The register shelf whose place and switch a provider category shelf inherits.
    ///
    /// **The same inheritance as for the portal folders, for the same reason** (decision
    /// 27, C2): until 2026-09-26 the provider catalog appeared on the phone as one shelf per
    /// register catalog (`list|vod`, `list|series`); since then as one per category
    /// (`list|vod|4711`). Whoever pulled the old shelf to the top or switched it off said
    /// so about the catalog — its categories take that over until someone
    /// touches one of them themselves.
    static func registerShelf(zu shelf: Shelf.Identifier) -> Shelf.Identifier? {
        ProviderCategory.registerShelf(zu: shelf.rawValue).map(Shelf.Identifier.init(rawValue:))
    }

    /// Whether this shelf may fill the header area.
    public func fillsHeroes(_ shelf: Shelf.Identifier) -> Bool {
        ShelfView.fillsHeroes(shelf.rawValue, heroShelves: Set(heroShelves.map(\.rawValue)))
    }

    /// Order and hide the generated shelves — **in one step.**
    ///
    /// What the order knows comes in its sequence; everything else **at the back in the
    /// order in which it was generated** — not alphabetical and not random,
    /// otherwise a new shelf would wander elsewhere on every start.
    ///
    /// **"Continue Watching" is moved to the front wherever it stands.** A stored order
    /// from the time before this rule could have it at the back.
    public func arrange(_ shelves: [Shelf]) -> [Shelf] {
        let isVisible = shelves.filter { shows($0.id) }
        let ordered: [Shelf]
        if order.isEmpty {
            ordered = isVisible
        } else {
            // **The first mention wins, a duplicate does not crash** (check finding A-S2,
            // 2026-09-27): an order that carries the same ID twice made
            // `uniqueKeysWithValues` abort here — and since AP58 R6 two
            // placeholders fall on the same ID `all`.
            let rank = Dictionary(
                order.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first })
            // **The own ID takes precedence, the stand-in is the fallback**
            // (2026-09-12). Finding of the product owner: with 5 portals here, the order of
            // which one goes where should be adjustable.
            // Up to here this spot read **only** `representative(shelf.id)` — so the same rank for every
            // portal shelf. They could be dragged anyway, and
            // ``HomeViewModel/move(from:after:)`` wrote their own IDs
            // properly into the order; here they fell out again. Five portal shelves
            // remained one block, and none of them could be placed individually between "Recently added" and
            // "Movies".
            //
            // **The fallback stays, and it is the reason for the inheritance** (see
            // ``portalSlot``): whoever pulled "From the portals" to the top said so about
            // **the portals**. A portal shelf that does not yet appear in the order — freshly chosen, or an order from before 2026-09-12 —
            // still inherits that place. Only whoever touches one detaches it.
            func placement(_ identifier: Shelf.Identifier) -> Int? {
                rank[identifier] ?? rank[representative(identifier)]
            }
            // **With equal rank the generation order decides.** Two
            // portal shelves that both still inherit would otherwise appear in a different
            // sequence on every start, because `sorted` is not stable — exactly the bug the
            // rule "not alphabetical and not random" is meant to prevent.
            let withRank = isVisible.enumerated().compactMap { slot, shelf in
                placement(shelf.id).map { (rank: $0, slot: slot, shelf: shelf) }
            }
            ordered =
                withRank.sorted { ($0.rank, $0.slot) < ($1.rank, $1.slot) }.map(\.shelf)
                + isVisible.filter { placement($0.id) == nil }
        }
        let pinned = ordered.filter { $0.id == Self.immovable }
        return pinned + ordered.filter { $0.id != Self.immovable }
    }

    // MARK: - Changing

    public mutating func set(order incoming: [Shelf.Identifier]) {
        order = incoming
    }

    /// Show or hide a shelf.
    ///
    /// - Parameter all: All shelf IDs known today — needed for the
    ///   migration below. The same construction as for ``fillHeroes(_:_:from:)``, and for the
    ///   same reason: the preferences keep no list of the shelves, and one that
    ///   did would be a second truth about which exist.
    ///
    /// **Since 2026-09-12 the switch of a portal shelf affects only that one.**
    /// Before, it wrote `representative(shelf)`, i.e. `ausDenPortalen` — it thereby hid
    /// **all** portal shelves. That was right as long as the portals were one block;
    /// since each can be placed individually, the switch looks as if it belonged to
    /// its row, and did something else.
    ///
    /// **The migration is the core, and without it the switch would be broken.** A
    /// collective statement ("all portals off") and an individual statement ("this one on")
    /// contradict each other; ``shows(_:)`` lets the collective statement win as long as it
    /// stands. Whoever switched a row on while portals were hidden would have
    /// pressed a switch that does nothing. The collective statement is therefore **resolved**
    /// before the individual statement overrules it: it is dropped, and every known
    /// portal shelf carries it itself from then on. The state stays the same — eight
    /// hidden portals are afterwards eight entries instead of one —, and the next
    /// press works.
    ///
    /// **Once and only when needed.** If there is no collective statement, nothing migrates; whoever
    /// never hid their portals does not get eight entries in the store.
    public mutating func show(
        _ shelf: Shelf.Identifier, _ on: Bool, from all: [Shelf.Identifier] = []
    ) {
        guard shelf != Self.immovable else { return }
        // **Since 2026-09-27 the migration lives in ``Core/ShelfView``** and thereby also applies
        // to the provider's category shelves and on the TV (check finding A-S7).
        hidden = Set(
            ShelfView.setEnabled(
                shelf.rawValue, on: on, hidden: Set(hidden.map(\.rawValue)),
                all: all.map(\.rawValue)
            ).map(Shelf.Identifier.init(rawValue:)))
    }

    /// - Parameter on: Whether this shelf may fill the hero.
    ///
    /// **The last one cannot be deselected.** An empty set means "all" — whoever
    /// deselected the last one would suddenly get all again. A switch that flips into
    /// its opposite is worse than one that does not give way.
    public mutating func fillHeroes(
        _ shelf: Shelf.Identifier, _ on: Bool, from all: [Shelf.Identifier]
    ) {
        heroShelves = Set(
            ShelfView.fill(
                shelf.rawValue, on: on, heroShelves: Set(heroShelves.map(\.rawValue)),
                start: all.map(\.rawValue)
            ).map(Shelf.Identifier.init(rawValue:)))
    }

    public mutating func set(liveChannel incoming: [String]) {
        liveChannel = incoming
    }

    /// Whether this folder is chosen — the question the checkmark hangs on.
    public func selects(portalFolders identifier: String) -> Bool {
        portalFolders.contains { $0.identifier == identifier }
    }

    /// **A second press on the same folder withdraws the choice, a press on another
    /// one replaces the choice of the same portal.**
    ///
    /// The toggle logic is the same as for the sort chips and for the channel choice: without
    /// it there would be no way back to "automatic" — you could only pin another
    /// folder, never none at all again.
    ///
    /// **Replacement happens only within one portal**, and it is recognised by the prefix: every
    /// level ID of a portal begins with its root ID. That comes from outside
    /// (``PortalContentSource/root(zu:)``) and is not rebuilt here — otherwise the
    /// form of the ID would stand in a second place and stay there when it
    /// changes.
    ///
    /// - Parameter hoechstens: This many choices stay; the oldest yields. The
    ///   number comes from ``FromPortals/atMost``, because that is where it is decided how
    ///   many shelves arise — a choice that gets no shelf would be a promise
    ///   without fulfilment. The same split as for the channels and
    ///   ``TodayLive/atMost``.
    public mutating func set(
        portalFolders new: PortalChoice, under root: String, atMost: Int
    ) {
        guard !selects(portalFolders: new.identifier) else {
            portalFolders.removeAll { $0.identifier == new.identifier }
            return
        }
        if !root.isEmpty { portalFolders.removeAll { $0.identifier.hasPrefix(root) } }
        portalFolders.append(new)
        if portalFolders.count > atMost { portalFolders.removeFirst() }
    }

    // MARK: - Store

    /// **Since 2026-09-21 one file and not five Keychain lines** (AP40).
    ///
    /// Before, five strings lay here under `home.…`, entries separated by a
    /// line break, ID and name of a portal folder by a
    /// tab. The TV stored the same thing under `shelves.…`, with `;` and
    /// U+001F. Two formats for one setting — and a value of one side was unusable for
    /// the reader of the other.
    ///
    /// Now both are stored as ``Core/ShelfOrder`` in `shelves.json`, and the
    /// separators are gone entirely: a portal folder has two fields because it has two.
    ///
    /// **Per profile** (AP58 R6, St1) — as on the TV (``Core/ShelfPreferences/load(from:forItem:)``)
    /// the callers pass in the displayed profile; the default is the device.
    public static func load(
        from store: any KeyValueStore, forItem profile: String? = nil
    ) -> StartPreferences {
        let order = ShelfOrder.read(from: store, forItem: profile)
        // **`init(stored:)` and not `init(rawValue:)`** (AP40, 2026-09-20): a list stored before
        // the renaming carries `weiterSchauen`, `heuteLive`,
        // `ausDenPortalen`; it is read with the names the TV also knows.
        return StartPreferences(
            order: order.order.map(Shelf.Identifier.init(stored:)),
            hidden: Set(order.hidden.map(Shelf.Identifier.init(stored:))),
            heroShelves: Set(order.heroShelves.map(Shelf.Identifier.init(stored:))),
            liveChannel: order.liveChannel,
            portalFolders: order.portalFolders.map {
                PortalChoice(identifier: $0.identifier, name: $0.name)
            })
    }

    /// **It is saved on top of what is already there.** The provider categories and the
    /// number "this many shelves per provider" are set only by the TV; overwriting them here
    /// would mean taking something away from a transferred state that this
    /// side does not know exists.
    public func save(to store: any KeyValueStore, forItem profile: String? = nil) {
        var sortOrder = ShelfOrder.read(from: store, forItem: profile)
        sortOrder.order = order.map(\.rawValue)
        sortOrder.hidden = hidden.map(\.rawValue).sorted()
        sortOrder.heroShelves = heroShelves.map(\.rawValue).sorted()
        sortOrder.liveChannel = liveChannel
        sortOrder.portalFolders = portalFolders.map {
            ShelfOrder.FolderChoice(identifier: $0.identifier, name: $0.name)
        }
        sortOrder.write(in: store, forItem: profile)
    }

    // MARK: - What stood there before

    /// The keys under which the order lay in the Keychain until 2026-09-21.
    ///
    /// **They remain here only for the takeover** and are no longer written.
    private enum Legacy {
        static let order = "home.shelfOrder"
        static let hidden = "home.shelfHidden"
        static let heroes = "home.heroShelves"
        static let live = "home.liveChannels"
        static let portalFolders = "home.portalFolder"
        static let all = [order, hidden, heroes, live, portalFolders]

        /// **A separator that occurred in no ID.** Shelf IDs carry
        /// colons ("neu:medienserver…"), channel names spaces and brackets.
        static let separator = "\n"
        /// Between ID and name of a portal choice. **Without it the whole line is the
        /// ID** — the single value from the time before 2026-09-07, when the folder name
        /// was not yet written along.
        static let fieldSeparator = "\t"
    }

    /// Brings an order stored in the Keychain into the file — **once.**
    ///
    /// **If the file already contains something, nothing happens**, and clean-up only happens once
    /// what was written can be read back. The reason is at
    /// ``Core/ShelfPreferences/adopt(from:in:)``: on the Apple TV a store was
    /// once silently swallowed, and the same caution costs nothing here.
    ///
    /// - Returns: Whether something was taken over. For the check, not for operation.
    @discardableResult
    public static func adopt(
        from keychain: any KeyValueStore, in store: any KeyValueStore
    ) -> Bool {
        guard (try? store.value(for: ShelfOrder.key)) == nil else { return false }

        func list(_ key: String) -> [String] {
            guard let raw = try? keychain.value(for: key), !raw.isEmpty
            else { return [] }
            return raw.components(separatedBy: Legacy.separator).filter { !$0.isEmpty }
        }
        let folder = list(Legacy.portalFolders).map { row -> ShelfOrder.FolderChoice in
            let split = row.components(separatedBy: Legacy.fieldSeparator)
            return .init(identifier: split.first ?? "", name: split.dropFirst().joined())
        }
        // Translated already here: what once stands in the file carries the names both
        // programs know — and ``load(from:)`` needs the old board only
        // for devices that never took this step.
        func identifiers(_ key: String) -> [String] {
            list(key).map { Shelf.Identifier(stored: $0).rawValue }
        }
        let order = ShelfOrder(
            order: identifiers(Legacy.order),
            hidden: identifiers(Legacy.hidden),
            heroShelves: identifiers(Legacy.heroes),
            liveChannel: list(Legacy.live),
            portalFolders: folder)

        guard order != ShelfOrder() else { return false }
        order.write(in: store)
        guard ShelfOrder.read(from: store) == order else { return false }
        for key in Legacy.all { try? keychain.remove(key) }
        return true
    }
}
