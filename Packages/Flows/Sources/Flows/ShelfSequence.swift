import Core
import Foundation

/// **The default order of the Home screen — one board for both apps** (decision
/// 27, parity C3, 2026-09-26).
///
/// Until then two `ShelfPlan` types stood side by side, and they ordered differently: the
/// TV "portals before Recently Added", the phone the reverse; the TV also sorted
/// the shelves on the Home screen by the kind of their library and showed in
/// shelf management a different order than on the screen. The phone's order is the
/// decided one: **first the own, then the foreign.**
///
/// **What the board does not do:** It does not say which shelves exist and what is in them —
/// the apps' plans know that. It orders what they have produced. A saved
/// order by the viewer takes precedence (``Core/ShelfPreferences/arrange(_:)``); the board is
/// only the default for everything not in it.
public nonisolated enum ShelfSequence {

    /// A place on the board, in the order in which the Home screen shows it.
    public enum Slot: Int, Sendable, CaseIterable, Comparable {
        case continueWatching
        case collections
        case live
        case recent
        /// The collective shelf over all portals **and** the selected portal folders.
        case portals
        /// One shelf per library or provider category.
        case catalogs

        public static func < (links: Slot, right: Slot) -> Bool {
            links.rawValue < right.rawValue
        }
    }

    /// The board itself: Continue Watching · Collections · Live · Recently Added · Portals ·
    /// Catalogs.
    public static let board: [Slot] = Slot.allCases

    /// Which place a shelf is in — **read off the ID** that both apps
    /// share (``Core/ShelfIdentifier``).
    public static func slot(forItem identifier: String) -> Slot {
        switch identifier {
        case ShelfIdentifier.continueWatching: .continueWatching
        case ShelfIdentifier.collections: .collections
        case ShelfIdentifier.live: .live
        case ShelfIdentifier.recent: .recent
        case ShelfIdentifier.portals: .portals
        default: ShelfIdentifier.isPortalFolder(identifier) ? .portals : .catalogs
        }
    }

    /// The order within the catalogs: **origin before kind.**
    ///
    /// First the media server, then the provider catalog — the own before the foreign. Within
    /// an origin series, films, everything else and home videos last: Private recordings
    /// are what one looks for least often and shows least when guests are in the room.
    public static func catalogRank(identifier: String, kind: Library.Kind?) -> [Int] {
        let origin = Origin.allCases.firstIndex(of: Origin.forItem(library: identifier)) ?? 0
        let kindRank =
            switch kind {
            case .series: 0
            case .movies: 1
            case .homeVideos: 3
            default: 2
            }
        return [origin, kindRank]
    }

    /// Orders generated shelves by the board — **stable**: With equal rank the order
    /// in which they were generated stays.
    public static func arrange<Shelf>(
        _ shelves: [Shelf], identifier: (Shelf) -> String, kind: (Shelf) -> Library.Kind?
    ) -> [Shelf] {
        func rank(_ shelf: Shelf) -> [Int] {
            let slot = slot(forItem: identifier(shelf))
            guard slot == .catalogs else { return [slot.rawValue] }
            return [slot.rawValue] + catalogRank(identifier: identifier(shelf), kind: kind(shelf))
        }
        return shelves.enumerated()
            .map { (rank: rank($0.element), location: $0.offset, shelf: $0.element) }
            .sorted { links, right in
                links.rank == right.rank
                    ? links.location < right.location
                    : links.rank.lexicographicallyPrecedes(right.rank)
            }
            .map(\.shelf)
    }
}
