import Core
import DesignSystemPhone
import Downloads
import Flows
import ParentalControls
import SwiftUI

/// The detail page of a title.
///
/// **In content it matches the TV state** — ratings, cast with German voices, chapters,
/// similar titles, parts of the series, season description and the fact list.
/// The requirement of 2026-09-05 was clear: many points did not match, and the phone page
/// must follow the tvOS state in content. A stripped-down detail page is the point at
/// which the phone looks like a second device.
///
/// **The order is not the TV's.** There the cast stands far down, because focus jumps
/// there in a fraction of a second; here you have to swipe for it. What answers the
/// question "should I watch this now" therefore stands at the top: title, ratings,
/// synopsis, then the episodes. What you **look up** — cast, similar titles, facts —
/// stands below.
///
/// **The main button names the next step, not the title.** "Continue episode 5" instead
/// of "Play": whoever stopped at episode 4 does not want to know that the series
/// exists — they want to know where it continues.
public struct DetailView: View {

    @State private var model: DetailModel
    /// What is played — **and what this page is called.**
    ///
    /// **The second value is the name of the page and not that of the tile** (finding of
    /// 2026-09-07). When a series page plays its third episode, the tile is called "3 - Der Fall"
    /// and the page "Bloufeit"; only here are both known at the same time. The history records
    /// the series name along with it, and "Continue Watching" labels the tile with it — otherwise
    /// the episode would stand above a tile that opens the series. See
    /// ``PlaybackJob/seriesTitle``.
    ///
    /// **Empty means "no series above it".** On a film or episode page, page
    /// and tile are the same; ``TabPlaceholder/series(forItem:)`` recognizes this by comparing the
    /// identifiers and then discards both.
    /// **The page keeps it too, not just the model.** Since 2026-09-09 the shelves below the page
    /// carry the same long press as those of the Home screen, and their
    /// commands need exactly this source — it decides by identifier who is asked
    /// (``AggregateDetailSource``).
    private let source: (any DetailSource)?
    private let play: (TileContent, String) -> Void
    private let playFrom: (TileContent, TimeInterval, String) -> Void
    private let open: (TileContent) -> Void
    private let back: () -> Void

    /// How a title stands in the downloads.
    ///
    /// **As a function and not a value.** The page asks for the title, for each episode
    /// and for the season — three different identifiers, one place to answer. A
    /// passed-in value would be the title's and wrong for the episodes.
    private let downloadState: (String) -> DownloadState?
    /// What happens when the button is pressed.
    ///
    /// **A ``DownloadRequest`` and not an identifier.** The scope comes from the trigger, and the
    /// trigger is this page: on the title it is the film or the open season, on the
    /// episode row the episode. The switch above it would not know that and, until 2026-09-08,
    /// built a film out of every press.
    private let onDownloadsTap: (DownloadRequest) -> Void
    /// What happens when "Add to downloads" is pressed in the sheet.
    private let queueDownload: (DownloadJob, DownloadRequest, Bool) -> Void
    /// Whether "Add more" is offered in the download sheet — see ``DownloadSheet/offersTopUp``.
    private let offersTopUp: Bool
    /// Where the download sheet gets hosts and language versions — set only for portals.
    private let hostSource: (@Sendable (String) async throws -> PortalSourceChoice)?

    /// Where "Language of this series" comes from — **new on the phone** (AP58 G1, A9), the same
    /// flow as on the TV (``Flows/SeriesLanguageFlow``). Shown only for a
    /// series of a portal.
    private let languageSource: (any PortalContentSource)?
    @State private var languageChoice: SeriesLanguageFlow?
    @State private var isLanguageChoiceOpen = false

    /// The request that the download sheet is currently deciding.
    @State private var downloadRequest: DownloadRequest?

    /// The size class — **it says whether the header block stands in the header or below it.**
    ///
    /// It is decided not here but at ``HeaderSpaceMetrics/hasColumn(_:)``: the header
    /// asks the same place, and only that way do both flip at the same time.
    @Environment(\.horizontalSizeClass) private var width

