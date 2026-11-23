import Downloads
import Foundation

/// From what the detail page currently has in hand, this builds what lies next to the file.
///
/// **A pure conversion and not a fetcher** (2026-09-09). What is fetched is decided by
/// ``DownloadsManager``; **how** a ``DetailContent`` becomes a ``DownloadDescription``
/// is stated here — without network, without folders, without side effects. Only this way can it be verified
/// that five episodes of a series carry the same series identifier without running five downloads.
///
/// **Nothing is invented and nothing fetched twice.** Every item comes from the
/// ``DetailContent`` passed in or from the ``ExternalInfo`` that the detail page
/// has already fetched anyway. Where a source delivers nothing, the field stays empty — an
/// invented year would be worse than none.
enum DownloadDescriber {

    /// What remains to be done after the conversion is finished.
    struct Outcome {
        var description: DownloadDescription
        /// File name → address. **A dictionary and not a list**, because the same address
        /// occurs several times (the series poster is on the title and on every episode) and the
        /// name for the same address is the same.
        var frames: [String: URL]
    }

    /// This many faces are fetched.
    ///
    /// **Ten and not all.** A film's cast has thirty entries; through
    /// a tunnel with a measured 0.31 Mbit/s (finding of 2026-09-05) that is thirty
    /// requests next to the actual download. The cast circle shows a rolling
    /// row — what lies behind the tenth face almost nobody sees anyway, and the
    /// **names** are all there regardless.
    static let maxFaces = 10

    /// This many people appear in the description.
    static let maxPeople = 20

    /// Converts a detail content into the description next to the file.
    ///
    /// **An episode's rating is its series' rating — if the series page was read**
    /// (check 2026-09-25). ``DownloadsManager`` fetches the series page for an episode;
    /// if that fails, only the episode page remains. Then the series' rating is **open**
    /// (``Downloads/DownloadDescription/seriesClearanceChecked`` `false`), and the filter blocks the
    /// episode for a child — the same rule as `Core.MediaItem.awaitsSeriesClearance`.
    static func compose(
        _ job: DownloadJob, from content: DetailContent, info: ExternalInfo = .empty,
        series: String? = nil
    ) -> Outcome {
        var frames: [String: URL] = [:]

        /// Remembers the address and returns the file name.
        func memorize(_ address: URL?) -> String? {
            guard let address else { return nil }
            let name = DownloadImages.name(forItem: address)
            frames[name] = address
            return name
        }

        let held = content.title
        let episode = content.seasons.flatMap(\.episodes).first { $0.id == job.id.rawValue }
        let decomposed = Traits(held.attributes)

        // **The server's ratings and the external ones together** — exactly as the
        // detail page shows them (``DetailContent/using(_:)``): if an IMDb figure comes from
        // outside, the community rating yields, otherwise it stays. Deciding a second
        // time here would mean the downloads show different numbers than the page
        // from which the download was started.
        let scores = held.using(ratings: info.ratings).ratings

        let people =
            content.cast
            .filter { $0.task == .cast }
            .prefix(maxPeople)

        let description = DownloadDescription(
            id: job.id.rawValue,
            // **The title as the viewer read it when downloading.** It is already
            // in the download job, and it is more precise there than anything here: for an episode it
            // is the episode title, for a season "Season 2", for a film the film title.
            title: job.title.isEmpty ? held.tile.title : job.title,
            beside: job.beside ?? held.tile.beside,
            year: decomposed.year,
            // **The episode's synopsis takes precedence over the series'.** Whoever has downloaded a single
            // episode wants to read what it is about; the series description
            // is the same on each of its ten episodes and says nothing about any of them.
            description: episode?.description ?? held.description,
            series: series,
            seriesTitle: series == nil ? nil : held.tile.title,
            season: seasonNumber(job),
            episode: episode?.number ?? number(job),
            duration: episode?.duration ?? job.runtime ?? held.tile.duration,
            ratings: Dictionary(
                scores.map { (key($0.origin), $0.text) }, uniquingKeysWith: { first, _ in first }),
            // **The server's wording before the parsed attribute line** (thread G,
            // 2026-09-25) — the filter in the downloads asks this field, and from the line
            // "TV-MA" and "R" were lost as a genre (``HeroContent/approval``).
            ageRating: held.approval ?? decomposed.ageRating,
            // Without a digit the rating used to stand among the genres; there it now duplicates
            // the field above it.
            genres: decomposed.genres.filter { $0 != held.approval },
            poster: memorize(held.tile.image),
            backdrop: memorize(held.tile.backdrop),
            cast: people.enumerated().map { slot, person in
                DownloadDescription.Person(
                    id: person.id, name: person.name, role: person.characterName,
                    image: slot < maxFaces ? memorize(person.imageAddress) : nil)
            },
            ratingShares: Dictionary(
                scores.map { (key($0.origin), $0.portion) },
                uniquingKeysWith: { first, _ in first }),
            logo: memorize(held.logo),
            episodeImage: memorize(episode?.image),
            seriesClearanceChecked: series.map { held.tile.id == $0 })

        return Outcome(description: description, frames: frames)
    }

