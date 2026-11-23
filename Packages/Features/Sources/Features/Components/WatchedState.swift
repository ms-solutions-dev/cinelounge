import Core

extension MediaItem {

    /// Whether the title counts as watched.
    ///
    /// For a series what counts is whether **everything** is watched: the server keeps the
    /// number of unwatched episodes for that, and it is the more reliable information than the
    /// flag on the series entry itself, which it keeps only as long as nobody
    /// toggles individual episodes. The same rule applies on the detail page — it
    /// appears here a second time because cards and the long-press menu need it,
    /// without building a detail model for that.
    var isWatched: Bool {
        if kind == .series, let unplayed = unplayedCount {
            return unplayed == 0
        }
        return progress?.isWatched == true
    }
}
