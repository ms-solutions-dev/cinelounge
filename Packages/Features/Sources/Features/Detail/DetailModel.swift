import Core
import DesignSystem
import Flows
import Foundation
import JellyfinKit
import ParentalControls
import PlaylistKit
import PortalKit
import RatingsKit
import SwiftUI

/// Loads a title's detail page: description, seasons, episodes.
public final class DetailModel: ObservableObject {

    public enum State: Equatable {
        case loading
        case ready
        case failed(String)

        /// Siehe ``HomeModel/State/isFailed``.
        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var item: MediaItem
    /// For series the seasons, otherwise empty.
    @Published public private(set) var seasons: [MediaItem] = []
    @Published public private(set) var episodes: [MediaItem] = []

    /// Why the episode list is empty.
    ///
    /// **Empty does not mean the same as empty.** A series without episodes looks on
    /// screen just like one whose fetch failed — both times
    /// there is a page without a Play button, and the viewer looks for the
    /// fault in themselves. The occasion (iptvhost, 2026-08-22): about a fifth of this
    /// provider's series have no episode entries at all in the panel — among them
    /// "A Seikoca plebra Naunzoukau", which even still reports its seasons. No
    /// evaluator helps against that, only a sentence that says so.
    public enum EpisodeGap: Equatable {
        /// There are episodes, or they are still on the way.
        case none
        /// The fetch went through, the provider carries no episode for this title.
        case providerHasNone
        /// The fetch itself failed.
        case lookupFailed
    }

    @Published public private(set) var episodeGap: EpisodeGap = .none

    /// Related titles for the "Similar" row — only for films and home videos.
    @Published public private(set) var similar: [MediaItem] = []

    /// The parts of a collection, by release date — only for collections.
    @Published public private(set) var parts: [MediaItem] = []
    @Published public private(set) var selectedSeason: MediaItem?
    /// Ratings from IMDb, Rotten Tomatoes and Metacritic. Loaded afterwards,
    /// once the title is in place — the page should not wait for them.
    @Published public private(set) var external = ExternalRatings()

    /// The finished target for the trailer button, or `nil`.
    ///
    /// **The finished target and not just a flag.** The button appears only if
    /// a trailer is attached *and* something can be played from it; both are
    /// only settled with the target. A button that does nothing on press is worse than
    /// none — on a TV focus then sits on something that does not
    /// respond, and the app is taken for frozen.
    ///
    /// Building costs no second request: the address is only assembled.
    @Published public private(set) var trailerTarget: PlaybackTarget?
    /// What was found as a trailer (AP78) — the button with its language badge hangs on this,
    /// before the address is in place. ``trailerTarget`` follows as soon as YouTube or the
    /// server has answered.
    @Published private(set) var trailerFinding: TrailerFinding?
    /// Resolution has failed: YouTube has changed or the video is blocked.
    /// The button stays, a press shows the board with the jump into the YouTube app.
    @Published public private(set) var trailerFailed = false
    private var trailerResolution: Task<PlaybackTarget?, Never>?

    /// The bandwidth limit with which the trailer target was built.
    ///
    /// Kept here because the playback view needs it as well and both
    /// have to use the same one: two separate reads would drift apart
    /// as soon as someone changes the setting while opening.
    ///
    /// It is read in ``load()`` and not in the initialiser — the Keychain
    /// blocks on a computer as soon as it expects an approval, and this
    /// model is created in tests.
    ///
    /// Without `@Published`, and that holds: it is set immediately **before**
    /// ``trailerTarget``, and that one's notification redraws the view anyway.
    /// Read the other way round, the old limit would stand here for one image change.
    public private(set) var streamQuality: StreamQuality = .unlimited

    private let source: any ContentSource
    private let ratings: OMDbClient?
    /// Now only for the German voices — the score has come from MAL since AP68.
    private let anilist: AniListClient?
    private let anime: AnimeRating?
    /// Where portraits come from when the source carries none — see
    /// ``loadPortraits()``.
    private let portraitSource: TMDbClient?

    /// The rule by which "Similar", seasons, episodes and the parts of a collection
    /// are filtered (cross-check AP45, 2026-09-25, M3).
    ///
    /// **The page itself has passed the filter already, its lists have not.** An
    /// approved film carried an 18-rated title in "Similar titles", and a press on it
    /// did not open it — the funnel stops it — but title and poster
    /// stood on a child's page. Filtering therefore happens **before** the list is
    /// set, as everywhere else (``ParentalControls/ProtectionRule/shows(approval:)``).
    private let rule: ProtectionRule

