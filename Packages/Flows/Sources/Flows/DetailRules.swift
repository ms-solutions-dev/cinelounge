import Core
import Foundation

/// What a detail page fetches — **the rules both apps share** (AP58 R6, St5).
///
/// **What is here and what is not.** Both detail pages load in their own ways: the
/// TV season by season into `MediaItem`s, the phone all episodes at once into
/// its season cards. This way of loading stays per device — the phone holds the whole series
/// for downloads and the episode menu, the TV pages and loads more. Shared are the questions
/// above it: which season opens and which episode the button plays
/// (``Core/ContinueWatching``), whether there are "Similar" titles, the external ratings
/// and portraits (``RatingsKit/ExternalLookup``) and the "have it" marker in the filmography
/// (``CatalogIndex``).
public nonisolated enum DetailRules {

    /// This many "Similar" titles are fetched — the row scrolls horizontally, and what lies behind the
    /// twelfth poster nobody sees.
    public static let maxSimilar = 12

    /// Whether a detail page of this kind shows "Similar" titles.
    ///
    /// **Films, home videos and series** — decided in R6. The TV asked only for
    /// films and home videos, the phone for everything, also for collections, seasons and
    /// episodes. For a series the media server returns similar series, and those are
    /// information; for an episode it would be the siblings of its series, for a collection
    /// its parts — both are already on the page.
    public static func fetchesSimilar(_ kind: MediaItem.Kind) -> Bool {
        kind == .movie || kind == .homeVideo || kind == .series
    }
}
