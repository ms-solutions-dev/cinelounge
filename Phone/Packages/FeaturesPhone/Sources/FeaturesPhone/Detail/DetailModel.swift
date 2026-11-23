import Core
import DesignSystemPhone
import Diagnose
import Flows
import Foundation
import Observation
import ParentalControls
import Trailer

/// What the detail page shows, what it loads afterwards and what it sets.
///
/// **Three waves, not one.** First the title appears with everything the media server
/// delivers in one go; then come the external data (ratings, awards, German
/// voices); last the portraits from the film database. A page that waits for the third
/// wave would be a page that does not appear at all with the network switched off — and
/// none of the three is the precondition of the previous one.
@MainActor
@Observable
public final class DetailModel {

    public enum Situation: Sendable, Equatable {
        case isLoading
        case settled
        case disrupted(PlaybackPhase)
    }

    public private(set) var state: Situation = .isLoading
    public private(set) var content: DetailContent?

    /// Which season is open.
    ///
    /// **The one of the next step, not the first.** Whoever is at season 3 wants to see
    /// season 3; opening the first would send them back three taps
    /// every time.
    public var season: Int?

    /// Exactly one sheet at a time — **its own layer and not the wrapper's.**
    ///
    /// A sheet belongs above the screen from which it was opened. The wrapper
    /// shows its own at the root; a detail-page sheet would lie there over a view
    /// that does not know it, and would have to have its content passed across the tree.
    /// The rule "only one" still applies, because it applies per layer — and from the
    /// detail page the wrapper's is not reachable.
    public let sheetState = SheetState()

    /// The episode whose menu is open.
    public var selectedEpisode: EpisodeInfo?

    /// The person whose career is open.
    public var selectedPerson: PersonDetail?
    public private(set) var filmography: Filmography?
    public private(set) var isFilmographyLoading = false

    /// **Which career fetch applies** (check 2026-09-27, D5): tap person A, immediately
    /// person B — if A arrived later, A's career stood in B's sheet, and A's `defer`
    /// removed B's spinner. Every fetch draws a token; an older one writes nothing.
    @ObservationIgnored private var filmographyToken = 0

    /// The same token for the title profile of the career.
    @ObservationIgnored private var profileMarker = 0

    /// The upper limit with which it is delivered.
    ///
    /// **It lives on the model and not on the source**, because it is a decision of the
    /// viewer and not a property of the file. Until AP14 passes it on to the player,
    /// this page remembers it — and that is more than nothing: whoever
    /// sets it sees from the checkmark that it is set.
    public var quality: StreamQuality = .unlimited

    /// The chosen audio track. `nil` means: the server's.
    ///
    /// **Until AP58 G1 the choice stayed on this page** and never reached the player.
    /// Now it goes through ``select(audioTrack:)`` into the per-title audio choice
    /// (``Core/AudioMemory``) — the same store from which the start on both devices reads.
    public private(set) var audioTrack: String?

    /// Where the per-title audio choice lives — the person's compartment; ephemeral in the tests.
    var audioStore: any KeyValueStore = ProfileStore.playback

    /// Chooses an audio track — **and remembers its language for this title** (A10). A track
    /// without a language is shown but not remembered: in the next file you would not
    /// find it again.
    public func select(audioTrack track: AudioTrackInfo) {
        audioTrack = track.id
        guard let language = track.language, !language.isEmpty else { return }
        AudioMemory.memorize(language, identifier: identifier, series: nil, in: audioStore)
    }

    /// The track that carries this title's remembered language — for the checkmark in the sheet,
    /// as long as nothing has been chosen here yet.
    public var rememberedAudioTrack: String? {
        guard let language = AudioMemory.load(from: audioStore).language(forItem: identifier) else {
            return nil
        }
        return content?.audioTracks.first { LanguageCode.matches($0.language, language) }?.id
    }

    /// The address of the trailer, once it has been fetched.
    public private(set) var trailerURL: URL?
    public private(set) var isTrailerLoading = false
    /// What plays as the trailer (AP78): own file or YouTube, according to ``Core/TrailerRule``.
    /// Is settled as soon as the external data is there; until then only the own file counts.
    public private(set) var trailer: TrailerChoice?
    /// The YouTube key whose resolution failed — the view shows the board
    /// with the jump to the YouTube app.
    public var trailerError: String?
    /// The trailer of a foreign title from the short profile, for playing full screen.
    public var profileTrailer: TrailerPlayback?
    public private(set) var isProfileTrailerLoading = false