    /// The build form — it brings the origin scope along (``ParentalControls/ChildScope/opens(_:origin:)``).
    private let surface: Surface

    /// The same filter for the player this page opens — the trailer gets it like
    /// every other build of ``PlayerModel`` (check 2026-09-25, finding 1).
    func mayPlay(_ title: MediaItem) -> Bool {
        rule.scope.opens(title)
    }

    /// What is left of a list on this page.
    private func filter(_ title: [MediaItem]) -> [MediaItem] {
        title.filter { rule.scope.opens($0) }
    }

    /// Portraits by **name**, for sources without their own person images.
    @Published public private(set) var personPortraits: [String: URL] = [:]

    /// "Language of this series" — **shared with the phone** (AP58 G1, A9,
    /// ``Flows/SeriesLanguageFlow``). `nil` where there is no choice.
    ///
    /// **The choice belongs to the series and not to the episode** (viewer request 2026-08-28: "otherwise
    /// automatic playback from episode to episode would no longer work at all").
    public private(set) var languageChoice: SeriesLanguageFlow?

    /// In which languages this series can be watched — empty where there is no choice.
    public var languages: [String] { languageChoice?.languages ?? [] }

    /// The chosen language — empty means: no preference, the bridge takes the
    /// first source that works.
    public var language: String { languageChoice?.language ?? "" }

    /// Whether the list is being fetched right now.
    public var loadingLanguages: Bool { languageChoice?.isLoading ?? false }

    /// The German dubbing voices for the roles — empty where there are none.
    ///
    /// **And empty is the normal case**: the source is AniList, and it carries them
    /// only for anime. The cast row therefore shows its second line only
    /// where something is in it — an empty field under every face would look like
    /// a bug, not like missing information.
    @Published public private(set) var germanVoices = GermanVoices(byCharacter: [:])

    /// - Parameter source: **No longer fixed to the media server** (2026-08-22): the
    ///   provider area needs the same page for its films and series, and
    ///   the media server does not know those. Of the nine things this page
    ///   demands from a source, seven are in the contract; the other two
    ///   — chapter images and collections — are Jellyfin-specific and meaningless for a
    ///   provider title anyway. They therefore sit behind a
    ///   query instead of behind a narrower type.
    public init(
        source: any ContentSource,
        item: MediaItem,
        ratings: OMDbClient? = nil,
        anilist: AniListClient? = nil,
        anime: AnimeRating? = nil,
        portraits: TMDbClient? = nil,
        rule: ProtectionRule = .pending,
        surface: Surface = .familiar
    ) {
        self.rule = rule
        self.surface = surface
        self.source = source
        self.item = item
        self.ratings = ratings
        self.anilist = anilist
        self.anime = anime
        self.portraitSource = portraits
        self.languageChoice = Self.languageChoice(forItem: item, from: source)
    }

    /// The series' language choice, **only for a series from a portal** — see
    /// ``canChooseLanguage``.
    static func languageChoice(
        forItem item: MediaItem, from source: (any ContentSource)?
    ) -> SeriesLanguageFlow? {
        guard let portal = source as? PortalSource, item.kind == .series || item.kind == .season
        else { return nil }
        let identifier = item.id
        return SeriesLanguageFlow(
            routes: SeriesLanguageFlow.Routes(
                read: { try await portal.language(forItem: identifier) },
                list: { try await portal.languages(forItem: identifier) },
                set: { try await portal.setLanguage($0, forItem: identifier) }))
    }

    // MARK: - Language choice of a portal series

    /// Whether this page can carry a language choice at all.
    ///
    /// Only for a series from a portal: a film has no episodes to which
    /// a preference would apply, and the media server knows no hosts.
    public var canChooseLanguage: Bool {
        source is PortalSource && (item.kind == .series || item.kind == .season)
    }

    /// Fetch the remembered choice — cheap, a look into the store.
    public func loadLanguage() async {
        await languageChoice?.loadLanguage()
    }

    /// Fetch the options — only on demand.
    public func loadLanguages() async {
        await languageChoice?.loadLanguages()
    }

    /// Set the choice — immediately in the display, back on failure.
    public func setLanguage(_ wanted: String) async {
        await languageChoice?.select(wanted)
    }

