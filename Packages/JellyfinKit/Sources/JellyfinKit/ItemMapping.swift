import Core
import Foundation
import JellyfinAPI

/// Translates the server's responses into the models from ``Core``.
///
/// This layer is the reason the UI later knows nothing about Jellyfin. It is also
/// the place that breaks silently when the server renames fields — which is why it is
/// secured against real server responses and not against made-up examples.
public enum ItemMapping {

    /// The server counts times in hundred-nanosecond ticks. Ten million of them
    /// make one second.
    static let ticksPerSecond: Double = 10_000_000

    public static func seconds(fromTicks ticks: Int?) -> TimeInterval? {
        guard let ticks, ticks > 0 else { return nil }
        return Double(ticks) / ticksPerSecond
    }

    // MARK: - Titel

    public static func mediaItem(from dto: BaseItemDto) -> MediaItem? {
        guard let id = dto.id, !(dto.type.map(foreignTitleKinds.contains) ?? false) else {
            return nil
        }

        var item = MediaItem(
            id: id,
            kind: kind(from: dto.type),
            title: dto.name ?? "",
            // The server's sort title, with its rules for articles.
            // Needed since the lists are ordered client-side — the
            // order must stay the same as it was from the server before.
            sortTitle: dto.sortName,
            parentTitle: dto.seriesName,
            seriesID: dto.seriesID,
            seasonNumber: dto.parentIndexNumber,
            episodeNumber: dto.indexNumber,
            overview: dto.overview,
            year: dto.productionYear,
            genres: dto.genres ?? [],
            studio: dto.studios?.first?.name,
            ageRating: dto.officialRating,
            runtime: seconds(fromTicks: dto.runTimeTicks),
            // Chapter marks only come with the single-item query — lists do not
            // carry them, and `nil` would also be right there: no knowledge, no mark.
            chapters: dto.chapters.map { list in
                list.compactMap { entry in
                    Chapter(
                        title: entry.name,
                        start: seconds(fromTicks: entry.startPositionTicks) ?? 0,
                        imageTag: entry.imageTag
                    )
                }
            },
            // The recording date first, the creation date as fallback — the
            // reasoning is at the field itself.
            recordedAt: dto.premiereDate ?? dto.dateCreated,
            // For "Recently Added", since ordering is done client-side.
            addedAt: dto.dateCreated,
            seasonCount: dto.childCount,
            episodeCount: dto.recursiveItemCount,
            unplayedCount: dto.userData?.unplayedItemCount,
            ratings: ratings(from: dto),
            artwork: artwork(from: dto),
            progress: progress(from: dto),
            isFavorite: dto.userData?.isFavorite ?? false,
            source: dto.mediaSources?.first.flatMap(mediaSource(from:)),
            cast: people(from: dto),
            directors: directors(from: dto)
        )
        // For "Continue Watching" by time, across all sources (2026-09-28).
        item.lastWatched = dto.userData?.lastPlayedDate
        return item
    }

    static func kind(from type: BaseItemKind?) -> MediaItem.Kind {
        switch type {
        case .series: .series
        case .season: .season
        case .episode: .episode
        case .movie: .movie
        case .tvChannel, .liveTvChannel: .channel
        // The server simply reports home videos as "Video" — the assignment
        // to the library decides how they are displayed.
        case .video: .homeVideo
        // The server keeps collections as BoxSet — the film series as an entry.
        case .boxSet: .collection
        default: .movie
        }
    }

    static func ratings(from dto: BaseItemDto) -> Ratings {
        Ratings(
            community: dto.communityRating.map(Double.init),
            critic: dto.criticRating.map { Int($0.rounded()) },
            imdbID: dto.providerIDs?["Imdb"] ?? nil,
            anilistID: dto.providerIDs?["AniList"] ?? nil,
            // **With TMDb identifier** (AP78, 2026-10-11): Until here only IMDb, AniList and
            // TVDB came along, and the detail view searched TMDb by title and year — for
            // remakes a grab at the wrong one. Only film and series: An episode's number
            // leads at TMDb to a path of its own, which the app does not take.
            tmdbID: (dto.type == .movie || dto.type == .series)
                ? Ratings.tmdbIdentifier(dto.providerIDs?["Tmdb"] ?? nil, series: dto.type == .series)
                : nil,
            tvdbID: dto.providerIDs?["Tvdb"] ?? nil
        )
    }