    /// How tall the header was last drawn — **for the trailer that replaces it.**
    ///
    /// In regular the header no longer has a fixed height; a trailer in its place must have
    /// the same one, otherwise the page jumps at start. It is measured at the header and not
    /// at the trailer: while the trailer plays, the header is not there, and the last
    /// measured value is exactly the height it will take again shortly. See
    /// ``HeaderSpaceMetrics/trailerHeight(_:measured:)``.
    @State private var headerHeight: CGFloat?
    /// Spoiler protection of the profile (AP85) — read once per page.
    @State private var guardsSpoilers = BingePreferences.load(from: ProfileStore.playback).hidesSpoilers

    /// Where it plays — **from outside and not from here.**
    ///
    /// ``HeaderRow`` has said it literally since 2026-09-06: *"The playback target belongs
    /// there and not on a title. It applies to the app and not to a film."*
    /// Until 2026-09-12 the source had both answers at the same time — a
    /// ``DetailModel/target`` per page that nobody else saw, and next to it a sheet with
    /// `isTVReachable: false`. Now the page only passes the target **on**, it does not
    /// hold it.
    private let target: PlaybackDestination
    private let onTargetTap: () -> Void

    public init(
        identifier: String,
        source: (any DetailSource)?,
        external: (any RatingSource)? = nil,
        people: (any CareerSource)? = nil,
        rule: ProtectionRule,
        play: @escaping (TileContent, String) -> Void = { _, _ in },
        playFrom: @escaping (TileContent, TimeInterval, String) -> Void = { _, _, _ in },
        open: @escaping (TileContent) -> Void = { _ in },
        back: @escaping () -> Void = {},
        downloadState: @escaping (String) -> DownloadState? = { _ in nil },
        onDownloadsTap: @escaping (DownloadRequest) -> Void = { _ in },
        queueDownload: @escaping (DownloadJob, DownloadRequest, Bool) -> Void = { _, _, _ in },
        offersTopUp: Bool = false,
        hostSource: (@Sendable (String) async throws -> PortalSourceChoice)? = nil,
        languageSource: (any PortalContentSource)? = nil,
        target: PlaybackDestination = .phone,
        onTargetTap: @escaping () -> Void = {}
    ) {
        _model = State(
            initialValue: DetailModel(
                identifier: identifier, source: source, external: external, people: people,
                rule: rule))
        self.source = source
        self.play = play
        self.playFrom = playFrom
        self.open = open
        self.back = back
        self.downloadState = downloadState
        self.onDownloadsTap = onDownloadsTap
        self.queueDownload = queueDownload
        self.offersTopUp = offersTopUp
        self.hostSource = hostSource
        self.languageSource = languageSource
        self.target = target
        self.onTargetTap = onTargetTap
    }