    /// Fetches portraits **where the source delivers none.**
    ///
    /// An Xtream provider carries only cast *names* for its titles; the
    /// circles therefore stayed empty, while the same page shows
    /// faces for the media server (user finding 2026-08-22). TMDb knows the people by
    /// name — by the same name with which the filmography searches anyway.
    ///
    /// **Only if the source really has nothing.** With the media server the
    /// images come from it; bypassing it would mean making a
    /// third-party request for every cast whose answer fits worse.
    ///
    /// Failures are inconsequential here: if a name stays without an image, the
    /// circle shows the hint it already had before.
    private func loadPortraits() async {
        guard !item.cast.isEmpty else { return }
        // If the source carries images itself, there is nothing to do here.
        guard item.cast.allSatisfy({ Self.personURL(for: $0, from: source) == nil }) else {
            return
        }

        // **Without access there are no faces — and that should be said.**
        // Otherwise "the app does not fetch them" cannot be told from "no key
        // is stored"; both look the same on the TV,
        // namely like empty circles (lesson of 2026-08-22).
        guard let portraitSource else {
            Diagnostics.playbackProblem(
                "Cast: \(item.cast.count) names without a picture, and no "
                    + "movie database access stored — Settings → Ratings",
                since: nil
            )
            return
        }

        // One after another and capped: the circles stand side by side, the
        // first ones are seen first — and a dozen simultaneous requests to
        // TMDb help nobody.
        // **Up to four side by side** (AP7 · L9): twelve names in sequence
        // cost 1.8 to 3.0 seconds. The width is deliberately small — TMDb
        // is a third-party counterpart, and a dozen simultaneous requests
        // help nobody. Four cover the circles that are
        // in the picture before anyone pages on.
        let pending = item.cast.prefix(ExternalLookup.maxPortraits).map(\.name)
            .filter { personPortraits[$0] == nil }
        let foundItem = await ExternalLookup.portraits(zu: pending, from: portraitSource)
        for (name, url) in foundItem { personPortraits[name] = url }
        let hit = foundItem.count

        if hit == 0 {
            Diagnostics.playbackProblem(
                "Cast: not a single picture found for \(item.cast.count) names "
                    + "— access present, but the query returns nothing",
                since: nil
            )
        } else {
            Diagnostics.verbose("Cast: \(hit) pictures fetched later")
        }
    }

    /// Listens to the source's change stream — the marks must never be stale
    /// (rule of 2026-07-29): after playback ``JellyfinSource`` reports
    /// the end, and otherwise the Play button shows the state from before the film
    /// until the page is reopened. Refreshing is silent — title and
    /// episodes, without touching the loading state, so that nothing flickers.
    private var listObservation: Task<Void, Never>?

    private func observeListChanges() {
        guard listObservation == nil else { return }
        listObservation = Task { [weak self, source] in
            for await _ in await source.listChanges() {
                await self?.refreshMarks()
            }
        }
    }

    deinit {
        listObservation?.cancel()
    }

    /// Fetches progress and marks anew, without rebuilding the page.
    private func refreshMarks() async {
        item = await (try? source.item(id: item.id)) ?? item
        await reloadEpisodes()
    }

    /// How many portraits are fetched at the same time — see
    /// ``loadPortraits()``.
    static let portraitWidth = ExternalLookup.concurrentPortraits

