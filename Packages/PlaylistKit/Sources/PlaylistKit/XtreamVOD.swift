import Core
import Foundation

/// Evaluates the Xtream responses for movies and series.
///
/// This holds **only** the evaluation and the address construction. The network
/// fetch is done by the client; everything here is a pure function on an already
/// fetched response. The reason is the test rig: evaluation is the place
/// that breaks silently when a panel writes fields differently — and it must remain
/// testable without a server.
///
/// **Xtream responses are JSON only nominally.** The panels are grown
/// PHP applications, and the same detail comes, depending on panel and version, as a number
/// or as a string, empty, with `0` as "unknown" or not at all. That is why
/// everything here **reads leniently**: every field is fetched via
/// ``Field``, which understands both notations, and an entry that lacks
/// something essential is skipped instead of letting the whole list fail
/// — the same rule as in the ``M3UParser``.
///
/// The four responses that arrive here:
///
/// ```
/// get_vod_categories  [{category_id, category_name}]
/// get_vod_streams     [{stream_id, name, stream_icon, container_extension, rating, …}]
/// get_vod_info        {info: {plot, cast, director, genre, duration_secs, …}, movie_data: {…}}
/// get_series          [{series_id, name, cover, plot, genre, rating}]
/// get_series_info     {info: {name, …}, episodes: {"1": [{id, title, episode_num, info}]}}
/// ```
public enum XtreamVOD {

    // MARK: - Fehler

    /// What the evaluation may fail on.
    ///
    /// Deliberately only two cases, and both concern the **whole** response: a
    /// wrong password is answered by the panel with an object instead of a
    /// list, an overloaded one with an HTML page. Letting either pass as an "empty
    /// library" would be the worst message to the viewer — they would look for the fault
    /// on their own side. Individual unusable entries, by contrast, never throw; they are
    /// skipped.
    public enum Failure: Error, Equatable {
        /// The response was not JSON, usually an error page from the panel.
        case notJSON
        /// JSON, but not the expected shape — with wrong credentials
        /// the panels return an object with `user_info` instead of the list.
        case unexpectedShape
    }

    // MARK: - Kennungen

    /// Takes apart and builds the ID of an entry.
    ///
    /// **Why the playback address lives in the ID:** ``MediaItem`` carries
    /// no address — the source supplies it later via
    /// `ContentSource.streamURL(for:decision:)`, and solely from the
    /// ID. With Jellyfin the title's ID suffices for that. Xtream additionally needs
    /// the file extension, because the address is
    /// `…/movie/USER/PASS/1234.mkv`.
    ///
    /// Keeping the extension in the cache instead would be wrong: the app
    /// also starts a title from "Continue Watching", without having loaded the library
    /// beforehand. After a restart the cache would be
    /// empty and playback would fail. In the ID the detail
    /// is always present.
    ///
    /// Layout: `<list>#<kind>#<Xtream ID>[#<extension>]`
    public struct Reference: Sendable, Equatable {

        public enum Role: String, Sendable, Equatable {
            case movie
            case series
            case episode
        }

        public let playlistID: String
        public let role: Role
        /// The ID that the panel assigns — `stream_id`, `series_id` or
        /// the episode's ID.
        public let id: String
        /// Without a dot and in lower case, or `nil` if the panel named
        /// none.
        public let containerExtension: String?

        public init(
            playlistID: String,
            role: Role,
            id: String,
            containerExtension: String? = nil
        ) {
            self.playlistID = playlistID
            self.role = role
            self.id = id
            self.containerExtension = containerExtension.flatMap(XtreamVOD.normalized(extension:))
        }

        /// Reads back an ID that ``itemID`` produced.
        ///
        /// The **last** matching kind is searched for, not the first: the
        /// list ID comes first and may itself be called `movie` without
        /// shifting the split.
        public init?(itemID: String) {
            let parts = itemID.split(separator: "#", omittingEmptySubsequences: false)
            guard
                let roleIndex = parts.lastIndex(where: { Role(rawValue: String($0)) != nil }),
                let role = Role(rawValue: String(parts[roleIndex])),
                parts.count > roleIndex + 1
            else { return nil }

            let id = String(parts[roleIndex + 1])
            guard !id.isEmpty else { return nil }

            self.playlistID = parts[..<roleIndex].joined(separator: "#")
            self.role = role
            self.id = id
            self.containerExtension =
                parts.count > roleIndex + 2
                ? XtreamVOD.normalized(extension: String(parts[roleIndex + 2])) : nil
        }

