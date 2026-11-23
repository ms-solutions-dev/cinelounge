import Core
import JellyfinKit
import Testing

@testable import Features

/// Whether the downloads are read at all at startup.
///
/// **This check exists because of a bug that was completely silent.** At startup
/// all libraries were fetched and put into the cache — with `kinds: []`.
/// The library view, however, asks with the kinds of its library, and the key
/// in the cache contains the request. The two never met: the downloads were
/// filled and afterwards never read once.
///
/// From outside nothing of this was visible. There was no error, no message, no
/// slower spot — only the viewer's observation that every view still loads on
/// first entry, although everything was fetched at startup. Bugs like this
/// are not found on the device, but only by holding the two sides
/// against each other.
@Suite("Prefetch at startup")
struct PrewarmTests {

    @Test(
        "Prefetch and view ask for the same kinds",
        arguments: [
            Core.Library.Kind.series,
            .movies,
            .homeVideos,
            .mixed,
            .music,
            .liveTV,
        ]
    )
    func prewarmMatchesTheView(_ kind: Core.Library.Kind) {
        // Two versions of the same mapping, because one lives in `JellyfinKit` and
        // the other in `Features` — from there the respective other is not
        // reachable. As long as that is so, a test has to hold them together.
        #expect(
            JellyfinSource.itemKinds(for: kind) == HomeModel.kinds(for: kind),
            """
            For \(kind) the prefetch asks for different kinds than the view. \
            Its result therefore lands under a different key, and the prefetch \
            is useless — without anything failing.
            """
        )
    }

    @Test("Libraries with content also deliver kinds")
    func contentLibrariesHaveKinds() {
        // The counter-check to the check above: that both versions agree does
        // nothing if both are empty. For the three libraries the viewer
        // actually opens, something must come out.
        for kind in [Core.Library.Kind.series, .movies, .homeVideos] {
            #expect(
                !JellyfinSource.itemKinds(for: kind).isEmpty,
                "\(kind) without kinds would mean: the prefetch fetches everything and the view nothing"
            )
        }
    }

    /// **The test that was missing the first time.** The check above holds only
    /// the kinds against each other — but the key in the cache contained the
    /// whole request, and for home videos the downloads missed despite equal
    /// kinds, because the view sorts descending by recording date.
    /// Hence the **complete key** here, for every sort pill of every
    /// library kind and for the shelves of the Home screen.
    @Test(
        "Every pill and every shelf hits the prefetch key",
        arguments: [
            Core.Library.Kind.series,
            .movies,
            .homeVideos,
            .mixed,
        ]
    )
    func everyViewFilterHitsThePrewarmKey(_ kind: Core.Library.Kind) {
        let library = "lib-unter-pruefung"
        let prewarmKey = JellyfinSource.listCacheKey(
            library: library,
            filter: Core.ItemFilter(kinds: JellyfinSource.itemKinds(for: kind))
        )

        // The library view: every offered sort order.
        for sorting in LibraryModel.Sorting.choices(for: kind) {
            let viewFilter = Core.ItemFilter(
                kinds: HomeModel.kinds(for: kind),
                sortBy: sorting.filter,
                ascending: sorting.ascending
            )
            #expect(
                JellyfinSource.listCacheKey(library: library, filter: viewFilter) == prewarmKey,
                "The pill \"\(sorting.rawValue)\" for \(kind) bypasses the prefetch"
            )
        }

        // The Home shelf: "Recently Added", 20 items — the request
        // from `HomeModel.buildShelves`.
        let shelfFilter = Core.ItemFilter(
            kinds: HomeModel.kinds(for: kind),
            sortBy: .dateAdded,
            ascending: false,
            limit: 20
        )
        #expect(
            JellyfinSource.listCacheKey(library: library, filter: shelfFilter) == prewarmKey,
            "The Home shelf for \(kind) bypasses the prefetch"
        )
    }
}
