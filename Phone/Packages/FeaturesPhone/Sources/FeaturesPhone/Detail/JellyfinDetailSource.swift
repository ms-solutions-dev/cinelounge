import Core
import DesignSystemPhone
import Flows
import Foundation
import JellyfinKit

/// The detail page on the media server.
///
/// **Everything fetched side by side.** A series needs four answers (title, seasons,
/// episodes, similar) and a film three; one after the other that would be four times the wait
/// for a page that you look at as a whole. What depends on each other still
/// runs in sequence: the season names come from a different answer than the
/// episodes and are merged only afterwards.
public struct JellyfinDetailSource: DetailSource {

    private let source: any ContentSource
    private let width: Int
    private let headerWidth: Int
    private let logoWidth: Int

    public init(source: any ContentSource, width: Int, headerWidth: Int, logoWidth: Int) {
        self.source = source
        self.width = width
        self.headerWidth = headerWidth
        self.logoWidth = logoWidth
    }

    /// This many similar titles are fetched.
    ///
    /// Twelve and not twenty: the row scrolls horizontally, and what lies behind the twelfth
    /// poster nobody sees anyway. Each of them costs an image.
    static let maxSimilar = DetailRules.maxSimilar

    public func detailInfo(zu identifier: String) async throws -> DetailContent {
        var title = try await source.item(id: identifier)
        // A portal title gets the registered providers' details added — Jellyfin and
        // IPTV never ask, see ``ExtrasSupplement``.
        let extras = await ExtrasSupplement.extras(zu: title, source: source)
        if let extras { title = ExtrasSupplement.completed(title, um: extras) }
        let held = TileArtwork.held(
            title, source: source, width: headerWidth, logoWidth: logoWidth)

        let fetchesSimilar = DetailRules.fetchesSimilar(title.kind)
        async let similar = tiles(
            fetchesSimilar
                ? (try? await source.similarItems(to: identifier, limit: Self.maxSimilar)) ?? []
                : [])
        async let lookahead = (try? await source.trailer(for: identifier)) ?? nil

        let cast =
            extras.map(ExtrasSupplement.cast(from:)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.cast(from: title, source: source)
        let details = Self.details(zu: title)

        if title.kind == .series {
            async let children = (try? await source.children(of: identifier)) ?? []
            async let episodes = (try? await source.episodes(of: identifier)) ?? []
            return DetailContent(
                title: held,
                isSeries: true,
                seasons: Self.grouped(
                    await episodes, seasons: await children, source: source, width: width),
                next: Self.next(from: await episodes).map {
                    TileArtwork.tile($0, source: source, width: width)
                },
                sources: Self.sources(from: title),
                audioTracks: Self.audioTracks(from: title),
                cast: cast,
                similar: await similar,
                details: details,
                trailerFile: Self.trailerFile(await lookahead),
                watchDuration: WatchEstimate.forSeries(title))
        }

        // A collection carries its parts as children — and **no** play target of its own.
        // The main button is therefore omitted there; it is a container, not a film.
        let split: [TileContent] =
            title.kind == .collection
            ? tiles((try? await source.children(of: identifier)) ?? []) : []

        return DetailContent(
            title: held,
            seasons: [],
            next: title.kind == .collection
                ? nil : TileArtwork.tile(title, source: source, width: width),
            sources: Self.sources(from: title),
            audioTracks: Self.audioTracks(from: title),
            cast: cast,
            chapters: Self.chapters(
                zu: title, source: source,
                // **Asked only for a film.** A series has no chapters, and the
                // request costs an answer that nobody looks at.
                raster: (try? await source.trickplay(for: identifier)) ?? nil),
            similar: await similar,
            split: split,
            details: details,
            trailerFile: Self.trailerFile(await lookahead))
    }

    /// The own file with the language of its first audio track — `nil` without a file.
    static func trailerFile(_ trailer: MediaItem?) -> TrailerFile? {
        trailer.map { TrailerFile(language: $0.source?.audioTracks.first?.language) }
    }

    public func set(seen: Bool, forItem identifier: String) async throws {
        try await source.setPlayed(seen, for: identifier)
    }

    public func set(favorite: Bool, forItem identifier: String) async throws {
        try await source.setFavorite(favorite, for: identifier)
    }

    public func removeFromContinueWatching(_ identifier: String) async throws {
        try await source.removeFromContinueWatching(identifier)
    }

    /// The tile does not know its kind; the source reads it from the identifier.
    public func seriesReference(zu tile: TileContent) async -> String? {
        await source.seriesReference(zu: MediaItem(id: tile.id, kind: .movie, title: tile.title))
    }

    /// The address of the trailer — **fetched only on press.**
    ///
    /// Two requests (the trailer title and its address) and a registered
    /// playback session at the server: doing that for every title when the page opens
    /// would mean letting the server start an encode on every scroll that
    /// nobody looks at.
    ///
    /// **Via HLS and with a capped bitrate**, although the file might perhaps be
    /// directly playable. A trailer here runs at 393 points width in a header image;
    /// four megabits suffice for that, and what lies above it is wait time on the way
    /// that nobody looks at anymore. The right decision is made by AP14 for the
    /// player — here it would be an imitation with the same numbers in a second
    /// place.
    public func previewURL(zu identifier: String) async throws -> URL? {
        guard let trailer = try await source.trailer(for: identifier) else { return nil }
        return try await source.streamURL(
            for: trailer.id,
            decision: PlaybackDecision(
                engine: .native, delivery: .hls, reason: .nativeContainer,
                maxBitrate: 4_000_000, maxWidth: 1280))
    }

    private func tiles(_ title: [MediaItem]) -> [TileContent] {
        title.map { TileArtwork.tile($0, source: source, width: width) }
    }

    /// The episodes by season, **in the server's order within a
    /// season.**
    ///
    /// Sorted by season number, because the server may deliver them mixed; within a season
    /// not re-sorted, because there its order is the right one — it knows
    /// double episodes and special episodes, sorting by number would scramble them.
    ///
    /// **Name and story arc come from the season response, not from the episodes.**
    /// An episode knows which season it is in, but not what the season
    /// is about. If the entry is missing — say because the server is currently not delivering
    /// the seasons — the bundling is still complete; it is then called "Season 3"
    /// instead of by name.
    ///
    /// **And an episode is not a season** (2026-09-09). `children(of:)` does not return
    /// seasons for every source: the provider catalog does not structure, its
    /// `get_series_info` carries the **episodes** under `episodes`, keyed by season number.
    /// Unfiltered, the first episode of each season would then land in
    /// `byNumber` — and the season picker would be called "Neiscand - S01E01 - Folge 1" instead of
    /// "Season 1", with its plot as the season description. Therefore only
    /// what identifies itself as a season is taken; where none comes, the case that
    /// the paragraph above carries anyway applies.
    static func grouped(
        _ episodes: [MediaItem], seasons: [MediaItem], source: any ContentSource, width: Int
    )
        -> [Season]
    {
        let byNumber = Dictionary(
            seasons.compactMap { season -> (Int, MediaItem)? in
                guard season.kind == .season, let number = season.seasonNumber else {
                    return nil
                }
                return (number, season)
            }, uniquingKeysWith: { first, _ in first })

        let grouped = Dictionary(grouping: episodes) { $0.seasonNumber ?? 0 }
        return grouped.keys.sorted().map { number in
            let season = byNumber[number]
            return Season(
                id: number,
                name: season?.title.nilIfEmpty,
                description: season?.overview?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                episodes: (grouped[number] ?? []).map { episode in
                    EpisodeInfo(
                        id: episode.id,
                        number: episode.episodeNumber,
                        title: episode.title,
                        // Empty text is the same as no text — otherwise a row would stand there
                        // with a gap where there is nothing at all.
                        description: episode.overview?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).nilIfEmpty,
                        // **The still frame of the episode, not the background image.**
                        // Seen on screen: all 35 episodes showed the same image.
                        // An episode carries its own `Primary` at Jellyfin — that is
                        // its still frame —, but **no backdrops of its own**; it inherits those
                        // from its parent. Whoever asks for the background image therefore
                        // gets the same series image back for every episode, and the
                        // list looks as if it were broken.
                        image: PosterAddress.url(for: episode, from: source, width: width),
                        duration: episode.runtime,
                        progress: TileArtwork.progress(episode),
                        seen: episode.progress?.isWatched ?? false,
                        favorite: episode.isFavorite)
                })
        }
    }