    static func artwork(from dto: BaseItemDto) -> Artwork {
        // The server delivers images not as addresses but as identifiers.
        // The address only arises at fetch time — including the desired width,
        // so that a full-size image is not loaded for every tile.
        // **The images' identifiers are carried along, not just their presence.**
        // Here stood `dto.imageTags?["Primary"] != nil ? dto.id : nil` — the tag was
        // read and thrown away. But it is exactly what the server needs
        // to mark an image as durably cacheable; see
        // ``JellyfinSource/imageURL(itemID:kind:width:tag:)``.
        //
        // Only the item's own tag is taken: If the image falls back to the series'
        // (`parentBackdropItemID`), it comes with a different tag that this item
        // does not know. Then it stays empty, and the address is as before — correct,
        // just without the additional gain.
        Artwork(
            posterID: dto.imageTags?["Primary"] != nil ? dto.id : nil,
            // Episodes carry no backdrop of their own — then the series' one applies,
            // which the server supplies as the parent identifier.
            backdropID: (dto.backdropImageTags?.isEmpty == false)
                ? dto.id : dto.parentBackdropItemID,
            logoID: dto.imageTags?["Logo"] != nil ? dto.id : dto.parentLogoItemID,
            thumbID: dto.imageTags?["Thumb"] != nil ? dto.id : nil,
            posterTag: dto.imageTags?["Primary"],
            backdropTag: dto.backdropImageTags?.first,
            logoTag: dto.imageTags?["Logo"],
            thumbTag: dto.imageTags?["Thumb"],
            isWide: wideImage(dto),
            // **The series poster comes along and is no longer thrown away**
            // (finding of 2026-09-09). On an episode `posterID` is the episode's identifier,
            // and behind it lies the episode screenshot in 16 : 9 format — in the
            // poster frame of the "Continue Watching" shelf a black area with a
            // small image in it. `SeriesId` and `SeriesPrimaryImageTag` are in the
            // same response (test record `resume.json`); the access costs no
            // additional query.
            //
            // **Both together or not at all.** Without the tag the address would be correct,
            // but not cacheable (see above); without the identifier there would be none. Whoever
            // reads the value therefore only checks the identifier — see ``Core/Artwork/seriesPosterID``.
            seriesPosterID: dto.seriesPrimaryImageTag != nil ? dto.seriesID : nil,
            seriesPosterTag: dto.seriesPrimaryImageTag
        )
    }

