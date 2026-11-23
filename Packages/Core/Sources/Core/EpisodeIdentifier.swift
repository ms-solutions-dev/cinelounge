import Foundation
import WordingKit

/// "S1 F3" — **the position of an episode, from the shared catalog.**
///
/// **Finding B3 of the check of 2026-09-27:** five places in both programs assembled the
/// identifier themselves, with the German "F" for Folge. In English the abbreviation is
/// "E" (Episode), in Turkish "B" (Bölüm). Since then it comes from `common.seasonEpisode` in the
/// `WordingKit` package, and all places ask here — also so that TV and phone
/// show the same notation (decision 25).
public enum EpisodeIdentifier {

    /// The identifier in the app's language.
    ///
    /// - Parameter sprache: The language to write in; without a value, the one that applies in
    ///   the app (``AppLanguageSetting/current``).
    public static func text(
        season: Int, episode: Int, language: String? = AppLanguageSetting.current
    ) -> String {
        WordingKit.text("common.seasonEpisode \(season) \(episode)", language: language)
    }
}

extension MediaItem {

    /// This title's identifier if it carries season and episode — otherwise `nil`.
    public var episodeIdentifier: String? {
        guard let seasonNumber, let episodeNumber else { return nil }
        return EpisodeIdentifier.text(season: seasonNumber, episode: episodeNumber)
    }
}
