import Core
import Diagnose
import Foundation
import RatingsKit

/// Ratings, awards and German voices from IMDb, the critics' portals, MyAnimeList and
/// AniList (only the voices now, AP68).
///
/// **Why at all, when the server already supplies a number:** its community rating comes
/// from TMDb or IMDb depending on the setting, and it does not say which of the two it
/// is. Anyone who shows a number should be able to say whose number it is.
///
/// **Only for the eight heroes and the open title, not for the eighty tiles.** OMDb gives
/// a thousand queries a day in the free tier; with twenty tiles per shelf that would be
/// used up after twelve starts. The tiles therefore keep what the server supplies — the
/// header area and the detail page get the more precise information because there is room
/// for it there.
///
/// **MyAnimeList first** (AP68, formerly AniList). If the anime mapping knows the title,
/// it is anime — and critics' portals have nothing there.
public struct ExternalRatingsSource: RatingSource {

    private let omdb: OMDbClient?
    private let anilist: AniListClient
    private let anime: AnimeRating?
    /// For titles without an IMDb identifier (2026-09-29) — via the TMDb number to the IMDb
    /// identifier.
    private let tmdb: TMDbClient?

    /// - Parameter omdbSchluessel: the personal access. Without it only AniList remains,
    ///   and that is a full-fledged state: Home then keeps showing the server's numbers.
    /// - Parameter tmdbSchluessel: the access to the film database. With it, IPTV and
    ///   CL-Server titles get the same ratings as Jellyfin titles via their TMDb number.
    public init(
        omdbKey: String?, anilist: AniListClient = AniListClient(),
        tmdbKey: String? = nil, anime: AnimeRating? = nil
    ) {
        // **On disk** (2026-09-29): until then the cache lived only in memory — after every
        // start the phone queried OMDb again and ate into the daily quota. The TV has always kept
        // its answers.
        self.omdb = omdbKey.flatMap {
            $0.isEmpty ? nil : OMDbClient(apiKey: $0, store: FileStore())
        }
        self.anilist = anilist
        self.anime = anime
        // **With the app language** (AP78): until then the phone always asked TMDb in German —
        // descriptions and trailers came in German even when the app was set to Turkish.
        self.tmdb = tmdbKey.flatMap {
            $0.isEmpty
                ? nil : TMDbClient(apiKey: $0, language: TMDbClient.language(AppLanguageSetting.current))
        }
    }

    public func trailer(zu identifier: RatingID, file: TrailerFile?) async -> TrailerChoice? {
        await TrailerSource.trailer(
            tmdb: identifier.tmdb,
            search: identifier.search.map {
                ExternalLookup.TitleSearch(title: $0.title, year: $0.year, series: $0.series)
            },
            file: file, appLanguage: AppLanguageSetting.current ?? "de", client: tmdb)
    }

    /// **Everything fetched at once and side by side.**
    ///
    /// One after another it would be double the waiting time for something that the page only
    /// supplements anyway — the TV program does it the same way. AniList needs no key, OMDb
    /// does; if it is missing, the AniList number and voices remain anyway.
    /// **Since AP58 R6 via ``RatingsKit/ExternalLookup/fetch(imdb:anilist:omdb:anilistClient:)``**
    /// — the same query as on the TV's detail page. What remains here is the mapping onto this
    /// app's badges.
    ///
    /// **The order is that of explanatory power**, not that of response time: that an AniList
    /// identifier is present already means the title is anime — and critics' portals have
    /// nothing there.
    public func info(zu identifier: RatingID) async -> ExternalInfo {
        let state = await ExternalLookup.fetch(
            imdb: identifier.imdb, anilist: identifier.anilist, omdb: omdb, anilistClient: anilist,
            tmdb: identifier.tmdb, tmdbClient: tmdb,
            search: identifier.search.map {
                ExternalLookup.TitleSearch(title: $0.title, year: $0.year, series: $0.series)
            }, tvdb: identifier.tvdb, anime: anime)
        let titleInfo = try? state.tmdb?.get()
        for (service, error) in state.error {
            Diagnose.hint(.network, "\(service) not fetched", error)
        }
        let values = try? state.omdb?.get()
        let scores = [
            Rating.fromTen((try? state.mal?.get())??.score, .mal),
            values.flatMap { Rating.fromTen($0.imdb, .imdb) },
            values.flatMap { Rating.fromHundred($0.rottenTomatoes, .critics) },
            values.flatMap { Rating.fromPoints($0.metacritic, .metacritic) },
        ].compactMap { $0 }
        return ExternalInfo(
            ratings: scores,
            award: Self.award(from: values?.awards),
            voices: state.voicesOrEmpty,
            isAccessConfigured: omdb != nil,
            backdrop: titleInfo?.backdrop,
            description: titleInfo?.description,
            genres: titleInfo?.genres ?? [],
            cast: Self.cast(from: titleInfo),
            hasMuteMark: Self.muted(state.mal))
    }

    /// Whether MAL was responsible and did not respond. "Not found" is information, not
    /// silence.
    static func muted(_ mal: Result<MALClient.Rating?, any Error>?) -> Bool {
        guard case .failure(let error) = mal else { return false }
        return (error as? MALClient.Failure) != .notFound
    }

    /// The TMDb cast in the phone's form — the identifier carries `tmdb:` in front, so that
    /// nobody mistakes it for a server identifier.
    static func cast(from info: TitleInfo?) -> [PersonDetail] {
        (info?.cast ?? []).map { person in
            let task: PersonDetail.Role =
                switch person.role {
                case .actor: .cast
                case .director: .directors
                case .writer: .ledger
                default: .other
                }
            return PersonDetail(
                id: "tmdb:" + person.name, name: person.name, characterName: person.characterName,
                task: task, image: person.image)
        }
    }

    static func award(from awards: Awards?) -> Accolade? {
        guard let awards, !awards.isEmpty else { return nil }
        return Accolade.from(
            oscarsWon: awards.oscarsWon,
            oscarNominations: awards.oscarNominations,
            emmysWon: awards.emmysWon,
            wins: awards.totalWins,
            nominations: awards.totalNominations)
    }
}