        /// The ID under which the entry is kept in the app.
        public var itemID: String {
            let head = "\(playlistID)#\(role.rawValue)#\(id)"
            guard let containerExtension else { return head }
            return "\(head)#\(containerExtension)"
        }
    }

    // MARK: - Sparten

    /// A category of the panel — "Action", "New 2026" and so on.
    public struct Category: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Evaluates `get_vod_categories` or `get_series_categories`.
    public static func categories(from data: Data) throws(Failure) -> [Category] {
        try objects(in: data).compactMap { raw in
            guard let id = Field.text(raw["category_id"]),
                let name = Field.text(raw["category_name"])
            else { return nil }
            return Category(id: id, name: name)
        }
    }

    // MARK: - Filme

    /// Evaluates `get_vod_streams`.
    ///
    /// - Parameter playlistID: ID of the account. It is part of every
    ///   entry ID so that the same movie from two accounts does not count
    ///   as one — the same consideration as with channels.
    public static func movies(
        from data: Data, playlistID: String = ""
    ) throws(Failure)
        -> [MediaItem]
    {
        try objects(in: data).compactMap { movie(from: $0, playlistID: playlistID) }
    }

    static func movie(from raw: [String: Any], playlistID: String) -> MediaItem? {
        // Without an ID there is no address, without a name no entry that can be found
        // again in a list of ten thousand. Both are a reason to
        // skip, neither to abort.
        guard let streamID = Field.text(raw["stream_id"]),
            let title = Field.text(raw["name"])
        else { return nil }

        let reference = Reference(
            playlistID: playlistID,
            role: .movie,
            id: streamID,
            containerExtension: Field.text(raw["container_extension"])
        )

        // At the provider the title comes with prefix and year in one row:
        // `DE - The Nitzodut Rouflen (2019)`. Why it is split and how far
        // is explained at ``XtreamTitle``.
        let parsed = XtreamTitle.parse(title)

        return MediaItem(
            id: reference.itemID,
            kind: .movie,
            title: parsed.title,
            overview: Field.text(raw["plot"]) ?? Field.text(raw["description"]),
            // The provider's field beats the year from the title: it is the
            // maintained value. In the test catalog `get_vod_streams` carries none at all,
            // though, and then the bracket in the title is the only source for
            // 19045 of 27558 movies.
            year: year(in: raw) ?? parsed.year,
            genres: Field.list(raw["genre"]),
            runtime: duration(in: raw),
            // `added` is the time at which the panel added the movie. ``MediaItem``
            // has no field of its own for it, and for the
            // "recently added" sort it is the only usable
            // value — hence here.
            recordedAt: date(from: raw["added"]),
            ratings: ratings(in: raw, series: false),
            artwork: artwork(in: raw),
            source: mediaSource(containerExtension: reference.containerExtension)
        )
    }

    /// Evaluates `get_vod_info` — the details of a movie.
    ///
    /// Returns `nil` if the panel does not know the movie: it then answers
    /// not with an error but with `{"info":[],"movie_data":[]}` —
    /// empty **lists** where objects normally stand.
    public static func movieDetail(
        from data: Data, playlistID: String = ""
    ) throws(Failure)
        -> MediaItem?
    {
        let root = try object(in: data)
        let info = root["info"] as? [String: Any] ?? [:]
        let movieData = root["movie_data"] as? [String: Any] ?? [:]

        guard let streamID = Field.text(movieData["stream_id"]) else { return nil }

        let reference = Reference(
            playlistID: playlistID,
            role: .movie,
            id: streamID,
            containerExtension: Field.text(movieData["container_extension"])
        )

        let rawTitle = Field.text(movieData["name"]) ?? Field.text(info["name"]) ?? ""
        let parsed = XtreamTitle.parse(rawTitle)

        return MediaItem(
            id: reference.itemID,
            kind: .movie,
            title: parsed.title,
            overview: Field.text(info["plot"]) ?? Field.text(info["description"]),
            year: year(in: info) ?? year(in: movieData) ?? parsed.year,
            genres: Field.list(info["genre"]),
            runtime: duration(in: info),
            recordedAt: date(from: movieData["added"]),
            ratings: ratings(in: info, series: false),
            artwork: artwork(in: info),
            source: mediaSource(containerExtension: reference.containerExtension, info: info),
            cast: people(in: info)
        )
    }

