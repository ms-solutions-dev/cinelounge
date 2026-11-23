import Core
import Diagnose
import Flows
import Foundation
import PortalKit

/// The portals via the bridge.
///
/// **Thin, because the work lives elsewhere.** `PortalSource` (PortalKit, shared) speaks
/// the bridge's contract and at the same time fulfils `Core.ContentSource`. This file
/// only translates what the phone views call differently — and holds the one rule
/// that nobody else holds: **A portal without a state is not a portal without a state,
/// but a silent one.**
public struct BridgePortalSource: PortalContentSource {

    private let source: PortalSource
    private let width: Int

    public init(source: PortalSource, width: Int) {
        self.source = source
        self.width = width
    }

    /// Only portals that this person's server currently shows (``PortalKit/PortalSource/resumable(limit:)``).
    public func continueWatching(atMost: Int) async -> [TileContent] {
        let title = (try? await source.resumable(limit: atMost)) ?? []
        return title.map { TileArtwork.tile($0, source: source, width: width) }
    }

    public func portals() async throws -> [PortalInfo] {
        // **One request and not two** (2026-09-12). Here there stood
        // `availablePortals()` and `capabilities()` one after the other — two routes to
        // the same answer, of which the second only works if the first ran before.
        // ``PortalKit/PortalRow`` brings both along, plus description and limits.
        let reported = try await source.portalRows()
        Diagnose.step(.network, "Portals: \(reported.count) reported")
        return reported.map { row in
            PortalInfo(
                id: row.id, name: row.name,
                state: PortalState(row),
                capabilities: row.capabilities,
                description: row.description, limits: row.limits,
                adult: row.adult)
        }
    }

    public func root(zu portal: String) -> String {
        PortalSource.rootID(portal: portal)
    }

    public func level(
        zu identifier: String, title: String, next: String?
    ) async throws
        -> PortalLayer
    {
        try await level(
            zu: identifier, title: title, next: next, sorting: nil, progress: { _ in })
    }

    public func level(
        zu identifier: String, title: String, next: String?, sorting: PortalSorting?,
        progress: @Sendable (Int) async -> Void
    ) async throws -> PortalLayer {
        let fetched = try await source.sortedLevel(
            identifier, next: next, sorting: sorting, progress: progress)
        return PortalLayer(
            identifier: identifier,
            title: title,
            entries: fetched.items.map { entry in
                PortalEntry(
                    id: entry.id,
                    title: entry.title,
                    image: PosterAddress.url(for: entry, from: source, width: width),
                    // **The shared package is asked, not this file.** A second
                    // version of "leads deeper" would stay in place when the first
                    // changes — and it changes as soon as the bridge gains a kind.
                    leadsDeeper: PortalSource.levelID(forItem: entry),
                    isSeparator: entry.kind == .separator,
                    // **The same mapping as for the media server**, so that "8.2" on a
                    // portal tile means the same as on every other. Today the bridge fills
                    // only the community rating; `best(from:)` takes what is there.
                    rating: TileArtwork.rating(entry),
                    // **The format note comes from the bridge** (`bild_breit`) and is passed
                    // through here, not measured. Until 2026-09-08 it ended at
                    // this line, because ``PortalEntry`` had no field for it — and in the
                    // portal a landscape poster stood in a portrait frame.
                    wide: entry.artwork.isWide)
            },
            hint: fetched.hint,
            query: fetched.query,
            total: fetched.total,
            next: fetched.next,
            // **The suggestion comes from the bridge** (`eingabe_vorschlag`) and is passed
            // through here, not guessed. It is what the reader's keyboard would have been
            // prefilled with — the full reasoning is at
            // ``PortalLayer/suggestion``.
            suggestion: fetched.suggestion,
            // **A follow-up question is not an empty report.** It comes alongside `hint` and
            // not in its place — the reasoning is at ``PortalLayer/followUpQuestion``.
            followUpQuestion: fetched.followUpQuestion,
            truncated: fetched.truncated)
    }

    /// Take one page out of "Recently Used" — the server lets the next one move up.
    public func forgetRecent(_ identifier: String) async throws {
        try await source.forgetRecent(identifier)
    }

    /// The hosts of a title — **unchanged, as the bridge orders them.**
    ///
    /// The order is information: the bridge pulls the sources of the chosen
    /// language to the front and works through them in `/play` from the top. Whoever sorted here
    /// would override the choice that was already made one level deeper.
    public func host(zu identifier: String) async throws -> [PortalHost] {
        try await source.host(forItem: identifier).map {
            PortalHost(
                id: $0.id, name: $0.name, language: $0.language, locked: $0.locked,
                reason: $0.reason)
        }
    }

    /// The same level with a search term — **a level of its own.**
    ///
    /// It has to be its own: two readers use the same identifier, the folder list
    /// and the grid. The full reasoning is at `PortalLibraryID.input`.
    public func needle(in identifier: String, after input: String) -> String? {
        PortalSource.searchedID(forItem: identifier, input: input)
    }

    public func languages(zu identifier: String) async throws -> [String] {
        try await source.languages(forItem: identifier)
    }

    public func select(language: String, forItem identifier: String) async throws {
        try await source.setLanguage(language, forItem: identifier)
    }

    public func language(zu identifier: String) async throws -> String {
        try await source.language(forItem: identifier)
    }

    /// **The same mapping as everywhere** — ``TileArtwork`` and not a second one here.
    ///
    /// The width comes from the caller, because a portal's favorites in its own area
    /// may stand in a wide grid and in the shelf next to it not; see
    /// ``TileContent/wide``.
    public func favorites(width: Int) async throws -> [TileContent] {
        try await source.favorites().map {
            TileArtwork.tile($0, source: source, width: width)
        }
    }
}
