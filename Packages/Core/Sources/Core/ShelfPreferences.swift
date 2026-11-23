import Foundation

/// Which rows the Home screen shows and in what order.
///
/// **The default follows what people want most often:** Continue Watching comes
/// first — whoever opens the app usually wants to carry on there. Then series, then
/// movies, then home videos. The order does not come from the server; it delivers
/// its libraries in arbitrary order, and without an order of our own
/// "Home videos and pictures" sometimes stood in front of the series.
///
/// Both are customisable — order and visibility. The reason is the same as for the
/// libraries of the hero area: only the viewer knows what they want to see.
/// Someone who does not need home videos on the Home screen should be able to hide
/// them without removing them from the media library.
///
/// **The order is stored as a list, and what is hidden is stored separately.**
/// The reason is the same as for ``HeroPreferences``: a library that is added
/// tomorrow is in neither list — it then appears at the end and is visible. With
/// an allow list it would be silently invisible, and you would look for the bug in
/// the app.
public struct ShelfPreferences: Sendable, Equatable {

    /// The identifiers in the desired order. Whatever is missing here comes afterwards.
    public private(set) var order: [String]
    /// Identifiers that should not appear.
    public private(set) var hidden: Set<String>

    /// The chosen portal folders — **identifier and name.**
    ///
    /// **Empty is the normal case**, and then a single shelf "From the portals" stands
    /// above all others. Whoever chooses here gets one shelf per folder instead —
    /// "Animehub · Popular series" next to "Serieshub · Most watched right now". The
    /// same rule as on the phone (``StartPreferences/portalFolders``), and the reason for
    /// the two fields is stated there as well: **The name is stored too, because
    /// otherwise nobody knows it any more.** A portal level answers with entries, not
    /// with a heading; whoever stores only the identifier can later call the shelf only
    /// "Serieshub" and not "Serieshub · Popular series" — and exactly that suffix
    /// is the information, because "Popular series" exists on several portals.
    public private(set) var portalFolders: [PortalChoice]

    /// A chosen portal folder.
    public struct PortalChoice: Sendable, Equatable, Identifiable, Hashable {

        /// The level identifier — `portal|Suchbegriff|EntryPoint`.
        public let identifier: String
        /// What the shelf is called, with the portal in front.
        public let name: String

        public var id: String { identifier }

        public init(identifier: String, name: String) {
            self.identifier = identifier
            self.name = name
        }
    }

    /// At most this many portal shelves — **the same number as on the phone.**
    ///
    /// Three, because the Home screen below still carries the catalogs. A dozen portal
    /// shelves would be the portal area done badly, and the own libraries would sit
    /// below four screen heights of other people's content.
    public static let maximumPortalFolders = 3

    /// Which channels stand in the live shelf — **in this order.**
    ///
    /// **Empty means "automatic"**, and that is the normal case: ``LiveShelf`` then
    /// takes the most recently watched, the favourites and after that the provider's
    /// order. Exactly the same fallback as on the phone (``StartPreferences/liveChannel``):
    /// *"Without a choice, the most recently watched ones that are showing something
    /// right now."*
    ///
    /// **Names and not identifiers** (decision 21, 2026-09-26) — see
    /// ``Channel/channelName`` and ``nameChannels(from:)``.
    public private(set) var liveChannel: [String]

    /// Whether ``liveChannel`` reliably holds names — ``ShelfOrder/liveChannelsNamed``.
    ///
    /// **An empty choice counts as named**: it contains no identifier, and whatever is
    /// added from now on is a name.
    public private(set) var liveChannelsNamed: Bool

    /// That many categories of the **provider catalog** get a shelf of their own.
    ///
    /// **The finding of 2026-09-12, from the client:** the VOD area showed 8 categories,
    /// whereas normally only 2 items are shown (one from movies and one from series),
    /// and this should preferably be adjustable under appearance.
    ///
    /// **The media server is not affected**, and that is the core of the distinction:
    /// its libraries were created and named by the viewer — "Movies", "Series",
    /// "Home videos". The categories of a provider are that provider's own sorting
    /// ("DE| KINO", "DE| MAGENTA SERIEN"), and eight of them push the viewer's own
    /// catalogs four screen heights down.
    ///
    /// **Two as the default and not eight.** ``ShelfRule/perOrigin`` applied equally
    /// to all origins; the number dates from the time when only the media server
    /// filled shelves. Two is the case the client names as the usual one — one from
    /// movies, one from series.
    public private(set) var shelvesPerProvider: Int