    /// Builds the language choice — **only for a series of a portal**, and fetches the remembered
    /// choice right away: it is cheap, the list is not.
    private func setUpLanguageChoice() async {
        guard languageChoice == nil, model.content?.isSeries == true, let languageSource,
            PlaybackJob.origin(zu: model.identifier) == .portals
        else { return }
        let identifier = model.identifier
        let choice = SeriesLanguageFlow(
            routes: SeriesLanguageFlow.Routes(
                read: { try await languageSource.language(zu: identifier) },
                list: { try await languageSource.languages(zu: identifier) },
                set: { try await languageSource.select(language: $0, forItem: identifier) }))
        languageChoice = choice
        await choice.loadLanguage()
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ColorRole.reason.color.ignoresSafeArea()

            switch model.state {
            case .isLoading:
                LoadingState(forItem: .loadingStart)
            case .disrupted(let state):
                // The same dead button as on the Home screen — see ``StartView``.
                StateView(state: state, action: { Task { await model.load() } })
            case .settled:
                if let content = model.content {
                    page(content)
                    // **Here the floating bar is right** — unlike on the
                    // Home screen. There it stayed put while the box above it
                    // kept paging, and nobody could say what it plays. A
                    // detail page has exactly **one** main thing, and the button for it
                    // belongs under the thumb: under the synopsis it would sit somewhere depending on
                    // the text length, mostly outside the picture.
                    if let caption = model.buttonLabel(target: target), let next = content.next {
                        floatingBar(caption: caption, next: next)
                    }
                }
            }
        }
        .task { await model.load() }
        .task(id: model.content?.isSeries) { await setUpLanguageChoice() }
        .trailerErrorBoard($model.trailerError)
        // The trailer of a foreign title from the short profile (AP78) — full screen, because the
        // sheet has no header image that it could replace.
        .trailerFullscreen($model.profileTrailer)
        .confirmationDialog(
            Text(app: "detail.languageTitle"), isPresented: $isLanguageChoiceOpen,
            titleVisibility: .visible
        ) {
            if let languageChoice {
                ForEach(languageChoice.languages, id: \.self) { word in
                    Button {
                        Task { await languageChoice.select(word) }
                    } label: {
                        Text(verbatim: word)
                    }
                }
                // **"No preference" is a choice of its own** — without it nobody would get back
                // to "take what works".
                if !languageChoice.language.isEmpty {
                    Button {
                        Task { await languageChoice.select("") }
                    } label: {
                        Text(app: "detail.languageAny")
                    }
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(app: languageChoice?.isLoading == true ? "detail.languageLoading" : "detail.languageHint")
        }
        // **The system navigation bar stays away.** It laid its own
        // "‹ Back" button over the round one in the header image — two ways back on top of each other,
        // one of them half hidden. The header space carries its own, because it has to lie
        // over the image and not above it.
        .withoutNavigationBar()
        .withSwipeBack()
        .sheet(model.sheetState) { identifier in sheetContent(identifier) }
    }

    // MARK: - The page

    /// **The scope on the title depends on what kind of thing the page shows.**
    ///
    /// A film is a film. For a series the button on the title is the **open
    /// season** and not "everything" — the design says so, and it is the amount
    /// that someone standing on a season page means. "Everything unwatched" exists, but
    /// as a choice in the sheet and not as the default: it can span two seasons and
    /// be eight times as large.
    /// **The first press asks, every further one does not.**
    ///
    /// Whoever has not added anything yet gets the sheet: scope, quality level or host
    /// and language version are decisions made only once and not changeable afterwards.
    /// If something is already running, a sheet would be a question about a decision that
    /// has long been made — then the press means what it shows:
    /// pause or resume.
    private func submitDownloadRequest(_ request: DownloadRequest) {
        if downloadState(request.identifier) == .notQueued {
            downloadRequest = request
            model.sheetState.open(.load)
        } else {
            onDownloadsTap(request)
        }
    }

    /// The identifier under which a **whole season** lies in the downloads.
    ///
    /// **It is not that of an episode**, and it has to come from the page: the downloads
    /// carry a season as **one** row, and a row needs an identifier. Without its
    /// own, the season would sit under the identifier of its first episode — and a press on
    /// the episode would afterwards show the season as added.
    private func seasonID(_ season: Season) -> String {
        DownloadDescriber.seasonID(series: model.identifier, season: season.id)
    }

    /// How long a **single** episode of this season runs.
    ///
    /// **Per episode and not per season** — ``Downloads/DownloadJob/runtime`` is meant that way,
    /// and ``DownloadChoice`` multiplies it by the episode count. Whoever put the sum in
    /// here would get the season squared.
    ///
    /// **The mean and not the first episode.** Pilot episodes are regularly longer,
    /// and a season size that hangs on the exception is too large throughout.
    /// **`nil` if not a single episode carries a runtime** — for the portals that is
    /// the normal case (measured at the bridge, 2026-09-09), and then the sheet shows no number
    /// instead of an invented one.
    private func runtimePerEpisode(_ season: Season) -> TimeInterval? {
        let known = season.episodes.compactMap(\.duration)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    private func request(forItem season: Season) -> DownloadRequest {
        DownloadRequest(
            identifier: seasonID(season), title: model.content?.title.tile.title ?? "",
            beside: season.label,
            extent: .season(number: season.id, episodes: season.episodes.count),
            source: sourceKind, runtime: runtimePerEpisode(season), series: model.identifier)
    }

    private func request(forItem episode: EpisodeInfo, in season: Season) -> DownloadRequest {
        DownloadRequest(
            identifier: episode.id, title: episode.title,
            beside: model.content?.title.tile.title,
            extent: .episode(season: season.id, number: episode.number ?? 0),
            source: sourceKind, runtime: episode.duration, series: model.identifier)
    }

    private func request(forItem content: DetailContent) -> DownloadRequest {
        let extent: Extent
        if content.isSeries, let season = model.openSeason {
            extent = .season(number: season.id, episodes: season.episodes.count)
        } else {
            extent = .film
        }
        return DownloadRequest(
            identifier: model.identifier, title: content.title.tile.title,
            beside: content.title.tile.beside,
            extent: extent, source: sourceKind,
            // **For a film its own runtime, for a series that of one episode.** The
            // scope above already says which case applies; the runtime must match it,
            // otherwise ``DownloadChoice`` computes a season from a film length.
            runtime: content.isSeries
                ? model.openSeason.flatMap(runtimePerEpisode) : content.title.tile.duration,
            // **The series here is the title itself** — this page *is* the series. For
            // a film the slot stays empty: there is nothing to add more of.
            series: content.isSeries ? model.identifier : nil)
    }

    /// The download request for a **foreign** tile — from the long press in the shelves
    /// "Parts of the series" and "Similar".
    ///
    /// **The scope here is ``Extent/film`` and cannot be anything else.** A tile
    /// does not say whether it means a film or a series: ``TileContent`` carries image,
    /// caption and state, but no kind — and the season and episode counts of a
    /// foreign series are unknown to this page anyway. Fetching them just so that a
    /// menu entry can appear would be one query per shelf tile.
    ///
    /// **That is not a wrong statement but a narrower one.** The sheet names the title it
    /// decides about, and whoever needs the season choice opens the tile — there
    /// is the downloads button, which knows the open season (``request(forItem:)`` on
    /// ``DetailContent``). The long press is the shortcut for the normal case and not
    /// its replacement.
    ///
    /// **And the origin comes from the same rule as the switch** — see
    /// ``sourceKind``. A similar title can come from a different source than the page
    /// it appears on; therefore its own identifier is asked and not the page's.
    private func request(forItem tile: TileContent) -> DownloadRequest {
        DownloadRequest(
            identifier: tile.id, title: tile.title, beside: tile.beside, extent: .film,
            source: SourceKind(AggregateDetailSource.origin(tile.id)) ?? .jellyfin)
    }

    /// **Where the title comes from — by the same rule as the switch.**
    ///
    /// `AggregateDetailSource.origin(_:)` reads it from the identifier; by exactly that
    /// it also decides which detail source answers. Guessing again here would mean having two
    /// answers to the same question — and the wrong one would show a portal title
    /// resolution levels that do not exist there.
    ///
    /// **There is no `nil` here**, because a detail page never belongs to a channel: the
    /// rule knows three outcomes, and all three may load.
    private var sourceKind: SourceKind {
        SourceKind(AggregateDetailSource.origin(model.identifier)) ?? .jellyfin
    }

    private func page(_ content: DetailContent) -> some View {
        ScrollSurface(bottomClearance: Metrics.aboveFloatingBar, edgelessTop: true) {
            VStack(alignment: .leading, spacing: 0) {
                header(content)

                // **In regular the header block stands in the header, next to the poster** (AP7,
                // 2026-09-24) — ``HeaderSpace`` draws it there, and here it drops out.
                // The same switch as in the header, otherwise the title would appear twice or not
                // at all.
                if !HeaderSpaceMetrics.hasColumn(width) {
                    headerBlock(content)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, MetricsBoard.phone.gutter)
                }

                if content.isSeries {
                    if model.episodeGap == .none {
                        episodes.padding(.top, MetricsBoard.phone.section)
                    } else {
                        // **A sentence instead of a blank** (E62). A series page without
                        // episodes and without a play button cannot be told apart from an app
                        // error — and with this provider it is none:
                        // about a fifth of its series carries no episode entries
                        // in the panel (measured 958 of 4,974).
                        //
                        // **Two sentences and not one.** "The provider carries none" is
                        // information about the catalog, "the fetch failed" is about
                        // the network; they lead to different next steps, and
                        // a shared sentence would be wrong for one of the two cases.
                        Text(
                            appKey: model.episodeGap == .fetchFailed
                                ? "detail.episodesUnreachable" : "detail.noEpisodes"
                        )
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                        // An explanatory sentence is running text too — and this one stands alone on
                        // an otherwise empty page, where a 992-point-long line is the most
                        // conspicuous.
                        .readingColumn()
                        .padding(.top, MetricsBoard.phone.section)
                    }
                }

                ChapterRow(chapters: content.chapters) { location in
                    guard let next = content.next else { return }
                    playFrom(next, location, pageTitle)
                }
                .padding(.top, MetricsBoard.phone.section)

                CastBlock(
                    cast: content.cast,
                    openPerson: model.isFilmographyReachable
                        ? { person in Task { await model.openFilmography(person) } } : nil,
                    showAll: { model.sheetState.open(.cast) })

                SimilarShelf(
                    title: "detail.parts", tiles: content.split, open: open,
                    commandSource: source, downloadState: downloadState,
                    load: { tile in submitDownloadRequest(request(forItem: tile)) },
                    following: { Task { await model.load() } })
                SimilarShelf(
                    title: "detail.similar", tiles: content.similar, open: open,
                    commandSource: source, downloadState: downloadState,
                    load: { tile in submitDownloadRequest(request(forItem: tile)) },
                    following: { Task { await model.load() } })

                AboutTheTitle(details: content.details)
            }
            .padding(.bottom, Metrics.bottomInsetWithBar)
            .containerRelativeFrame(.horizontal)
        }
    }

    /// Title, ratings, buttons, synopsis — **the block that answers the question "should I watch
    /// this now".**
    ///
    /// **One function and not two places**, because depending on the size class it
    /// stands in two locations: in compact below the header, in regular as a column **in** the
    /// ``HeaderSpace``.
    ///
    /// **Without a reading cap** (AP7, step 4). Until 2026-09-24 `.readingColumn()` lay here
    /// — right as long as the block below the header ran across the full width.
    /// In regular it now stands in a column of ``MetricClass/detailColumn(_:)``
    /// = 520 points, narrower than the cap at 720; in compact the device was narrower
    /// anyway. The cap would have had no effect anywhere, and its justification would have been
    /// wrong.
    private func headerBlock(_ content: DetailContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            titleLine(content)

            HStack(alignment: .center, spacing: Metrics.targetSpacing) {
                MetaRow(split: content.title.attributes)
                Spacer(minLength: 0)
            }

            if let watchDuration = content.watchDuration {
                WatchDurationRow(estimate: watchDuration)
            }

            RatingBadgeStrip(
                ratings: content.title.ratings,
                award: model.award,
                hasMuteMark: model.hasMuteMark
            ) {
                model.sheetState.open(.ratings)
            }

            HeaderButtonRow(
                seen: content.seen,
                favorite: content.favorite,
                trailer: model.trailer,
                hasSourceChoice: !content.sources.isEmpty,
                downloadState: downloadState(model.identifier),
                toggleWatched: { Task { await model.setEnabled(seen: !content.seen) } },
                toggleFavorite: { Task { await model.setEnabled(favorite: !content.favorite) } },
                onDownloadsTap: { submitDownloadRequest(request(forItem: content)) },
                showTrailer: { Task { await model.fetchTrailer() } },
                showSources: { model.sheetState.open(.sources) },
                showMenu: { model.sheetState.open(.titleMenu) }
            )
            .padding(.top, 2)

            if let languageChoice, content.isSeries {
                DisclosureRow(
                    title: "detail.languageTitle", icon: Glyph.language.name,
                    value: languageChoice.language.isEmpty
                        ? AppLanguageSetting.text("detail.languageAny") : languageChoice.language,
                    isContained: true
                ) {
                    isLanguageChoiceOpen = true
                    Task { await languageChoice.loadLanguages() }
                }
            }

            if let description = content.title.description, !description.isEmpty {
                ExpandableText(text: description)
            }
        }
    }