    public func load() async {
        observeListChanges()
        // **What already stands stays standing** (diagnosis F-039, 2026-09-30): after
        // leaving the player the page reloads, and the IPTV provider with one
        // connection slot refuses while the playback connection is still being torn down.
        // The finished page thereby turned into the error page — on the device that looked like a
        // video crash.
        let alreadyReady = state == .ready
        if !alreadyReady { state = .loading }

        do {
            // The full title brings description, cast and the
            // technical details with it — the overviews do not deliver that.
            item = try await fetchTitle()

            // **The page is set here, not only at the end.**
            //
            // The checkpoint used to sit further down (viewer finding 2026-08-08, "it takes
            // quite a while until content arrives"): for a series the seasons and their episodes
            // came before this point — **three**
            // network hops in a row, and until the last one the screen stayed
            // grey. Yet this one fetch brings everything that makes up the look:
            // image, title, description, cast.
            //
            // Seasons and episodes are extras and catch up by themselves. A
            // failure there is therefore no longer a reason to report the whole page
            // as failed — only this first fetch decides
            // that.
            state = .ready

            await loadChildren()

            // **Four services side by side instead of one after another** (AP7 · L9,
            // expert review 2026-08-24): trailer, ratings, portraits and
            // "Similar" asked in sequence — 0.8 to 1.6 s instead of 0.2 to
            // 0.4, and on **every** detail page.
            //
            // **Why here and not everywhere:** the many other serial
            // places in the project are deliberate — narrow tunnel for a
            // provider with one connection slot, one-connection rule. Here
            // none of those reasons applies: these are four **different**
            // counterparts (media server, TMDb, OMDb/AniList), and none of
            // them knows about the others.
            //
            // The order on screen stays the same nonetheless: each branch sets its
            // own published value as soon as it is there.
            async let trailer: Void = loadTrailer()
            async let ratings: Void = loadExternalRatings()
            async let portraits: Void = loadPortraits()
            async let host: Void = warmHosts()
            // The ID and the kind are read **before** the concurrent part:
            // an `async let` that accesses `item` would lead the
            // main actor into an expression that does not belong to it.
            let identifier = item.id
            let fetchesSimilar = DetailRules.fetchesSimilar(item.kind)
            let sourceItem = source
            async let related: [MediaItem] =
                fetchesSimilar
                ? ((try? await sourceItem.similarItems(
                    to: identifier, limit: DetailRules.maxSimilar)) ?? [])
                : []

            _ = await (trailer, ratings, portraits, host)
            similar = filter(await related)
        } catch _ where alreadyReady {
            // The page is already up — a failed refresh does not take it away.
            Diagnostics.step(
                "Detail page: refresh failed, the loaded page stays", since: nil,
                area: "Oberfläche")
        } catch let failure as JellyfinSource.SourceFailure {
            Diagnostics.defect(
                "Detail page not loaded: \(Diagnostics.explain(failure))", since: nil,
                area: "Oberfläche")
            state = .failed(HomeModel.messageKey(for: failure))
        } catch is CancellationError {
            // Not an error but a cancellation — reasoning in ``HomeModel/load()``.
        } catch {
            Diagnostics.defect(
                "Detail page not loaded: \(Diagnostics.explain(error))", since: nil, area: "Oberfläche")
            // **What arrives here has often already said what it lacks** (AP39,
            // 2026-09-20). Until then `error.unreachable` stood at this point —
            // "No response. Is the server running?". A refusal from the portal service
            // (`401 auth.profile_required`) thereby became a question about the network,
            // and the viewer looked at the router while two clicks further the
            // profile choice stood. The interpretation knows the origin and says it more precisely;
            // where it knows nothing more precise, it returns the same sentence as before.
            state = .failed(
                DisruptionInterpretation.rejection(forItem: error, origin: Origin.forItem(source: source)))
        }
    }

    /// The full title — **on a connection refusal a second attempt after
    /// 1.5 s** (diagnosis F-039): the IPTV provider with one connection slot says "not
    /// reachable" as long as the playback that just ended still holds its slot.
    private func fetchTitle() async throws -> MediaItem {
        do {
            return try await source.item(id: item.id)
        } catch let error where Self.worthLookup(error) {
            Diagnostics.step(
                "Detail page: provider unreachable, second attempt in 1.5 s", since: nil,
                area: "Oberfläche")
            try await Task.sleep(for: Self.lookupPause)
            return try await source.item(id: item.id)
        }
    }

    static let lookupPause: Duration = .milliseconds(1500)

    /// Only connection refusals — a refusal with a reason (no access, not found) does not
    /// turn out differently the second time.
    nonisolated static func worthLookup(_ error: any Error) -> Bool {
        if let f = error as? JellyfinSource.SourceFailure { return f == .unreachable }
        if let f = error as? XtreamClient.Failure { return f == .unreachable }
        if let f = error as? URLError {
            return [
                .cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost,
                .dnsLookupFailed,
            ].contains(f.code)
        }
        return false
    }