    /// How a season identifier is recognized.
    ///
    /// **A season has no identifier of its own on the server**, it is a selection from
    /// a series. ``DetailView`` therefore builds one (`<series>#season#2`), and the
    /// downloads must be able to read it back: sending it to the media server yields
    /// no match, and the failure would look like a network outage — the same finding
    /// as on 2026-09-05 with the provider titles, only one level deeper.
    ///
    /// **Built and read in one place.** Two places would be two formats as soon as
    /// one of them is touched.
    static let seasonMarker = "#staffel#"

    static func seasonID(series: String, season: Int) -> String {
        "\(series)\(seasonMarker)\(season)"
    }

    /// The series behind a season identifier — `nil` if it is not one.
    static func seriesID(from identifier: String) -> String? {
        guard let markerRange = identifier.range(of: seasonMarker) else { return nil }
        return String(identifier[identifier.startIndex..<markerRange.lowerBound])
    }

    /// The key under which a rating is stored in the ledger.
    ///
    /// **Fixed by agreement and not derived.** A `rawValue` of ``Rating/Origin``
    /// would be the same text — but it could then be changed by a rename in the source code,
    /// and an already stored ledger would go silent at the next start.
    static func key(_ origin: Rating.Origin) -> String {
        switch origin {
        case .community: "gemeinde"
        case .imdb: "imdb"
        case .mal: "mal"
        case .critics: "kritiker"
        case .metacritic: "metacritic"
        }
    }

    static func origin(_ key: String) -> Rating.Origin? {
        Rating.Origin.allCases.first { Self.key($0) == key }
    }

    private static func seasonNumber(_ job: DownloadJob) -> Int? {
        switch job.extent {
        case .episode(let season, _): season
        case .season(let number, _): number
        case .film, .unwatched: nil
        }
    }

    private static func number(_ job: DownloadJob) -> Int? {
        if case .episode(_, let number) = job.extent { return number }
        return nil
    }

    /// The attribute line, taken apart again.
    ///
    /// **Why it is taken apart at all:** ``DownloadDescription`` carries year,
    /// age rating and genres individually — so that the view sets the separators and does
    /// not have to split a composed string. ``HeroContent/attributes``
    /// had them individually once for the same reason and then made them into a list;
    /// this is the way back, and it is the only place where guessing happens.
    ///
    /// **The rules, in this order** (the list is built in
    /// ``TileArtwork/attributes(_:)``):
    ///
    /// * A four-digit number between 1880 and 2100 is the **year**. A genre is
    ///   never called that.
    /// * **After** the year comes the age rating, and only it contains a digit
    ///   ("FSK 12", "PG-13", "TV-MA" — and "12" alone). Genres are words.
    /// * Everything else is genres.
    ///
    /// **When in doubt nothing is claimed.** What cannot be recognized becomes a genre —
    /// there it stands behind a separator and reads correctly; a wrong
    /// age rating, by contrast, would be information nobody checks.
    struct Traits {
        var year: Int?
        var ageRating: String?
        var genres: [String] = []

        init(_ split: [String]) {
            var rest = split
            if let location = rest.firstIndex(where: { Self.isYear($0) }) {
                year = Int(rest[location])
                rest.removeFirst(location + 1)
            }
            if let first = rest.first, first.contains(where: \.isNumber) {
                ageRating = first
                rest.removeFirst()
            }
            genres = rest
        }

        static func isYear(_ text: String) -> Bool {
            guard text.count == 4, let year = Int(text) else { return false }
            return (1880...2100).contains(year)
        }

        /// The way there — **so that the downloads page shows the same line as the detail page.**
        static func row(year: Int?, ageRating: String?, genres: [String]) -> [String] {
            var split: [String] = []
            if let year { split.append(String(year)) }
            if let ageRating, !ageRating.isEmpty { split.append(ageRating) }
            return split + genres
        }
    }
}
