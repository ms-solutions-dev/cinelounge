import Flows
import Foundation

/// What generates shelves — **rules instead of cases.**
///
/// A rule gets the catalog situation and delivers zero to n shelves. With that the six
/// fixed cases of `Regalart` split into two kinds: those that deliver exactly one when
/// their precondition is there, and those that deliver one **per catalog**.
public protocol ShelfRule: Sendable {
    var id: String { get }
    func shelves(forItem state: CatalogState) -> [Shelf]
}

/// A fixed shelf that appears when one of its sources is there.
public struct FixedShelf: ShelfRule {

    public let id: String
    private let label: CaptionLabel
    private let sources: Set<Catalog.Origin>
    private let form: TileShape

    public init(
        id: String, key: String, sources: Set<Catalog.Origin>,
        form: TileShape = .poster
    ) {
        self.id = id
        self.label = .key(key)
        self.sources = sources
        self.form = form
    }

    public func shelves(forItem state: CatalogState) -> [Shelf] {
        guard sources.contains(where: state.hasKey) else { return [] }
        return [Shelf(id: .fixed(id), label: label, sources: sources, form: form)]
    }
}

/// One shelf per chosen portal folder.
///
/// **Why a rule of its own and not ``ShelvesPerCatalog``.** Both make a shelf out of a
/// catalog, and yet they are two questions. A catalog shelf **opens** a library — it
/// carries a target, and two things hang on that: the cap of four per origin in
/// ``StartModel/visibleShelves`` and the question of whether it may fill the header area
/// (``HomeViewModel/heroShelves``). For a portal level both are wrong: it is not a
/// store but a menu item of a third-party service, and its tiles have no background image —
/// the reason for that has long stood at ``ShelvesPerCatalog`` ("Live and portal levels do
/// not"), and it still applies.
///
/// **What a shelf gets is the explicit choice** (``StartPreferences/portalFolders``) and
/// nothing else. It is recognised by the source identifier: the aggregate catalog that
/// ``CatalogState/fromAccesses(jellyfin:channelList:portals:downloads:provider:)``
/// creates for the tab bar carries none — it stands for "there are portals" and not for
/// "this folder is here". Without this distinction a second, empty shelf would appear next
/// to "From the Portals" every time a bridge is registered.
public struct ShelvesPerPortalFolder: ShelfRule {

    public let id = "je-portalordner"

    public init() {}

    public func shelves(forItem state: CatalogState) -> [Shelf] {
        state.catalogs(from: .portals)
            .filter { !$0.sourceIdentifier.isEmpty }
            .prefix(FromPortals.atMost)
            .map { Shelf(id: .zu($0.id), label: $0.label, sources: [.portals]) }
    }
}

/// One shelf per catalog with its newest.
///
/// **This is where the sixth library becomes visible** instead of merely reachable — the
/// real gain of this rebuild.
///
/// **Three kinds get none, each for a reason of its own:**
///
/// * **Music** does not, because album covers are 1 : 1 and every shelf carries 2 : 3. A
///   square in portrait is a crop, and the app does not play albums anyway.
/// * **Directories** do not, because a folder library has no meaningful "newest" — what
///   is there is meant to be sorted by folder and not by date.
/// * **Live and portal levels** do not, because their catalog is not a store but a
///   program — for that there are "Live today" and "From the Portals".
///
/// **Only what has content is capped — and that is a lesson from the screen.** A first
/// version took the first four catalogs and loaded only those. "Verzeichnisse" has zero
/// titles on this server, `Library.itemCount` is never filled by `JellyfinKit`, and
/// collections and directories cannot be told apart as `Library.Kind.mixed` — which of the
/// two got the fourth place was thus decided by chance. Whichever got it stayed empty,
/// dropped out under the rule "an empty shelf does not appear", and the place was wasted.
///
/// This rule therefore generates **all** shelves; the cap of four happens in
/// ``StartModel/visibleShelves`` after the empty ones have dropped out.
///
/// **The four is a question of loading and not of taste:** a shelf is about 265 points
/// high and carries twenty tiles; ten shelves are 3.7 screen heights and **200 images**
/// through a tunnel with a measured 0.31 Mbit/s.
public struct ShelvesPerCatalog: ShelfRule {

    public let id = "je-bestand"

    /// At most this many **filled** catalog shelves appear.
    public static let atMost = HomeLayout.shownPerOriginPhone

    /// This many catalogs are loaded — twice as many as are shown.
    ///
    /// The buffer catches the empty ones without sending twenty queries through the tunnel
    /// with twenty libraries.
    public static let maxLoaded = HomeLayout.librariesPerOrigin

    static let withoutShelf: Set<Genre> = [.music, .directory, .live, .portalLevel]

    public init() {}

    public func shelves(forItem state: CatalogState) -> [Shelf] {
        let eligible = state.catalogs
            // **A placeholder is not a catalog** (check finding A-S2, 2026-09-27): the situation from
            // ``CatalogState/fromAccesses(jellyfin:channelList:portals:downloads:provider:)`` stands
            // for "there is a media server" and carries no source identifier. Since AP58 R6 two such
            // placeholders fall onto the same shelf identifier `all`, and "Arrange shelves" offered a
            // shelf that never occurs on Home. ``ShelvesPerPortalFolder`` makes the same distinction.
            .filter { !$0.sourceIdentifier.isEmpty }
            .filter { !Self.withoutShelf.contains($0.kind) }
            // **The collections already exist as a fixed shelf** (decision 27, C1) — the same rule as
            // on the TV, see ``Flows/HomeLayout/isCollectionLibrary(name:kind:)``.
            .filter {
                $0.kind != .isCollection
                    && !HomeLayout.isCollectionLibrary(
                        name: $0.label.raw, kind: $0.kind.libraryKind ?? .mixed)
            }
            // **The provider catalog belongs here, the channel list does not.** A catalog has a
            // newest; a channel list has a program — for that there is "Live today". Until 2026-09-05.
            // `channelList` stood here, and the catalog dropped out because of it, although the rule
            // had long meant it.
            .filter { $0.origin == .jellyfin || $0.origin == .provider }

        // **The loading buffer applies per origin.** Counted across all, with six libraries and
        // two provider rows exactly the provider rows would drop out — they stand at the back
        // because one's own comes before the foreign. The number is meant to protect the tunnel,
        // not to make the second service invisible.
        var perOrigin: [Catalog.Origin: Int] = [:]
        return
            eligible
            .filter { catalog in
                let previous = perOrigin[catalog.origin, default: 0]
                guard previous < Self.maxLoaded else { return false }
                perOrigin[catalog.origin] = previous + 1
                return true
            }
            .map { catalog in
                Shelf(
                    id: .zu(catalog.id),
                    label: catalog.label,
                    sources: [catalog.origin],
                    target: catalog.id,
                    form: catalog.kind == .homeVideos ? .wide : .poster)
            }
    }
}
