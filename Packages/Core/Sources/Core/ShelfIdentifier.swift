import Foundation

/// What a Home shelf is called — **one identifier form for both programs.**
///
/// **The finding from report A (St1, AP58 R6):** both programs store their shelf order in
/// the same `shelves.json` (``ShelfOrder``), but they named the same shelf differently.
/// The TV took the library's identifier (`a1b2…`, `list|vod|4711`,
/// `portal|search|entry`), the phone a prefix in front of it
/// (`fresh:jellyfin:movies:a1b2…`). Only the fixed shelves matched. An
/// order that arose on the phone and arrived at the TV via handoff or profile
/// named nothing there — and vice versa.
///
/// **The common form is the TV's**: the identifier under which the source itself carries the
/// library. It already carries its origin in the form (``Origin``); the
/// phone's prefix said the same thing a second time. On the phone the prefix stays in
/// `Catalog.Identifier`, where it is needed (Xtream keeps its own number ranges
/// for movies and series); the shelf identifier does not need it, because a provider section carries its kind
/// in the identifier (`|vod|` versus `|series|`).
///
/// **It is adopted on reading** (``read(_:)``): ``ShelfOrder/read(from:forItem:)``
/// rewrites every stored identifier into the common form. On the next save it
/// stands that way in the file; a migration of its own would have to stay in place forever.
public nonisolated enum ShelfIdentifier {

    // MARK: - The fixed shelves

    /// "Continue Watching" — `resume` on both sides since AP40.
    public static let continueWatching = "resume"
    /// „Jetzt live" / „Heute live".
    public static let live = "live"
    /// "Recently Added".
    public static let recent = "zuletztHinzugefuegt"
    /// The collective shelf across all portals.
    public static let portals = "portale"
    /// The collections of the media server — since decision 27 (C1) a shelf
    /// of its own on both devices.
    public static let collections = "collections"

    /// The fixed shelves — everything else is a library or a portal folder.
    public static let fixed: Set<String> = [continueWatching, live, recent, portals, collections]

    // MARK: - Bibliotheken

    /// The shelf of a library or a portal folder: **the identifier of the source.**
    public static func library(_ sourceIdentifier: String) -> String { sourceIdentifier }

    /// Whether this shelf comes from a portal folder — read off the form.
    public static func isPortalFolder(_ identifier: String) -> Bool {
        !fixed.contains(identifier) && Origin.forItem(library: identifier) == .portals
    }

    /// The register shelf behind a category of the provider catalog — `list|vod|4711`
    /// belongs to `list|vod`. `nil` for everything that is not a category of the provider.
    ///
    /// **Until 2026-09-27 on the phone** (`ProviderCategory`); since visibility became a
    /// rule for both programs (``ShelfView``), it lives here.
    public static func registerShelf(zu identifier: String) -> String? {
        guard Origin.forItem(library: identifier) == .provider else { return nil }
        // **From the back** (2026-09-29): a derived list identifier itself carries dashes
        // (`xtream|host|user|vod|4711`) — with "exactly three parts" every one of its
        // categories fell through.
        let split = identifier.split(separator: "|", omittingEmptySubsequences: false)
        guard split.count >= 3, !split[0..<(split.count - 2)].joined().isEmpty,
            split[split.count - 2] == "vod" || split[split.count - 2] == "series",
            !split[split.count - 1].isEmpty
        else { return nil }
        return split.dropLast().joined(separator: "|")
    }

    // MARK: - Adoption

    /// The phone's names until 2026-09-20 (AP40).
    static let legacyFixedNames = [
        "weiterSchauen": continueWatching, "heuteLive": live, "ausDenPortalen": portals,
    ]

    /// The prefix under which the phone stored a catalog shelf until AP58 R6.
    static let phonePrefix = "neu:"

    /// The origins that could stand behind the prefix (`Catalog.Origin`).
    static let phoneOrigins: Set<Substring> = [
        "medienserver", "senderliste", "anbieter", "portale", "vorrat",
    ]

    /// A stored identifier in the common form — **what is already right stays.**
    ///
    /// `fresh:<origin>:<kind>:<sourceIdentifier>` becomes the source identifier. It is cut at
    /// most three times: the source identifier itself may carry a colon (a
    /// portal URL does), the two fields before it never.
    public static func read(_ raw: String) -> String {
        if let known = legacyFixedNames[raw] { return known }
        guard raw.hasPrefix(phonePrefix) else { return raw }
        let split = raw.dropFirst(phonePrefix.count)
            .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard split.count == 3, phoneOrigins.contains(split[0]), !split[2].isEmpty
        else { return raw }
        return String(split[2])
    }

    /// The shelf of a phone catalog entry — from its identifier `<origin>:<kind>:<raw>`.
    ///
    /// The phone carries the origin in the catalog identifier because Xtream has its own number ranges for movies and
    /// series. The shelf does not need it; it is named as
    /// the source names the catalog entry.
    public static func fromPhoneCatalog(_ catalogIdentifier: String) -> String {
        read(phonePrefix + catalogIdentifier)
    }

    /// A list of stored identifiers in the common form — **without duplicates.**
    ///
    /// Two old entries can fall onto the same new identifier (a list that was already
    /// half adopted). The first wins because it stood further ahead in the order.
    public static func read(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map(read).filter { seen.insert($0).inserted }
    }
}
