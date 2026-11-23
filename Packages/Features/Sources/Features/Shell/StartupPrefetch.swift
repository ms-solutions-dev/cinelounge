import Core
import DesignSystem
import Foundation
import JellyfinKit

/// After the prefetch, loads the first posters of each library into the image cache.
///
/// **The last step of the startup prefetch, and it lives here instead of in the
/// source:** `JellyfinKit` does not know the image cache — that lives in
/// `DesignSystem` —, and the width of a poster is known only to whoever draws the
/// tiles. Only here do the two come together.
///
/// Without this step the **lists** were warm after startup, the **images** were not:
/// every grid poster began loading only when its tile appeared, and popped in
/// afterwards. Exactly the tiles that are seen first when a library opens are
/// preloaded — in the sort order with which the view opens, in the width and decode
/// size with which ``PosterCard`` draws. If any of these differs, the image lies under
/// a foreign key, and the whole prefetch would be silently ineffective — the same trap
/// the list prefetch once ran into.
nonisolated enum StartupPrefetch {

    /// How many posters per library are prefetched.
    ///
    /// **Raised from twelve to one hundred (2026-08-08).** Twelve was "two rows, what is
    /// visible without scrolling" — and that was exactly too tight a notion: anyone who
    /// scrolls sees placeholders again from the third row, and in the tested catalog that
    /// is 75 of the 87 movies (viewer finding 2026-08-08, "images do not render
    /// immediately").
    ///
    /// One hundred covers a grown private collection completely and stays affordable: a
    /// poster at grid width weighs about 40 KB, that is four megabytes per library — once
    /// at startup, afterwards from disk. The image cache decides by itself what it keeps
    /// decoded; the prefetch initially fills only the disk.
    ///
    /// **Not "all".** A limit has to remain: whoever one day holds a thousand movies
    /// should not pull forty megabytes at startup, nine tenths of which they never look
    /// at.
    static let postersPerLibrary = 100

    static func warmPosters(from source: JellyfinSource) async {
        guard let libraries = try? await source.libraries() else { return }

        var urls: [URL] = []
        for library in libraries {
            let kinds = JellyfinSource.itemKinds(for: library.kind)
            guard !kinds.isEmpty else { continue }

            // The same default as ``LibraryModel``: home videos open by the most recent date,
            // everything else by title. The lists are in memory after the prefetch — this costs no
            // network fetch.
            let filter = Core.ItemFilter(
                kinds: kinds,
                sortBy: library.kind == .homeVideos ? .dateCreated : .title,
                ascending: library.kind != .homeVideos,
                limit: postersPerLibrary
            )
            guard let items = try? await source.items(in: library.id, filter: filter) else {
                continue
            }
            // **The same calculation as the tile** — via ``PosterAddress``. A prefetch under a
            // foreign key warms nothing, and two separate calculations have drifted apart before.
            urls += items.compactMap { item in
                PosterAddress.url(
                    for: item, from: source,
                    width: ImageSizing.requestWidth(points: MetricsBoard.tv.poster.width))
            }
        }

        await ImageCache.shared.prefetch(
            urls,
            decodeLimit: ImageSizing.decodeLimit(points: MetricsBoard.tv.poster)
        )
    }

    /// The wide cards of "Continue Watching" — thumbnails of the started episodes and
    /// movies.
    ///
    /// A step of its own next to the posters, because size and address are different: the
    /// card draws via ``HomeModel/stillURL(for:from:width:)``, and only with exactly the
    /// same calculation does the image lie under the same key.
    static func warmResumableStills(from source: JellyfinSource) async {
        guard let started = try? await source.resumable(limit: 12) else { return }
        let urls = started.compactMap { HomeModel.stillURL(for: $0, from: source) }
        await ImageCache.shared.prefetch(
            urls,
            decodeLimit: ImageSizing.decodeLimit(points: MetricsBoard.tv.episode)
        )
    }
}