    /// Seasons, episodes or the parts of a collection — depending on the kind of title.
    ///
    /// **Does not throw.** They come after the page is already up; a
    /// failure from here on must not overturn anything the viewer already has
    /// in front of them. If the list stays empty, a section is missing — that is
    /// more honest than an error message in place of a finished page.
    private func loadChildren() async {
        switch item.kind {
        case .series:
            guard let children = try? await source.children(of: item.id) else {
                episodeGap = .lookupFailed
                return
            }
            seasons = filter(children.filter { $0.kind == .season })

            // Load the season you are standing in right away: whoever opens a series
            // wants to see the episodes, not first pick a season —
            // and certainly not navigate there from season 1 every time. Which
            // one that is, is stated in ``startingSeason(in:)``.
            if let starting = Self.startingSeason(in: seasons) {
                await selectSeason(starting)
            } else {
                // Series without season structure — then the children
                // are already the episodes.
                episodes = filter(children.filter { $0.kind == .episode })
            }
            // Only if there was no season at all: with a season
            // ``selectSeason(_:)`` has already set the finding and knows the
            // chosen season — here it would be discarded again.
            if seasons.isEmpty {
                episodeGap = episodes.isEmpty ? .providerHasNone : .none
            }

        case .season:
            guard let children = try? await source.children(of: item.id) else {
                episodeGap = .lookupFailed
                return
            }
            episodes = filter(children)
            episodeGap = episodes.isEmpty ? .providerHasNone : .none

        case .collection:
            // The parts of the series in release order — they ARE the page:
            // a collection has neither trailer nor resume point, only its films.
            // The media server has a query of its own for this; a portal (Filmhub film series,
            // since 2026-11-08) delivers the parts as children — as on the phone.
            if let jellyfin = source as? JellyfinSource {
                parts = filter((try? await jellyfin.collectionItems(in: item.id)) ?? [])
            } else {
                parts = filter((try? await source.children(of: item.id)) ?? [])
            }

        default:
            break
        }
    }

    /// **Fetch the hosts of a CL-Server title already when the page opens** (server log
    /// 2026-10-11, "Bringrarn Klozirn"): the server resolves the first usable host ahead of time
    /// as soon as someone fetches the list. Until now only the press on
    /// Play fetched it — and `/play` came 0.1 s later and waited for the same resolution, 2.7 s.
    /// From here it runs while you are still reading; the press finds it ready. The
    /// list itself is remembered for 120 s, the player does not ask the portal for it again but
    /// the server. Only films and episodes: a series has no hosts.
    private func warmHosts() async {
        guard item.kind == .movie || item.kind == .episode, let portal = portalDataSource else { return }
        _ = try? await portal.host(forItem: item.id)
    }

    /// The same unfolding as ``PlayerModel/portalDataSource``: parental controls filter before it.
    private var portalDataSource: PortalSource? {
        (source as? PortalSource) ?? ((source as? FilteredSource)?.source as? PortalSource)
    }

    /// Looks for the trailer and builds its target.
    ///
    /// Only for films and series: for an episode or a season the server carries
    /// no trailers, the query would be a wait without a result.
    ///
    /// The source in the target is **the trailer's** — it is a file of its own with
    /// its own container, and with the film's the picture would stay black. The reasoning
    /// as a whole is at ``TrailerPlayback``.
    private func loadTrailer() async {
        guard item.kind == .movie || item.kind == .series else { return }

        streamQuality = StreamQuality.load(from: SecureStore())
        guard let fund = await TrailerPlayback.fund(for: item, from: source, tmdb: portraitSource)
        else { return }
        trailerFinding = fund

        // **The address right afterwards, not only on press** — as with the CL-Server's
        // host (#59): the YouTube resolution takes two to five seconds, and whoever
        // presses "Trailer" should not wait. If it fails, the button stays and shows
        // the board; the page itself notices nothing.
        let (film, source, quality) = (item, source, streamQuality)
        trailerResolution = Task { [weak self] in
            let target = try? await TrailerPlayback.target(
                forItem: fund, film: film, from: source, quality: quality)
            guard let self else { return nil }
            if let target { self.trailerTarget = target } else { self.trailerFailed = true }
            return target
        }
    }

    /// The target for the button — waits for the running resolution. `nil` means: failed,
    /// the view shows the board.
    public func trailerDestination() async -> PlaybackTarget? {
        if let trailerTarget { return trailerTarget }
        return await trailerResolution?.value
    }

    /// The source from which playback catches up on its details.
    ///
    /// The player needs it for chapters, scrub preview and position reports and
    /// gets it passed through from the view. As ``ContentSource`` and not as
    /// ``JellyfinSource``, because it does not need to know where the title comes from.
    public var contentSource: any ContentSource { source }

    /// OMDb, MAL score and German voices **side by side** — since AP58 R6 via
    /// ``RatingsKit/ExternalLookup/fetch(imdb:anilist:omdb:anilistClient:)``, the same query
    /// as on the phone.
    /// **With TMDb where the IMDb ID is missing** (2026-09-29): IPTV and CL-Server titles
    /// usually carry only the TMDb number. Through it come IMDb, Rotten Tomatoes and
    /// Metacritic — and whatever the title itself does not have (description, genres,
    /// backdrop image, TMDb score). Nothing is overwritten, only supplemented.
    private func loadExternalRatings() async {
        let state = await ExternalLookup.fetch(
            imdb: item.ratings.imdbID, anilist: item.ratings.anilistID, omdb: ratings,
            anilistClient: anilist, tmdb: item.ratings.tmdbID, tmdbClient: portraitSource,
            search: Self.titleSearch(forItem: item), tvdb: AnimeRating.tvdb(item), anime: anime)
        var combined = (try? state.omdb?.get()) ?? ExternalRatings()
        combined.mal = (try? state.mal?.get())??.score
        external = combined
        germanVoices = state.voicesOrEmpty
        if let info = try? state.tmdb?.get() { complete(from: info) }
    }

