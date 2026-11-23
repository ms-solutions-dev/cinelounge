import Foundation

/// How Home is ordered — **the store that both programs share.**
///
/// **Before, there were two formats in two places** (AP40, 2026-09-21). The TV put
/// six strings into the Keychain (`shelves.order` and siblings, entries
/// separated by `;`, identifier and name of a portal folder by U+001F). The phone
/// put five into the Keychain (`home.shelfOrder` and siblings, entries separated by
/// line break, fields by tab). The same thing, two names, two separators,
/// and a value from one side was unusable for the reader on the other.
///
/// **By the rule — `README.md`, "Where a setting belongs" — this is structure and
/// belongs in a file.** That removes the separators entirely: a portal folder has
/// two fields because it has two fields, and not because between them stands a character
/// that must occur in neither. The earlier construction was not wrongly conceived,
/// it was just built from the only tool that existed: the Keychain knows
/// strings, so everything became one.
///
/// **What lies together here and what does not.** What lies together is the *store* — one set of
/// fields, one file name, one reader. The two preference types stay separate,
/// ``ShelfPreferences`` (TV) and `StartPreferences` (phone), because they answer
/// different questions: on the TV there are provider categories and a number "this many
/// shelves per provider", on the phone hero shelves and the inheritance of the portal slot. Merging both
/// into one type would mean loading each side with the operation of the other —
/// and the store would be not one bit more shared for it than it is here.
///
/// **A field this side does not know is not deleted.** ``ShelfPreferences``
/// and `StartPreferences` first read what is there when saving, and overwrite only
/// their own. Otherwise a phone that once orders something would take the provider
/// categories away from the transferred state — silently, because it does not even know they existed.
public struct ShelfOrder: Codable, Sendable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case order = "reihenfolge"
        case hidden = "ausgeblendet"
        case heroShelves = "heldenregale"
        case liveChannel = "liveSender"
        case liveChannelsNamed = "liveSenderBenannt"
        case portalFolders = "portalordner"
        case shelvesPerProvider = "regaleJeAnbieter"
        case providerCategories = "anbieterkategorien"
    }

    /// The identifiers in the desired sequence. What is missing here comes afterwards.
    public var order: [String]
    /// Identifiers that should not appear.
    public var hidden: [String]
    /// Which shelves may fill the header area — **empty means: all.** Both programs
    /// read and write it per profile (since 2026-09-27, review finding A-S8); the device-wide
    /// ``HeroPreferences`` of the TV is now only the fallback of a profile without a choice.
    public var heroShelves: [String]
    /// The channels of the live shelf, in the chosen sequence. **Empty means "automatic".**
    ///
    /// **Channel names** (``Channel/channelName``), on all devices (decision 21). Until 2026-09-26 the
    /// TV stored channel identifiers here; see
    /// ``liveChannelsNamed``.
    public var liveChannel: [String]
    /// Whether ``liveChannel`` surely carries names — **`false` means "possibly still identifiers
    /// from the TV".**
    ///
    /// **A mark and not guessed anew on every read.** The translation discards what
    /// cannot be matched to a channel; if it ran on every read, a
    /// chosen channel would vanish as soon as its list falls silent. Once translated, the
    /// choice stays, even if it currently points to nothing. The phone does not set the mark
    /// and does not need to: what it writes are names, and those survive the
    /// translation unchanged.
    public var liveChannelsNamed: Bool
    /// The chosen portal folders.
    public var portalFolders: [FolderChoice]
    /// This many categories of the provider catalog get a shelf. **TV only**;
    /// `nil` means "never set" and not "no shelves".
    public var shelvesPerProvider: Int?
    /// The chosen categories of the provider catalog. **TV only.**
    public var providerCategories: [String]

    /// A chosen portal folder — **identifier and name.**
    ///
    /// The name is included because otherwise nobody knows it anymore: a portal level answers
    /// with entries and not with a heading. Whoever stores only the identifier can
    /// later call the shelf "Serieshub" and not "Serieshub · Popular Series" — and
    /// exactly the addition is the information, because "Popular Series" exists several times.
    public struct FolderChoice: Codable, Sendable, Equatable, Hashable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case identifier = "kennung"
            case name
        }

        /// The level identifier — `portal|Suchbegriff|EntryPoint`.
        public var identifier: String
        /// What the shelf is called. **Empty is allowed** and means: the shelf carries only the
        /// portal's name — a choice from the time when the name was not written
        /// along.
        public var name: String

        public init(identifier: String, name: String = "") {
            self.identifier = identifier
            self.name = name
        }
    }

    public init(
        order: [String] = [], hidden: [String] = [], heroShelves: [String] = [],
        liveChannel: [String] = [], liveChannelsNamed: Bool = false,
        portalFolders: [FolderChoice] = [],
        shelvesPerProvider: Int? = nil, providerCategories: [String] = []
    ) {
        self.order = order
        self.hidden = hidden
        self.heroShelves = heroShelves
        self.liveChannel = liveChannel
        self.liveChannelsNamed = liveChannelsNamed
        self.portalFolders = portalFolders
        self.shelvesPerProvider = shelvesPerProvider
        self.providerCategories = providerCategories
    }

    /// **Every field may be missing.** A file that an older version wrote
    /// does not know the fields added later; discarding it as unreadable for that reason
    /// would mean taking the viewer's arrangement away on update. The
    /// generated `init(from:)` demanded every field — that is why it is written by hand here.
    public init(from decoder: any Decoder) throws {
        let bucket = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) throws -> [String] {
            try bucket.decodeIfPresent([String].self, forKey: key) ?? []
        }
        self.init(
            order: try list(.order),
            hidden: try list(.hidden),
            heroShelves: try list(.heroShelves),
            liveChannel: try list(.liveChannel),
            liveChannelsNamed: try bucket.decodeIfPresent(Bool.self, forKey: .liveChannelsNamed)
                ?? false,
            portalFolders: try bucket.decodeIfPresent([FolderChoice].self, forKey: .portalFolders) ?? [],
            shelvesPerProvider: try bucket.decodeIfPresent(Int.self, forKey: .shelvesPerProvider),
            providerCategories: try list(.providerCategories))
    }

    // MARK: - Ablage

    /// **One key for everything**, and therefore a file: `shelves.json`.
    ///
    /// Six keys for one setting were the consequence of a
    /// Keychain row carrying only a string. A file carries a set of
    /// fields — and a half-written set cannot arise, because
    /// ``FileStore`` writes and replaces completely.
    public static let key = "shelves"

    /// Reads the order. **Nothing stored means "nothing set"** and yields the
    /// empty order — not an error that every caller would have to catch.
    /// The key for this profile — or the device's.
    ///
    /// **The same form as with ``ParentalControls/ProfileSlot``**, and for the same reason
    /// written down separately there and here: `Core` must not depend on parental controls,
    /// and a shared building block for two lines of string work would be a
    /// dependency for nothing. The form is the same, and both places refer to each other.
    public static func key(forItem profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return key }
        return key + "." + profile
    }

    /// - Parameter profil: Whose arrangement. `nil` is the **device's** — the state before
    ///   the first setup and the base that the takeover draws from.
    ///
    /// **The shelf identifiers come back in the common form** (AP58 R6,
    /// ``ShelfIdentifier/read(_:)``): what the phone had stored as `fresh:<origin>:…` until then
    /// every side reads as the library's identifier. It is written on the
    /// next save, and then the file contains what both programs understand.
    public static func read(
        from store: any KeyValueStore, forItem profile: String? = nil
    ) -> ShelfOrder {
        var order = RecordSheet.read(under: key(forItem: profile), from: store) ?? ShelfOrder()
        order.order = ShelfIdentifier.read(order.order)
        order.hidden = ShelfIdentifier.read(order.hidden)
        order.heroShelves = ShelfIdentifier.read(order.heroShelves)
        return order
    }

    /// Writes the order — **and deletes it when nothing is left in it.**
    ///
    /// A file with nothing but empty lists says the same as no file, and the second
    /// form is the more honest one: whoever looks at what the app has stored should not stumble over
    /// settings that nobody made.
    public func write(in store: any KeyValueStore, forItem profile: String? = nil) {
        let key = Self.key(forItem: profile)
        defer { Self.written?() }
        guard self != ShelfOrder() else {
            RecordSheet.cleanUp(key, in: store)
            return
        }
        RecordSheet.write(self, under: key, in: store)
    }

    /// Whoever wants to learn that an order was written — **the app uses it to trigger the
    /// sync** (2026-09-28): Home has since traveled along via the cloud, and
    /// `Core` does not know the cloud. Set in `CloudStartup`.
    nonisolated(unsafe) public static var written: (@Sendable () -> Void)?
}
