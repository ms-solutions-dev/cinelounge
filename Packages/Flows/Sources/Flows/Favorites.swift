import Core
import Foundation

/// How favourites are ordered and switched — **one rule for both apps**
/// (AP58 R6, St3).
///
/// **What had diverged** (report A): The TV grouped by kind — films, series
/// (marked episodes under their series), providers, portals, channels —, each group by
/// title. The phone grouped by origin in the server's order, and it left out the
/// provider catalog's favourites, on the grounds that the panel knew none. That was
/// outdated since AP42: The still-frame wrapper (`StateSource`) keeps the marks in the person's
/// still-frame book.
///
/// **Decided: the TV's order on both devices.** A film and a series
/// are different handles, even when they come from the same server; five marked episodes
/// of a series are one entry and not five; and a list that sorts itself the way
/// the server happens to answer forces a search every time.
public nonisolated enum FavoritesOrder {

    /// The sections in their order: the own by kind, then the foreign, then the
    /// channels — a channel is not a title but a running picture.
    public enum Segment: String, Sendable, Hashable, CaseIterable {
        case movies = "filme"
        case allSeries = "serien"
        case provider = "anbieter"
        case portals = "portale"
        case channels = "sender"
    }

    /// A series in the favourites — **marked itself, via its episodes, or both.**
    public struct SeriesEntry: Sendable, Equatable {
        public let id: String
        public var title: String
        /// How many of its episodes are marked.
        public var episodes: Int
        /// The series itself if it is marked — otherwise the first marked episode.
        public var representative: MediaItem
        /// Whether the series itself is marked.
        public var isMarkedItself: Bool
        /// The marked episodes — **for "No longer a favourite"** (check finding F1): A series
        /// that is present only via its episodes loses its mark only when all are cleared.
        public var markedEpisodes: [MediaItem] = []
    }

    /// Splits the media server's favourites into films and series.
    ///
    /// **Marked episodes go under their series** — whoever marks five episodes wants the
    /// series, and the count stays visible. If the series is additionally marked itself,
    /// there is still only one entry. **An episode without a series ID** stays as itself
    /// with the films — better an entry with an episode name than none. Seasons,
    /// channels, collections, folders and subheadings are not entries here.
    ///
    /// Both lists come out ordered **by title**.
    public static func split(_ title: [MediaItem]) -> (movies: [MediaItem], allSeries: [SeriesEntry]) {
        var movies: [MediaItem] = []
        var allSeries: [String: SeriesEntry] = [:]
        var order: [String] = []

        func memorize(_ series: SeriesEntry) {
            if allSeries[series.id] == nil { order.append(series.id) }
            allSeries[series.id] = series
        }

        for entry in title {
            switch entry.kind {
            case .movie, .homeVideo:
                movies.append(entry)
            case .series:
                var series =
                    allSeries[entry.id]
                    ?? SeriesEntry(
                        id: entry.id, title: entry.title, episodes: 0, representative: entry,
                        isMarkedItself: true)
                series.title = entry.title
                series.representative = entry
                series.isMarkedItself = true
                memorize(series)
            case .episode:
                guard let identifier = entry.seriesID else {
                    movies.append(entry)
                    continue
                }
                var series =
                    allSeries[identifier]
                    ?? SeriesEntry(
                        id: identifier, title: entry.parentTitle ?? entry.title, episodes: 0,
                        representative: entry, isMarkedItself: false)
                series.episodes += 1
                series.markedEpisodes.append(entry)
                if series.title.isEmpty { series.title = entry.parentTitle ?? entry.title }
                memorize(series)
            case .season, .channel, .collection, .folder, .separator:
                continue
            }
        }
        return (
            byTitle(movies, title: \.title),
            byTitle(order.compactMap { allSeries[$0] }, title: \.title)
        )
    }

    /// By title, **stable** — so that the order is the same between two visits.
    public static func byTitle<ContentEntryRecord>(
        _ list: [ContentEntryRecord], title: (ContentEntryRecord) -> String
    )
        -> [ContentEntryRecord]
    {
        list.enumerated()
            .sorted { links, right in
                let a = title(links.element)
                let b = title(right.element)
                return a == b ? links.offset < right.offset : a < b
            }
            .map(\.element)
    }
}

/// Toggles a mark — **first the display, then the service, back on error.**
///
/// Both apps did it this way and rewrote it per view (Home, detail page,
/// favourites). The display switches **before** the response arrives — otherwise the card
/// would look unchanged after the press, one would press again and take the mark straight back.
public enum MarkToggle {

    /// - Parameters:
    ///   - neu: the desired state.
    ///   - vorher: the state before the press — where it goes back to on an error.
    ///   - zeige: sets the state in the display.
    ///   - sende: tells the service.
    /// - Returns: `nil` if the service accepted it — otherwise its error, so that the
    ///   platform can write it to the log.
    @discardableResult
    public static func setEnabled<State>(
        to fresh: State, previous: State, show: (State) -> Void,
        send: () async throws -> Void
    ) async -> (any Error)? {
        show(fresh)
        do {
            try await send()
            return nil
        } catch {
            show(previous)
            return error
        }
    }
}