    /// Whether this item's image is wide — **measured and not guessed.**
    ///
    /// **The rule stood at ``Core/Artwork/isWide`` since 2026-08-27 and applied only to
    /// portals:** "The same rule already carries the home videos (image from the film, so
    /// wide)." It did not — the media server reported no format on any item
    /// until 2026-09-08, and `isWide` stayed `nil` everywhere. It was reported
    /// by the product owner on the phone: home videos are normally landscape here too, but
    /// posters are displayed in portrait.
    ///
    /// **Measured on our own server (2026-09-08), `PrimaryImageAspectRatio`:**
    ///
    /// | Library      | Items    | Aspect ratio            |
    /// |--------------|---------:|-------------------------|
    /// | Home videos  |       22 | 21 × 1.222 · 1 × 1.778  |
    /// | Films        |      102 | 0.667                   |
    /// | Series       |       22 | 0.666 to 0.750          |
    /// | Collections  |       15 | 0.667 to 0.701          |
    /// | Episodes     |        — | 1.333 and 1.778         |
    ///
    /// The limit at 1 is thus not a stipulation but a gap: Between 0.75 and
    /// 1.222 there is not a single item.
    ///
    /// **Without a poster it is always wide**, and that is no assumption about the server,
    /// but one about our own code: ``Core/PosterAddress`` then falls back to the
    /// preview or the backdrop image, and both are 16 : 9. The format
    /// describes the image that is shown — not the one that is missing.
    ///
    /// **`nil` stays where the server says nothing.** A series with no value and no
    /// images is not "tall", it is unchecked; the layer rule
    /// (``Core/MediaItem/prefersWideArtwork(in:)``) distinguishes this explicitly.
    static func wideImage(_ dto: BaseItemDto) -> Bool? {
        if dto.imageTags?["Primary"] != nil {
            guard let ratio = dto.primaryImageAspectRatio else { return nil }
            return ratio > 1
        }
        let fallback =
            dto.imageTags?["Thumb"] != nil || dto.backdropImageTags?.isEmpty == false
            || dto.parentBackdropItemID != nil
        return fallback ? true : nil
    }

    /// The cast, filtered and in a sensible order.
    ///
    /// Only contributors with an image and in a leading role: A strip of gray
    /// placeholders for production assistants helps nobody. The server's order
    /// is kept — the lead roles come first there.
    static func people(from dto: BaseItemDto) -> [Person] {
        (dto.people ?? [])
            .compactMap { dto -> Person? in
                guard let id = dto.id, let name = dto.name else { return nil }
                let role = Person.Role(rawValue: dto.type?.rawValue ?? "")
                guard role.isProminent else { return nil }

                return Person(
                    id: id,
                    name: name,
                    role: role,
                    character: dto.role,
                    hasImage: dto.primaryImageTag != nil
                )
            }
            .filter(\.hasImage)
            .prefix(12)
            .map { $0 }
    }

    /// The director, as bare names.
    ///
    /// Separate from ``people(from:)``, because its image filter would be wrong here:
    /// directors rarely have an image stored and would drop out of the detail page's
    /// info line without comment. `nil` instead of empty if the server sends no
    /// contributors at all — list responses do not carry the field,
    /// and "not asked" is different information from "no director".
    static func directors(from dto: BaseItemDto) -> [String]? {
        guard let people = dto.people else { return nil }
        return
            people
            .filter { Person.Role(rawValue: $0.type?.rawValue ?? "") == .director }
            .compactMap(\.name)
    }

    static func progress(from dto: BaseItemDto) -> PlaybackProgress? {
        guard let userData = dto.userData,
            let duration = seconds(fromTicks: dto.runTimeTicks)
        else { return nil }

        let position = seconds(fromTicks: userData.playbackPositionTicks) ?? 0
        let seen = userData.isPlayed ?? false
        return PlaybackProgress(
            position: position,
            duration: duration,
            isWatched: seen,
            // Jellyfin decides itself what is resumable (see ``Core/PlaybackProgress/runsOnServer``).
            runsOnServer: position > 0 && !seen
        )
    }

    // MARK: - Technische Beschaffenheit

    public static func mediaSource(from info: MediaSourceInfo) -> MediaSource {
        let streams = info.mediaStreams ?? []

        return MediaSource(
            container: MediaSource.Container(rawValue: info.container ?? ""),
            videoCodec: streams.first { $0.type == .video }?.codec,
            videoRange: videoRange(from: streams.first { $0.type == .video }),
            audioTracks: streams.filter { $0.type == .audio }.map(track(from:)),
            subtitleTracks: streams.filter { $0.type == .subtitle }.map(track(from:)),
            supportsDirectPlay: info.isSupportsDirectPlay ?? false,
            bitrate: info.bitrate,
            // The server knows it from the file; without this line the
            // value would stay empty, and the engine choice could not
            // see interlacing (roadmap P11).
            isInterlaced: streams.first { $0.type == .video }?.isInterlaced,
            // The same kind of information for the bit depth: H.264 at ten bits
            // (Hi10P) is not decoded by any Apple hardware, and only the server
            // knows the depth before the file is open.
            videoBitDepth: streams.first { $0.type == .video }?.bitDepth
        )
    }