    /// **Two as the default**, and the number stands only here: it is also the value
    /// that is **not** stored. A field whose content is the default says the same as a
    /// missing one — and the missing one is the more honest form, because whoever looks
    /// at the file should not find a setting that nobody made.
    public static let shelvesPerProviderDefault = 2

    /// The values on offer.
    ///
    /// **No free number.** A TV has no number field, and a slider for a number between
    /// one and eight would be more operation than information.
    public static let providerLevels = [0, 1, 2, 4, 8]

    /// The **chosen** categories of the provider catalog — library identifiers.
    ///
    /// **The finding of 2026-09-13:** VOD now shows only 2 items, but both appear to be
    /// from series, so it should be possible to choose these items somewhere. A number
    /// alone decides only **how many** — and which ones was decided by the provider's
    /// order. Its series categories come first, so two series categories stood there.
    ///
    /// **Empty means "the first ``shelvesPerProvider``"** and is the normal case: whoever
    /// chooses nothing gets a selection and not an empty Home screen.
    ///
    /// **Sorting does not happen here.** The chosen categories appear as rows in
    /// "Rows on the Home screen" and are moved there like any other shelf — a second
    /// order at this spot would drift apart from that one.
    public private(set) var providerCategories: [String]

    /// Which shelves may fill the hero area — **empty means: all** (check finding A-S8).
    ///
    /// **The same choice as on the phone, per profile** (``ShelfOrder/heroShelves``).
    /// Until 2026-09-27 it was stored on the TV device-wide as an exclusion list in the
    /// Keychain (``HeroPreferences``): if an adult took a library out of the hero, that
    /// applied to all profiles on the device, and the phone of the same profile knew
    /// nothing about it. The old list stays as a fallback for a profile that has not
    /// chosen yet (``fillsHeroes(_:device:)``).
    public private(set) var heroShelves: Set<String>

    public init(
        order: [String] = [], hidden: Set<String> = [],
        portalFolders: [PortalChoice] = [], liveChannel: [String] = [],
        liveChannelsNamed: Bool = true,
        shelvesPerProvider: Int = ShelfPreferences.shelvesPerProviderDefault,
        providerCategories: [String] = [], heroShelves: Set<String> = []
    ) {
        self.providerCategories = providerCategories
        self.heroShelves = heroShelves
        self.order = order
        self.hidden = hidden
        self.portalFolders = portalFolders
        self.liveChannel = liveChannel
        self.liveChannelsNamed = liveChannelsNamed || liveChannel.isEmpty
        self.shelvesPerProvider = shelvesPerProvider
    }

    public mutating func setShelvesPerProvider(_ count: Int) {
        shelvesPerProvider = count
    }

    /// Select or deselect a category of the provider.
    public mutating func selectCategory(_ identifier: String, on: Bool) {
        providerCategories.removeAll { $0 == identifier }
        if on { providerCategories.append(identifier) }
    }

    public func selectsCategory(_ identifier: String) -> Bool {
        providerCategories.contains(identifier)
    }

    /// The fixed identifier of the "Continue Watching" row.
    ///
    /// It does not come from the server and therefore needs one of its own — otherwise
    /// it could be neither moved nor hidden.
    public static let resumeID = ShelfIdentifier.continueWatching

    // MARK: - Abfragen

    /// Whether this row appears — **the rule of both apps** (``ShelfView``): a hidden
    /// "From the portals" also hides the portal folder shelves, and a hidden register
    /// shelf hides its categories, as long as none is switched on individually.
    public func isVisible(_ id: String) -> Bool {
        ShelfView.shows(id, hidden: hidden)
    }

    /// Whether this shelf may fill the hero area.
    ///
    /// - Parameter geraet: The device's old exclusion list — **it applies as long as the
    ///   profile itself has chosen nothing.** That way nobody loses their choice on
    ///   update.
    public func fillsHeroes(_ id: String, device: HeroPreferences = HeroPreferences()) -> Bool {
        heroShelves.isEmpty ? device.allows(id) : heroShelves.contains(id)
    }

