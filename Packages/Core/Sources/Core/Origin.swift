import Foundation

/// Where a title or a library comes from — **read off the form of the identifier, in
/// one place for both programs.**
///
/// **Until AP58 R6 (2026-09-26) this question stood three times** (report A, St8): on the TV
/// as `Features.Origin`, on the phone as `PlaybackJob.origin(zu:)`, and in the
/// Top Shelf rule as `ShelfFilter.isMediaServerIdentifier`. The rules were meant to be the same,
/// but written three times; the child filter hangs on them (``ChildScope`` lets only the
/// media server through in child mode), and a deviation would have been a gap.
///
/// **Why in `Core` and not next to the identifier types.** `PortalItemID` lives in
/// `PortalKit`, `XtreamVOD.Reference` in `PlaylistKit`; the Top Shelf extension and
/// parental controls depend on neither. The form rules therefore live here as
/// string work, and `AblaeufeTests/OriginFormTests` holds them against the readers of the
/// two packages: If one side deviates, the check goes red and the child profile
/// does not leak.
///
/// **The order of the cases is the order of the sources** — it decides what comes first in
/// a collected list. Not that of the response times: Whoever answers first
/// would otherwise determine a different order at every open.
///
/// On the phone there are finer terms (`Catalog.Origin` additionally carries channel list and
/// downloads). They cannot be read off an identifier and stay there; their three
/// readable cases carry the same raw values as here.
public nonisolated enum Origin: String, Sendable, Hashable, Codable, CaseIterable {

    /// The media server — Jellyfin.
    case jellyfin = "medienserver"

    /// The **catalog** of a provider: films and series on demand.
    ///
    /// A separate origin and not "channel list", although both come from the same access:
    /// Channels run by schedule, a catalog is searched.
    case provider = "anbieter"

    /// The portals via the bridge on the home network.
    case portals = "portale"

    /// **The order in which collected lists show their origins.**
    ///
    /// Explicitly `allCases` and not a second enumeration: Anyone who introduces an origin
    /// should not have to enter it in two places.
    public static let order = allCases

    /// Where this **title** comes from.
    ///
    /// **Nothing is guessed here.** A portal identifier is `portal|key|address`
    /// (three parts, the first not empty), a provider identifier
    /// `list#movie|series|episode#identifier[#suffix]`. What is neither can only come from the
    /// media server, because its identifiers are bare hex digits.
    public static func forItem(identifier: String) -> Origin {
        if isPortalIdentifier(identifier) { return .portals }
        if isProviderIdentifier(identifier) { return .provider }
        return .jellyfin
    }

    /// Where this **library** comes from — the same rule one level up.
    ///
    /// **The narrower check first.** Both forms have three parts with `|`:
    /// `list|vod|4711` at the provider, `portal|search|entry` at the portal. The portal form
    /// accepts any middle part, the provider form requires literally `vod` or
    /// `series`. If the wide one stood first, every provider section counted as a portal level — the mistake
    /// of the first draft on the TV, found by a test and not by
    /// reasoning.
    public static func forItem(library identifier: String) -> Origin {
        if isProviderCategory(identifier) { return .provider }
        if isPortalIdentifier(identifier) { return .portals }
        return .jellyfin
    }

    /// Whether an identifier **certainly** comes from the media server — the narrow version for filters.
    ///
    /// **Narrower than ``forItem(identifier:)``, and deliberately so.** There the media server is the
    /// fallback, because a title has to go somewhere. A filter asks the other way round: What does not
    /// unambiguously look like media server (hex digits and hyphens) counts as foreign —
    /// in child mode it is thereby dropped. A channel identifier carries no marker and lands
    /// in ``forItem(identifier:)`` at the media server; not here.
    public static func isMediaServerIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    // MARK: - Die Formen

    /// The separator of a portal identifier. It occurs in none of the three parts (see
    /// `PortalItemID`).
    static let portalSeparator: Character = "|"

    /// The roles a provider identifier carries (`XtreamVOD.Reference.Role`).
    static let providerRoles: Set<Substring> = ["movie", "series", "episode"]

    /// The markers of a provider section (`XtreamVODSource.parseLibraryID`).
    static let categoryMarkers = ["|series|", "|vod|"]

    /// `portal|key|address` — at most two cuts, the first part not empty,
    /// **and not a provider identifier.**
    ///
    /// **The finding (diagnosis F-025, 2026-09-28):** Since AP42 a channel list is called
    /// `xtream|host|account`, so a title from it is `xtream|iptvhost.example|account#movie#123` —
    /// three parts, first not empty. The portal probe stood first and accepted it: Details,
    /// state and the deep link of an IPTV title went to the CL-Server, which answered with
    /// `state.unknown_key` for `iptvhost.example`, up to thirty times in a row.
    static func isPortalIdentifier(_ identifier: String) -> Bool {
        let split = identifier.split(
            separator: portalSeparator, maxSplits: 2, omittingEmptySubsequences: false)
        return split.count == 3 && !split[0].isEmpty && !isProviderIdentifier(identifier)
    }

    /// The portal of a portal identifier (`portal|key|address`) — the first part; `nil`
    /// for everything that is not a portal identifier.
    public static func portal(fromIdentifier identifier: String) -> String? {
        guard isPortalIdentifier(identifier) else { return nil }
        return identifier.split(separator: portalSeparator, maxSplits: 1).first.map(String.init)
    }

    /// `list#role#identifier[#suffix]` — the **last** role counts, and behind it stands
    /// a non-empty identifier.
    static func isProviderIdentifier(_ identifier: String) -> Bool {
        let split = identifier.split(separator: "#", omittingEmptySubsequences: false)
        guard let role = split.lastIndex(where: providerRoles.contains),
            split.count > role + 1
        else { return false }
        return !split[role + 1].isEmpty
    }

    /// `list|vod|section` or `list|series|section`, both sides not empty.
    static func isProviderCategory(_ identifier: String) -> Bool {
        categoryMarkers.contains { tag in
            let split = identifier.components(separatedBy: tag)
            return split.count == 2 && !split[0].isEmpty && !split[1].isEmpty
        }
    }
}