    public struct TrailerPlayback: Identifiable, Equatable {
        public let url: URL
        public var id: String { url.absoluteString }
    }

    /// Whether a ratings account is configured at all — for the sentence in the sheet.
    public private(set) var hasRatingAccess = false

    /// Whether AniList would be responsible but has delivered nothing.
    public private(set) var hasMuteMark = false

    /// **No longer private since 2026-09-08**: The downloads button on the detail page asks
    /// for exactly this title, and the view otherwise knows it only from the content — which
    /// for an episode page carries a different identifier than the page itself.
    private(set) var identifier: String
    private let source: (any DetailSource)?
    private let external: (any RatingSource)?
    private let people: (any CareerSource)?

    /// The rule in force — for the "already in the catalog" checkmark of the career
    /// (``CatalogIndex/index(from:rule:)``, AP58 R1).
    private let rule: ProtectionRule

    public init(
        identifier: String, source: (any DetailSource)?,
        external: (any RatingSource)? = nil, people: (any CareerSource)? = nil,
        rule: ProtectionRule
    ) {
        self.identifier = identifier
        self.source = source
        self.external = external
        self.people = people
        self.rule = rule
    }

    public var seasons: [Season] { content?.seasons ?? [] }

    /// Why a series page shows no episodes.
    ///
    /// **Measured on 2026-08-22 in the TV project: 958 of 4 974 series — 19.3 %.** At the
    /// provider iptvhost, about a fifth of the series in the panel carry **no** episode entries;
    /// "Buhin Briakloul Filmreihe" and "A Seikoca plebra Naunzoukau" were the cases where it
    /// stood out — the latter even still reports its seasons.
    ///
    /// **A series page without episodes and without a play button cannot be told apart from an
    /// app error.** No evaluator helps against that, only a sentence that says so — and the
    /// **right** one: "The provider carries none" is information about the catalog,
    /// "the fetch failed" is about the network, and the two lead to different next steps.
    ///
    /// **Taken over from the TV app** (`DetailModel.EpisodeGap`), case by case.
    public enum EpisodeGap: Equatable, Sendable {
        /// There are episodes, or they are still on their way.
        case none
        /// The fetch went through, the provider carries no episode for this title.
        case providerHasNone
        /// The fetch itself failed.
        case fetchFailed
    }

    public private(set) var episodeGap: EpisodeGap = .none

    public var openSeason: Season? {
        seasons.first { $0.id == season } ?? seasons.first
    }

    /// Whether the career can be opened at all.
    public var isFilmographyReachable: Bool { people?.entered ?? false }

    /// What the main button says.
    ///
    /// **The stem is remembered, not the whole sentence** — "Play episode 5" and "Play episode 5
    /// on the TV" are the same button with a different target. Whoever kept two sentences
    /// would have three at the third target.
    public var buttonStem: String? {
        guard let next = content?.next else { return nil }
        // **The position only for a series** — finding of 2026-09-05: On *Bringrarn Piosiaspeit Slausnonspel*
        // it said "1997 continue watching". The second line of a tile is "S1 E35" for an
        // episode and the **release year** for a film; inserting it unchecked as the position
        // turned the year into a place.
        let location = content?.isSeries == true ? next.beside : nil
        if let location, next.progress != nil {
            return AppLanguageSetting.text("action.continueAt \(location)")
        }
        if let location {
            return AppLanguageSetting.text("action.playAt \(location)")
        }
        // A started film is called "Continue Watching" — without a position, because the minute
        // is in the progress bar and not on the button.
        if next.progress != nil {
            return AppLanguageSetting.text("home.continueWatching")
        }
        return AppLanguageSetting.text("common.play")
    }

    /// The full label — stem plus target, if it is not this device.
    ///
    /// **The target appears only when it is surprising.** "Play episode 5" on the device
    /// you hold in your hand needs no addition; "on the TV" does, because
    /// a picture starts in another room right away.
    ///
    /// **The target comes in and does not live on the model** (2026-09-12). It applies to the
    /// app and not to a title — that is how it stands in ``HeaderRow`` since 2026-09-06, and
    /// until then this page still kept its own.
    public func buttonLabel(target: PlaybackDestination) -> String? {
        guard let stem = buttonStem else { return nil }
        guard target == .tv else { return stem }
        return AppLanguageSetting.text("action.onAppleTV \(stem)")
    }