    /// Arranges the existing identifiers according to the setting.
    ///
    /// The order is a **wish list, not a rule**: identifiers that are in it but not
    /// present are skipped; present ones that are not in it come last — in the order
    /// in which they arrived.
    ///
    /// As a result the setting survives a deleted library just as well as a new one,
    /// without anybody having to touch it.
    public func arrange(_ available: [String]) -> [String] {
        let present = Set(available)
        let wanted = order.filter(present.contains)
        let rest = available.filter { !order.contains($0) }
        return (wanted + rest).filter(isVisible)
    }

    // MARK: - Changing

    /// - Parameter available: All identifiers known today — needed to resolve a
    ///   collective statement (``ShelfView/setEnabled(_:on:hidden:all:)``).
    public mutating func setVisible(
        _ isVisible: Bool, for id: String, within available: [String] = []
    ) {
        hidden = ShelfView.setEnabled(id, on: isVisible, hidden: hidden, all: available)
    }

    /// Select or deselect a shelf for the hero area — **the rule of the phone**
    /// (``ShelfView/fill(_:on:heroShelves:start:)``).
    ///
    /// - Parameters:
    ///   - alle: The shelves that can fill the hero area.
    ///   - geraet: The old exclusion list; the first own choice starts from what it
    ///     allowed.
    public mutating func fillHeroes(
        _ id: String, _ on: Bool, from candidates: [String], device: HeroPreferences = HeroPreferences()
    ) {
        heroShelves = ShelfView.fill(
            id, on: on, heroShelves: heroShelves, start: candidates.filter(device.allows))
    }

    /// Moves a row by one position.
    ///
    /// By one position and not to a given position: on a TV you move things with two
    /// buttons, not with a mouse. "Up" and "down" are what can be operated with a
    /// remote.
    ///
    /// - Parameter available: All existing identifiers in their natural order.
    ///   Necessary because the setting is empty at first — without it this method
    ///   would not know between which neighbours to swap.
    public mutating func move(_ id: String, up: Bool, within available: [String]) {
        // First establish the actual order, so that something sensible comes out even on
        // the first move.
        var current = order.filter(available.contains)
        current += available.filter { !current.contains($0) }

        guard let index = current.firstIndex(of: id) else { return }
        let target = up ? index - 1 : index + 1
        guard current.indices.contains(target) else { return }

        current.swapAt(index, target)
        // **Absent entries keep their place** (check finding A-S6): a portal folder that
        // is silent today is not in `available` — its place in the order stays anyway.
        order = ShelfView.merge(order: order, using: current)
    }

    /// Adopts an order that came from outside — **from a handoff bundle.**
    ///
    /// **Since AP58 R6 it also names the libraries.** Until then an order transferred
    /// from the phone carried that device's catalog identifiers (`fresh:…`), which named
    /// nothing here; only the fixed rows arrived. Now every identifier is brought into
    /// the shared form (``ShelfIdentifier/read(_:)``), and a phone that still sends
    /// the old form nevertheless orders this device's libraries. **What this device
    /// does not know still does no harm** — ``arrange(_:)`` skips it.
    public mutating func adopt(order incoming: [String]) {
        order = ShelfIdentifier.read(incoming)
    }

    // MARK: - Portalordner und Sender setzen

    /// Select or deselect a portal folder.
    ///
    /// **The fourth drops out at the back and is not rejected.** A choice that does
    /// nothing and says nothing cannot be explained on the remote; the viewer sees that
    /// the oldest one yields, and that is information.
    public mutating func select(_ choice: PortalChoice, on: Bool) {
        portalFolders.removeAll { $0.identifier == choice.identifier }
        guard on else { return }
        portalFolders.append(choice)
        if portalFolders.count > Self.maximumPortalFolders {
            portalFolders.removeFirst(portalFolders.count - Self.maximumPortalFolders)
        }
    }

    public func selects(_ identifier: String) -> Bool {
        portalFolders.contains { $0.identifier == identifier }
    }

