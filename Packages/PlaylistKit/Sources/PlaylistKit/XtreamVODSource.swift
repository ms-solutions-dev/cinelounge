import Core
import Foundation

/// The library of an Xtream provider as a ``ContentSource``.
///
/// **This is the second source the contract was built for** (roadmap
/// P8): the same library view that shows the Jellyfin library —
/// grid, jump markers, detail column — thereby shows the provider's movies,
/// without a line of display code of its own.
///
/// Three peculiarities compared with the media server:
///
/// 1. **Categories are libraries.** The provider groups into categories
///    ("Action", "New 2026"); each is kept as its own ``Library``, with
///    the list and category ID in the library ID.
/// 2. **Watched, favourites and progress live with us.** An Xtream panel
///    knows no user state — what the viewer has watched, the app remembers
///    locally (``VODMemory``).
/// 3. **Images are foreign addresses.** The provider delivers finished addresses;
///    by agreement they sit in `posterID`, and ``imageURL`` passes them
///    through instead of building (see the note at `XtreamVOD.artwork`).
public actor XtreamVODSource: ContentSource {

    public nonisolated let displayName = "IPTV"

    /// A panel delivers files, not a stream from a requested position — seeking and
    /// resuming are handled by the player via partial requests.
    public nonisolated var canStartAtOffset: Bool { false }

    private let store: PlaylistStore
    private let indexStore: SeriesEpisodeIndexStore
    /// One client per list — built once and kept, including credentials.
    private var clients: [String: XtreamClient] = [:]

    /// The most recently fetched response to `get_series_info`.
    ///
    /// **One fetch, two readers** (user finding 2026-08-22: "episodes are generally not
    /// shown", sometimes yes, sometimes no). The detail page first asks
    /// ``item(id:)`` for the series and right afterwards ``children(of:)`` for the
    /// episodes — both are answered by **the same** response from the panel. Without this
    /// slot that would be two fetches in quick succession to a panel that allows
    /// **one** connection; the second was rejected, `children` threw,
    /// and the page stood there without episodes — depending on the panel's mood, sometimes
    /// one way, sometimes the other. The `URLCache` did not help: panels answer without permission
    /// to cache.
    ///
    /// Only the **last** series, not all: the page asks twice in a row
    /// for the same one, and this slot does not need to do more.
    private var lastSeriesInfo: (id: String, data: Data)?

    /// The beginning of a response, for diagnostics — **without credentials.**
    ///
    /// The panels' responses carry user name and password in addresses;
    /// the beginning suffices to recognise the **shape** (`{"seasons":[]` versus
    /// `{"episodes":{`), and they do not appear further forward.
    static func head(of data: Data, limit: Int = 160) -> String {
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    /// Fetches `get_series_info` — and hands the same bytes to the second reader
    /// instead of asking again.
    private func seriesInfo(playlistID: String, seriesID: String) async throws -> Data {
        if let lastSeriesInfo, lastSeriesInfo.id == seriesID { return lastSeriesInfo.data }

        let client = try await client(for: playlistID)
        let data = try await client.fetchData(
            action: "get_series_info",
            extra: ["series_id": seriesID]
        )
        lastSeriesInfo = (seriesID, data)
        return data
    }

    public init(
        store: PlaylistStore,
        indexStore: SeriesEpisodeIndexStore = .shared
    ) {
        self.store = store
        self.indexStore = indexStore
    }

    // MARK: - Klienten

    private func client(for playlistID: String) async throws -> XtreamClient {
        if let existing = clients[playlistID] { return existing }

        guard let playlist = await store.playlist(withID: playlistID),
            case .xtream(let server, let username) = playlist.kind,
            let password = await store.password(for: playlistID)
        else { throw XtreamClient.Failure.unauthorized }

        let client = XtreamClient(
            playlist: playlist,
            credentials: XtreamEndpoint(server: server, username: username, password: password)
        )
        clients[playlistID] = client
        return client
    }

    private func endpoint(for playlistID: String) async throws -> XtreamEndpoint {
        guard let playlist = await store.playlist(withID: playlistID),
            case .xtream(let server, let username) = playlist.kind,
            let password = await store.password(for: playlistID)
        else { throw XtreamClient.Failure.unauthorized }
        return XtreamEndpoint(server: server, username: username, password: password)
    }

    /// The state of the episode index, without waiting for it.
    ///
    /// Returns `nil` as long as there is none — so on the very first open,
    /// and permanently with every provider whose `get.php` is blocked. Then
    /// the library behaves as before.
    private func episodeIndex(for playlistID: String) async -> SeriesEpisodeIndex? {
        guard let endpoint = try? await endpoint(for: playlistID) else { return nil }
        return await indexStore.index(for: playlistID, endpoint: endpoint)
    }

    // MARK: - Bibliotheken

    /// Layout of the library ID: `<list>|vod|<category>` for movies,
    /// `<list>|series|<category>` for series.
    ///
    /// The vertical bar instead of the hash is deliberate: the hash already structures
    /// the entry IDs (``XtreamVOD/Reference``), and two
    /// separators with the same meaning in two places could no longer be told apart when reading
    /// an ID.
    ///
    /// **The kind belongs in the ID and not beside it** (2026-08-22): Xtream
    /// keeps separate categories for movies and series with **its own
    /// number range** — "427" is a different category for series than for movies.
    /// Without the kind in the ID, `xyz|vod|427` could not reveal
    /// which fetch it means, and the library would show, by chance,
    /// one or the other.
    static func libraryID(
        playlistID: String, categoryID: String, kind: Library.Kind = .movies
    )
        -> String
    {
        "\(playlistID)|\(kind == .series ? "series" : "vod")|\(categoryID)"
    }

    /// **Public because the UI needs it:** the sidebar derives from the categories
    /// which lists carry movies or series at all —
    /// and the list is in the ID. A second source for that could deviate from
    /// this one, and then a provider without a category would appear there.
    public static func parseLibraryID(
        _ id: String
    )
        -> (playlistID: String, categoryID: String, kind: Library.Kind)?
    {
        for (marker, kind) in [("|series|", Library.Kind.series), ("|vod|", .movies)] {
            let parts = id.components(separatedBy: marker)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            return (parts[0], parts[1], kind)
        }
        return nil
    }

    /// All categories of the enabled lists — **movies and series**.
    ///
    /// Series were missing here until 2026-08-22, and that was the whole reason why
    /// the UI showed none: the parsers ``XtreamVOD/series(from:playlistID:)``
    /// and ``XtreamVOD/episodes(from:seriesID:playlistID:)`` were ready, checks
    /// included — only the test suite called them.
    ///
    /// **Composed from ``libraries(for:)``** — the loop over the lists is
    /// all that still happens here.
    public func libraries() async throws -> [Library] {
        var result: [Library] = []

        for playlist in await store.enabledPlaylists {
            guard case .xtream = playlist.kind else { continue }
            result.append(contentsOf: await libraries(for: playlist.id))
        }

        return result
    }

    /// The categories of **one** account — movies and series.
    ///
    /// **The finding from 2026-09-07:** anyone who meant only one account still asked all of them via
    /// ``libraries()``. On the phone the provider cache remembers the
    /// result **per list**; with two accounts set up, the fetch for
    /// list 1 got four responses and stored them under "list 1", the fetch for list 2
    /// found nothing there and fetched the same four again. Eight requests instead of
    /// four — against an account with **one** allowed connection, which answers
    /// HTTP 512 from the second simultaneous one on.
    ///
    /// **If one of the two queries fails, the other still counts.** Not
    /// every panel carries both; whoever discards everything here as soon as one fetch
    /// fails also loses what is there. That is why this query does not throw
    /// but returns what it has — in the worst case nothing.
    /// A caller that gets nothing must **not** remember that as a result.
    ///
    /// **A failure appears in the report** (phone, 2026-09-29: movies and series empty, full
    /// on the iPad). Until then every error here became "no categories" — whether the password
    /// was missing, the provider throttled or the response could not be read, nobody saw.
    public func libraries(for playlistID: String) async -> [Library] {
        let client: XtreamClient
        do {
            client = try await self.client(for: playlistID)
        } catch {
            Diagnostics.defect(
                "IPTV catalog: no access to the list — \(Diagnostics.explain(error))", since: nil,
                area: "IPTV")
            return []
        }

        func fetchCategories(
            _ kind: String, _ fetch: () async throws -> [XtreamVOD.Category]
        ) async -> [XtreamVOD.Category] {
            do {
                return try await fetch()
            } catch {
                Diagnostics.defect(
                    "IPTV catalog: \(kind) not loaded — \(Diagnostics.explain(error))", since: nil,
                    area: "IPTV")
                return []
            }
        }
        let movies = await fetchCategories("movie categories") { try await client.vodCategories() }
        let allSeries = await fetchCategories("series categories") { try await client.seriesCategories() }
        if movies.isEmpty || allSeries.isEmpty {
            Diagnostics.defect(
                "IPTV catalog: \(movies.count) movie, \(allSeries.count) series categories", since: nil,
                area: "IPTV")
        }

        var result: [Library] = []
        for (kind, categories) in [
            (Library.Kind.movies, Optional(movies)),
            (Library.Kind.series, Optional(allSeries)),
        ] {
            for category in categories ?? [] {
                result.append(
                    Library(
                        id: Self.libraryID(
                            playlistID: playlistID, categoryID: category.id, kind: kind),
                        name: category.name,
                        kind: kind
                    )
                )
            }
        }
        return result
    }

    // MARK: - Titel

    public func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
        guard let (playlistID, categoryID, kind) = Self.parseLibraryID(library) else { return [] }

        let client = try await client(for: playlistID)
        let isSeries = kind == .series
        let data = try await client.fetchData(
            action: isSeries ? "get_series" : "get_vod_streams",
            extra: ["category_id": categoryID]
        )
        var items =
            isSeries
            ? try XtreamVOD.series(from: data, playlistID: playlistID)
            : try XtreamVOD.movies(from: data, playlistID: playlistID)

        if let term = filter.searchTerm, !term.isEmpty {
            items = items.filter { $0.title.localizedCaseInsensitiveContains(term) }
        }

        // **Which series have episodes at all** — with the provider examined,
        // 19.3 % have none. The state comes from disk and waits for nothing;
        // if it is missing, every title stays untouched. Rationale in the index
        // itself (``SeriesEpisodeIndex``).
        if isSeries, let index = await episodeIndex(for: playlistID) {
            items = index.marking(items)
        }

        return Self.sorted(items, by: filter)
    }

    /// The source does the sorting itself — the panel has none.
    ///
    /// **The direction is a matter of contract, and the contract is the media server's**
    /// (2026-09-13): `ascending: false` means, for date and rating, **newest and
    /// best first** — Jellyfin turns it into `SortOrder: Descending`, and ``LibraryModel``
    /// sends exactly that as the natural direction of these two orders. Here it was
    /// the wrong way round: the list was built descending and reversed **once more**
    /// for `ascending == false` — under "New" stood the oldest, under "Rating" the
    /// worst, and the label did not show it.
    /// `XtreamSortDirectionTests` pins the contract down.
    ///
    /// **Unknowns go at the end, in both directions.** A title without a date is
    /// neither young nor old, one without a rating neither good nor bad; pulling it to the front
    /// when reversing would be a statement nobody made.
    static func sorted(_ items: [MediaItem], by filter: ItemFilter) -> [MediaItem] {
        switch filter.sortBy {
        case .title:
            let ordered = items.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return filter.ascending ? ordered : ordered.reversed()
        case .dateAdded, .dateCreated:
            // `recordedAt` carries the panel field `added`.
            return Self.ordered(items, by: \.recordedAt, ascending: filter.ascending)
        case .rating:
            return Self.ordered(items, by: \.ratings.community, ascending: filter.ascending)
        case .natural:
            // As the panel delivers. The case belongs to the portals; it is listed here
            // so that a new value does not silently end up as "by title".
            return items
        }
    }

    /// By a key that may be missing — **the known ones in the requested
    /// direction, the unknown ones after them.**
    static func ordered<Value: Comparable>(
        _ items: [MediaItem], by keyPath: KeyPath<MediaItem, Value?>, ascending: Bool
    ) -> [MediaItem] {
        let known = items.filter { $0[keyPath: keyPath] != nil }
            .sorted { $0[keyPath: keyPath]! < $1[keyPath: keyPath]! }
        let unknown = items.filter { $0[keyPath: keyPath] == nil }
        return (ascending ? known : known.reversed()) + unknown
    }

    /// Searches the movies of ALL accounts for the term.
    ///
    /// **For the global search** (user request 2026-08-16): a category carries
    /// thousands of titles, and clicking through is not a search. The full list of an
    /// account comes in one piece (`get_vod_streams` without a category) and is
    /// kept for the lifetime of the source — from the second letter on
    /// it is only filtered, no longer loaded.
    public func search(term: String, limit: Int = 60) async throws -> [MediaItem] {
        var hits: [MediaItem] = []
        for playlist in await store.enabledPlaylists {
            guard case .xtream = playlist.kind else { continue }
            let all = try await allMovies(of: playlist.id)
            hits.append(
                contentsOf: all.filter { $0.title.localizedCaseInsensitiveContains(term) })
            if hits.count >= limit { break }
        }
        return Array(hits.prefix(limit))
    }

    /// Warms up the search cache — when the search opens instead of at the first
    /// letter (on-device finding 2026-08-16: the first search waited for the provider's
    /// full list).
    public func prewarmSearch() async throws {
        for playlist in await store.enabledPlaylists {
            guard case .xtream = playlist.kind else { continue }
            _ = try await allMovies(of: playlist.id)
        }
    }

    /// The full movie list of an account — fetched once, then from the cache.
    private func allMovies(of playlistID: String) async throws -> [MediaItem] {
        if let cached = movieIndex[playlistID] { return cached }
        let client = try await client(for: playlistID)
        let data = try await client.fetchData(action: "get_vod_streams")
        let movies = try XtreamVOD.movies(from: data, playlistID: playlistID)
        movieIndex[playlistID] = movies
        return movies
    }

    /// Siehe ``allMovies(of:)``.
    private var movieIndex: [String: [MediaItem]] = [:]

    /// The whole series catalog of a list — for ``seriesReference(zu:)``, once per run.
    private func allSeries(of playlistID: String) async throws -> [MediaItem] {
        if let cached = seriesIndex[playlistID] { return cached }
        let client = try await client(for: playlistID)
        let data = try await client.fetchData(action: "get_series")
        let series = try XtreamVOD.series(from: data, playlistID: playlistID)
        seriesIndex[playlistID] = series
        return series
    }

    private var seriesIndex: [String: [MediaItem]] = [:]

    /// The series for a movie that is an episode — **only on exactly one match.**
    ///
    /// Measured on 2026-10-01 at iptvhost (26,413 movies, 5,273 series): 191 movies carry an
    /// episode pattern, 167 find exactly one series, 23 none (shows that are missing as a series),
    /// one finds two ("Jetlobre |TR" and "Jetlobre | TR"). With more than one match it
    /// stays with the movie page: a guessed series would be worse than none.
    public func seriesReference(zu item: MediaItem) async -> String? {
        // By the ID and not by `kind`: the phone does not know the kind of a tile,
        // the ID carries it (`…#movie#…`).
        guard let reference = XtreamVOD.Reference(itemID: item.id), reference.role == .movie,
            let name = SequelFilm.seriesName(from: item.title),
            let seriesList = try? await allSeries(of: reference.playlistID)
        else { return nil }
        let needle = SequelFilm.key(name)
        let match = seriesList.filter { SequelFilm.key($0.title) == needle }
        return match.count == 1 ? match[0].id : nil
    }

    public func item(id: String) async throws -> MediaItem {
        guard let reference = XtreamVOD.Reference(itemID: id) else {
            throw XtreamClient.Failure.malformed
        }

        let client = try await client(for: reference.playlistID)
        switch reference.role {
        case .movie:
            let data = try await client.fetchData(
                action: "get_vod_info",
                extra: ["vod_id": reference.id]
            )
            guard
                let detail = try XtreamVOD.movieDetail(
                    from: data, playlistID: reference.playlistID)
            else { throw XtreamClient.Failure.malformed }
            return detail

        case .series:
            // **One fetch carries both**: `get_series_info` delivers the details
            // of the series AND all seasons including episodes. Only the series is
            // needed here; ``children(of:)`` reads the episodes from **the same bytes**
            // — see ``seriesInfo(playlistID:seriesID:)``.
            let data = try await seriesInfo(
                playlistID: reference.playlistID, seriesID: reference.id)
            guard
                let detail = try XtreamVOD.seriesDetail(
                    from: data, seriesID: reference.id, playlistID: reference.playlistID)
            else { throw XtreamClient.Failure.malformed }
            return detail

        case .episode:
            // **An episode is never looked up individually.** The panel has
            // no fetch for it; it arises exclusively from the response
            // of its series. Whoever lands here has an ID from
            // memory — and the series above it is the right place.
            throw XtreamClient.Failure.malformed
        }
    }

    /// All episodes of a series — **the same response as ``children(of:)``.**
    ///
    /// **The finding from 2026-09-09, on the phone** (Library → Series → "DE|
    /// MAGENTA SERIEN" → "Neiscand|DE"): the detail page showed header image,
    /// description, cast and facts — and **no season, no episode,
    /// no play button.** The page fetches both side by side,
    /// ``children(of:)`` for the seasons and ``ContentSource/episodes(of:)``
    /// for the episodes; here the second had only the contract's default,
    /// and that is `[]`. Zero episodes became zero seasons and no
    /// next step — exactly the picture that was reported.
    ///
    /// **And it really is the same response and not a second view.** The
    /// contract justifies the separation by ``children(of:)`` returning **seasons**
    /// for structured series; the panel does not structure — under `episodes` it
    /// carries the episodes, keyed by season number, and
    /// a season has neither an ID nor a fetch there. Both paths therefore end
    /// in the same ``seriesInfo(playlistID:seriesID:)``, which remembers the
    /// most recently fetched bytes: **one** fetch to an account with **one**
    /// allowed connection, not two.
    ///
    /// The detail page builds the seasons from the episodes' ``Core/MediaItem/seasonNumber``.
    /// No name per season arises that way — measured on
    /// 2026-09-09 at iptvhost, `seasons` in `get_series_info` is empty (`[]`), for
    /// "Neiscand" as for "Cefeibrem Klimuma" with seven seasons.
    public func episodes(of seriesID: String) async throws -> [MediaItem] {
        try await children(of: seriesID)
    }

    /// The episodes of a series, in broadcast order across all seasons.
    ///
    /// **Empty instead of an error for everything that is not a series.** A movie has no
    /// children, and a caller that does not check that beforehand should not
    /// fail because of it — it gets what applies: nothing.
    public func children(of itemID: String) async throws -> [MediaItem] {
        guard let reference = XtreamVOD.Reference(itemID: itemID), reference.role == .series
        else { return [] }

        let data = try await seriesInfo(
            playlistID: reference.playlistID, seriesID: reference.id)
        let episodes = try XtreamVOD.episodes(
            from: data, seriesID: reference.id, playlistID: reference.playlistID)

        // **So that "no episodes" becomes answerable** (user finding 2026-08-22: one
        // series opened without a single episode, another did not). From outside,
        // a panel that delivers nothing looks exactly like a parser
        // that finds nothing — and like a view that shows nothing.
        //
        // **No episodes is a finding, not chatter**, and therefore it sits
        // in the always-recorded part: the first attempt at this report was
        // `verbose` and thus invisible exactly when someone reports without
        // recording switched on.
        //
        // **And the finding separates two cases**, now that it is clear both
        // exist: if the `episodes` field is missing entirely, the gap is at the provider and
        // there is nothing to fetch here. If it is there and still holds nothing, the fault is in
        // this page — only then does the beginning of the response belong in the log.
        if episodes.isEmpty {
            if XtreamVOD.carriesEpisodeField(in: data) {
                Diagnostics.playbackProblem(
                    "Series \(reference.id): NO episodes from \(data.count) bytes "
                        + "of get_series_info although the field is there — beginning: "
                        + "\(Self.head(of: data))",
                    since: nil
                )
            } else {
                Diagnostics.verbose(
                    "Series \(reference.id): provider carries no episodes "
                        + "(no `episodes` field in \(data.count) bytes)"
                )
            }
        } else {
            Diagnostics.verbose(
                "Series \(reference.id): \(episodes.count) episodes from "
                    + "\(data.count) bytes of get_series_info"
            )
        }
        return episodes
    }

    // MARK: - User state — **not here**

    /// All six bodies here are empty, and since AP42 (2026-09-21) that is the truth
    /// about this source: **an Xtream panel knows no user state.**
    ///
    /// Before, the state lived here, in a memory of its own. The reasoning for that was
    /// right — there is no place at the provider —, the conclusion was not: it follows
    /// that the state lives **locally**, not that it belongs to the source. It belongs
    /// to the person who sat in front of it; ``StateSource`` books it into the ``Core/StillLedger``.
    ///
    /// **Empty bodies and no inherited defaults.** The contract would have defaults for some of them;
    /// taking them would look shorter and conceal that a decision
    /// was made here. Whoever uses this source without a wrapper gets no state — that
    /// should be visible in six empty bodies and not in their absence.
    public nonisolated var tracksStateItself: Bool { false }

    public func resumable(limit: Int) async throws -> [MediaItem] { [] }

    public func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}

    public func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}

    public func favorites() async throws -> [MediaItem] { [] }

    public func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}

    public func endSession(for itemID: String, at position: TimeInterval) async throws {}

    public func segments(for itemID: String) async throws -> [MediaSegment] { [] }

    // MARK: - Lieferung

    public func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        guard let reference = XtreamVOD.Reference(itemID: itemID) else {
            throw XtreamClient.Failure.malformed
        }
        let endpoint = try await endpoint(for: reference.playlistID)
        guard let url = XtreamVOD.playbackURL(for: itemID, account: endpoint) else {
            throw XtreamClient.Failure.malformed
        }
        return url
    }

    // MARK: - Bilder

    /// Passes the provider's finished address through.
    ///
    /// With Xtream, `posterID`/`backdropID` hold the **complete address**
    /// (see `XtreamVOD.artwork`); callers hand in exactly this field as
    /// the ID. Whatever is not an address — an entry ID as a
    /// fallback, say — deliberately yields nothing: better an empty tile than a
    /// fetch that never answers.
    public nonisolated func imageURL(
        itemID: String, kind: ImageKind, width: Int, tag: String?
    ) -> URL? {
        guard let url = URL(string: itemID),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        return Self.toWidth(url, width: width)
    }

    /// Brings the TMDb size level in the address to the requested width.
    ///
    /// **The finding from 2026-09-05 on the phone:** the requested width was so far
    /// silently thrown away here — the address went out as the panel
    /// reports it, and that is `…/t/p/w600_and_h900_bestv2/…` for practically every title.
    /// For a tile 103 points wide that is 80 to 120 kilobytes instead of about
    /// thirty; a screen full of posters thus weighed a good megabyte, and over
    /// a narrow connection a poster grid was unusable.
    ///
    /// **TMDb writes the size into the path**, in exactly one place: `/t/p/<level>/`.
    /// Rewriting it is therefore no tinkering with a foreign address but
    /// the intended way — the levels are part of the public address form.
    ///
    /// **Only for TMDb and only for a known level.** A provider that serves its
    /// posters itself gets its address back unchanged: there a path segment
    /// means nothing, and a guessed intervention would lead to a
    /// fetch that never answers.
    static nonisolated func toWidth(_ address: URL, width: Int) -> URL {
        guard width > 0, address.host()?.hasSuffix("image.tmdb.org") == true else {
            return address
        }
        var split = address.pathComponents
        // ["/", "t", "p", "<stufe>", "<datei>"]
        guard split.count >= 5, split[1] == "t", split[2] == "p",
            split[3].hasPrefix("w") || split[3] == "original"
        else { return address }

        split[3] = tier(forItem: width)
        var setup = URLComponents(url: address, resolvingAgainstBaseURL: false)
        setup?.path = "/" + split.dropFirst().joined(separator: "/")
        return setup?.url ?? address
    }

    /// The smallest TMDb level that still carries the requested width.
    ///
    /// **Rounded up and not down.** A level that is too small is visible; one that is too large
    /// only costs bytes. Above the largest level it stays at `w780` — `original`
    /// would be a multiple for nothing on a poster.
    static nonisolated func tier(forItem width: Int) -> String {
        let slots = [92, 154, 185, 342, 500, 780]
        let matching = slots.first { $0 >= width } ?? slots[slots.count - 1]
        return "w\(matching)"
    }

    /// A stream that never reports anything — there is no background sync
    /// here: a provider's list comes in one piece and is not
    /// delivered piece by piece afterwards.
    ///
    /// **Spelled out and not inherited**, since the contract no longer has a default
    /// for it — why is explained at ``ContentSource/listChanges()``: a
    /// convenient default once cut the wire for the source that actually
    /// reports.
    public func listChanges() async -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// What the app remembers about foreign libraries: watched, favourite, progress.
