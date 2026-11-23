import Foundation

/// What is offered next after a film if it is part of a series.
///
/// The rule for the queue candidate: **collection before similar.**
/// After Jeipik-Bousjinflut (2002), Jeipik-Bousjinflut 2 (2004) belongs in the offer — not
/// any film that seems similar to the server. Only when the series has ended
/// or the title is in none may the `Similar` endpoint guess.
public enum FollowUpRule {

    /// The next part of a series after this title, or `nil`.
    ///
    /// - Parameter parts: The parts of the collection, **ordered by release
    ///   date** — that is how the source delivers them (see `collectionItems`).
    ///
    /// The next **unwatched** part is preferred: whoever has long known part 2
    /// is offered part 3 instead of a repeat. If all following ones are
    /// watched, the immediately next one still applies — continuing the series
    /// is the best guess even then, and dismissing costs one press.
    public static func nextPart(after itemID: String, in parts: [MediaItem]) -> MediaItem? {
        guard let index = parts.firstIndex(where: { $0.id == itemID }) else { return nil }

        let following = parts[parts.index(after: index)...]
        guard !following.isEmpty else { return nil }

        return following.first { !($0.progress?.isWatched ?? false) } ?? following.first
    }
}
