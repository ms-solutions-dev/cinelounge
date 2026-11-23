import Core
import Foundation

extension JellyfinSource {

    // MARK: - Clientseitige Ordnung

    // **Moved out on 2026-09-02** (AP18, "Refactoring the oversized"). These
    // calculations have nothing to do with the server: they order a catalog
    // the way the server would have ordered it, and touch neither access nor
    // connection. Living in the same file as handshake, address building and
    // cache only meant they had to be paged through along with them.
    //
    // **And they really do move out**, without loosening anything:
    // everything here is `static` and uses no private property. That is
    // exactly the limit of this move — the rest of the actor shares
    // 28 private fields, and `private` applies per file. Splitting it would
    // mean opening them all: shorter files in exchange for a softer boundary,
    // which is not a gain but a trade.
    /// Orders and trims a catalog the way the server used to.
    static func arrange(_ items: [MediaItem], by filter: Core.ItemFilter) -> [MediaItem] {
        var result = sorted(items, by: filter.sortBy, ascending: filter.ascending)
        if let limit = filter.limit, result.count > limit {
            result = Array(result.prefix(limit))
        }
        return result
    }

    /// The sort order the server would have returned for the same request.
    ///
    /// Titles go by the server's sort title (`SortName`), which has already
    /// stripped articles; if it is missing, the article itself is removed. Items
    /// without a value — no date, no rating — go last, in both directions: an
    /// unrated film does not belong at the front for "best first", nor for
    /// "worst first".
    static func sorted(
        _ items: [MediaItem],
        by sortBy: Core.ItemFilter.SortBy,
        ascending: Bool
    ) -> [MediaItem] {
        switch sortBy {
        case .title:
            return items.sorted { left, right in
                let l = titleKey(left)
                let r = titleKey(right)
                guard l != r else { return left.id < right.id }
                return ascending ? l < r : l > r
            }
        case .dateAdded:
            return ordered(items, by: \.addedAt, ascending: ascending)
        case .dateCreated:
            return ordered(items, by: \.recordedAt, ascending: ascending)
        case .rating:
            return ordered(items, by: \.ratings.community, ascending: ascending)
        case .natural:
            // The media server delivers according to what the request said — that
            // is then already the order itself. Nothing to do here.
            return items
        }
    }

    /// The comparison key for titles: the server's sort title, otherwise the
    /// title without its leading article — both without case and accents, so
    /// that "Krainsto" does not end up after "Goprishei".
    static func titleKey(_ item: MediaItem) -> String {
        let base: String
        if let sortTitle = item.sortTitle, !sortTitle.isEmpty {
            base = sortTitle
        } else {
            base = withoutLeadingArticle(item.title)
        }
        return base.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The fallback if the server supplies no sort title — the same articles
    /// as for the library's jump marks.
    static func withoutLeadingArticle(_ title: String) -> String {
        let articles = ["der ", "die ", "das ", "the ", "a ", "an ", "ein ", "eine "]
        let lower = title.lowercased()
        for article in articles where lower.hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }

    private static func ordered<Value: Comparable>(
        _ items: [MediaItem],
        by value: (MediaItem) -> Value?,
        ascending: Bool
    ) -> [MediaItem] {
        items.sorted { left, right in
            switch (value(left), value(right)) {
            case (let l?, let r?):
                // On a tie the title decides — the same secondary order the server
                // applies, and it keeps the sequence stable across two fetches.
                guard l != r else { return titleKey(left) < titleKey(right) }
                return ascending ? l < r : l > r
            case (nil, nil):
                return titleKey(left) < titleKey(right)
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }
    }

    /// Orders parts of a series by release date.
    ///
    /// ``MediaItem/recordedAt`` carries the release date (`PremiereDate`, with
    /// the creation date as fallback). Items without one go last — the same
    /// principle as for the library sorting.
    static func byPremiereDate(_ items: [MediaItem]) -> [MediaItem] {
        ordered(items, by: \.recordedAt, ascending: true)
    }
}
