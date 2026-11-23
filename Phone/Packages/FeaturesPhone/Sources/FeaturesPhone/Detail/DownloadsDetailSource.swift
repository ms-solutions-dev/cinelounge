import Diagnose
import Downloads
import Foundation
import ParentalControls

/// The detail page from what lies next to the file — **the only one that stands without a network.**
///
/// **The requirement of 2026-09-09:** even when only one episode is
/// downloaded, navigation inside Downloads should work like this: poster →
/// detail view with the downloaded episodes … all of it should be stored with OMDb, TMDb etc.
/// ratings and so on, roughly like Jellyfin content. A screenshot of the Jellyfin detail page
/// goes with it: header image, logo, "2007 · FSK-12 · Comedy", the
/// rating badges, the description with "more", below it "Season 1" with the
/// episode list. That is the yardstick, and all of it comes here from the
/// ``DescriptionLedger``.
///
/// ## When it answers — and why not always
///
/// **It answers to its own identifier** (``identifier(forItem:)``), that is, exactly when
/// the page was opened **from the downloads**. That is not frugality
/// but the core: a series' downloads page is a **different page** from the library's.
/// Whoever has downloaded three of twenty-four episodes of "Bloufeit" wants to see **three** in
/// Downloads — and **twenty-four** in the library. Both answers
/// are right, and neither may displace the other. A precedence "what lies here is
/// answered from here" would have cut twenty-one episodes from the library as soon as
/// someone downloads a single one.
///
/// **And it catches what the responsible source cannot answer.** Without a network
/// the source throws; then the stored state is the only information there is. Showing an
/// error screen for a title that sits on the disk would be the
/// repetition of exactly the finding this is built against. Both are plugged into
/// ``AggregateDetailSource``.
public struct DownloadsDetailSource: DetailSource {

    /// **In two pieces, so that `scripts/strings.py` does not take it for a catalog key**
    /// — the same caution as at ``DownloadLedger/stem``.
    public static let prefix = "vorrat" + ":"

    /// The identifier under which the downloads screen opens a page.
    ///
    /// - Parameter key: the **series identifier** for a series, otherwise the identifier
    ///   of the download job. Both are ``DownloadDescription/series`` or
    ///   ``DownloadDescription/id`` respectively; which of the two is meant is decided during
    ///   lookup and the caller does not need to know.
    public static func identifier(forItem key: String) -> String { prefix + key }

    /// Reads back what ``identifier(forItem:)`` generated — **the same make as
    /// `PortalItemID` and `XtreamVOD.Reference`.**
    ///
    /// The ``AggregateDetailSource`` decides by the identifier and not by trial and error;
    /// for that every source must recognize its own.
    public static func key(from identifier: String) -> String? {
        identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : nil
    }

    /// The usual location — **computed once and then held.**
    ///
    /// ``Store/folder()`` creates the directory and sets the "not in the
    /// backup" mark; that is cheap, but it is a system call, and
    /// ``SourceAssembly/detailContentSource(width:headerWidth:logoWidth:rule:)`` is called from within a
    /// view body. A `static let` runs exactly once.
    ///
    /// **The downloads are the only source that needs nothing set up** — no
    /// account, no address, no key. Making them depend on a setup like the others
    /// would mean the downloads stop working exactly when
    /// an access credential has expired.
    static let standardFolder: URL? = try? Store.folder()

    /// The downloads at the usual location, **with the profile's rule** (check 2026-09-27, D1).
    ///
    /// Until then there was a source without a rule here as the default of the
    /// ``AggregateDetailSource``. It answered every identifier for which something was stored —
    /// including that of an age-16 film a parent had downloaded, when a child
    /// opened it through a remembered identifier. Without a rule it no longer exists.
    public static func standard(rule: ProtectionRule) -> DownloadsDetailSource? {
        DownloadsDetailSource(folder: standardFolder, rule: rule)
    }

    private let ledger: DescriptionLedger
    private let folder: URL

    /// The profile's rule — **every answer goes through it** (check 2026-09-27, D1).
    ///
    /// The downloads list filters over the same question (``DownloadsModel``), the player too
    /// (``CompositePlayerSource``). The detail page was the third door and the only one without a
    /// filter: through the fallback of the ``AggregateDetailSource`` a blocked title opened together with the
    /// play button. **Mandatory in the creator and without a default**, so that no new call site
    /// builds without a rule.
    private let rule: ProtectionRule

    public init(folder: URL, rule: ProtectionRule) {
        self.folder = folder
        self.ledger = DescriptionLedger(folder: folder)
        self.rule = rule
    }

    /// **`nil` if there is no downloads folder.** Then nothing is in it either, and a
    /// source that answers every question with "nothing stored" would be a detour with a
    /// name.
    public init?(folder: URL?, rule: ProtectionRule) {
        guard let folder else { return nil }
        self.init(folder: folder, rule: rule)
    }

    /// Whether anything is stored for this identifier — **for the fallback path.**
    public func knows(_ identifier: String) -> Bool {
        let key = Self.key(from: identifier) ?? identifier
        return ledger.read().contains { $0.id == key || $0.series == key }
    }

