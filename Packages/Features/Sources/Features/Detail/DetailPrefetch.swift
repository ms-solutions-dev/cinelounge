import Core
import DesignSystem
import Foundation
import JellyfinKit

/// Fetches the detail page's images **before** it is opened.
///
/// **The finding this came from** (viewer question 2026-08-08): since
/// ``StartupPrefetch`` holds the posters of a whole library, the
/// grid appears immediately — the detail page does not. It shows four more
/// kinds of image, none of which was in the store: the backdrop image, the
/// cast photos, for series the still frames of the episodes, and the chapter images.
/// Whoever opened a film saw placeholders again, although the grid
/// before it had appeared instantly.
///
/// **Prefetching is done for the title on which focus has come to rest** —
/// and not for all. That is not a saving measure but the actual
/// insight: exactly this title is opened next, because that is what
/// you rest on it for. Prefetching for all would mean pulling several
/// hundred images for eighty films, of which one is looked at.
///
/// **Chapter images are deliberately left out.** A film brings thirty to
/// forty, and they only become visible when someone unfolds the chapter bar
/// — almost nobody does. Taking them along would multiply the
/// store volume tenfold for a sight that rarely comes.
nonisolated enum DetailPrefetch {

    /// How many episodes of a series are prefetched.
    ///
    /// A season opens with the first episode at the top; what is visible without scrolling
    /// is a few cards. Twelve covers that by a wide margin and stays affordable for
    /// a series with twenty seasons.
    static let episodesAhead = 12

    /// How many cast photos are prefetched.
    ///
    /// The row shows the lead roles first; whoever scrolls to the fortieth
    /// supporting actor may wait a moment.
    static let castAhead = 16

    /// Prepares a title's detail page.
    ///
    /// - Parameter item: Must be the **full** title, that is after
    ///   `LibraryModel.loadDetails(for:)` — the cast is not in the
    ///   list response but only in the single fetch. With a short title
    ///   only the backdrop image remains, and that is still the
    ///   largest single item on the page.
    ///
    /// Without a `Task` of its own: the caller is ``FocusFollowUp``, and it cancels
    /// as soon as focus moves on. That is exactly intended — whoever
    /// pages through should not load images for titles they have
    /// long passed. An unstructured operation here would take the connections away
    /// from the visible posters; this bug has already been made at this
    /// spot once.
    /// Only the backdrop image — the largest single item and the only one that
    /// manages **without a single fetch**: its ID is already in the
    /// list response. It is therefore offered separately and fetched in the grid
    /// as the very first thing, even before accent colour and ratings.
    /// The size under which the backdrop image is stored **and** read.
    ///
    /// **The finding** (AP7 · L4, expert review 2026-08-24): the prefetch stored
    /// under `1920×1080`, the view read under the **geometry** of its
    /// surface — and on the detail page that is narrower than the screen.
    /// Two keys, two entries: the prefetch warmed nothing, and the
    /// 8.29 MB it held decoded nobody read. With 160 MB of memory
    /// the store is full of corpses after nineteen titles paged through,
    /// and all posters are evicted.
    ///
    /// Both ends now name the same number. That it does not match the surface
    /// exactly is deliberate: decoding an image a few points larger
    /// costs nothing, two keys cost the whole prefetch.
    static let backdropSize = CGSize(width: 1920, height: 1080)

    static func warmBackdrop(for item: MediaItem, from source: any ContentSource) async {
        guard let backdrop = DetailModel.backdropURL(for: item, from: source) else { return }
        await ImageCache.shared.prefetch(
            [backdrop],
            decodeLimit: ImageSizing.decodeLimit(points: Self.backdropSize, headroom: 1)
        )
    }

    static func warm(for item: MediaItem, from source: any ContentSource) async {
        // Offered a second time and yet free: if it is already in
        // memory, the store skips it. Whoever reaches this spot without the route
        // via the grid gets it here.
        await warmBackdrop(for: item, from: source)

        guard !Task.isCancelled else { return }

        let cast = item.cast.prefix(castAhead)
        if !cast.isEmpty {
            await ImageCache.shared.prefetch(
                cast.compactMap { DetailModel.personURL(for: $0, from: source) },
                decodeLimit: ImageSizing.decodeLimit(
                    points: CGSize(
                        width: MetricsBoard.tv.person, height: MetricsBoard.tv.person))
            )
        }

        guard !Task.isCancelled else { return }

        // For a series additionally the first episodes. Their still frames
        // are wide cards and thereby the second large item on the page.
        //
        // **Asked for only with series**, and that is the reason for the condition:
        // a film has no episodes, but the question about them would still be
        // a request — when paging through, one per title, for a predictably
        // empty result.
        guard item.kind == .series else { return }
        guard let episodes = try? await source.episodes(of: item.id) else { return }

        await ImageCache.shared.prefetch(
            episodes.prefix(episodesAhead).compactMap {
                DetailModel.stillURL(for: $0, from: source)
            },
            decodeLimit: ImageSizing.decodeLimit(points: MetricsBoard.tv.episode)
        )
    }
}