///
/// **Local, because there is no place for it at the provider** — an Xtream panel knows
/// no user state.
///
/// **Since AP42 (2026-09-21) a reader of the ``Core/StillLedger``.** The rationale above was correct
/// and incomplete: from "the provider cannot do it" it follows that the state
/// lives locally — not that it belongs to the **device**. Until then it sat as `vod.memory.v1` in the
/// Keychain, and the profile switch left it standing: the next day a child profile found the
/// started movies of the parent profile under "Continue Watching".
///
/// **The scope of this type is unchanged.** It grew on real catalogs —
/// the descriptors, the legacy data without them, the rule that a descriptor alone does not keep an
/// entry alive. What has changed is where it looks.
///
/// **Without a cache of its own.** Before, this actor kept the dictionary in
/// memory and wrote it back whole. On the Standbuch it must not do that: it also
/// carries the most recently watched channel, and ``Core/LiveMemory`` writes that from the
/// main thread. A state held here from earlier would overwrite it at the next remember —
/// silently, and it would be noticed only when the TV opens on the wrong channel.
public actor VODMemory {

    /// The key under which the state lived until AP42 — **now only read.**
    /// ``StateTransfer`` brings it over on first launch; it is deleted as soon as the
    /// takeover into the profile is in place (``StateTransfer/clearLegacyCatalog(listen:from:in:)``,
    /// AP48, 2026-09-25).
    static let oldKey = "vod.memory.v1"

    /// Where the Standbuch ledgers live.
    private let store: KeyValueStore

    /// **``FileStore`` and no longer the Keychain**, following the store rule from
    /// `README.md`: a state is structure and belongs in a file.
    public init(store: KeyValueStore = FileStore()) {
        self.store = store
    }

    private var ledger: StillLedger {
        StillLedger.read(from: store, forItem: ProfilePointer.active)
    }

    private func record(_ event: StillEvent) {
        var ledger = self.ledger
        ledger.record(event)
        ledger.write(in: store, forItem: ProfilePointer.active)
    }

    /// Puts the remembered states into fresh titles — **and remembers the descriptor
    /// in passing** of those that already have an entry.
    ///
    /// Nothing is created in the process: whoever has no entry here does not get one.
    func enrich(_ items: [MediaItem]) -> [MediaItem] {
        var ledger = self.ledger
        let previous = ledger

        let enrichedItem = items.map { item in
            guard let state = ledger.state.titlePositions[item.id] else { return item }

            if state.title != item.title || state.kind != item.kind
                || state.image != item.artwork.posterID
                || (item.seriesID != nil && state.series != item.seriesID)
            {
                ledger.record(
                    .profileCard(
                        title: item.id, name: item.title, kind: item.kind,
                        image: item.artwork.posterID, series: item.seriesID))
            }

            var enriched = item
            enriched.isFavorite = state.favorite
            enriched.progress = PlaybackProgress(
                position: state.location ?? 0,
                duration: state.duration ?? item.runtime ?? 0,
                isWatched: state.seen
            )
            return enriched
        }

        // **Written once at the end and not per title.** A category has thousands.
        if ledger != previous { ledger.write(in: store, forItem: ProfilePointer.active) }
        return enrichedItem
    }

    /// The started titles, **most recently touched first** — fully drawn, without
    /// a single fetch to the provider.
    ///
    /// Watched ones drop out: "Continue Watching" is not a history. Whoever has no descriptor
    /// is not listed here — for them there is ``resumableWithoutProfile(limit:)``.
    func resumable(limit: Int) -> [MediaItem] {
        started
            .filter { $0.value.title != nil }
            .prefix(limit)
            .map { identifier, state in
                var item = MediaItem(
                    id: identifier,
                    kind: state.kind ?? .movie,
                    title: state.title ?? "",
                    runtime: state.duration,
                    artwork: Artwork(posterID: state.image),
                    progress: PlaybackProgress(
                        position: state.location ?? 0,
                        duration: state.duration ?? 0,
                        isWatched: false
                    )
                )
                item.lastWatched = state.recent
                item.seriesID = state.series
                return item
            }
    }

    /// The remembered series of a title — see ``Core/StateRecording/TitlePosition/series``.
    func series(forItem title: String) -> String? {
        ledger.state.titlePositions[title]?.series
    }

    /// Remembers the series for a title that already has an entry.
    func rememberSeries(_ series: String, forItem title: String) {
        guard let state = ledger.state.titlePositions[title], state.series != series else { return }
        record(
            .profileCard(
                title: title, name: state.title ?? "", kind: state.kind, image: state.image,
                series: series))
    }

    /// When this title last played — for titles whose descriptor is filled in later.
    func lastWatched(_ identifier: String) -> Date? {
        ledger.state.titlePositions[identifier]?.recent
    }

    /// The IDs of started titles **without** a descriptor.
    ///
    /// That is the legacy data: everything remembered before 2026-09-20 carries only
    /// ID and position. The source resolves them individually while they are still there —
    /// on the first pass through a list they fill in their descriptor and are
    /// free from then on.
    func resumableWithoutProfile(limit: Int) -> [String] {
        started
            .filter { $0.value.title == nil }
            .prefix(limit)
            .map(\.key)
    }

    /// Started means: a position remembered and not ticked off as watched.
    private var started: [(key: String, value: StateRecording.TitlePosition)] {
        ledger.state.titlePositions
            .filter { $0.value.location != nil && !$0.value.seen }
            .sorted { ($0.value.recent ?? .distantPast) > ($1.value.recent ?? .distantPast) }
            .map { (key: $0.key, value: $0.value) }
    }

    func setWatched(_ watched: Bool, for itemID: String) {
        record(.seen(title: itemID, watched))
    }

    func setFavorite(_ favorite: Bool, for itemID: String) {
        record(.titelfavorit(title: itemID, favorite))
    }

    /// The IDs of all marked titles — for the favourites area.
    var favoriteIDs: [String] {
        ledger.state.titlePositions.filter(\.value.favorite).map(\.key).sorted()
    }

    func setPosition(_ position: TimeInterval, of duration: TimeInterval?, for itemID: String) {
        record(.titlePosition(title: itemID, location: position, duration: duration))
    }
}
