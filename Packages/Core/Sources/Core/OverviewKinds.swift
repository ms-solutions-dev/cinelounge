import Foundation

extension Library.Kind {

    /// Which title kinds a library shows in the overview — **the one board** (AP58 R6,
    /// St6).
    ///
    /// It used to stand three times: `HomeModel.kinds(for:)` on the TV,
    /// `JellyfinSource.itemKinds` for warm-up and `JellyfinStartSource.kinds` on the
    /// phone — identical, but each with the comment that it must match the other.
    ///
    /// In a series library these are the **series**, not their episodes. A
    /// **portal level** gets no kind filter: It delivers episodes, films, seasons and
    /// folders side by side, and every filter would be a claim about a foreign list.
    public nonisolated var overviewKinds: [MediaItem.Kind] {
        switch self {
        case .series: [.series]
        case .movies: [.movie]
        case .homeVideos: [.homeVideo]
        case .mixed: [.series, .movie]
        case .music, .liveTV, .portalLevel: []
        }
    }
}