    /// Header image — or the trailer in its place.
    @ViewBuilder
    private func header(_ content: DetailContent) -> some View {
        if let address = model.trailerURL {
            ZStack(alignment: .top) {
                HeaderTrailer(address: address) { model.endTrailer() }
                    // **The same case distinction as the header** (AP7, step 3): In
                    // regular it is as tall as its content, and a trailer with a fixed
                    // height would pull the page together at start.
                    .frame(height: HeaderSpaceMetrics.trailerHeight(width, measured: headerHeight))
                    .clipped()
                HStack {
                    Button {
                        model.endTrailer()
                    } label: {
                        Image(systemName: Glyph.close.name)
                    }
                    .buttonStyle(.rounded)
                    .accessibilityLabel(Text(app: "common.done"))
                    Spacer()
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.top, 52)
            }
            // **Scrolling away ends it.** That is the gesture that takes the place of resting
            // focus here: whoever keeps scrolling no longer sees it — and a film that
            // keeps playing where nobody looks is compute time and bandwidth for
            // nothing.
            .onScrollVisibilityChange(threshold: 0.2) { isVisible in
                if !isVisible { model.endTrailer() }
            }
        } else {
            // **In regular the header carries the block, and the trailer replaces both.**
            // Title and buttons then disappear for the duration of the trailer — unlike in
            // compact, where they stay below. That is the price for the page
            // not jumping: a trailer next to the column would be 160 points wide, one
            // behind it would lie under text.
            HeaderSpace(content: content.title, back: back) {
                headerBlock(content)
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                headerHeight = $0
            }
        }
    }