    /// Translates a choice from channel identifiers into channel names — **once**
    /// (decision 21).
    ///
    /// Per entry: if it is already the name of a channel, it stays. If it is the
    /// identifier of a channel, it becomes that channel's name. **Otherwise it is
    /// dropped** — an identifier for which there is no channel can never be translated
    /// again, and leaving it would mean occupying one of the six places with something
    /// nobody can deselect, because nobody knows what it was.
    ///
    /// **Without a channel list nothing happens.** An empty list means "not loaded yet"
    /// and not "there is no channel"; translating then would discard the whole choice.
    ///
    /// - Returns: Whether something changed and should be saved.
    @discardableResult
    public mutating func nameChannels(from channels: [Channel]) -> Bool {
        guard !liveChannelsNamed, !channels.isEmpty else { return false }
        let names = Set(channels.map(\.channelName))
        var byIdentifier: [String: String] = [:]
        for channel in channels where byIdentifier[channel.id] == nil {
            byIdentifier[channel.id] = channel.channelName
        }
        var seen = Set<String>()
        liveChannel = liveChannel.compactMap { entry in
            let name = names.contains(entry) ? entry : byIdentifier[entry]
            guard let name, seen.insert(name).inserted else { return nil }
            return name
        }
        liveChannelsNamed = true
        return true
    }

    /// Select or deselect a channel for the live shelf.
    ///
    /// - Parameter id: The **channel name** (``Channel/channelName``), not the identifier.
    ///
    /// **The rule lives in ``LiveShelfChoice/select(_:on:in:)``** and applies on the phone
    /// just the same: at most ``LiveShelfChoice/atMost``, the oldest yields (AP58 R5).
    public mutating func selectChannel(_ id: String, on: Bool) {
        liveChannel = LiveShelfChoice.select(id, on: on, in: liveChannel)
    }

    public func selectsChannel(_ id: String) -> Bool { liveChannel.contains(id) }

    /// Moves a chosen channel by one position (AP46/AP32, from E80).
    ///
    /// **The order of choosing was the only order until 2026-09-25**, and whoever
    /// wanted to change it had to deselect and choose again — for the seventh channel
    /// that meant: all six before it once more. The order decides which six the shelf
    /// shows (``LiveShelfChoice/atMost``), so it is not cosmetic.
    ///
    /// **By one position, as with the shelves** (``move(_:up:within:)``): on a TV you
    /// move things with two buttons. At the edge nothing happens — the buttons there
    /// are greyed out and not removed.
    public mutating func moveChannel(_ id: String, up: Bool) {
        guard let location = liveChannel.firstIndex(of: id) else { return }
        let target = up ? location - 1 : location + 1
        guard liveChannel.indices.contains(target) else { return }
        liveChannel.swapAt(location, target)
    }

    // MARK: - Ablage

    /// **Since 2026-09-21 one file and not six Keychain rows** (AP40).
    ///
    /// The content is stored as ``ShelfOrder`` in `shelves.json`; the phone stores the
    /// same fields under the same name and reads them with the same reader. Before
    /// that, this side had a format of its own with two separators — `;` between the
    /// entries and U+001F between identifier and name —, and each side had its own.
    ///
    /// **It is saved on top of what is already there.** The phone's hero shelves have
    /// no counterpart here; they would vanish on the first move of a row if this spot
    /// reinvented the file instead of changing it.
    ///
    /// **Per profile** (AP58 R6, St1): the apps pass in the displayed profile
    /// (``ProfilePointer/active``); ``ProfileKit/ProfileShelves`` gives each profile the
    /// device's arrangement once. Until then nobody read it, and whoever re-sorted,
    /// re-sorted for everybody on the device. **The default remains the device** — and
    /// not the shared pointer, which concurrent checks switch around: whoever wants
    /// "per profile" says so.
    public static func load(
        from store: any KeyValueStore, forItem profile: String? = nil
    ) -> ShelfPreferences {
        let order = ShelfOrder.read(from: store, forItem: profile)
        return ShelfPreferences(
            order: order.order,
            hidden: Set(order.hidden),
            portalFolders: order.portalFolders.map {
                PortalChoice(identifier: $0.identifier, name: $0.name)
            },
            liveChannel: order.liveChannel,
            liveChannelsNamed: order.liveChannelsNamed,
            // **If the entry is missing, the default applies** — and not zero. An empty store
            // means "nothing set yet", not "no shelves".
            shelvesPerProvider: order.shelvesPerProvider ?? Self.shelvesPerProviderDefault,
            providerCategories: order.providerCategories,
            heroShelves: Set(order.heroShelves))
    }