    /// The page for an identifier — **only from what the rule lets open.**
    ///
    /// **Fail-closed** (check 2026-09-27, D1): a film that the rule does not open throws
    /// ``ParentalControls/ChildProtectionError/locked``. For a series, blocked
    /// episodes drop out; if none remains, it throws likewise. The question is asked per description via
    /// ``ParentalControls/ProtectionRule/opens(downloads:)`` — origin, title rule and the
    /// series rating of a download, the same questions as in list and player.
    public func detailInfo(zu identifier: String) async throws -> DetailContent {
        let key = Self.key(from: identifier) ?? identifier
        let queued = ledger.read()
        let visible = queued.filter { rule.opens(downloads: $0) }

        let group = visible.filter { $0.series == key }
        if !group.isEmpty { return series(key, from: group) }

        guard let single = visible.first(where: { $0.id == key }) else {
            if queued.contains(where: { $0.id == key || $0.series == key }) {
                Diagnose.step(.downloads, "Downloads: \(key) blocked by parental controls")
                throw ChildProtectionError.locked
            }
            Diagnose.step(.downloads, "Downloads: no description for \(key)")
            throw Missing.description
        }
        // An episode whose series was not passed along (see ``DownloadDescription/series``)
        // stands alone — then it is its own page and not a series with one episode.
        if let seriesID = single.series {
            return series(seriesID, from: visible.filter { $0.series == seriesID })
        }
        return film(single)
    }

    // MARK: - Descriptions become a page

    private func film(_ b: DownloadDescription) -> DetailContent {
        let tile = tile(b, id: b.id, title: b.title)
        return DetailContent(
            title: held(b, tile: tile, description: b.description),
            isSeries: false,
            next: tile,
            cast: cast(b))
    }

    /// A series with **the downloaded episodes** as a season list.
    ///
    /// **The header comes from the first description and not from a row of its own.**
    /// Series title, poster, background and ratings are on **every** episode — that is
    /// the decision from ``DownloadDescription`` ("one description per download job"),
    /// and it pays off here: there is no case in which the series row is missing
    /// while episodes are present.
    ///
    /// **The most recently stored one is taken.** Whoever downloads more gets to see the fresher
    /// ratings this way, without anything having to be updated.
    private func series(_ identifier: String, from group: [DownloadDescription]) -> DetailContent {
        let sortedEntries = group.sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        }
        let header = group.max { $0.storedAt < $1.storedAt } ?? sortedEntries[0]

        let seasons = Dictionary(grouping: sortedEntries) { $0.season ?? 0 }
            .map { number, episodes in
                Season(id: number, episodes: episodes.map(episodeInfo))
            }
            .sorted { $0.id < $1.id }

        let tile = tile(header, id: identifier, title: header.seriesTitle ?? header.title)
        return DetailContent(
            title: held(header, tile: tile, description: header.seriesDescription),
            isSeries: true,
            seasons: seasons,
            // **The main button plays the first downloaded episode.** "The next step" here
            // is not the next one of the series but the next one that is **possible without a
            // network** — anything else would be a button that leads nowhere on a plane.
            next: seasons.first?.episodes.first.map { episode in
                TileContent(
                    id: episode.id, title: episode.title, beside: header.seriesTitle,
                    image: episode.image, duration: episode.duration, series: identifier)
            },
            cast: cast(header))
    }

    private func episodeInfo(_ b: DownloadDescription) -> EpisodeInfo {
        EpisodeInfo(
            id: b.id, number: b.episode, title: b.title, description: b.description,
            image: address(b.episodeImage), duration: b.duration)
    }

    private func tile(_ b: DownloadDescription, id: String, title: String) -> TileContent {
        TileContent(
            id: id, title: title, beside: b.beside, image: address(b.poster),
            backdrop: address(b.backdrop), duration: b.duration,
            rating: Rating.best(from: ratings(b)),
            series: b.series)
    }

    /// The head of the page.
    ///
    /// **Without ``RatingID``, and that is intentional.** It is the key with which
    /// ``DetailModel`` **asks** OMDb and AniList — on a plane that costs one
    /// failed attempt, and with a network the fresh answer would overwrite exactly the numbers
    /// stored here. What stands here is the state from the time of downloading; it appears immediately
    /// and needs nobody.
    private func held(
        _ b: DownloadDescription, tile: TileContent, description: String?
    ) -> HeroContent {
        HeroContent(
            tile: tile, logo: address(b.logo),
            description: description ?? b.description,
            attributes: DownloadDescriber.Traits.row(
                year: b.year, ageRating: b.ageRating, genres: b.genres),
            ratings: ratings(b), identifier: RatingID(),
            approval: b.ageRating)
    }

    /// The stored ratings, turned back into ``Rating``.
    ///
    /// **Text and share belong together; if one is missing, the rating is missing.** A bar without a
    /// number and a number without a bar are both half information — and the share could only be
    /// guessed from "88 %" (see ``DownloadDescription/ratingShares``).
    private func ratings(_ b: DownloadDescription) -> [Rating] {
        b.ratings.compactMap { key, text in
            guard let origin = DownloadDescriber.origin(key),
                let portion = b.ratingShares[key]
            else { return nil }
            return Rating(origin: origin, portion: portion, text: text)
        }
    }

    private func cast(_ b: DownloadDescription) -> [PersonDetail] {
        b.cast.map {
            PersonDetail(
                id: $0.id, name: $0.name, characterName: $0.role, task: .cast,
                image: address($0.image))
        }
    }

    /// A file name becomes an address — **`file://` and not `https://`.**
    ///
    /// The rest of the app loads images through ``DesignSystemPhone/ImageLoader``, and that takes
    /// a `URL`. A file address is one; so the same tile shows the same image
    /// whether it comes from the server or from the disk — without a second path through the
    /// views.
    private func address(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        return folder.appendingPathComponent(name)
    }

    /// **Its own error and not an empty content.** "Nothing stored" is something different
    /// from "a title without details" — the ``AggregateDetailSource`` distinguishes by it whether
    /// it may pass on.
    enum Missing: Error { case description }
}