    /// What the main button does: **the next open episode, not the first.**
    ///
    /// Whoever is at episode 22 wants episode 23 — not to start over. The started one
    /// takes precedence over the first unwatched: finishing a half-watched episode
    /// is the nearer step.
    ///
    /// **Since AP58 R6 by the rules in ``Core/ContinueWatching``, the same as on the
    /// TV.** Started means ``Core/PlaybackProgress/isResumable`` (here there was
    /// a threshold of its own from 1 % to 99 %). Without a started one the season decides
    /// (``Core/ContinueWatching/startSeason(in:pending:)``) and within it the episode — **if everything
    /// is watched, the first episode of the last season** and no longer the first of the series.
    /// The phone knows all episodes, the TV only the count per season; a
    /// started title in a later season therefore still wins here over
    /// unwatched ones before it. The specials (group 0) do not count as a season
    /// (check 2026-09-27, D3).
    static func next(from episodes: [MediaItem]) -> MediaItem? {
        if let started = episodes.first(where: { $0.progress?.isResumable == true }) {
            return started
        }
        var numbers: [Int] = []
        for episode in episodes where !numbers.contains(episode.seasonNumber ?? 0) {
            numbers.append(episode.seasonNumber ?? 0)
        }
        let season = ContinueWatching.startSeason(in: numbers.sorted(), number: { $0 }) { number in
            episodes.filter { ($0.seasonNumber ?? 0) == number && $0.progress?.isWatched != true }
                .count
        }
        return ContinueWatching.nextEpisode(
            from: episodes.filter { ($0.seasonNumber ?? 0) == season })
    }