    // MARK: - Serien

    /// Evaluates `get_series`.
    ///
    /// Series carry no `container_extension`: episodes are played, the
    /// series itself is only a folder. ``playbackURL(for:account:)`` therefore
    /// deliberately returns nothing for it.
    public static func series(
        from data: Data, playlistID: String = ""
    ) throws(Failure)
        -> [MediaItem]
    {
        try objects(in: data).compactMap { raw in
            guard let seriesID = Field.text(raw["series_id"]),
                let title = Field.text(raw["name"])
            else { return nil }

            let reference = Reference(playlistID: playlistID, role: .series, id: seriesID)

            // Besides the prefix, series carry the country of origin in a
            // second bracket: `DE - Driasuski Vajetlor (1985) (US)`. The 1194 titles with
            // this bracket would otherwise look in every row like a language hint
            // that is none.
            let parsed = XtreamTitle.parse(title)

            return MediaItem(
                id: reference.itemID,
                kind: .series,
                title: parsed.title,
                overview: Field.text(raw["plot"]),
                year: year(in: raw) ?? parsed.year,
                genres: Field.list(raw["genre"]),
                // `episode_run_time` is left out: it is the length of an
                // **episode**, and `runtime` on the series would read in the display
                // as a total length.
                recordedAt: date(from: raw["last_modified"]),
                ratings: ratings(in: raw, series: true),
                artwork: artwork(in: raw)
            )
        }
    }

    /// Evaluates `get_series_info` — the details of the **series itself**.
    ///
    /// **The same response also carries the episodes** (see
    /// ``episodes(from:seriesID:playlistID:)``); only the header is
    /// evaluated here. That is intentional: the detail page needs both, but at
    /// different times, and a shared return type of series
    /// and episode list would have had to be unpacked at every call site.
    ///
    /// - Parameter seriesID: The `series_id` that was queried — the
    ///   response does not name it. Without it the series could not be traced back to its
    ///   ID.
    ///
    /// Returns `nil` if the panel does not know the series: as with movies
    /// it then answers not with an error but with empty **lists**
    /// where objects normally stand.
    public static func seriesDetail(
        from data: Data, seriesID: String, playlistID: String = ""
    ) throws(Failure) -> MediaItem? {
        let root = try object(in: data)
        guard let info = root["info"] as? [String: Any], !info.isEmpty else { return nil }

        let reference = Reference(playlistID: playlistID, role: .series, id: seriesID)
        let parsed = XtreamTitle.parse(Field.text(info["name"]) ?? "")

        // **The runtime is left out.** `episode_run_time` is the length of an
        // episode; shown on the series it would read as a total length — the same
        // reason as in ``series(from:playlistID:)``.
        return MediaItem(
            id: reference.itemID,
            kind: .series,
            title: parsed.title,
            overview: Field.text(info["plot"]),
            year: year(in: info) ?? parsed.year,
            genres: Field.list(info["genre"]),
            recordedAt: date(from: info["last_modified"]),
            ratings: ratings(in: info, series: true),
            artwork: artwork(in: info),
            cast: people(in: info)
        )
    }