    public func load() async {
        guard let source else {
            state = .disrupted(.notSetUpYet)
            return
        }
        do {
            let fetched = try await source.detailInfo(zu: identifier)
            content = fetched
            trailer = fetched.trailerFile.map { .file(language: $0.language) }
            // **The gap is determined here and not in the view body.** Whether
            // a series has episodes is decided at load time — the view would see
            // the same empty list for a failed fetch and for a provider
            // that carries none, and could never tell the two apart.
            episodeGap =
                fetched.isSeries && fetched.seasons.allSatisfy(\.episodes.isEmpty)
                ? .providerHasNone : .none
            defer { Task { await openFirstPerson() } }
            // Open the season of the next step — if none is set, the first.
            season =
                fetched.seasons.first(where: { season in
                    season.episodes.contains { $0.id == fetched.next?.id }
                })?.id ?? fetched.seasons.first?.id
            state = .settled
            Diagnose.step(
                .network,
                "Detail page: \(fetched.seasons.count) seasons, "
                    + "\(fetched.cast.count) people, \(fetched.chapters.count) chapters, "
                    + "\(fetched.similar.count) similar")
        } catch {
            Diagnose.error(.network, "Detail page not loaded", error)
            episodeGap = .fetchFailed
            // **The catch-all error now names the right source.**
            //
            // **Finding of 2026-09-06, seen on the device by the client:** A portal title
            // and a provider title both opened "No answer from the media server — is
            // the server running, and is it on the same network?". Both servers were running, and neither
            // of them was asked. The sentence thus sent people in the wrong direction, and
            // on **every** failure of this page.
            //
            // The same interpretation as in the player (``DisruptionInterpretation``, since E25) and
            // the same switch as in ``AggregateDetailSource``: decided by the identifier,
            // not by trial and error.
            state = .disrupted(
                DisruptionInterpretation.state(
                    forItem: error, origin: PlaybackJob.origin(zu: identifier)))
            return
        }
        await fetchExternalInfo()
        await fetchPortraits()
    }

    /// Ratings, awards and voices — **delivered afterwards, never awaited.**
    private func fetchExternalInfo() async {
        guard let external, let state = content else { return }
        async let choice = external.trailer(zu: state.title.identifier, file: state.trailerFile)
        let info = await external.info(zu: state.title.identifier)
        trailer = await choice
        hasRatingAccess = info.isAccessConfigured
        award = info.award
        // **A service that delivers nothing although it would be responsible is named.**
        // On 2026-09-05 the AniList number was missing on every anime, and on screen it was
        // impossible to tell whether the title is not carried there or whether the service
        // is simply not answering. It was the latter: the interface has reported
        // HTTP 403 ("temporarily disabled due to severe stability issues") since that
        // morning. Since AP68 the same applies to MyAnimeList: if the mapping knows the title and MAL
        // does not answer, the absence is a fault (``ExternalInfo/hasMuteMark``).
        hasMuteMark = info.hasMuteMark
        guard info.hasContent || !info.voices.isEmpty else { return }
        content = state.using(info)
    }

    /// The award sits next to the ratings and therefore belongs here, not in the
    /// content: it comes from outside and is not information from the media server.
    public private(set) var award: Accolade?

    /// Faces, **only where the server carries none.**
    ///
    /// Its image matches the title; the fetched one is a name search and can miss on
    /// identical names. Whoever fetched both would pay for a third-party query for
    /// the worse image.
    private func fetchPortraits() async {
        guard let people, let state = content else { return }
        let withoutImage = state.cast.filter { $0.image == nil }.map(\.name)
        guard !withoutImage.isEmpty else { return }
        let found = await people.portraits(zu: withoutImage)
        guard !found.isEmpty, let now = content else { return }
        content = now.using(portraits: found)
    }

    // MARK: - Marken setzen

    /// **First on screen, then at the server — and back if it does not cooperate.**
    ///
    /// A checkmark that waits half a second for the answer feels broken. A
    /// checkmark that stays on an error is worse: it claims a state the
    /// server does not have, and the next time it is opened it is gone again —
    /// without anyone learning why.
    public func setEnabled(seen: Bool) async {
        guard var state = content, let source else { return }
        let previous = state.seen
        state.seen = seen
        content = state
        do {
            try await source.set(seen: seen, forItem: identifier)
        } catch {
            Diagnose.error(.network, "Watched mark not set", error)
            state.seen = previous
            content = state
        }
    }