    /// The cast — **actors and director, not everyone.**
    ///
    /// Production and music rarely matter in the living room; on the TV
    /// `Person.Role.isProminent` decides that, and the same rule applies here. Writer is
    /// added because it is named in the fact list anyway and a face for it costs no
    /// additional request.
    static func cast(from title: MediaItem, source: any ContentSource) -> [PersonDetail] {
        title.cast.compactMap { person in
            let task: PersonDetail.Role =
                switch person.role {
                case .actor: .cast
                case .director: .directors
                case .writer: .ledger
                default: .other
                }
            guard task != .other else { return nil }
            return PersonDetail(
                id: person.id,
                name: person.name,
                characterName: person.character?.nilIfEmpty,
                task: task,
                // **Ask only where the server carries an image.** `hasImage` is the
                // information that saves a 404 request per face — exactly the finding
                // of 2026-08-22 that produced one per tile on the Home screen.
                image: person.hasImage
                    ? source.imageURL(
                        itemID: person.id, kind: .primary,
                        width: ImageSizes.pixels(forItem: MetricsBoard.phone.person, reference: 3),
                        tag: nil)
                    : nil)
        }
    }

    /// The chapter marks — **only with a name or image, and never a single one.**
    ///
    /// Two cases drop out here, and both would look like an error. Many servers
    /// write "Chapter 3" as the name: that is the number in another language, and
    /// it is discarded so that the card shows its own count. And a file with
    /// **one** mark at 0:00 has no chapters — it has a beginning.
    static func chapters(
        zu title: MediaItem, source: any ContentSource, raster: Trickplay? = nil
    ) -> [ChapterDetail] {
        let marks = title.chapters ?? []
        guard marks.count > 1 else { return [] }
        let jellyfin = source as? JellyfinSource
        return marks.enumerated().map { location, tag in
            let name = tag.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let own = name.flatMap { $0.lowercased().hasPrefix("chapter") ? nil : $0.nilIfEmpty }
            return ChapterDetail(
                id: location,
                name: own,
                start: tag.start,
                image: jellyfin?.chapterImageURL(
                    itemID: title.id, index: location, tag: tag.imageTag,
                    width: ImageSizes.pixels(forItem: MetricsBoard.phone.episode.width, reference: 3)),
                lookahead: raster.map { Self.slice(from: $0, at: tag.start) })
        }
    }