    /// Evaluates `get_series_info` and returns the episodes in broadcast order.
    ///
    /// - Parameter seriesID: The `series_id` that was queried. The
    ///   response itself does not name it, and without it the episodes could
    ///   not be traced back to their series.
    public static func episodes(
        from data: Data,
        seriesID: String,
        playlistID: String = ""
    ) throws(Failure) -> [MediaItem] {
        let root = try object(in: data)
        let seriesTitle = (root["info"] as? [String: Any])
            .flatMap { Field.text($0["name"]) }
            .map { XtreamTitle.parse($0).title }
        let seriesItemID = Reference(playlistID: playlistID, role: .series, id: seriesID).itemID

        // **Three shapes, and all three occur** (finding 2026-08-22: "Skiaspous"
        // returned 70 013 bytes, and the parser found not a single episode).
        //
        // Only the first was handled here, and the others fell through without a word:
        //
        // 1. `{"1": [...], "2": [...]}` — keyed by season.
        // 2. `[[...], [...]]` — a list **of seasons**; the season number
        //    is then the position in the list, starting at one.
        // 3. `[{...}, {...}]` — a flat list of episodes; the season is
        //    then in the episode itself.
        //
        // Which one a panel sends depends on its PHP version and not on
        // the series. That is why we do not ask for the shape but for
        // what is in it.
        let grouped = seasonGroups(in: root["episodes"])
        guard !grouped.isEmpty else { return [] }

        return grouped.flatMap { key, entries -> [MediaItem] in

            // Even within a season the panel's order must not be
            // assumed; some deliver sorted by ID.
            return
                entries
                .enumerated()
                .sorted { left, right in
                    let a = Field.integer(left.element["episode_num"]) ?? .max
                    let b = Field.integer(right.element["episode_num"]) ?? .max
                    return (a, left.offset) < (b, right.offset)
                }
                .compactMap { _, raw in
                    episode(
                        from: raw,
                        seasonKey: key,
                        seriesItemID: seriesItemID,
                        seriesTitle: seriesTitle,
                        playlistID: playlistID
                    )
                }
        }
    }

    /// Does the response carry an `episodes` field at all?
    ///
    /// **Separates the provider from the parser** (finding 2026-08-22): around a fifth
    /// of the series at iptvhost come back without this field — "A Seikoca plebra
    /// Naunzoukau" reports its four seasons including the episode count, but carries not a
    /// single episode, and there are no other ways to get there (`season_id`,
    /// `get_series_episodes`, `get_simple_data_table` return nothing). Without
    /// this distinction a gap at the provider looks in the log like
    /// a bug here — and then the search goes to the wrong place.
    public static func carriesEpisodeField(in data: Data) -> Bool {
        guard let root = try? object(in: data) else { return false }
        return root["episodes"] != nil
    }