    /// Toggle the favorite mark — ``Flows/MarkToggle``, the same toggle as on the
    /// TV: first the display, then the service, back on error.
    public func setEnabled(favorite: Bool) async {
        guard let previous = content?.favorite, let source else { return }
        let identifier = self.identifier
        let rejected = await MarkToggle.setEnabled(
            to: favorite, previous: previous, show: { self.content?.favorite = $0 }
        ) {
            try await source.set(favorite: favorite, forItem: identifier)
        }
        if let rejected { Diagnose.error(.network, "Favorite mark not set", rejected) }
    }

    public func set(episode: EpisodeInfo, seen: Bool) async {
        await set(episodes: [episode.id], seen: seen)
    }

    /// The episodes **before** this one, as far as they are still open.
    ///
    /// **Only when setting, never when undoing** — whoever marks an episode as unwatched
    /// means that one. The follow-up question therefore does not arise at all when nothing
    /// comes back here.
    ///
    /// Across all seasons before and not only the open one: whoever starts at season 3
    /// episode 1 has watched seasons 1 and 2 — exactly the case in which the
    /// question is worth something.
    public func openPrior(_ episode: EpisodeInfo) -> [EpisodeInfo] {
        var before: [EpisodeInfo] = []
        for season in seasons {
            for entry in season.episodes {
                if entry.id == episode.id { return before.filter { !$0.seen } }
                before.append(entry)
            }
        }
        return []
    }

    public func setPrior(_ episode: EpisodeInfo) async {
        let identifiers = openPrior(episode).map(\.id) + [episode.id]
        await set(episodes: identifiers, seen: true)
    }

    private func set(episodes identifiers: [String], seen: Bool) async {
        guard let source, let state = content else { return }
        let affected = Set(identifiers)
        content = Self.withMarks(state, seen: seen, on: affected)
        for single in identifiers {
            do {
                try await source.set(seen: seen, forItem: single)
            } catch {
                Diagnose.error(.network, "Episode mark not set", error)
                // The whole move is undone and not the one episode: a half-set
                // batch is the state nobody expects — and that nobody
                // can undo either, because it is not visible.
                content = state
                return
            }
        }
    }

    /// Sets the mark on the named episodes — **testable outside the model.**
    nonisolated static func withMarks(
        _ state: DetailContent, seen: Bool, on identifiers: Set<String>
    ) -> DetailContent {
        let incoming = state.seasons.map { season in
            Season(
                id: season.id, name: season.name, description: season.description,
                episodes: season.episodes.map { episode in
                    guard identifiers.contains(episode.id) else { return episode }
                    var changed = episode
                    changed.seen = seen
                    return changed
                })
        }
        var new = DetailContent(
            title: state.title, isSeries: state.isSeries, seasons: incoming,
            next: state.next, sources: state.sources, cast: state.cast,
            chapters: state.chapters, similar: state.similar, split: state.split,
            details: state.details, trailerFile: state.trailerFile, watchDuration: state.watchDuration)
        new.seen = state.seen
        new.favorite = state.favorite
        return new
    }

    // MARK: - Trailer und Laufbahn

    /// Fetches the trailer address — **only on press**, see ``JellyfinDetailSource``.
    ///
    /// For YouTube (AP78) the device resolves it itself (``Trailer/TrailerResolution``);
    /// if that fails, the board appears with the jump to the YouTube app.
    public func fetchTrailer() async {
        guard trailerURL == nil, !isTrailerLoading, let trailer else { return }
        isTrailerLoading = true
        defer { isTrailerLoading = false }
        switch trailer {
        case .file:
            guard let source else { return }
            do {
                trailerURL = try await source.previewURL(zu: identifier)
            } catch {
                Diagnose.hint(.network, "Trailer not fetched", error)
            }
        case .youtube(let id, _):
            do {
                trailerURL = try await TrailerResolution.address(youtubeID: id).url
            } catch {
                Diagnose.hint(.network, "Trailer not resolved", error)
                trailerError = id
            }
        }
    }

