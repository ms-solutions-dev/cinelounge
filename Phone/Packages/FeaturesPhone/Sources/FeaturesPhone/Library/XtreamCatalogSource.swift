import Core
import Diagnose
import Flows
import Foundation
import PlaylistKit

/// The library at the Xtream provider.
///
/// **Two catalogs, not twenty-four.** The provider keeps its categories separate
/// by films and series; the index therefore has exactly two rows, and the categories
/// lie one level below. Lifting them into the index would mean twenty-four rows
/// between "Films" and "In downloads" — the TV made exactly this mistake and
/// reverted it on 2026-08-22.
///
/// **And the number on the index row stays empty.** Filling it would mean querying all
/// categories just to form a sum — with an account that has **one** permitted
/// connection and an IP throttle that also blocks the API, that is the most
/// expensive conceivable way to a number nobody misses.
public struct XtreamCatalogSource: CatalogSource {

    private let source: ProviderSource
    private let listen: [XtreamList]
    private let width: Int

    /// A set-up account — identifier and **name**.
    ///
    /// **The name comes from outside and is not invented here** (user finding 2026-09-05:
    /// "did you name the IPTV provider 'Provider'?"). Yes, I had — and with two
    /// accounts the same wording would have appeared twice. From AP21 the setup assigns
    /// it; until then ``SourceAssembly`` passes it through.
    public struct XtreamList: Sendable, Equatable {
        public let identifier: String
        public let name: String

        public init(identifier: String, name: String) {
            self.identifier = identifier
            self.name = name
        }
    }

    public init(source: ProviderSource, listen: [XtreamList], width: Int) {
        self.source = source
        self.listen = listen
        self.width = width
    }

    /// The two index rows.
    ///
    /// **Fixed and not built from the provider's response.** Whether it reports categories
    /// today decides the level below and not whether it exists: a set-up account that
    /// currently delivers nothing should appear in the index and show its empty state
    /// there — not vanish without a trace.
    public func state() async throws -> CatalogState {
        CatalogState(
            listen.flatMap { list in
                [
                    Catalog(
                        id: .init(.provider, .movies, "\(list.identifier)|vod"),
                        origin: .provider,
                        label: .key("tab.movies"), kind: .movies,
                        sourceIdentifier: "\(list.identifier)|vod",
                        group: .wording(list.name)),
                    Catalog(
                        id: .init(.provider, .allSeries, "\(list.identifier)|series"),
                        origin: .provider,
                        label: .key("tab.series"), kind: .allSeries,
                        sourceIdentifier: "\(list.identifier)|series",
                        group: .wording(list.name)),
                ]
            })
    }

    /// **An Xtream catalog has no titles of its own** — it has categories.
    ///
    /// The empty list is therefore not a failure but the right answer: the view asks for
    /// titles only once a category is chosen.
    public func title(
        from catalog: Catalog, slice: CatalogSlice?
    ) async throws -> [TileContent] {
        []
    }

    public func categories(zu catalog: Catalog) async throws -> [GenreCategory] {
        // "liste|vod" or "liste|series" — the identifier carries both, so that two accounts
        // do not overlap.
        //
        // **At the last bar, not the first** (phone, 2026-09-29: films and series empty).
        // A derived list identifier itself carries bars (`xtream|host|user`);
        // split at the first, the list was called "xtream", which does not exist — every
        // fetch ended as "unauthorized". With a UUID as identifier (on the iPad) it never
        // showed.
        guard let (list, allSeries) = Self.parse(catalog.sourceIdentifier) else { return [] }

        // **Once per session and only for this account** — see ``ProviderCache``.
        // The fetch costs two requests (film and series categories), and Home
        // asks for it per catalog; via `libraries()` that would be four
        // requests for two accounts, for an answer that concerns one.
        let allLibraries = await ProviderCache.shared.libraries(source, credential: list)
        return allLibraries.compactMap { library in
            guard let decomposed = XtreamVODSource.parseLibraryID(library.id) else { return nil }
            guard decomposed.playlistID == list, (decomposed.kind == .series) == allSeries else {
                return nil
            }
            // **No count.** `Library.itemCount` is empty for the provider, and counting it
            // afterwards would cost one query per category — with 108 categories and an
            // account with one connection that is out of the question.
            return GenreCategory(
                // **Folded, not smoothed.** The provider writes decorative characters into
                // its category names — `ᴴᴰ` instead of `HD`, `⁴ᴷ` instead of `4K` — and sometimes
                // frames them. `ChannelName.display` resolves exactly that; in the TV's test catalog
                // it affects 2,176 of 5,389 names. No information is lost in the process: a
                // superscript HD becomes an HD, a framed name becomes the same name.
                id: library.id, name: ChannelName.display(library.name),
                extent: library.itemCount, origin: .provider)
        }
    }

    /// `<XtreamList>|vod` or `<XtreamList>|series` — split **at the last bar**, see
    /// ``categories(zu:)``.
    static func parse(_ sourceIdentifier: String) -> (list: String, allSeries: Bool)? {
        guard let separatorIndex = sourceIdentifier.lastIndex(of: "|") else { return nil }
        let list = String(sourceIdentifier[..<separatorIndex])
        let listKind = sourceIdentifier[sourceIdentifier.index(after: separatorIndex)...]
        guard !list.isEmpty, listKind == "vod" || listKind == "series" else { return nil }
        return (list, listKind == "series")
    }

    public func title(from category: GenreCategory) async throws -> [TileContent] {
        // **From the cache, if it already has them.** Without it, the same category
        // appeared three times in the log — once for the library, twice for Home.
        let fetched = try await ProviderCache.shared.title(
            source, category: category.id, filter: ItemFilter(sortBy: .title))
        Diagnose.step(.network, "Category \(category.name): \(fetched.count) titles")
        return fetched.map { TileArtwork.tile($0, source: source, width: width) }
    }
}
