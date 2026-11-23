import Core
import Flows
import Foundation

/// Where the search gets its hits — **one source, one group.**
///
/// **Asked separately and shown separately.** A common pile of hits from three
/// catalogs would look tidier and would be a lie about the cost: a Jellyfin server
/// answers in milliseconds, a portal asks a third-party service, and what
/// comes from where decides whether you press. That is why each source stays its own group — with
/// its own number and its own footer.
///
/// **A source that does not answer does not take the others with it.** The same rule as
/// for the collective sources: an expired provider login must not cause
/// the library to show no hits either.
public protocol SearchSource: Sendable {

    /// The group this source contributes.
    ///
    /// Does not throw: a failure here is not an exceptional case but a result —
    /// "this source did not answer" is information that the group carries.
    func match(zu word: String, atMost: Int) async -> ResultBundle
}

/// What a source has to say about a search.
public struct ResultBundle: Sendable, Equatable, Identifiable {

    /// Which catalog the hits come from.
    public let origin: Catalog.Origin

    /// The heading of the group — the name of the catalog, not that of the service.
    public let headline: CaptionLabel

    /// The line below the group: **what was searched**, not what was found.
    ///
    /// "32,532 titles searched" and "3 of 4 portals answered" answer the
    /// question that comes up with zero hits: was it me or the search?
    public let footer: String?

    public let match: [Match]

    /// Whether the source answered at all.
    ///
    /// **Separate from "no hits".** A group without an answer and a group without a
    /// result look the same and mean different things — one says something about the
    /// search term, the other about the line.
    public let hasAnswered: Bool

    public var id: String { origin.rawValue }

    public init(
        origin: Catalog.Origin, headline: CaptionLabel, footer: String? = nil,
        match: [Match], hasAnswered: Bool = true
    ) {
        self.origin = origin
        self.headline = headline
        self.footer = footer
        self.match = match
        self.hasAnswered = hasAnswered
    }
}

/// A hit.
public struct Match: Sendable, Equatable, Identifiable {
    public let tile: TileContent
    /// The state of **this** hit — only portals carry one.
    ///
    /// **On the hit and not above the group.** When a portal demands a login,
    /// that is a property of this one result: the other portals in the same
    /// group are not affected, and a badge above the group would claim
    /// exactly that.
    public let state: PortalState?

    public var id: String { tile.id }

    public init(tile: TileContent, state: PortalState? = nil) {
        self.tile = tile
        self.state = state
    }
}