    /// The trailer from the short profile of a foreign title — full screen, because the sheet has
    /// no header image that it could replace.
    public func fetchProfileTrailer() async {
        guard case .youtube(let id, _) = profile?.trailer, !isProfileTrailerLoading else { return }
        isProfileTrailerLoading = true
        defer { isProfileTrailerLoading = false }
        do {
            profileTrailer = TrailerPlayback(url: try await TrailerResolution.address(youtubeID: id).url)
        } catch {
            Diagnose.hint(.network, "Trailer not resolved", error)
            trailerError = id
        }
    }

    /// Ends the trailer and restores the header image.
    public func endTrailer() {
        trailerURL = nil
    }

    /// Opens the career of the first cast person — **only as a check hook.**
    ///
    /// **`CINELOUNGE_BLATT=filmography` alone is not enough**, and that was noticed on 2026-09-08:
    /// the sheet only draws when a person is **chosen**, and one is chosen by a press on
    /// their circle. `simctl` cannot send one — the check hook therefore ended up in the
    /// developer placeholder, and the screen remained unseen. The same gap as with the
    /// player, which `CINELOUNGE_SPIELER` closed.
    func openFirstPerson() async {
        guard ProcessInfo.processInfo.environment["CINELOUNGE_BLATT"] == "laufbahn",
            let first = content?.cast.first
        else { return }
        await openFilmography(first)
    }

    /// The title the profile sheet is currently talking about.
    public private(set) var profileTitle = ""
    public private(set) var profile: TitleProfile?
    public private(set) var isProfileLoading = false

    /// **What you have opens; what you do not have explains itself.**
    ///
    /// The switch lives here and not in the row: whether a title is in the own catalog
    /// is decided by `libraryItemID`, and the row should not ask the question a second
    /// time.
    public func tapFilmography(
        _ entry: FilmographyEntry, open: (String) -> Void
    ) async {
        if let identifier = entry.libraryItemID {
            sheetState.close()
            open(identifier)
            return
        }
        profileTitle = entry.title
        profile = nil
        profileMarker &+= 1
        let tag = profileMarker
        sheetState.open(.titleProfile)
        guard let people else { return }
        isProfileLoading = true
        defer { if tag == profileMarker { isProfileLoading = false } }
        let fetched = await people.profile(zu: entry)
        guard tag == profileMarker else { return }
        profile = fetched
    }

    /// **The catalog is fetched alongside, not afterwards.**
    ///
    /// The career comes from the film database, the comparison from the media server; neither
    /// of the two paths is the precondition of the other. Called one after the other, the
    /// wait would be the **sum** instead of the longer one — and the catalog is already
    /// collected by the second opening anyway (``CatalogIndex``).
    ///
    /// **Marking happens only afterwards, in one move.** The row reads `libraryItemID`, and
    /// a sheet that stands there first without and a blink later with a checkmark would look
    /// as if the catalog had changed.
    public func openFilmography(_ person: PersonDetail) async {
        selectedPerson = person
        filmography = nil
        filmographyToken &+= 1
        let tag = filmographyToken
        sheetState.open(.filmography)
        guard let people else { return }
        isFilmographyLoading = true
        defer { if tag == filmographyToken { isFilmographyLoading = false } }

        let catalog = SourceAssembly.jellyfin()
        async let fetched = people.filmography(zu: person.name)
        async let own = CatalogIndex.shared.index(from: catalog, rule: rule)

        guard var found = await fetched else {
            _ = await own
            if tag == filmographyToken { filmography = nil }
            return
        }
        let index = await own
        guard tag == filmographyToken else { return }
        found.movies = CatalogIndex.mark(found.movies, against: index)
        found.series = CatalogIndex.mark(found.series, against: index)
        filmography = found
        // **Four reasons, one picture** (finding of 2026-09-12, from the client: "content that
        // already exists on Jellyfin is not marked here"). A missing checkmark means: no
        // media server set up, the catalog could not be fetched, the title really is not in the
        // house — or the comparison by title and year did not match. From the outside all four
        // look the same, and only two of them are errors. The row says which one it was.
        let matched =
            found.movies.filter(\.isInLibrary).count
            + found.series.filter(\.isInLibrary).count
        Diagnose.step(
            .network,
            "Career \(person.name): \(found.movies.count) movies, \(found.series.count) series; "
                + "own catalog \(index.isEmpty ? "empty or not fetched" : "present"); "
                + "marked \(matched)")
    }
}