    static func track(from stream: MediaStream) -> MediaTrack {
        MediaTrack(
            // The index is the identifier by which the track can later be
            // requested from the server.
            id: String(stream.index ?? -1),
            kind: stream.type == .audio ? .audio : .subtitle,
            title: stream.displayTitle ?? stream.title ?? "",
            language: stream.language,
            codec: stream.codec,
            subtitleFormat: stream.type == .subtitle
                ? MediaSource.SubtitleFormat(rawValue: stream.codec ?? "") : nil,
            isDefault: stream.isDefault ?? false,
            // Without these three lines the most important property of a
            // subtitle track never arrives in the app at all: The server knows
            // `IsForced` from the file; the app so far saw only "German"
            // and "German" (finding 2026-08-28).
            isForced: stream.isForced ?? false,
            isExternal: stream.isExternal ?? false,
            isHearingImpaired: stream.isHearingImpaired ?? false
        )
    }

    static func videoRange(from stream: MediaStream?) -> MediaSource.VideoRange {
        // The server reports the range as text, for example "SDR", "HDR10" or
        // "DOVI". Dolby Vision is the case that later determines the engine.
        let raw = (stream?.videoRangeType?.rawValue ?? stream?.videoRange?.rawValue ?? "").uppercased()

        if raw.contains("DOVI") || raw.contains("DOLBY") { return .dolbyVision }
        if raw.contains("HDR10") { return .hdr10 }
        if raw.contains("HLG") { return .hlg }
        return .sdr
    }

    // MARK: - Spulvorschau

    /// Preferred edge length of a single preview image in pixels.
    ///
    /// Explicitly **not** the largest available. A sheet of a hundred
    /// images at 320 pixels each is 3200 pixels wide and weighed 1.4 MB on the
    /// test server; at 640 it would be four times that — for a preview that
    /// appears a few hundred pixels wide while scrubbing. When scrubbing through, each
    /// sheet is loaded individually, and a sheet that only arrives when the thumb
    /// has already moved on is as good as none.
    static let preferredTrickplayWidth = 320

