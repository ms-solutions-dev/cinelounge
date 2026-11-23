import Core
import Foundation

/// Which slice of a catalog is meant — **the same chips on both devices**
/// (decision 27, C6). Until 2026-09-26 the TV knew only "Unwatched", and that
/// as a switch of its own with a rule of its own (`progress?.isWatched != true` — movies in progress
/// and all series counted as unwatched there).
///
/// **A type of its own and no `ItemFilter`.** The shared filter knows sorting,
/// direction, search term and upper limit; the library knows three slices, and
/// it should not be able to know more. What is not listed here, the view cannot request.
///
/// **"Recently added" dropped out on 2026-09-05** — it was never a slice,
/// but an **order**, and ``forItem(kind:isCollection:tracksState:)`` consequently never
/// returned it. Since there is the ordering "Newest first", it sits
/// where it belongs. A filter and a sort look the same as a chip and
/// do different things: One changes the **set**, the other only the **sequence**.
public nonisolated enum CatalogSlice: String, Sendable, Hashable, CaseIterable, Identifiable {

    /// Started, but not watched to the end.
    case started = "angefangen"

    /// Not watched at all.
    case unwatched = "ungesehen"

    /// Selbst gemerkt.
    case favorites = "favoriten"

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .started: "filter.inProgress"
        case .unwatched: "filter.unwatched"
        case .favorites: "tab.favorites"
        }
    }

    /// Which slices a catalog of this kind knows at all.
    ///
    /// **Gone rather than greyed out.** A dimmed chip is an invitation, and the
    /// answer to it would be the same every time — the same rule as with the tabs, one
    /// level deeper. If only "All" remains, the whole row disappears: A switch
    /// with one side is no switch.
    ///
    /// **Home videos know no "Unwatched".** A family recording is not
    /// ticked off; the watched marker is an entry there that nobody maintains, and a
    /// filter on it would show arbitrary results.
    ///
    /// **A collection has no playback state of its own** — it is a container. "Two
    /// thirds watched" applies to its parts, not to it.
    ///
    /// **The provider catalog and the portals know none at all**, and that is not a gap
    /// but decision E5: No server counts along there. Without progress, watched marker
    /// and favorites there is not a single state filter — the row is omitted there entirely.
    ///
    /// - Parameter fuehrtStand: whether the source keeps state and favorites — the media server
    ///   and, on the phone, the downloads.
    public static func forItem(
        kind: Library.Kind?, isCollection: Bool = false, tracksState: Bool
    ) -> [CatalogSlice] {
        guard tracksState else { return [] }
        if isCollection { return [.favorites] }
        return switch kind {
        case .movies, .series: [.started, .unwatched, .favorites]
        case .homeVideos: [.started, .favorites]
        default: []
        }
    }

    /// Whether a title falls into this slice — **via the state**
    /// (``WatchState/forItem(_:)``), not via progress or tick: Jellyfin keeps both only
    /// on episodes and movies.
    public func matches(_ title: MediaItem) -> Bool {
        switch self {
        case .started: WatchState.forItem(title) == .started
        case .unwatched: WatchState.forItem(title) == .untouched
        case .favorites: title.isFavorite
        }
    }
}

/// Where one stands on a title — **for the title as a whole.**
///
/// **Three cases and not two yes/no questions.** "Started" and "unwatched" exclude
/// each other, and two separate attributes can take the state "both", which does
/// not exist. That is exactly what the library filter failed on: It read two fields that
/// are both empty for series, and thereby answered a question that neither of the two
/// answers.
public nonisolated enum WatchState: String, Sendable, Equatable, CaseIterable {

    /// Nothing of it watched yet.
    case untouched = "unberuehrt"

    /// In the middle — for a movie a progress, for a series at least one
    /// watched and at least one open episode.
    case started = "angefangen"

    /// Ganz durch.
    case finished = "durch"

    /// The state of a title — **shared since decision 27 (C6)**, before that on the phone.
    ///
    /// **The finding of 2026-09-05:** The "Started" filter read `progress` and returned an empty list for
    /// twenty-three series. Jellyfin keeps `UserData.PlayedPercentage`
    /// only on episodes and movies; what a series **does** keep are `unplayedCount` and
    /// `episodeCount`:
    ///
    /// * no open episode → **finished**
    /// * all open → **untouched**
    /// * in between → **started**
    ///
    /// **Without both numbers nothing is claimed** — such a series counts as untouched.
    public static func forItem(_ title: MediaItem) -> WatchState {
        if title.kind == .series {
            guard let pending = title.unplayedCount, let total = title.episodeCount, total > 0
            else { return .untouched }
            if pending == 0 { return .finished }
            return pending < total ? .started : .untouched
        }
        if title.progress?.isWatched == true { return .finished }
        return portion(title) == nil ? .untouched : .started
    }

    /// How far a title has been watched — **only between the first and the last percent.**
    public static func portion(_ title: MediaItem) -> Double? {
        guard let state = title.progress, !state.isWatched else { return nil }
        let portion = state.fraction
        return (portion > 0.01 && portion < 0.99) ? portion : nil
    }
}