    /// Brings the three shapes of `episodes` down to one: season key plus
    /// episodes, in ascending season order.
    ///
    /// Ordered by **number** and not by text: the keys are
    /// strings, and in their order season 10 would come before season 2.
    static func seasonGroups(in value: Any?) -> [(key: String, entries: [[String: Any]])] {
        func objects(_ any: Any?) -> [[String: Any]] {
            (any as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }

        // Shape 1: keyed by season.
        if let dictionary = value as? [String: Any] {
            return dictionary.keys
                .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
                .map { ($0, objects(dictionary[$0])) }
        }

        guard let list = value as? [Any] else { return [] }

        // Shape 3: a flat list of episodes. Recognisable by the entries
        // themselves being objects.
        //
        // **Here — and only here — the episode's `season` field counts**, because
        // there is no key. Everywhere else the key wins:
        // many panels write `"season":0` throughout in the entry, and
        // every episode would then land in a season 0 (see the check
        // `seasonKeyWins`). The split therefore happens **here**, so that
        // further down the key applies without exception.
        if list.contains(where: { $0 is [String: Any] }) {
            let entries = list.compactMap { $0 as? [String: Any] }
            var bySeason: [String: [[String: Any]]] = [:]
            for entry in entries {
                let key = Field.text(entry["season"]).flatMap { Int($0) }.map(String.init) ?? "1"
                bySeason[key, default: []].append(entry)
            }
            return bySeason.keys
                .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
                .map { ($0, bySeason[$0] ?? []) }
        }

        // Shape 2: a list of seasons. The position is the number, and it
        // starts at **one** — panels write season 1 at position 0, and
        // nobody has a "season 0".
        return list.enumerated().compactMap { index, entry in
            let entries = objects(entry)
            guard !entries.isEmpty else { return nil }
            return (String(index + 1), entries)
        }
    }

    static func episode(
        from raw: [String: Any],
        seasonKey: String,
        seriesItemID: String,
        seriesTitle: String?,
        playlistID: String
    ) -> MediaItem? {
        guard let episodeID = Field.text(raw["id"]) else { return nil }

        let info = raw["info"] as? [String: Any] ?? [:]
        let reference = Reference(
            playlistID: playlistID,
            role: .episode,
            id: episodeID,
            containerExtension: Field.text(raw["container_extension"])
                ?? Field.text(info["container_extension"])
        )

        // The provider's episode title carries the whole series with it:
        // `DE-JO - Die Frasleihi Frimaspar (2026) (DE) - S01E01 - Episode 1`.
        // Uncut, the same long preamble would stand in all twelve rows of a season,
        // and the difference — the episode number — would sit in the middle,
        // where nobody looks for it.
        let parsed = XtreamTitle.parse(Field.text(raw["title"]) ?? Field.text(info["name"]) ?? "")

        return MediaItem(
            id: reference.itemID,
            kind: .episode,
            // Unlike movies, an episode without a title is kept: it
            // is playable and unambiguously named by season and number.
            title: parsed.episodeDisplayTitle ?? parsed.title,
            // The series name from the response beats the one from the episode title: it
            // is the maintained one. The one from the title serves when `info` is missing.
            parentTitle: seriesTitle ?? parsed.title,
            seriesID: seriesItemID,
            // The key of the season object beats the `season` field in the
            // entry: many panels write 0 there throughout. Last the
            // marker from the title — with the test provider it is maintained
            // throughout and agrees with the key there.
            seasonNumber: Int(seasonKey) ?? Field.integer(raw["season"]) ?? parsed.seasonNumber,
            episodeNumber: Field.integer(raw["episode_num"]) ?? parsed.episodeNumber,
            overview: Field.text(info["plot"]) ?? Field.text(info["description"]),
            runtime: duration(in: info),
            recordedAt: date(from: info["releasedate"]) ?? date(from: raw["added"]),
            ratings: ratings(in: info),
            artwork: artwork(in: info),
            source: mediaSource(containerExtension: reference.containerExtension, info: info)
        )
    }

    // MARK: - Adressen

    /// The playback address for an entry ID.
    ///
    /// Returns nothing for series: episodes are played, the series itself is
    /// only a folder and has no address in the Xtream protocol.
    public static func playbackURL(for itemID: String, account: XtreamEndpoint) -> URL? {
        guard let reference = Reference(itemID: itemID) else { return nil }

        switch reference.role {
        case .movie:
            return movieURL(
                streamID: reference.id,
                containerExtension: reference.containerExtension,
                account: account
            )
        case .episode:
            return episodeURL(
                episodeID: reference.id,
                containerExtension: reference.containerExtension,
                account: account
            )
        case .series:
            return nil
        }
    }

    /// `http://server/movie/BENUTZER/KENNWORT/STREAM_ID.ENDUNG`
    public static func movieURL(
        streamID: String,
        containerExtension: String?,
        account: XtreamEndpoint
    ) -> URL? {
        url(
            segment: "movie",
            id: streamID,
            containerExtension: containerExtension,
            account: account
        )
    }

    /// `http://server/series/USER/PASSWORD/EPISODE_ID.EXTENSION`
    ///
    /// The section is called `series` although an **episode** is meant. That is
    /// not a mix-up but the protocol's spelling: under
    /// `/series/` lie the episodes, the series itself has no address.
    public static func episodeURL(
        episodeID: String,
        containerExtension: String?,
        account: XtreamEndpoint
    ) -> URL? {
        url(
            segment: "series",
            id: episodeID,
            containerExtension: containerExtension,
            account: account
        )
    }

    static func url(
        segment: String,
        id: String,
        containerExtension: String?,
        account: XtreamEndpoint
    ) -> URL? {
        guard !id.isEmpty, !account.username.isEmpty else { return nil }

        let ending = containerExtension.flatMap(normalized(extension:)) ?? fallbackExtension

        // User name and password are **path components**, not
        // query values. `appending(path:)` encodes in them whatever has meaning in a
        // path — a `#` or `?` in the password would otherwise cut the address
        // in half.
        return
            account.server
            .appending(path: segment)
            .appending(path: account.username)
            .appending(path: account.password)
            .appending(path: "\(id).\(ending)")
    }

    /// The extension if the panel names none.
    ///
    /// The panels look the title up by ID and treat the extension
    /// as an accessory — that is why almost every one carries it. Even so, the
    /// most common one is taken, and at the same time the only one that Apple's own player
    /// opens without a detour, in case the panel does evaluate it. `mkv` would be
    /// the worse choice: it would needlessly pull in the VLC engine. Omitting
    /// the extension would be the worst — many panels then answer with 404.
    static let fallbackExtension = "mp4"

    /// Without a leading dot, without whitespace, lower case — or `nil`.
    static func normalized(extension raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Containers and tracks

    /// What is known about the file — above all the **container**.
    ///
    /// **This is the most important detail of the whole evaluation.** 22900 of the 27558
    /// movies in the test catalog are MKV, 4242 MP4, 415 AVI, one M4V. Without
    /// ``MediaSource`` on ``MediaItem``, ``PlaybackEngineSelector`` assumes the
    /// container is unknown — and picks for 83 percent of the catalog an
    /// engine that does not open MKV. The result is a black picture without
    /// a message, for four of five movies.
    ///
    /// **`supportsDirectPlay` is `true`, always.** Unlike with
    /// Jellyfin, there is nobody here who could transcode: an Xtream provider
    /// delivers the file as it lies. A `false` here would mean to the selector
    /// "then transcode" — and the job would go to a server that does not
    /// accept it.
    ///
    /// - Parameter info: The `info` part from `get_vod_info` or from an episode.
    ///   For series episodes it contains ffprobe's details — codec, audio track,
    ///   bitrate. For `get_vod_streams` nothing is there; then it stays with the
    ///   container, and that suffices for choosing the engine.
    static func mediaSource(
        containerExtension: String?,
        info: [String: Any] = [:]
    ) -> MediaSource {
        // If the provider names no extension, the container stays unknown — and
        // unknown means VLC to the selector. That is the right direction of
        // doubt: VLC also opens MP4, the reverse is not true.
        let container = MediaSource.Container(rawValue: containerExtension ?? "")

        let video = info["video"] as? [String: Any] ?? [:]
        let audio = info["audio"] as? [String: Any] ?? [:]

        var audioTracks: [MediaTrack] = []
        if let codec = Field.text(audio["codec_name"]) {
            let tags = audio["tags"] as? [String: Any] ?? [:]
            audioTracks = [
                MediaTrack(
                    id: "audio#\(Field.integer(audio["index"]) ?? 0)",
                    kind: .audio,
                    title: Field.text(tags["title"]) ?? codec.uppercased(),
                    language: Field.text(tags["language"]),
                    codec: codec,
                    isDefault: true
                )
            ]
        }

        return MediaSource(
            container: container,
            videoCodec: Field.text(video["codec_name"]),
            audioTracks: audioTracks,
            supportsDirectPlay: true,
            bitrate: bitrate(in: info)
        )
    }

    /// The bitrate in **bits** per second.
    ///
    /// The provider reports kilobits: one episode in the test catalog carries
    /// `"bitrate": 8453` at 1920×1080 in H.264 — 8.45 Mbit/s. Anyone who takes the number
    /// over unchanged reports 8 kbit/s, and every bandwidth limit
    /// considers it effortlessly met.
    ///
    /// `0` means "not measured" and not zero bits: `get_vod_info` carries it that
    /// way throughout in the test catalog.
    static func bitrate(in info: [String: Any]) -> Int? {
        guard let kilobits = Field.integer(info["bitrate"]), kilobits > 0 else { return nil }
        return kilobits * 1000
    }

    // MARK: - Einzelne Angaben

    /// Ratings, where available.
    ///
    /// **Including TMDb and IMDb ID** (2026-09-29) — ``Core/Ratings/tmdbID`` has existed
    /// since then. The panels write it as `tmdb_id` (movie info) or `tmdb` (lists),
    /// `imdb_id` only sometimes. For an episode it is left out: the series' number does
    /// not help there.
    static func ratings(in raw: [String: Any], series: Bool? = nil) -> Ratings {
        var ratings = Ratings(community: community(in: raw))
        if let series {
            ratings.tmdbID = Ratings.tmdbIdentifier(
                text(raw["tmdb_id"]) ?? text(raw["tmdb"]), series: series)
        }
        if let imdb = text(raw["imdb_id"]), imdb.hasPrefix("tt") { ratings.imdbID = imdb }
        return ratings
    }

    /// A field as text — the panels deliver numbers sometimes as a number, sometimes as a string.
    private static func text(_ raw: Any?) -> String? {
        if let text = raw as? String, !text.isEmpty { return text }
        if let number = raw as? Int { return String(number) }
        if let number = raw as? Double, number == number.rounded() { return String(Int(number)) }
        return nil
    }

    static func community(in raw: [String: Any]) -> Double? {
        // `0` is the default value for "not rated" with these panels and
        // not a rating. Showing zero points would claim something the data
        // does not support.
        if let value = Field.number(raw["rating"]), value > 0, value <= 10 {
            return value
        }
        // Some panels carry only the five-point scale.
        if let value = Field.number(raw["rating_5based"]), value > 0, value <= 5 {
            return value * 2
        }
        return nil
    }

    /// Artwork.
    ///
    /// **The model does not fit here yet:** ``Artwork`` carries IDs, not
    /// addresses — with Jellyfin the address is assembled from the ID and the
    /// requested width. Xtream, by contrast, delivers finished, foreign
    /// addresses (`stream_icon`, `cover`) over which we have no influence.
    ///
    /// Until Core can represent that, the complete address stands in `posterID`. That
    /// works because the address arises only via
    /// `ContentSource.imageURL(itemID:kind:width:)` anyway — the Xtream source
    /// simply returns the string there instead of building one.
    ///
    /// **Proposal for Core:** turn the four ID fields into one
    /// `Artwork.Reference` each, with the cases `.managed(id: String)` and
    /// `.remote(URL)`. Then the type says what today only a comment
    /// says, and no source can confuse the two meanings.
    static func artwork(in raw: [String: Any]) -> Artwork {
        Artwork(
            posterID: address(
                in: raw,
                keys: ["stream_icon", "cover", "cover_big", "movie_image"]
            ),
            backdropID: address(in: raw, keys: ["backdrop_path"])
        )
    }

    /// The first usable address among the given keys.
    ///
    /// `backdrop_path` is a **list** of addresses, the others are
    /// single ones — both arrive here.
    static func address(in raw: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = raw[key] else { continue }
            let candidates: [Any] = (value as? [Any]) ?? [value]
            for candidate in candidates {
                guard let text = Field.text(candidate),
                    let url = URL(string: text),
                    let scheme = url.scheme?.lowercased(),
                    scheme == "http" || scheme == "https"
                else { continue }
                return text
            }
        }
        return nil
    }

    /// The running time in seconds.
    ///
    /// **The clock notation takes precedence, not `duration_secs`** — and that
    /// is decided against the field's name, for a measured reason. This is how
    /// it appears in the recording of `get_vod_info` for a 90-minute movie:
    ///
    /// ```
    /// "duration_secs": "90"
    /// "duration":      "01:30:00"
    /// "episode_run_time": 90
    /// ```
    ///
    /// `duration_secs` carries **minutes** there. Anyone who takes it at its word shows "1 min"
    /// and the progress bar is at its end after one second. `01:30:00`, by contrast,
    /// cannot be misunderstood. For the series episodes of the same provider
    /// both fields agree (`2707` to `00:45:07`), so the precedence rule costs
    /// nothing there.
    static func duration(in raw: [String: Any]) -> TimeInterval? {
        if let text = Field.text(raw["duration"]), let seconds = seconds(fromClock: text) {
            return seconds
        }
        // Fallback if no clock time is present. Then only the number remains — with the
        // caveat that with some providers it means minutes.
        if let seconds = Field.number(raw["duration_secs"]), seconds > 0 {
            return seconds
        }
        return nil
    }

    /// Reads `hh:mm:ss` and `mm:ss`.
    static func seconds(fromClock text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }

        let total = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return total > 0 ? TimeInterval(total) : nil
    }