    /// Reads the scrub-preview information from a title response.
    ///
    /// The server delivers it only with `Fields=Trickplay` and nests it
    /// **twice**: outside by media source identifier, inside by image width
    /// as text. Example from a real response:
    ///
    /// ```
    /// "Trickplay": { "4f7a…e75f": { "320": {
    ///     "Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
    ///     "ThumbnailCount": 154, "Interval": 10000, "Bandwidth": 11539 } } }
    /// ```
    ///
    /// `TileWidth` and `TileHeight` count **preview images per row and
    /// column**, not pixels — the name suggests the opposite. Whoever reads them
    /// as edge length calculates with a grid of 320 × 180 cells and
    /// never gets to see an image.
    ///
    /// - Parameters:
    ///   - serverURL: Needed for the sheet address, because the server only
    ///     reports numbers and no addresses.
    ///   - accessToken: Must go into the address, not into a header. The sheets
    ///     are fetched by the image loader, which sends no sign-in — and
    ///     unlike with posters, the server answers here with 401 instead of handing
    ///     out the image. Verified on the server.
    public static func trickplay(
        from dto: BaseItemDto,
        serverURL: URL,
        accessToken: String
    ) -> Trickplay? {
        guard let itemID = dto.id, let sources = dto.trickplay, !sources.isEmpty else { return nil }

        // For several versions of a film — theatrical cut and director's cut —
        // there are several entries on the outside. The title's own version is
        // taken, because ``JellyfinSource/streamURL(for:decision:)`` requests no other.
        // The fallback goes through the sorted identifiers and not
        // through `.first`: A dictionary has no order, and preview images
        // that come from a different version at every start are a bug
        // that nobody gets to the bottom of.
        let byWidth = sources[itemID] ?? sources.sorted { $0.key < $1.key }.first?.value
        guard let byWidth else { return nil }

        let variants =
            byWidth
            .compactMap { key, info -> (width: Int, info: TrickplayInfoDto)? in
                // The width appears twice: as key and in the entry. The
                // entry takes precedence, the key is the fallback.
                guard let width = info.width ?? Int(key), width > 0 else { return nil }
                return (width, info)
            }
            .sorted { $0.width < $1.width }

        // The largest width that does not exceed the preferred one. If the
        // server only generates larger ones, then the smallest of those — a preview that is too large
        // is better than none.
        guard
            let chosen = variants.last(where: { $0.width <= preferredTrickplayWidth })
                ?? variants.first
        else { return nil }

        let info = chosen.info
        guard let height = info.height, height > 0,
            let interval = info.interval, interval > 0,
            let count = info.thumbnailCount, count > 0
        else { return nil }

        var components = URLComponents(
            url: serverURL.appending(path: "Videos/\(itemID)/Trickplay/\(chosen.width)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "api_key", value: accessToken)]
        guard let sheetBase = components?.url else { return nil }

        return Trickplay(
            width: chosen.width,
            height: height,
            tileColumns: info.tileWidth ?? 1,
            tileRows: info.tileHeight ?? 1,
            // The server reports the interval in milliseconds. The conversion
            // happens here and only here — ``Trickplay`` calculates exclusively
            // in seconds, and a factor of 1000 in the wrong place shows the first
            // preview image throughout while scrubbing.
            interval: Double(interval) / 1000,
            thumbnailCount: count,
            sheetBase: sheetBase
        )
    }

    // MARK: - Abschnitte

    public static func segment(from dto: MediaSegmentDto) -> MediaSegment? {
        guard let id = dto.id,
            let start = seconds(fromTicks: dto.startTicks) ?? (dto.startTicks == 0 ? 0 : nil),
            let end = seconds(fromTicks: dto.endTicks)
        else { return nil }

        return MediaSegment(
            id: id,
            kind: MediaSegment.Kind(rawValue: dto.type?.rawValue ?? ""),
            start: start,
            end: end
        )
    }

    // MARK: - Bibliotheken

    /// **Libraries this app does not show at all** (on-device test build 1332): music,
    /// music videos and books (Jellyfin keeps audiobooks as `books`).
    ///
    /// **Here and not in every view:** Every library list of both apps comes through
    /// ``library(from:)`` — shelves, "Recently Added", header area, library tabs.
    /// A music library got the empty type filter there, and an empty filter means
    /// "everything" at the server.
    static let foreignCollections: Set<String> = ["music", "musicvideos", "books", "audiobooks"]

    /// **Item types this app never shows** — the same limit for single items. It applies
    /// where no library filter reaches: "Continue Watching" (a started
    /// audiobook), mixed folders, children of an item. Without it such items
    /// became films for lack of a type of their own (``kind(from:)``).
    static let foreignTitleKinds: Set<BaseItemKind> = [
        .audio, .audioBook, .book, .musicAlbum, .musicArtist, .musicGenre, .musicVideo,
    ]

    public static func library(from dto: BaseItemDto) -> Library? {
        guard let id = dto.id,
            !foreignCollections.contains(dto.collectionType?.rawValue.lowercased() ?? "")
        else { return nil }

        return Library(
            id: id,
            name: dto.name ?? "",
            kind: libraryKind(from: dto.collectionType?.rawValue)
        )
    }

    static func libraryKind(from raw: String?) -> Library.Kind {
        switch raw?.lowercased() {
        case "movies": .movies
        case "tvshows": .series
        case "homevideos": .homeVideos
        case "music": .music
        case "livetv": .liveTV
        default: .mixed
        }
    }
}
