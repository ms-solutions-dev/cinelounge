import Foundation

/// A source that delivers a library **page by page** (AP60, 2026-09-30).
///
/// **Why this exists:** ``ContentSource/items(in:filter:)`` delivers a library in one piece,
/// and for the media server that is right. A level of the CL-Server, by contrast, is a
/// sequence of pages: "Anime Japan in German" has 900 entries on 38 pages, and on the TV
/// only the first one arrived until now. Whoever knows this kind can load more; whoever does
/// not still gets the one piece.
public protocol PageSource: ContentSource {

    /// One page of a library.
    ///
    /// - Parameters:
    ///   - weiter: The marker from the previous ``PageChunk``, unchanged; `nil` for the first
    ///     page.
    ///   - fortschritt: How many entries have already been collected while a sorted library is
    ///     still being prepared.
    func page(
        in library: Library.ID, filter: ItemFilter, next: String?,
        progress: @Sendable (Int) async -> Void
    ) async throws -> PageChunk
}

/// A page and the way to the next.
public struct PageChunk: Sendable, Equatable {

    public let items: [MediaItem]
    /// The marker of the next page — `nil` means: **that was all.**
    public let next: String?

    public init(items: [MediaItem], next: String?) {
        self.items = items
        self.next = next
    }
}