    /// The cell in the trickplay grid that belongs to this timestamp.
    ///
    /// This is computed in `Core.Trickplay` — expressly there and not here: confusing
    /// sheet number and frame number leads to images from the wrong spot and
    /// is noticed late, because the first sheets happen to be right. A second computation
    /// of the same kind is a second opportunity for that.
    static func slice(from raster: Trickplay, at time: TimeInterval) -> ArcExcerpt {
        let number = raster.thumbnailIndex(at: time)
        let cell = raster.cell(forThumbnail: number)
        return ArcExcerpt(
            sheet: raster.sheetURL(at: time),
            columns: raster.tileColumns, rows: raster.tileRows,
            column: cell.column, row: cell.row)
    }

    /// The fact list — what has no room above.
    ///
    /// **It does not repeat the attribute line.** There, year, rating and two
    /// genres stand in one line, because they count at first glance. Down here stands what
    /// was too long for that: director, writer, studio, the runtime and **all** genres.
    static func details(zu title: MediaItem) -> [Detail] {
        let directors = title.directors ?? title.cast.filter { $0.role == .director }.map(\.name)
        let ledger = title.cast.filter { $0.role == .writer }.map(\.name)
        return [
            Detail.when("fact.director", directors.prefix(3).joined(separator: ", ")),
            Detail.when("fact.writer", ledger.prefix(3).joined(separator: ", ")),
            Detail.when("fact.studio", title.studio),
            Detail.when("fact.genres", title.genres.joined(separator: ", ")),
            Detail.when("fact.year", title.year.map(String.init)),
            Detail.when("fact.rated", title.ageRating),
            Detail.when("fact.runtime", runtime(title.runtime)),
        ].compactMap { $0 }
    }

    /// "2 h 22 min" — via the formatter and not by hand.
    ///
    /// Built by hand, the string would follow the device language instead of the configured
    /// language of the app, and the page would be half translated. The TV program
    /// has made the same mistake once before.
    static func runtime(_ duration: TimeInterval?) -> String? {
        guard let duration, duration > 0 else { return nil }
        return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes]))
    }

    /// The versions of a title with their bitrates.
    static func sources(from title: MediaItem) -> [SourceInfo] {
        guard let source = title.source else { return [] }
        return [
            SourceInfo(
                id: title.id,
                name: Self.name(forItem: source),
                bitrate: source.bitrate,
                isDirectlyPlayable: source.supportsDirectPlay)
        ]
    }

    /// The audio tracks of the file.
    ///
    /// **The server's name takes precedence over the language.** It often writes "German DTS-HD MA
    /// 5.1" into the title, and that is more precise than anything that could be
    /// built from the language code. Only where it carries nothing does the language take its place — and where
    /// that is missing too, the number: a row without a label would be a choice without
    /// information.
    static func audioTracks(from title: MediaItem) -> [AudioTrackInfo] {
        guard let source = title.source else { return [] }
        return source.audioTracks.enumerated().map { location, track in
            let name =
                track.title.nilIfEmpty ?? track.language?.nilIfEmpty
                ?? AppLanguageSetting.text("sources.track \(location + 1)")
            let attributes = [track.codec?.uppercased()].compactMap { $0 }
            return AudioTrackInfo(
                id: track.id,
                name: name,
                attributes: attributes.isEmpty ? nil : attributes.joined(separator: DelimiterChars.point),
                isDefault: track.isDefault, language: track.language)
        }
    }

    /// "H.264 · HDR · MKV" — what distinguishes the title.
    ///
    /// **Without resolution, and that is no oversight:** `Core.MediaSource` carries container,
    /// encoding, color range, bitrate, interlacing and bit depth — **no frame size**.
    /// That sits on the tracks, not on the source. An invented "1080p" would be a
    /// claim about something nobody knows here; the **bitrate** answers the question
    /// you really ask yourself on the go more precisely anyway.
    static func name(forItem source: MediaSource) -> String {
        var split: [String] = []
        if let codec = source.videoCodec, !codec.isEmpty {
            split.append(codec.uppercased())
        }
        if source.videoRange != .sdr { split.append(source.videoRange.rawValue.uppercased()) }
        split.append(source.container.rawValue.uppercased())
        return split.joined(separator: DelimiterChars.point)
    }
}

extension String {
    /// Empty text is no text.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
