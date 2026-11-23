import Core
import Foundation

/// Finds a title's trailer — without the CL-Server, for all three services (AP78, 2026-10-11).
///
/// **Why here and not in the detail models:** TV and phone need the same
/// decision from the same ingredients (own file, TMDb videos, app language,
/// original language). Built twice, the language rule would have to be justified twice — and once
/// differently. The rule itself is in ``Core/TrailerRule`` and is tested there; here is
/// only where the ingredients come from.
///
/// The TMDb information is the same as for ratings and cast
/// (``TMDbClient/title(_:)``, 14 days in the cache) — so the trailer costs no second
/// request, unless the title is in a foreign language and has no trailer in the app language:
/// Then the original language is fetched separately (``TrailerRule/missingOriginal``).
public enum TrailerSource {

    /// - Parameters:
    ///   - kennung: `movie/603` or `tv/1399`, as far as the source knows it.
    ///   - suche: Title and year for the lookup when the identifier is missing (Jellyfin title
    ///     without a TMDb entry).
    ///   - datei: The catalog's own trailer file, with its audio language.
    ///   - appSprache: ISO 639-1, like ``Core/AppLanguageSetting/current``.
    public static func trailer(
        tmdb identifier: String?,
        search: ExternalLookup.TitleSearch?,
        file: TrailerFile?,
        appLanguage: String,
        client: TMDbClient?
    ) async -> TrailerChoice? {
        let started = Date()
        guard let client else {
            return TrailerRule.choice(file: file, videos: [], appLanguage: appLanguage, original: nil)
        }
        var identifier = identifier
        if identifier == nil, let search {
            identifier = try? await client.search(
                title: search.title, year: search.year, series: search.series)
        }
        guard let identifier, let info = try? await client.title(identifier) else {
            return TrailerRule.choice(file: file, videos: [], appLanguage: appLanguage, original: nil)
        }
        var videos = info.videos
        if let original = TrailerRule.missingOriginal(
            file: file, videos: videos, appLanguage: appLanguage, original: info.originalLang),
            let more = try? await client.videos(identifier, language: original)
        {
            videos += more
        }
        let choice = TrailerRule.choice(
            file: file, videos: videos, appLanguage: appLanguage, original: info.originalLang)
        Diagnostics.network.info(
            "Trailer \(identifier, privacy: .public): \(videos.count) videos, original \(info.originalLang ?? "?", privacy: .public), choice \(choice.map { "\($0)" } ?? "none", privacy: .public) after \(Int(Date().timeIntervalSince(started) * 1000)) ms"
        )
        return choice
    }
}
