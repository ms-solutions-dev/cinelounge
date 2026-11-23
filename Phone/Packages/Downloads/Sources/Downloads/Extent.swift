/// How much a download job fetches — **and the answer comes from the trigger, not from a question.**
///
/// From the menu on an episode it is the episode, from the menu on the title the whole
/// season. Whoever wants to take two episodes along for the train ride should not have to download 4.9 GB
/// — and whoever queues a season should not have to confirm the same thing eighteen times.
///
/// **In the downloads a season stays ONE row.** Eighteen rows for eighteen episodes would be
/// the same information, just unreadable; the row carries "8 of 8 episodes" instead.
public enum Extent: Sendable, Hashable, Codable {
    /// Stored case names keep their original (German) form — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case film
        case episode = "folge"
        case season = "staffel"
        case unwatched = "ungesehen"
    }

    /// Stored keys of ``episode`` keep their original (German) names (AP85 B4).
    private enum EpisodeCodingKeys: String, CodingKey {
        case season = "staffel"
        case number
    }

    /// Stored keys of ``episode`` keep their original (German) names (AP85 B4).
    private enum FolgeCodingKeys: String, CodingKey {
        case season = "staffel"
        case number = "nummer"
    }

    /// Stored keys of ``season`` keep their original (German) names (AP85 B4).
    private enum StaffelCodingKeys: String, CodingKey {
        case number = "nummer"
        case episodes = "folgen"
    }

    /// Stored keys of ``unwatched`` keep their original (German) names (AP85 B4).
    private enum UngesehenCodingKeys: String, CodingKey {
        case episodes = "folgen"
        case seasons = "staffeln"
    }

    case film

    case episode(season: Int, number: Int)

    case season(number: Int, episodes: Int)

    /// Everything not yet watched — also across season boundaries.
    ///
    /// **The only scope that changes under the hood.** What is fourteen episodes today
    /// is twelve tomorrow. That is why it carries its number: a download job is an
    /// agreement about a set that held at acceptance, and not a subscription.
    case unwatched(episodes: Int, seasons: Int)

    /// How many episodes it contains. A film is not an episode and counts zero.
    public var episodeCount: Int {
        switch self {
        case .film: 0
        case .episode: 1
        case .season(_, let episodes): episodes
        case .unwatched(let episodes, _): episodes
        }
    }

    /// **Always 1.** Stated here as a number and not as a sentence in the builder's head, because the
    /// temptation to draw one row per episode arises anew in every list.
    public var downloadRowCount: Int { 1 }

    /// What this scope is **searched** by — "s2 f4" for an episode, "s2" for a season.
    ///
    /// **Structured and not translated**, and there are two reasons. First, the
    /// season of a queued **episode** is in neither of its two lines: the title is the
    /// episode title, the second line the series. Whoever searches for "S2" would otherwise find nothing.
    /// Second, under `swift test` there is no app bundle — a search text from the catalog
    /// would be the key there, and a check on it would test the presence of the
    /// catalog instead of the search.
    ///
    /// **The letters are those of the display**, in every app language: the
    /// episode label (`Core.EpisodeIdentifier`) writes "S1 F35" in German, "S1 E35" in
    /// English and "S1 B35" in Turkish — what one searches for is what one has seen.
    /// All three are in the search text because it is built without a catalog (see above).
    public var searchText: String {
        switch self {
        case .film, .unwatched: ""
        case .episode(let season, let number):
            ["f", "e", "b"].map { "s\(season) \($0)\(number)" }.joined(separator: " · ")
        case .season(let number, _): "s\(number)"
        }
    }
}
