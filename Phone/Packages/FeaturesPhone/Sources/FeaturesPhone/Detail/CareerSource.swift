import Core
import Diagnose
import Foundation
import RatingsKit

/// Where faces and filmographies come from.
///
/// **Separate from ``RatingSource``, even though both are third-party services.** Ratings
/// come from OMDb and AniList and are **always** fetched; the filmography comes from TMDb
/// and only on demand. One protocol for both would force every check to rebuild
/// what it does not even look at.
///
/// **Whether an access credential is configured belongs in the contract.** Without it, a
/// cast circle stops being a button — instead of staying a button that does nothing. Only
/// the view can make that distinction, and only if it is told.
public protocol CareerSource: Sendable {

    /// Whether an access credential is configured at all.
    var entered: Bool { get }

    /// Portraits for names — what is not found is simply missing.
    func portraits(zu names: [String]) async -> [String: URL]

    /// What this person has otherwise worked on.
    func filmography(zu name: String) async -> Filmography?

    /// What the film database knows about a title you do **not** have.
    ///
    /// **"What you have opens; what you don't have explains itself."** The sentence appears
    /// verbatim in the TV project, where it has been built since 2026-08-08: a foreign
    /// row answers with what TMDb knows about it instead of not answering at all.
    /// `Core.TitleProfile` and `FilmographySource.profile(for:)` are available in the shared package
    /// — **the phone never called them.**
    func profile(zu entry: FilmographyEntry) async -> TitleProfile?
}

/// The filmography from the film database.
///
/// **Why TMDb and not the media server:** Jellyfin only knows its own catalog. Asked
/// "where has this person acted" it would return exactly that — and the "is in
/// my library" marker would be meaningless, because then everything shown is in it.
///
/// **And why not OMDb**, where the ratings come from: OMDb lists titles, not
/// people. AniList lists people, but only for anime.
public struct FilmDatabase: CareerSource {

    private let tmdb: TMDbClient?

    public init(key: String?) {
        self.tmdb = key.flatMap {
            $0.isEmpty
                ? nil : TMDbClient(apiKey: $0, language: TMDbClient.language(AppLanguageSetting.current))
        }
    }

    public var entered: Bool { tmdb != nil }

    /// At most this many faces are fetched later.
    ///
    /// Twelve, as on the TV: the circles sit in a rolling row, and anyone who swipes to
    /// the thirteenth has waited anyway. Anything beyond that would be a request to
    /// a third-party endpoint for an image nobody looks at.
    static let maxPortraits = ExternalLookup.maxPortraits

    /// **Four side by side, not all at once.**
    ///
    /// Twelve names one after another cost 1.8 to 3.0 seconds on the TV; twelve
    /// at the same time gain nothing for a third-party endpoint. Four cover the circles
    /// that are on screen before anyone swipes on.
    static let concurrently = ExternalLookup.concurrentPortraits

    public func portraits(zu names: [String]) async -> [String: URL] {
        guard let tmdb, !names.isEmpty else { return [:] }
        let pending = Array(names.prefix(Self.maxPortraits))
        let found = await ExternalLookup.portraits(
            zu: pending, from: tmdb, atMost: Self.maxPortraits,
            concurrently: Self.concurrently)
        if found.isEmpty {
            // **No throw, but a line in the ledger.** "Credential present, query returns nothing"
            // looks on screen exactly like "no credential" — namely like
            // empty circles. Only one of the two causes can be fixed.
            Diagnose.hint(.network, "Cast: no portrait for \(pending.count) names")
        }
        return found
    }

    public func profile(zu entry: FilmographyEntry) async -> TitleProfile? {
        guard let tmdb else { return nil }
        do {
            return try await tmdb.profile(for: entry)
        } catch {
            Diagnose.hint(.network, "No profile for \(entry.title): \(error)")
            return nil
        }
    }

    public func filmography(zu name: String) async -> Filmography? {
        guard let tmdb else { return nil }
        do {
            return try await tmdb.filmography(forPersonNamed: name)
        } catch {
            Diagnose.hint(.network, "Filmography not fetched", error)
            return nil
        }
    }
}