    /// The TMDb search for a title without an ID — only films and series with a year.
    nonisolated static func titleSearch(forItem item: MediaItem) -> ExternalLookup.TitleSearch? {
        guard let year = item.year, item.kind == .movie || item.kind == .series else { return nil }
        return ExternalLookup.TitleSearch(title: item.title, year: year, series: item.kind == .series)
    }

    /// The backdrop image from TMDb — only if the title has none.
    @Published public private(set) var tmdbBackdrop: URL?

    private func complete(from info: TitleInfo) {
        var fresh = item
        if fresh.overview?.isEmpty ?? true, let text = info.description { fresh.overview = text }
        if fresh.genres.isEmpty, !info.genres.isEmpty { fresh.genres = info.genres }
        if fresh.ratings.community == nil { fresh.ratings.community = info.rating }
        if fresh.ratings.imdbID == nil { fresh.ratings.imdbID = info.imdbID }
        // **The cast, where the source has none** — with the images from TMDb, so that the
        // row shows faces right away and every person can be selected as with Jellyfin.
        if fresh.cast.isEmpty, !info.cast.isEmpty {
            fresh.cast = info.cast.map { person in
                Person(
                    id: "tmdb:" + person.name, name: person.name, role: person.role,
                    character: person.characterName, hasImage: person.image != nil)
            }
            for person in info.cast {
                if let image = person.image { personPortraits[person.name] = image }
            }
        }
        if fresh != item { item = fresh }
        if Self.backdropURL(for: item, from: source) == nil { tmdbBackdrop = info.backdrop }
    }

    /// Opens a season and fetches its episodes.
    ///
    /// **Only the most recently chosen season writes** (check 2026-09-27, D2). The choice
    /// follows focus; if it moves from season 1 to 2 and the answer for 1 arrives later,
    /// the episode list of 1 stood under "Season 2" — and the Play button pointed at an
    /// episode of the wrong season. Every choice draws a token, an older answer is dropped.
    public func selectSeason(_ season: MediaItem) async {
        selectedSeason = season
        seasonMarker &+= 1
        let tag = seasonMarker
        let children = try? await source.children(of: season.id)
        guard tag == seasonMarker else { return }
        guard let children else {
            episodes = []
            episodeGap = .lookupFailed
            return
        }
        episodes = filter(children)
        episodeGap = children.isEmpty ? .providerHasNone : .none
    }

    /// The token of the last season choice — see ``selectSeason(_:)``.
    private var seasonMarker = 0

    /// The episode that starts on a press of "Play".
    ///
    /// Started ones take priority, then the first unwatched — not bluntly the
    /// first episode, otherwise you start from the beginning every time you open. Since AP58 R6 the rule
    /// lives in ``Core/ContinueWatching/nextEpisode(from:)``.
    public var playbackTarget: MediaItem? {
        // **A film is its own target.** This line was missing, and the bug stayed
        // invisible for a long time: the detail page was built for series, where the target is an episode
        // from the list. For a film the list stays empty — and because the
        // Play button hangs on the target, it disappeared entirely. All that then stood on the page
        // was "Trailer", which looks as if the film cannot be played.
        if episodes.isEmpty {
            return item.kind == .series || item.kind == .season ? nil : item
        }

        return ContinueWatching.nextEpisode(from: episodes)
    }

    public var isResuming: Bool {
        playbackTarget?.progress?.isResumable == true
    }

    // MARK: - Watched and favorite

    /// Whether the title counts as watched.
    ///
    /// For a series what counts is whether **everything** is watched: the server keeps the number
    /// of unwatched episodes for that. It is the more reliable information than the flag on the
    /// series entry itself, which it keeps only as long as nobody
    /// toggles individual episodes.
    public var isWatched: Bool {
        if item.kind == .series, let unplayed = item.unplayedCount {
            return unplayed == 0
        }
        return item.progress?.isWatched == true
    }

    public var isFavorite: Bool { item.isFavorite }