    /// The wordmark — or the title, if the server carries none.
    ///
    /// **On the detail page the title must not be truncated.** It is the subject
    /// of the page; ``Wordmark`` truncates its text fallback to two lines because it stands in the
    /// paging header area of the Home screen. Here nobody pages.
    /// What this page is called — empty as long as it has not loaded anything.
    ///
    /// **The name of the page and not that of the tile currently playing.** For a series
    /// that is the series name; for a film and an episode page it is the same as
    /// that of the tile, and there ``TabPlaceholder/series(forItem:)`` discards both.
    private var pageTitle: String {
        model.content?.title.tile.title ?? ""
    }

    @ViewBuilder
    private func titleLine(_ content: DetailContent) -> some View {
        if content.title.logo != nil {
            Wordmark(image: content.title.logo, title: content.title.tile.title)
        } else {
            PlaceholderTitle(title: content.title.tile.title)
        }
    }

    private func floatingBar(caption: String, next: TileContent) -> some View {
        FloatingBar {
            Button {
                play(next, pageTitle)
            } label: {
                Label {
                    Text(verbatim: caption)
                } icon: {
                    Image(systemName: Glyph.play.name)
                }
            }
            .buttonStyle(.loud)
            // **The one main button of this page** — and that is why the cap sits here and
            // not in the style; the reasoning is at ``PrimaryButtonWidth``. Without it the
            // bar was 945 points wide on an iPad Pro 13″.
            .primaryButtonWidth()

            // **The target stands next to the button and not in it.** "Play on the TV"
            // would be a button that does two things; here you choose the target and
            // then play — two taps for two decisions.
            Button(action: onTargetTap) {
                Image(systemName: target.icon)
            }
            .buttonStyle(.rounded)
            .accessibilityLabel(Text(app: "action.target"))
        }
    }