    /// The release year from the fields the panels use for it.
    static func year(in raw: [String: Any]) -> Int? {
        for key in ["releasedate", "releaseDate", "release_date", "year"] {
            guard let text = Field.text(raw[key]) else { continue }
            // Leading four digits, because the notations range from "2014"
            // through "2014-11-05" to "2014-11-05" — the latter yields no year
            // and then stays empty.
            let digits = text.prefix(4)
            if digits.count == 4, let year = Int(digits), year > 1880, year < 2200 {
                return year
            }
        }
        return nil
    }

    /// A point in time from a Unix timestamp or a date `2014-11-05`.
    static func date(from raw: Any?) -> Date? {
        if let seconds = Field.number(raw), seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = Field.text(raw) else { return nil }

        // Deliberately a fixed calendar without the device's time zone: the date serves
        // sorting and year display, not the time of day.
        var components = DateComponents()
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components)
    }

    /// Cast and director from the text fields of the detail response.
    ///
    /// Xtream delivers only names as one line, no images and no roles.
    /// `hasImage` therefore stays false — the display itself decides whether it
    /// shows names without an image.
    static func people(in raw: [String: Any]) -> [Person] {
        let actors = Field.list(raw["cast"] ?? raw["actors"]).map {
            Person(id: "actor#\($0)", name: $0, role: .actor)
        }
        let directors = Field.list(raw["director"]).map {
            Person(id: "director#\($0)", name: $0, role: .director)
        }
        return directors + actors
    }

    // MARK: - Aufbau der Antwort

    /// The response as a list of objects.
    static func objects(in data: Data) throws(Failure) -> [[String: Any]] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.notJSON
        }
        guard let list = parsed as? [Any] else { throw Failure.unexpectedShape }
        // Individual entries that are not objects are skipped — they
        // occur in responses with stray fields at the end.
        return list.compactMap { $0 as? [String: Any] }
    }

    /// The response as a single object.
    static func object(in data: Data) throws(Failure) -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.notJSON
        }
        guard let object = parsed as? [String: Any] else { throw Failure.unexpectedShape }
        return object
    }

    // MARK: - Nachsichtig lesen

    /// Fetches individual fields without relying on their JSON type.
    ///
    /// The core of it all: the same detail comes, depending on the panel, as `7.5`, as
    /// `"7.5"`, as `""` or as `"N/A"`. An evaluation with `Codable` would need its
    /// own decoder for each of these fields and would break
    /// at the first panel that adds yet another notation — here it stays
    /// in one place.
    enum Field {

        /// Text, even if the field is a number. Empty and `"null"` count
        /// as absent.
        static func text(_ raw: Any?) -> String? {
            switch raw {
            case let value as String:
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
            case let value as Int:
                // Checked before `Double`, so that the ID 1234 does not
                // become "1234.0" and the address point into nothing.
                return String(value)
            case let value as Double:
                return value == value.rounded() ? String(Int(value)) : String(value)
            default:
                return nil
            }
        }

        /// A number, even if it arrives as text.
        static func number(_ raw: Any?) -> Double? {
            switch raw {
            case let value as Double:
                return value.isFinite ? value : nil
            case let value as String:
                // Manche Panels schreiben deutsche Dezimalkommas.
                let cleaned = value.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: ".")
                guard let number = Double(cleaned), number.isFinite else { return nil }
                return number
            default:
                return nil
            }
        }

        static func integer(_ raw: Any?) -> Int? {
            guard let number = number(raw), number >= -1e9, number <= 1e9 else { return nil }
            return Int(number)
        }

        /// An enumeration like `"Action, Adventure"` as a list.
        static func list(_ raw: Any?) -> [String] {
            // Already delivered as a list — that occurs too.
            if let values = raw as? [Any] {
                return values.compactMap { text($0) }
            }
            guard let value = text(raw) else { return [] }
            return
                value
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
}