    /// Flips the watched flag.
    ///
    /// **The display goes first, the server follows.** On a TV feedback that comes only
    /// after the server's answer is felt as a delay — and over a thin line you wonder
    /// whether the press arrived. If it fails, it is put back: a mark that is there and
    /// gone at the next opening is worse than one that never appears in the first place.
    public func toggleWatched() async {
        let wanted = !isWatched
        item.progress = PlaybackProgress(
            position: wanted ? (item.runtime ?? 0) : 0,
            duration: item.runtime ?? item.progress?.duration ?? 0,
            isWatched: wanted
        )
        if item.kind == .series { item.unplayedCount = wanted ? 0 : (item.episodeCount ?? 1) }

        do {
            try await source.setPlayed(wanted, for: item.id)
            await reloadEpisodes()
        } catch {
            Diagnostics.defect(
                "Watched mark not set: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
            item = await (try? source.item(id: item.id)) ?? item
        }
    }

    public func toggleFavorite() async {
        let wanted = !isFavorite
        await MarkToggle.setEnabled(to: wanted, previous: !wanted, show: { item.isFavorite = $0 }) {
            try await source.setFavorite(wanted, for: item.id)
        }
    }

    /// Fetches the episodes anew after their state may have changed.
    ///
    /// A series marked as watched changes each of its episodes — and the
    /// Play button hangs on them. Without this it would keep offering the episode that
    /// was the first unwatched one a moment ago.
    private func reloadEpisodes() async {
        guard item.kind == .series, let season = selectedSeason else { return }
        episodes = (try? await source.children(of: season.id)).map { filter($0) } ?? episodes
    }

    /// Sets the flag or mark for a single episode.
    ///
    /// **A separate path next to the one for the title**, because a series is both at once:
    /// the button at the top means the series, the tile means the episode. A shared path
    /// would have to guess what is meant — and would be wrong in half the cases.
    public func setPlayed(_ isPlayed: Bool, for episode: MediaItem) async {
        try? await source.setPlayed(isPlayed, for: episode.id)
        await reloadEpisodes()
    }

    /// The unwatched episodes **before** this one — the reason for the confirmation prompt.
    ///
    /// **The case this exists for** (user request 2026-08-12): "I am at
    /// episode 65, in between there are over forty filler episodes, and I mark 108
    /// as watched." What is meant is almost always: everything up to there. Whoever had to do it
    /// one by one presses forty-three times — and whoever does not, the
    /// app keeps offering episode 66 afterwards.
    ///
    /// **Within the shown season and in its order.** The list
    /// is what stands on the screen; reaching across seasons
    /// would be an effect you cannot see.
    ///
    /// A pure calculation over values — the prompt should not guess how many
    /// there are, and the number appears in its text.
    public nonisolated static func precedingUnwatched(
        before episode: MediaItem, in episodes: [MediaItem]
    ) -> [MediaItem] {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return [] }
        return episodes[..<index].filter { $0.progress?.isWatched != true }
    }

    /// Marks the episode **and everything before it** as watched.
    ///
    /// One after another and not concurrently: the server keeps a flag per episode,
    /// and forty requests at once over a thin line are the
    /// sure way into a timeout. Only at the end is it reloaded —
    /// a rebuild per episode would make the row twitch forty times.
    public func setPlayedIncludingEarlier(_ episode: MediaItem) async {
        for earlier in Self.precedingUnwatched(before: episode, in: episodes) {
            try? await source.setPlayed(true, for: earlier.id)
        }
        try? await source.setPlayed(true, for: episode.id)
        await reloadEpisodes()
    }

    public func setFavorite(_ isFavorite: Bool, for episode: MediaItem) async {
        try? await source.setFavorite(isFavorite, for: episode.id)
        await reloadEpisodes()
    }

    // MARK: - Images

    /// The image for the colour extraction — requested tiny, see
    /// `AccentExtractor.sourceWidth`.
    public func accentSourceURL() -> URL? {
        // With `tag`, so that `URLCache` takes effect — reasoning at ``LibraryModel``.
        let id = item.artwork.backdropID ?? item.artwork.posterID ?? item.id
        let usesBackdrop = item.artwork.backdropID != nil
        return source.imageURL(
            itemID: id,
            kind: usesBackdrop ? .backdrop : .primary,
            width: AccentExtractor.sourceWidth,
            tag: usesBackdrop ? item.artwork.backdropTag : item.artwork.posterTag
        )
    }

    // All defaults calculated from the display size, see ``ImageSizing``. Before, they
    // were numbers, and the one for the backdrop image was too small: 1920 requested for
    // a surface drawn at 3840 pixels.