    @ViewBuilder
    private var episodes: some View {
        VStack(alignment: .leading, spacing: 0) {
            SeasonBlock(
                seasons: model.seasons, pending: model.openSeason,
                select: { model.sheetState.open(.season) },
                downloadState: model.openSeason.flatMap { downloadState(seasonID($0)) },
                onDownloadsTap: {
                    if let season = model.openSeason {
                        submitDownloadRequest(request(forItem: season))
                    }
                })

            if let season = model.openSeason {
                // **Lazy and not all at once.** Seen on screen: with a
                // series of fifty episodes the still frames stayed empty. A `VStack`
                // builds every row immediately, and so fifty image requests went out
                // at the same time — through a tunnel that carries 0.3 Mbit/s. The
                // `LazyVStack` only asks for what is in view.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(season.episodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            withDescription: season.showsDescriptions,
                            guardsSpoilers: guardsSpoilers,
                            play: {
                                play(
                                    TileContent(
                                        id: episode.id, title: episode.title, image: episode.image),
                                    pageTitle)
                            },
                            menu: {
                                model.selectedEpisode = episode
                                model.sheetState.open(.episodeMenu)
                            },
                            // **The scope comes from the trigger** — here it is the episode.
                            // Whoever wants to take two episodes along for the train ride should not have to
                            // load the whole season (usability finding 12).
                            downloadState: downloadState(episode.id),
                            onDownloadsTap: {
                                submitDownloadRequest(request(forItem: episode, in: season))
                            })
                        Divider().overlay(ColorRole.lineQuiet.color).padding(
                            .leading, MetricsBoard.phone.margin)
                    }
                }
            }
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }

    // MARK: - The sheets

    @ViewBuilder
    private func sheetContent(_ identifier: SheetID) -> some View {
        switch identifier {
        case .ratings:
            RatingsSheet(
                ratings: model.content?.title.ratings ?? [],
                award: model.award,
                credential: model.hasRatingAccess,
                hasMuteMark: model.hasMuteMark)

        case .cast:
            CastSheet(
                cast: model.content?.cast ?? [],
                openPerson: model.isFilmographyReachable
                    ? { person in Task { await model.openFilmography(person) } } : nil)

        case .filmography:
            if let person = model.selectedPerson {
                CareerSheet(
                    person: person, filmography: model.filmography, isLoading: model.isFilmographyLoading,
                    credential: model.isFilmographyReachable,
                    // **The sheet closes before the page opens.** Two levels
                    // on top of each other cannot be closed at 393 points — the same
                    // rule as for the account switch (E23). A foreign title, by contrast, stays
                    // in the sheet: it explains itself, it does not lead away.
                    press: { entry in
                        Task {
                            await model.tapFilmography(entry) { identifier in
                                open(
                                    TileContent(
                                        id: identifier, title: entry.title,
                                        beside: entry.year.map(String.init),
                                        image: entry.posterURL))
                            }
                        }
                    })
            }

        case .titleProfile:
            TitleProfileSheet(
                title: model.profileTitle, profile: model.profile, isLoading: model.isProfileLoading,
                isTrailerLoading: model.isProfileTrailerLoading,
                playTrailer: { Task { await model.fetchProfileTrailer() } },
                // **Back to the career you came from** — it is still in the model,
                // nothing has to be fetched again.
                back: model.selectedPerson.map { person in
                    (wohin: person.name, action: { model.sheetState.open(.filmography) })
                })

        case .season:
            SeasonSheet(seasons: model.seasons, pending: model.season) { season in
                model.season = season.id
                model.sheetState.close()
            }

        case .sources:
            SourcesSheet(
                sources: model.content?.sources ?? [],
                audioTracks: model.content?.audioTracks ?? [],
                quality: model.quality,
                audioTrack: model.audioTrack ?? model.rememberedAudioTrack,
                selectQuality: { model.quality = $0 },
                selectAudioTrack: { model.select(audioTrack: $0) })

        case .load:
            if let downloadRequest {
                DownloadSheet(
                    job: downloadRequest.job,
                    enqueue: { done, queueNew in
                        model.sheetState.close()
                        queueDownload(done, downloadRequest, queueNew)
                    },
                    offersTopUp: offersTopUp,
                    // **The host list comes from the same source as when playing.**
                    // `/sources` answers for a title which hosts and
                    // language versions exist; the player has long asked it, and a
                    // second list would be the place where the two drift apart.
                    sources: hostSource)
            }

        case .titleMenu:
            titleMenu

        case .episodeMenu:
            episodeMenu

        case .before:
            before

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var titleMenu: some View {
        if let content = model.content {
            TitleMenuSheet(
                seen: content.seen,
                favorite: content.favorite,
                canRestart: content.next?.progress != nil,
                // Until AP26 there are no downloads — and a dimmed row would be the
                // invitation that ``TitleMenuSheet`` expressly avoids.
                addToDownloads: nil,
                // **Name and first attribute — that is the year for a film and
                // "S1 E35" for an episode.** More would be a summary that
                // nobody wants to send; less would be too little for a name like "Greswotrio" to
                // find it again.
                shareable: Self.shareableTitle(content.title),
                toggleWatched: {
                    model.sheetState.close()
                    Task { await model.setEnabled(seen: !content.seen) }
                },
                toggleFavorite: {
                    model.sheetState.close()
                    Task { await model.setEnabled(favorite: !content.favorite) }
                },
                fromStart: {
                    model.sheetState.close()
                    if let next = content.next { playFrom(next, 0, pageTitle) }
                })
        }
    }

    /// "Skefijiot - Kidreplias Rufrotbe (2014)" — what ends up in the box when sharing.
    ///
    /// **A function of its own and not an expression in the body**, because it has two cases and
    /// only a test suite hits one of them equally twice: a title without attributes
    /// must not end with an empty parenthesis.
    nonisolated static func shareableTitle(_ held: HeroContent) -> String {
        guard let first = held.attributes.first, !first.isEmpty else { return held.tile.title }
        return "\(held.tile.title) (\(first))"
    }

    @ViewBuilder
    private var episodeMenu: some View {
        if let episode = model.selectedEpisode {
            EpisodeMenuSheet(
                episode: episode,
                openPrior: model.openPrior(episode).count,
                play: {
                    model.sheetState.close()
                    play(
                        TileContent(id: episode.id, title: episode.title, image: episode.image),
                        pageTitle)
                },
                toggleWatched: {
                    model.sheetState.close()
                    Task { await model.set(episode: episode, seen: !episode.seen) }
                },
                toggleFavorite: { model.sheetState.close() },
                askForPrior: { model.sheetState.open(.before) })
        }
    }

    @ViewBuilder
    private var before: some View {
        if let episode = model.selectedEpisode {
            PriorEpisodesSheet(
                count: model.openPrior(episode).count,
                onlyThis: {
                    model.sheetState.close()
                    Task { await model.set(episode: episode, seen: true) }
                },
                alsoBefore: {
                    model.sheetState.close()
                    Task { await model.setPrior(episode) }
                })
        }
    }
}

/// A column in which you can read — AP7, 2026-09-23.
///
/// **The finding:** On an iPad Pro 13″ the descriptions of the detail page ran across
/// about 992 points and thus **about 120 characters per line**. 60 to 80 are easy to read;
/// beyond that the eye loses the line on the return sweep. ``MetricClass/readingWidth`` is the
/// number for it.
///
/// **The second frame is the reason this modifier exists.** A cap alone
/// only says how wide the block may become *at most*, and leaves its **position** to the
/// parent — which pins it to the left. ``StateBlock`` had exactly this half sentence, and
/// "What are you looking for?" then stood centered in a 393-point-wide column at the left
/// edge (see `LeerzustandBreiteTests`). Whoever caps also centers; here both sit in
/// one call so that they cannot be separated again.
///
/// **On the phone it never applies.** 720 points are more than an iPhone is wide — the block
/// is proposed the same width as before, and `.frame(maxWidth: .infinity)`
/// changes nothing for a block that fills the width anyway.
private struct ReadingColumn: ViewModifier {

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: MetricClass.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

extension View {

    /// Caps running text at ``MetricClass/readingWidth`` and places it **centered** — see
    /// ``ReadingColumn``.
    fileprivate func readingColumn() -> some View {
        modifier(ReadingColumn())
    }
}
