import Diagnose
import Foundation

/// Several start sources as one.
///
/// **Home is a dashboard over all used content** — that was the requirement of 2026-09-05.
/// (Home is effectively a dashboard over all used content), and until today it was a
/// Jellyfin home with room for more. Without this layer it would have to know how many
/// sources there are and keep a branch for each.
///
/// **Queried side by side, assembled in a fixed order.** Whoever answers first would
/// otherwise decide what is on top — and that would be a different page every time it is
/// opened. The order is the one in which the sources were passed: one's own first, then the
/// foreign.
///
/// **A source that does not respond does not take the others with it.** An expired provider
/// login must not lead to the media server disappearing too — that would be an outage that
/// looks like data loss. The same rule as in ``AggregateCatalogSource``.
public struct CompositeStartSource: StartSource {

    private let sources: [any StartSource]

    public init(_ sources: [any StartSource]) {
        self.sources = sources
    }

    public func home(perShelf: Int) async throws -> StartContent {
        var catalogs: [Catalog] = []
        var heroes: [HeroContent] = []
        var tiles: [Shelf.Identifier: [TileContent]] = [:]
        var disruptions: [Shelf.Identifier: ShelfDisruption] = [:]
        // **`nil` until a source says something about it** — the difference from "none" is at
        // ``StartContent/portals``. Only ``FromPortals`` answers the question; whoever loads
        // without a portal source should not have their history filtered by it.
        var portals: Set<String>?

        for reply in await Self.allConcurrently(sources, perShelf: perShelf) {
            do {
                let part = try reply.get()
                catalogs += part.state.catalogs
                heroes += part.heroes
                // **Merged and not replaced.** Two sources can fill the same fixed shelf — "Continue
                // Watching" explicitly takes every one. Anyone who assigns here instead of appending loses
                // what the first contributed.
                for (identifier, split) in part.tiles {
                    tiles[identifier, default: []] += split
                }
                // **The first reason wins.** Two sources that fill the same fixed shelf and both fail
                // would otherwise have two messages for one row — and the second would cover the first
                // without saying more.
                disruptions.merge(part.disruptions) { first, _ in first }
                if let reported = part.portals {
                    portals = (portals ?? []).union(reported)
                }
            } catch {
                Diagnose.hint(.network, "A start source is not responding", error)
            }
        }

        return StartContent(
            state: CatalogState(catalogs), heroes: heroes, tiles: tiles,
            disruptions: disruptions, portals: portals)
    }

    /// Queries the sources **simultaneously** and returns the answers in their sequence.
    ///
    /// **The finding (2026-09-29, on all devices):** Home stood for a long time on "loading"
    /// and was there immediately after a tab switch. Source after source was queried, so the
    /// wait was the sum — with a CL-Server that needs as much as 20 s for one portal. **Except
    /// two:** catalog and Live program query the same provider, whose account throttles on
    /// connection storms (one connection). They stay one after the other, only alongside the
    /// others. Anyone who takes longer than three seconds appears in the report.
    static func allConcurrently(
        _ sources: [any StartSource], perShelf: Int
    ) async -> [Result<StartContent, any Error>] {
        let provider = sources.indices.filter {
            sources[$0] is XtreamStartSource || sources[$0] is TodayLive
        }
        let single = sources.indices.filter { !provider.contains($0) }
        @Sendable func query(_ source: any StartSource) async -> Result<StartContent, any Error> {
            let start = Date()
            defer {
                let duration = Date().timeIntervalSince(start)
                if duration > 3 {
                    Diagnose.hint(
                        .network, "Home: \(type(of: source)) took \(Int(duration)) s")
                }
            }
            do { return .success(try await source.home(perShelf: perShelf)) } catch {
                return .failure(error)
            }
        }
        return await withTaskGroup(of: [(Int, Result<StartContent, any Error>)].self) { group in
            for location in single {
                let source = sources[location]
                group.addTask { [(location, await query(source))] }
            }
            if !provider.isEmpty {
                let chain = provider.map { ($0, sources[$0]) }
                group.addTask {
                    var answers: [(Int, Result<StartContent, any Error>)] = []
                    for (location, source) in chain { answers.append((location, await query(source))) }
                    return answers
                }
            }
            var all: [(Int, Result<StartContent, any Error>)] = []
            for await part in group { all += part }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// **The first source that yields something** — not all together.
    ///
    /// A box with eight titles from two sources would be a mixed catalog in which nobody knows
    /// where the title currently shown comes from. And the query is expensive; asking it twice
    /// in order to throw half away would be the worse of two options.
    public func heroes(atMost: Int) async throws -> [HeroContent] {
        for source in sources {
            if let found = try? await source.heroes(atMost: atMost),
                !found.isEmpty
            {
                return found
            }
        }
        return []
    }
}