    public func backdropURL(width: Int = ImageSizing.backdropWidth(points: 1920)) -> URL? {
        Self.backdropURL(for: item, from: source, width: width) ?? tmdbBackdrop
    }

    // MARK: - The same addresses, without a model in hand
    //
    // **Why these twins exist:** the image prefetch runs in the grid, that is
    // before any ``DetailModel`` exists — it knows only the title and the
    // source. Nevertheless it has to arrive at **exactly the same address in exactly the same
    // width** as the detail page later, otherwise the image lies under
    // a foreign key and the whole prefetch is silently ineffective.
    // The same trap has already caught the list prefetch once.
    //
    // The calculation therefore exists exactly once, down here; the methods above point
    // to it. A second calculation at the prefetch site would be exactly the
    // duplication that drifts apart as soon as someone changes a width.

    public nonisolated static func backdropURL(
        for item: MediaItem,
        from source: any ContentSource,
        width: Int = ImageSizing.backdropWidth(points: 1920)
    ) -> URL? {
        guard let id = item.artwork.backdropID else { return nil }
        return source.imageURL(
            itemID: id, kind: .backdrop, width: width, tag: item.artwork.backdropTag)
    }

    /// The same address as ``personURL(for:)``, without a model in hand.
    public nonisolated static func personURL(
        for person: Person,
        from source: any ContentSource,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.person)
    ) -> URL? {
        // `tag: nil` is written out here because the contract knows no default
        // for it — the source does. The same address comes out of it.
        source.imageURL(itemID: person.id, kind: .primary, width: width, tag: nil)
    }

    public nonisolated static func stillURL(
        for episode: MediaItem,
        from source: any ContentSource,
        width: Int = 840
    ) -> URL? {
        // **The IMAGE ADDRESS, not the title ID** (user finding 2026-08-22:
        // "for series where episodes are shown, the images do not render").
        //
        // `episode.id` stood here. With the media server that goes unnoticed, because
        // there both are the same — ``ItemMapping`` sets `posterID` to the
        // title's ID. A provider carries an **address** (`movie_image`) instead of an ID,
        // and it lives exclusively in the artwork.
        // The ID `xyz#episode#123` is not an address, ``imageURL`` therefore returned
        // `nil`, and every episode card stayed empty.
        //
        // The fallback to `episode.id` keeps the media server at exactly its
        // previous behaviour for episodes without an image.
        source.imageURL(
            itemID: episode.artwork.posterID ?? episode.id,
            kind: .primary, width: width, tag: nil)
    }

    public func logoURL(
        width: Int = ImageSizing.requestWidth(points: TVMetrics.logo.width, headroom: 1)
    ) -> URL? {
        guard let id = item.artwork.logoID else { return nil }
        return source.imageURL(itemID: id, kind: .logo, width: width, tag: item.artwork.logoTag)
    }

    /// The thumbnail of a chapter mark — `nil` if the server has not extracted
    /// one; the card then shows only name and time.
    ///
    /// Not `nonisolated` like its neighbours: the ID comes from ``item``,
    /// and that belongs to the main actor — and so does the call site (the view).
    public func chapterImageURL(index: Int, tag: String?, width: Int) -> URL? {
        // Chapter images exist only with the media server. `nil` means for the
        // view "draw no mark" — exactly right for a title that has
        // none.
        (source as? JellyfinSource)?
            .chapterImageURL(itemID: item.id, index: index, tag: tag, width: width)
    }

    /// Poster of a third-party title — for "Similar" and the parts of a collection.
    public nonisolated func posterURL(
        for other: MediaItem,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.poster.width)
    ) -> URL? {
        PosterAddress.url(for: other, from: source, width: width)
    }

    /// **Not `nonisolated`**, since there is a lookup: the
    /// portraits caught up are state of this model, and that belongs to the
    /// main actor.
    public func personURL(
        for person: Person,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.person)
    ) -> URL? {
        // The source leads: its image fits the title, the one caught up is
        // only the substitute for sources without their own person images.
        // A person from the TMDb cast has no image at the source — their ID
        // would be an invented address there.
        if person.id.hasPrefix("tmdb:") { return personPortraits[person.name] }
        return Self.personURL(for: person, from: source, width: width)
            ?? personPortraits[person.name]
    }

    public nonisolated func stillURL(for episode: MediaItem, width: Int = 840) -> URL? {
        Self.stillURL(for: episode, from: source, width: width)
    }
}
