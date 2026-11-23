import Core

/// What the CL-Server sorts a level by **across all its pages** (AP60, 2026-09-30).
///
/// **The product requirement:** sorted by rating, no 6 may appear on page 1 before an
/// 8 from page 3. On the device that cannot be kept while only part of the level is
/// loaded, and the providers themselves cannot sort (Serieshub's collections know
/// no order but their own). So the server sorts, and this app only tells it by what.
public struct PortalSorting: Sendable, Equatable {

    public enum Kind: String, Sendable {
        case title = "title"
        case rating = "rating"
        case year = "year"
    }

    public let kind: Kind
    /// Z to A, or best first. Titles without a value come last on the server in both
    /// directions.
    public let descending: Bool

    public init(kind: Kind, descending: Bool) {
        self.kind = kind
        self.descending = descending
    }

    /// The sort order a filter demands — `nil` for the source's own order.
    ///
    /// **The direction follows the media server's contract:** `ascending == false` means
    /// "best first" for rating and "Z to A" for title. Both are `desc` on the server.
    public init?(_ filter: ItemFilter) {
        switch filter.sortBy {
        case .title: self.init(kind: .title, descending: !filter.ascending)
        case .rating: self.init(kind: .rating, descending: !filter.ascending)
        case .dateAdded, .dateCreated, .natural: return nil
        }
    }
}

extension ItemFilter {

    /// The same filter without its own sorting — for a list that already arrives sorted.
    var withoutSorting: ItemFilter {
        var filter = self
        filter.sortBy = .natural
        return filter
    }
}