    public func save(to store: any KeyValueStore, forItem profile: String? = nil) {
        var sortOrder = ShelfOrder.read(from: store, forItem: profile)
        sortOrder.order = order
        sortOrder.hidden = hidden.sorted()
        sortOrder.portalFolders = portalFolders.map {
            ShelfOrder.FolderChoice(identifier: $0.identifier, name: $0.name)
        }
        sortOrder.liveChannel = liveChannel
        sortOrder.liveChannelsNamed = liveChannelsNamed && !liveChannel.isEmpty
        sortOrder.shelvesPerProvider =
            shelvesPerProvider == Self.shelvesPerProviderDefault ? nil : shelvesPerProvider
        sortOrder.providerCategories = providerCategories
        sortOrder.heroShelves = heroShelves.sorted()
        sortOrder.write(in: store, forItem: profile)
    }

    /// Reads the order and translates an old channel choice into names along the way —
    /// **and saves the result**, so that the translation happens once and not on every
    /// read (see ``nameChannels(from:)``).
    public static func loadNamed(
        from store: any KeyValueStore, channels: [Channel], forItem profile: String? = nil
    ) -> ShelfPreferences {
        var preferences = load(from: store, forItem: profile)
        if preferences.nameChannels(from: channels) { preferences.save(to: store, forItem: profile) }
        return preferences
    }

    // MARK: - Was vorher dastand

    /// The keys under which the order lived in the Keychain until 2026-09-21.
    ///
    /// **They remain here only for the migration** and are no longer written. They may
    /// be removed only once no device comes from a version before that day — and since
    /// nobody can determine that, they stay.
    private enum Legacy {
        static let order = "shelves.order"
        static let hidden = "shelves.hidden"
        static let portal = "shelves.portalFolders"
        static let live = "shelves.liveChannels"
        static let provider = "shelves.providerShelves"
        static let categories = "shelves.providerCategories"
        static let all = [order, hidden, portal, live, provider, categories]

        /// Between the entries.
        static let separator: Character = ";"
        /// Between identifier and name of a portal choice — **not `|`**, because the level
        /// identifier itself uses it, and not `;`, because that separates the entries.
        static let nameSeparator: Character = "\u{001F}"
    }

    /// Moves an order stored in the Keychain into the file — **once.**
    ///
    /// **If the file already contains something, nothing happens.** The same rule as
    /// for the age limit and the device identifier: a migration that overwrites takes
    /// away from the viewer, on the second start, what they set after the first.
    ///
    /// **Write first, then read back, then clean up — in this order.** Reading back is
    /// not the caution of a doubter but the on-device finding of 2026-08-16: on the
    /// Apple TV a store under Application Support was silently swallowed. Whoever
    /// deleted here without checking would take the viewer's arrangement away and
    /// write it nowhere. If nothing comes back, the old rows stay, and the next start
    /// tries again.
    ///
    /// - Returns: Whether something was migrated. For testing, not for operation.
    @discardableResult
    public static func adopt(
        from keychain: any KeyValueStore, in store: any KeyValueStore
    ) -> Bool {
        guard (try? store.value(for: ShelfOrder.key)) == nil else { return false }

        func list(_ key: String) -> [String] {
            guard let raw = try? keychain.value(for: key), !raw.isEmpty
            else { return [] }
            return raw.split(separator: Legacy.separator).map(String.init)
        }
        let folder = list(Legacy.portal).compactMap { entry -> ShelfOrder.FolderChoice? in
            let split = entry.split(separator: Legacy.nameSeparator, maxSplits: 1)
            guard let identifier = split.first, !identifier.isEmpty else { return nil }
            return .init(identifier: String(identifier), name: split.dropFirst().joined())
        }
        let order = ShelfOrder(
            order: list(Legacy.order),
            hidden: list(Legacy.hidden),
            liveChannel: list(Legacy.live),
            portalFolders: folder,
            shelvesPerProvider: (try? keychain.value(for: Legacy.provider)).flatMap(Int.init)
                .flatMap { $0 == Self.shelvesPerProviderDefault ? nil : $0 },
            providerCategories: list(Legacy.categories))

        guard order != ShelfOrder() else { return false }
        order.write(in: store)
        guard ShelfOrder.read(from: store) == order else { return false }
        for key in Legacy.all { try? keychain.remove(key) }
        return true
    }
}
