import Core
import DesignSystem
import Foundation
import RatingsKit
import SwiftUI

/// The detail page of a title — layout follows the UI template.
public struct DetailView: View {

    @StateObject private var model: DetailModel
    @FocusState private var focus: String?

    /// The season row's area — for ``prefersDefaultFocus(_:in:)``.
    ///
    /// **`defaultFocus` alone is not enough here**, and this is verified on the device
    /// (2026-08-10): Pressing down from the play button still landed focus on
    /// season 2, because it sits right below. `defaultFocus` names the preferred
    /// target **when tvOS would otherwise have none** — here it has one,
    /// namely the geometrically nearest. `prefersDefaultFocus(_:in:)`, by contrast,
    /// applies to entering an area and beats geometry.
    @Namespace private var seasonScope

    /// The episode row's area — the same answer as for the seasons, and for the
    /// same reason (AP4 · K5).
    ///
    /// **This had `defaultFocus` with a season identifier** — in the
    /// episode row, where there is no season. The comment block above it was
    /// copied word for word from the season row. The setting could hit
    /// nothing: it names a target that is not in this area, and entry into the
    /// episodes still went by geometry. That is the flash `episode#… → episode#…` (22 ms)
    /// that the review measured.
    ///
    /// `defaultFocus` alone is not enough here either — on the detail page it has
    /// already failed twice on the device. What held was `@Namespace` +
    /// `.focusScope` + `.prefersDefaultFocus(_:in:)`, and exactly that now
    /// sits above the episodes too.
    @Namespace private var episodeScope
    /// The scroller of the season row — without it there is no jump to a season that
    /// is not currently on screen. See ``jumpToSeason(_:)``.
    @State private var seasonScroller: ScrollViewProxy?
    /// The scroller of the episode row — see ``jumpToEpisode(_:)``.
    @State private var episodeScroller: ScrollViewProxy?

    /// Where an entry **from outside** into this row leads — season and episode,
    /// one each. `nil` means the focus is already inside, so its choice counts.
    ///
    /// **This is the answer to "season 2 lights up for a few milliseconds"**
    /// (viewer finding 2026-08-12), and it had to be turned around twice.
    ///
    /// The first attempt highlighted the right season **as soon as the correction
    /// ran**. The focus trace refuted it: the key press arrives three
    /// milliseconds **after** the focus change, so the correction runs at the
    /// earliest after that — a highlight that follows the correction therefore
    /// arrives too late in principle, and at best only slightly too late.
    ///
    /// **So it no longer catches up, it holds ahead.** When focus is
    /// outside the row, every entry is an assignment by tvOS and not a
    /// choice — and where it belongs is already known beforehand. The row then
    /// highlights that season, no matter which one the focus briefly
    /// touches. Only whoever moves **within** the row has chosen; then
    /// the value drops away and the focus counts again.
    ///
    /// That this works at all comes from an earlier decision: the
    /// highlight in this app is entirely self-drawn —
    /// ``bareFocusableButton()`` explicitly switches off the system effect. There
    /// is nothing that could light up without this view saying so.
    @State private var seasonCorrection: String?
    @State private var episodeCorrection: String?
    /// Spoiler protection of the profile (AP85) — read once per page, a toggle in the
    /// settings is seen on the next one.
    @State private var guardsSpoilers = BingePreferences.load(from: ProfileStore.playback).hidesSpoilers

    /// The running follow-up task per row — **cancellable, and that is not a
    /// detail.**
    ///
    /// The focus trace showed what happens without it: pressing down twice quickly
    /// starts two follow-ups at once — one for
    /// the season, one for the episode — and the two reset the focus
    /// back and forth. In the trace this shows as ping-pong over a whole
    /// second; on the TV it would be a view that cannot be operated.
    @State private var seasonJump: Task<Void, Never>?
    @State private var episodeJump: Task<Void, Never>?

    /// The episode the focus last stood on.
    ///
    /// **The same device as ``focusBeforeFilmography``, only for the path via
    /// the player.** It sits as a full screen over this page; while it is up,
    /// the page has no focus, and on return the episode row sees an
    /// entry from outside like any other. Without this memo the continue
    /// episode wins, and someone who paged 62 episodes in is back at the
    /// start (finding K6, 2026-08-24).
    ///
    /// It invalidates itself: on a season switch the remembered
    /// episode is no longer in the list, and ``FocusRules`` discards it.
    @State private var lastFocusedEpisode: String?

    /// When the viewer last pressed a key themselves.
    ///
    /// For ``FocusRules/abandonsRetry(startedAt:lastInput:grace:)``. The same
    /// construction as `focusMovedAt` in ``AppSidebar`` — a timestamp in the view's
    /// state, written where the view already records the press for
    /// the focus trace. `Date.distantPast` instead of `Date?`, so that "never
    /// pressed" is not a reason to abort by itself.
    @State private var lastInputAt = Date.distantPast

    /// Whether this element is to be highlighted.
    ///
    /// Without a hold-ahead the focus draws. With one, the hold-ahead draws — but
    /// only while the focus is in this row at all: otherwise a season would light
    /// up while the viewer is on the play button above, and
    /// two bright spots are worse than one wrong one.
    private func drawsFocus(_ id: String, correcting correction: String?, inRow: Bool) -> Bool {
        guard let correction, inRow else { return focus == id }
        return id == correction
    }

    /// Whether the focus is in the season row.
    private var focusIsOnSeason: Bool { focus?.hasPrefix(Self.seasonPrefix) == true }

    /// Whether the focus is on an episode. Via the list and not via a
    /// prefix: episodes carry their own identifier, and "play" would otherwise be one.
    private var focusIsOnEpisode: Bool {
        guard let focus else { return false }
        return model.episodes.contains { $0.id == focus }
    }

    /// Where an entry **from outside** into the episode row belongs — the press
    /// down from the season and the hold-ahead of the highlight both take
    /// this value.
    ///
    /// **One value for all ways in.** If the ranking stood separately at each place,
    /// the hold-ahead would keep pointing at the continue episode while the
    /// entry has landed on the remembered episode since ``lastFocusedEpisode`` — and
    /// the wrong card would light up for one frame. Exactly this kind of flash
    /// is finding K5.
    private var episodeEntryTarget: String? {
        Self.episodeEntry(
            episodes: model.episodes.map(\.id),
            resuming: model.playbackTarget?.id,
            remembered: lastFocusedEpisode
        )
    }
    @State private var palette = AccentPalette.brand
    /// Set while the trailer plays in full screen. As a target and not as a memo,
    /// so that playback gets exactly what the button meant.
    @State private var trailer: PlaybackTarget?
    /// The YouTube key whose resolution failed — the board offers the jump
    /// to the YouTube app (AP78).
    @State private var trailerError: String?

    /// The trailer in the background (AP82, 2026-10-12): the same clock as in the library
    /// column, the same setting. Runs **once per visit** — after the end or
    /// an abort by user input the still frame stays.
    @StateObject private var backgroundTrailer = TrailerAutostart()
    @State private var backgroundPlayed = false

    /// Opens another title — for "Similar" and the parts of a
    /// collection. Optional, because not every embedding can navigate further.
    let onOpen: ((MediaItem) -> Void)?

    /// What is played — **and whether from the start.** The resume point arises only
    /// where the playback target is built; this page cannot remove it
    /// without having it looked up again right afterwards. So it states the
    /// intent instead of tweaking the result.
    let onPlay: (MediaItem, Bool) -> Void

    /// Starts playback from a position — for the chapter row.
    /// Optional like ``onOpen``: not every embedding can play.
    let onPlayFrom: ((MediaItem, TimeInterval) -> Void)?

    /// Where a person's career comes from. `nil` means: the cast row
    /// stays for viewing — no button that leads nowhere.
    let filmography: FilmographyContext?

    /// Counts up when the career closes and this page should get the focus
    /// back.
    ///
    /// **A counter and not "fetch it when it is gone"** — the same pattern as
    /// in the Live area (``LiveView/focusToken``) and for the same reason: the
    /// focus is not here while the window is open either, and whoever
    /// fetched it back there would tear it away from the window.
    ///
    /// Without it the focus falls into the sidebar after closing: the window
    /// disappears, the page is no longer disabled in the same instant,
    /// and tvOS looks for the nearest target — on the left (focus trace, 2026-08-12).
    var filmographyToken: Int = 0

    /// Where the focus stood before the career opened.
    @State private var focusBeforeFilmography: String?

    /// The episode for which the question is currently asked whether everything before it goes along.
    ///
    /// **The case from the user request (2026-08-12):** "I'm at episode 65,
    /// there are over forty filler episodes in between, and I mark 108." What is meant
    /// is almost always everything up to there — but not always, and forty
    /// marks cannot be undone with one press. That is why we ask
    /// and do not decide.
    @State private var markingEarlierFor: MediaItem?

    /// Whether the series' language choice is currently open.
    @State private var choosingLanguage = false

    public init(
        model: DetailModel,
        onOpen: ((MediaItem) -> Void)? = nil,
        onPlayFrom: ((MediaItem, TimeInterval) -> Void)? = nil,
        filmography: FilmographyContext? = nil,
        filmographyToken: Int = 0,
        onPlay: @escaping (MediaItem, Bool) -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        self.onOpen = onOpen
        self.onPlayFrom = onPlayFrom
        self.filmography = filmography
        self.filmographyToken = filmographyToken
        self.onPlay = onPlay
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            backdrop

            switch model.state {
            case .loading:
                // The anchor for the focus — see ``FocusAnchor``. Without it tvOS finds
                // nothing focusable when a film opens and falls back to the
                // sidebar; it opens, and the film opens with the
                // menu open.
                LoadingBand()
                    .focusAnchor("detail-loading", focus: $focus)
            case .failed(let key):
                VStack(spacing: 22) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(ColorRole.live.color)
                    Text(appKey: key)
                        .font(TypeLevel.header.font)
                        .foregroundStyle(ColorRole.text.color)
                }
                // **The failure case holds the focus too** (AP5 · B9). The
                // rule is spelled out in ``LibraryView`` and applied only
                // there: without a focusable element the focus falls into the
                // sidebar, and on tvOS that also means the
                // Menu button goes to the system — the case described in ``MainView``,
                // "the app closed."
                .focusAnchor("detail-failed", focus: $focus)
            case .ready:
                // **Disabling now lies with ``MainView``**, together with
                // the window: not only this page must then be no focus target,
                // but also the sidebar next to it — and it does not know
                // this view.
                content
            }

        }
        .environment(\.accentPalette, palette)
        .trailerCover(
            $trailer, source: model.contentSource, quality: model.streamQuality,
            mayPlay: model.mayPlay
        )
        .trailerErrorBoard($trailerError)
        // **The initial focus belongs on the play button — otherwise the sidebar takes it.**
        // That is exactly what was seen: opening a film also opened
        // the sidebar.
        .defaultFocus($focus, "play")
        .task {
            await model.load()
            palette = await AccentExtractor.shared.palette(for: model.accentSourceURL()) ?? .brand
        }
        // **`defaultFocus` alone is not enough here, and the reason is the loading state.**
        //
        // On appearing, this page shows only a loading spinner, and that takes no
        // focus. tvOS assigns it anyway — to the nearest thing that can take it, and
        // that is the sidebar. It then opens, and the film opens
        // with the menu open. When the content arrives afterwards, tvOS does not take
        // the focus back on its own.
        //
        // So it is fetched as soon as there is something to focus.
        .onChange(of: model.state) { _, current in
            guard case .ready = current else { return }
            startBackgroundTrailer()
            guard focus == nil else { return }
            focus = "play"
        }
        .onChange(of: trailer) { _, fresh in
            // Full screen with sound takes over — the background stops and does not come back.
            if fresh != nil { stopBackgroundTrailer() }
        }
        .onDisappear { backgroundTrailer.stop() }
        .retriesWhenAwake(isFailed: model.state.isFailed) { await model.load() }
        // **The series' language choice.** On the frame and not on the button, for
        // the same reason as the confirmation below: the button is no longer
        // focused when answering.
        .confirmationDialog(
            Text(app: "detail.languageTitle"),
            isPresented: $choosingLanguage,
            titleVisibility: .visible
        ) {
            ForEach(model.languages, id: \.self) { word in
                Button {
                    Task { await model.setLanguage(word) }
                } label: {
                    Text(verbatim: word)
                }
            }
            // **"No preference" is a choice of its own and not the absence
            // of one.** Without it nobody could return to "take whatever
            // works" — and that is exactly the right setting for a
            // series that exists in only one language.
            if !model.language.isEmpty {
                Button {
                    Task { await model.setLanguage("") }
                } label: {
                    Text(app: "detail.languageAny")
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            // What the viewer must know to understand the choice: it applies
            // to the whole series, and it does not force anything.
            Text(app: model.loadingLanguages ? "detail.languageLoading" : "detail.languageHint")
        }
        // **The confirmation for marking several episodes.** On the page's frame
        // and not on the menu: the long-press menu is long closed when answering.
        .confirmationDialog(
            Text(app: "detail.markEarlierTitle"),
            isPresented: Binding(
                get: { markingEarlierFor != nil },
                set: { if !$0 { markingEarlierFor = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let episode = markingEarlierFor {
                let earlier = DetailModel.precedingUnwatched(before: episode, in: model.episodes)
                // The number is in the button: "This and 43 before" says what
                // happens; "All" would leave open how many that is.
                Button {
                    Task { await model.setPlayedIncludingEarlier(episode) }
                } label: {
                    Text(app: "detail.markEarlierAll \(earlier.count)")
                }
                Button {
                    Task { await model.setPlayed(true, for: episode) }
                } label: {
                    Text(app: "detail.markEarlierOnly")
                }
                Button(role: .cancel) {
                } label: {
                    Text(app: "common.cancel")
                }
            }
        }
        // **The page takes the focus back when the career closes.**
        // Rationale at ``filmographyToken`` — and with the same follow-up as
        // everywhere: a single assignment is overwritten by the system's running
        // focus assignment.
        .onChange(of: filmographyToken) { _, _ in
            // Without a remembered position, the first row of the cast: that is where
            // the window came from, if anywhere.
            let fallback = model.item.cast.first.map { "cast-" + $0.id }
            guard let wanted = focusBeforeFilmography ?? fallback else { return }
            focus = wanted
            let startedAt = Date()
            Task { @MainActor in
                for _ in 1...5 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if focus == wanted { return }
                    // **The operator beats the follow-up** (AP4 · K7): a
                    // press in this window used to be not swallowed
                    // but actively undone.
                    if FocusRules.abandonsRetry(startedAt: startedAt, lastInput: lastInputAt) {
                        return
                    }
                    focus = wanted
                }
            }
        }
        // Observes only — see ``focusTrail(_:_:)``.
        .focusTrail("Detailseite", focus)
    }

    /// The background image stays put while the content scrolls over it —
    /// this makes the page feel anchored instead of like a loose list.
    // MARK: - Trailer in the background (AP82)

    /// Sets the clock as soon as the page is up. Muted and once; the address is the same
    /// as for the button and was already resolved when the page opened.
    private func startBackgroundTrailer() {
        guard !backgroundPlayed, backgroundTrailer.running == nil,
            backgroundTrailer.pending == nil
        else { return }
        backgroundTrailer.configure(
            preferences: TrailerPreferences.load(from: ProfileStore.playback),
            load: { _ in nil })
        backgroundTrailer.focus(id: model.item.id) { [model] in await model.trailerDestination() }
    }

    /// Played to the end or failed: softly back to the still frame, no second startup.
    private func backgroundEnded() {
        backgroundPlayed = true
        withAnimation(.easeInOut(duration: 0.6)) { backgroundTrailer.stop() }
    }

    /// User input takes over (play, full screen, short profile) — off immediately, so that never
    /// two players run at once, and not again for this visit.
    private func stopBackgroundTrailer() {
        backgroundPlayed = true
        backgroundTrailer.stop()
    }

    private var backdrop: some View {
        // Image and gradients share the same frame and take up the whole
        // screen. Before, the gradient sat above as a separate box and
        // ended with a hard edge while the image below still
        // continued — that looked like a bug, and was one.
        GeometryReader { geometry in
            // The area is only known here, so the display size comes from the
            // geometry. No margin — an area the size of the screen does not grow.
            // **The same measure as the prefetch** (AP7 · L4): `geometry.size` was used
            // here, and on this page it is narrower than the
            // screen — two keys for the same image, and the prefetch
            // warmed nothing. Drawing still happens in the geometry; only
            // the key is the same.
            RemoteImage(
                url: model.backdropURL(),
                displaySize: DetailPrefetch.backdropSize,
                headroom: 1
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay {
                // **The trailer in the image's place, below the gradients** (AP82):
                // texts and buttons stay readable because the same gradient lies above.
                // The area fades itself in as soon as the first frame is there.
                if let running = backgroundTrailer.running {
                    TrailerBackdrop(target: running.target) { backgroundEnded() }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .overlay {
                // Opaque from the left, fading out to the right: frees the text
                // without covering the image.
                LinearGradient(
                    stops: [
                        .init(color: ColorRole.reason.color, location: 0),
                        .init(color: ColorRole.reason.color.opacity(0.92), location: 0.28),
                        .init(color: ColorRole.reason.color.opacity(0.35), location: 0.62),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .overlay {
                // Opaque towards the bottom, so the episode row stands on solid ground
                // instead of floating in the image.
                LinearGradient(
                    stops: [
                        .init(color: ColorRole.reason.color, location: 0),
                        .init(color: ColorRole.reason.color.opacity(0.75), location: 0.3),
                        .init(color: .clear, location: 0.75),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
        }
        // Not on the left: the sidebar stands there, and the background image
        // would otherwise run beneath it.
        .ignoresSafeArea(edges: [.top, .bottom, .trailing])
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                heading
                    .padding(.top, 60)

                if !model.seasons.isEmpty {
                    seasonRow
                }

                // **The season description** (user request 2026-08-16: "each
                // season represents an arc — so you can read up
                // on what it is about"): Jellyfin delivers a separate
                // overview per season when the metadata carries it; it changes with
                // the selected season.
                if let arc = model.selectedSeason?.overview, !arc.isEmpty {
                    Text(verbatim: arc)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .lineLimit(3)
                        .frame(maxWidth: 860, alignment: .leading)
                }

                if !model.episodes.isEmpty {
                    episodeRow
                } else if model.episodeGap != .none {
                    episodeGapNote
                }

                if !model.parts.isEmpty {
                    partsRow
                }

                if !model.item.cast.isEmpty {
                    CastRow(
                        cast: model.item.cast,
                        imageURL: { model.personURL(for: $0) },
                        onSelect: filmography.map { context in
                            { person in
                                // Remember first, then open — on closing
                                // the way leads exactly back here.
                                focusBeforeFilmography = focus
                                stopBackgroundTrailer()
                                context.show(person)
                            }
                        },
                        voice: { person in
                            model.germanVoices.voice(forCharacter: person.character)
                        },
                        focus: $focus
                    )
                }

                if Self.showsAbout(for: model.item) {
                    aboutBlock
                }

                if let chapters = model.item.chapters, chapters.count >= 2, onPlayFrom != nil {
                    chapterRow(chapters)
                }

                if !model.similar.isEmpty {
                    similarRow
                }
            }
            .padding(.horizontal, MetricsBoard.tv.margin)
            .padding(.bottom, TVMetrics.topMargin)
        }
    }

    // MARK: - Header

    private var heading: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let logo = model.logoURL() {
                RemoteImage(
                    url: logo,
                    contentMode: .fit,
                    displaySize: TVMetrics.logo,
                    headroom: 1
                )
                .frame(
                    maxWidth: TVMetrics.logo.width,
                    maxHeight: TVMetrics.logo.height,
                    alignment: .leading
                )
            } else {
                Text(verbatim: model.item.title)
                    .font(TypeLevel.lead.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(2)
            }

            metaRow

            if RatingBadges.hasContent(serverRatings: model.item.ratings, external: model.external) {
                RatingBadges(serverRatings: model.item.ratings, external: model.external)
            }

            if let overview = model.item.overview, !overview.isEmpty {
                Text(verbatim: overview)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(3)
                    .frame(maxWidth: 860, alignment: .leading)
            }

            // Side by side in the same HStack: on tvOS the focus moves reliably only between
            // siblings. Two buttons in separate levels do not reach
            // each other.
            HStack(spacing: 22) {
                playButton
                restartButton
                languageButton
                trailerButton
                watchedButton
                favoriteButton
            }
            .padding(.top, 8)
            // **The button row is a section of its own, and because of the
            // return from below.** Without it geometry decides: someone on
            // season 6 who presses up finds nothing, because the
            // play button lies diagonally to the left and not in a row above. As a
            // section the focus jumps in as a whole — and lands where
            // it left the row.
            .focusSection()
            // **The correction starts at the key press, not at the
            // focus change** (viewer finding 2026-08-12: "season 2 still lights up for
            // one frame").
            //
            // That is the difference between "one frame too late" and "not at
            // all": `onChange(of: focus)` runs **after** tvOS has assigned the
            // focus — and drawing happens in between. Here the
            // correction is in place before the assignment even takes place.
            //
            // The focus change below stays as a safety net: if the press only
            // arrives after tvOS has already consumed it — the lesson from E20 —
            // ``seasonOnEntry(previous:current:selected:)`` catches it.
            .onMoveCommand { direction in
                Diagnostics.cursorKey("Detailseite · Knöpfe", FocusTrail.name(direction))
                // **Before the jump, not after** (finding K7): if this
                // handler triggers a follow-up itself, the press lies before
                // its trigger — and does not abort it right away.
                lastInputAt = Date()
                guard direction == .down, let season = model.selectedSeason else { return }
                jumpToSeason(Self.seasonPrefix + season.id)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 18) {
            if let year = model.item.year {
                Text(verbatim: String(year))
            }
            if !model.item.genres.isEmpty {
                dot
                Text(verbatim: model.item.genres.prefix(2).joined(separator: " · "))
            }
            if let studio = model.item.studio {
                dot
                Text(verbatim: studio)
            }
            if let age = model.item.ageRating {
                dot
                Text(verbatim: age)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(ColorRole.textQuiet.color, lineWidth: 2)
                            // As on Home: an outline is ornament and otherwise takes
                            // part in determining the focus target.
                            .allowsHitTesting(false)
                    }
            }
        }
        .font(TypeLevel.footer.font)
        .foregroundStyle(ColorRole.textMatt.color)
    }

    private var dot: some View {
        Circle().fill(ColorRole.textQuiet.color).frame(width: 6, height: 6)
    }

    @ViewBuilder
    private var playButton: some View {
        if let target = model.playbackTarget {
            Button {
                stopBackgroundTrailer()
                onPlay(target, false)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "play.fill")
                    // The label says what happens: Continue Watching for
                    // started items, otherwise the episode that is started.
                    if model.isResuming {
                        Text(app: "detail.resume")
                    } else if let episode = target.episodeNumber, let season = target.seasonNumber {
                        Text(app: "detail.playEpisode \(season) \(episode)")
                    } else {
                        Text(app: "common.play")
                    }
                }
                .font(TypeLevel.header.font)
                .foregroundStyle(focus == "play" ? ColorRole.text.color : ColorRole.reason.color)
                .padding(.horizontal, 44)
                .padding(.vertical, 20)
                .background(focus == "play" ? Color(palette) : ColorRole.text.color, in: Capsule())
            }
            .bareFocusableButton()
            .focused($focus, equals: "play")
            .focusHighlight(
                focus == "play",
                scale: Tokens.Focus.buttonScale,
                accent: Color(palette, .bright)
            )
            // **The same case distinction as the label** — and that is why it appears
            // here again instead of as "Play": whoever only listens must be able to tell
            // "Continue Watching" from "Season 2, episode 5".
            .info(Self.playbackInfo(target, resuming: model.isResuming))
        }
    }

    /// What the play button **does** — in words instead of a symbol.
    static func playbackInfo(_ target: MediaItem, resuming: Bool) -> Text {
        if resuming { return Text(app: "detail.resume") }
        if let episode = target.episodeNumber, let season = target.seasonNumber {
            return Text(app: "detail.playEpisode \(season) \(episode)")
        }
        return Text(app: "common.play")
    }

    /// Start from the beginning.
    ///
    /// **Only for started items**, and only then visible: where there is nothing to resume,
    /// it would be the same as "Play" — two buttons side by side doing the same,
    /// and you have to read first to notice it does not matter.
    ///
    /// Round and with a symbol like the two marks beside it: it is the exception to
    /// the regular case, and the regular case carries the label.
    @ViewBuilder
    private var restartButton: some View {
        if model.isResuming {
            circleButton(
                id: "restart",
                symbol: "arrow.counterclockwise",
                isOn: false,
                hintKey: "detail.restart"
            ) {
                guard let target = model.playbackTarget else { return }
                stopBackgroundTrailer()
                onPlay(target, true)
            }
        }
    }

    /// Watched mark and favorite mark.
    ///
    /// **Round and with a symbol only, no label.** Next to two labeled buttons,
    /// two more would be a row running across half the width; at three meters
    /// distance you read the shape first anyway. The state is in the fill:
    /// set means filled, and the symbol changes as well. Both together,
    /// because color alone says nothing with red-green color blindness and with strong image enhancement on the
    /// TV.
    @ViewBuilder
    private var watchedButton: some View {
        // For a season there is nothing to mark that the episodes themselves
        // would not know better.
        if model.item.kind != .season {
            circleButton(
                id: "watched",
                symbol: model.isWatched ? "checkmark.circle.fill" : "checkmark.circle",
                isOn: model.isWatched,
                hintKey: model.isWatched ? "detail.markUnwatched" : "common.markWatched"
            ) {
                Task { await model.toggleWatched() }
            }
        }
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if model.item.kind != .season {
            circleButton(
                id: "favorite",
                symbol: Glyph.favorite.pair.forItem(model.isFavorite),
                isOn: model.isFavorite,
                hintKey: model.isFavorite ? "common.unfavorite" : "detail.favorite"
            ) {
                Task { await model.toggleFavorite() }
            }
        }
    }

    private func circleButton(
        id: String,
        symbol: String,
        isOn: Bool,
        hintKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(
                    focus == id
                        ? ColorRole.reason.color
                        : (isOn ? Color(palette, .bright) : ColorRole.text.color)
                )
                .frame(width: 74, height: 74)
                .background(
                    focus == id ? ColorRole.text.color : ColorRole.surfaceHigh.color,
                    in: Circle()
                )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .focusHighlight(focus == id, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
        // What the button does is not shown next to it but announced: two symbols
        // without a label are unambiguous on their own, but not for screen
        // reader output — and there "button" is the only information that would remain.
        .accessibilityLabel(Text(appKey: hintKey))
    }

    /// The series' language choice — **once for all episodes.**
    ///
    /// **Why it sits here and not with the episode** (viewer request
    /// 2026-08-28: "instead of having to choose for every episode individually, can this be
    /// controlled centrally? Otherwise automatic playback from episode to
    /// episode would not work at all"): they are right. A choice per episode
    /// would have to be made anew at every episode change — either with a
    /// prompt in the middle of the credits or silently with the first source, that is
    /// German again.
    ///
    /// **Only for a portal that knows series.** With the media server there are
    /// no hosts to choose, and a portal without seasons lists exactly
    /// one source per entry — there the button would be a promise without backing.
    ///
    /// The list is fetched **only on press**: for this the bridge descends
    /// to the first episode of each of the first three seasons and reads their
    /// host lists. Doing that on every page open would be expensive for
    /// something most people never touch.
    @ViewBuilder
    private var languageButton: some View {
        if model.canChooseLanguage {
            Button {
                choosingLanguage = true
                Task { await model.loadLanguages() }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "captions.bubble")
                    // The chosen language is **in the button**, not behind it:
                    // whoever wants to know how they are currently watching should be able to read it
                    // without pressing the button. Without a choice it shows
                    // what it is for.
                    Text(
                        verbatim: model.language.isEmpty
                            ? AppLanguageSetting.text("settings.language")
                            : model.language)
                }
                .font(TypeLevel.header.font)
                .foregroundStyle(focus == "language" ? ColorRole.reason.color : ColorRole.text.color)
                .padding(.horizontal, 38)
                .padding(.vertical, 20)
                .background(
                    focus == "language" ? ColorRole.text.color : ColorRole.surfaceHigh.color,
                    in: Capsule()
                )
            }
            .bareFocusableButton()
            .focused($focus, equals: "language")
            .focusHighlight(
                focus == "language",
                scale: Tokens.Focus.buttonScale,
                accent: Color(palette, .bright)
            )
            // The chosen language is the **state**, not the name of the button:
            // "Language, German" instead of sometimes one and sometimes the other.
            .info(
                Text(app: "settings.language"),
                .word(model.language)
            )
            // The remembered choice appears on the page as soon as it is known — it is
            // cheap. Only the list of options is not.
            .task { await model.loadLanguage() }
        }
    }

    /// The trailer, if one is attached.
    ///
    /// **Without a trailer the button does not appear at all** — not dimmed and not
    /// empty. A dimmed button still takes focus on tvOS, and then
    /// the focus sits on something that does not respond; people think the app has hung.
    /// That there is one at all, the page knows before drawing: ``DetailModel``
    /// built the target while loading.
    @ViewBuilder
    private var trailerButton: some View {
        if let fund = model.trailerFinding {
            Button {
                Task {
                    if let target = await model.trailerDestination() {
                        trailer = target
                    } else {
                        trailerError = fund.choice.youtubeID ?? ""
                    }
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "film")
                    Text(app: "detail.trailer")
                    // The language badge (AP78): it says what was found — "DE" for the
                    // German trailer, "EN" for the fallback. Without a language, none.
                    if let badge = fund.choice.badge {
                        LanguageBadge(badge, bright: focus == "trailer")
                    }
                }
                .font(TypeLevel.header.font)
                // Styled as secondary: "Play" is the action you came
                // for. Two equally bright buttons side by side leave
                // open which one is meant.
                .foregroundStyle(focus == "trailer" ? ColorRole.reason.color : ColorRole.text.color)
                .padding(.horizontal, 38)
                .padding(.vertical, 20)
                .background(
                    focus == "trailer" ? ColorRole.text.color : ColorRole.surfaceHigh.color,
                    in: Capsule()
                )
            }
            .bareFocusableButton()
            .focused($focus, equals: "trailer")
            .focusHighlight(
                focus == "trailer",
                scale: Tokens.Focus.buttonScale,
                accent: Color(palette, .bright)
            )
            .info(appKey: "detail.trailer")
        }
    }

    // MARK: - Details, similar, parts

    /// Whether the details block has anything to contribute.
    ///
    /// It does not repeat the header: there the description is shortened to three lines.
    /// Down here it is shown in full — plus the director, which has no room
    /// above. Without both there would only be an empty card.
    static func showsAbout(for item: MediaItem) -> Bool {
        if let overview = item.overview, !overview.isEmpty { return true }
        return !(item.directors ?? []).isEmpty
    }

    /// The complete plot including director — as a **focusable** card.
    ///
    /// Focusable for a technical reason, not a design one:
    /// tvOS scrolls a page only to where focus can go. Plain text at the
    /// bottom of the page would be unreachable — for the remote the page would end at
    /// the cast, and nobody would know that something still sits below.
    private var aboutBlock: some View {
        let isFocused = focus == "about"

        return VStack(alignment: .leading, spacing: 14) {
            Text(app: "detail.about")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            Button {
                // The card does nothing on press — it is a reading target. A
                // separate full-screen dialog for it would be a second place for the same
                // text; whoever arrives here already sees it in full.
            } label: {
                VStack(alignment: .leading, spacing: 16) {
                    if let overview = model.item.overview, !overview.isEmpty {
                        Text(verbatim: overview)
                            .font(TypeLevel.text.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }

                    HStack(spacing: 18) {
                        if let directors = model.item.directors, !directors.isEmpty {
                            Text(app: "detail.director")
                                .foregroundStyle(ColorRole.textQuiet.color)
                            Text(verbatim: directors.joined(separator: ", "))
                                .foregroundStyle(ColorRole.textMatt.color)
                        }
                        if let runtime = model.item.runtime, runtime > 0 {
                            dot
                            // Via `Text` with a format instead of preformatted text:
                            // only that way the app's environment language applies — a string built by
                            // hand would follow the device language,
                            // and the page would be half translated.
                            Text(
                                Duration.seconds(runtime),
                                format: .units(allowed: [.hours, .minutes])
                            )
                            .foregroundStyle(ColorRole.textMatt.color)
                        }
                    }
                    .font(TypeLevel.footer.font)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ColorRole.surface.color.opacity(isFocused ? 1 : 0.6),
                    in: RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous)
                )
            }
            .bareFocusableButton()
            .focused($focus, equals: "about")
        }
    }

    /// The chapters as a springboard: selecting one starts playback **from there**.
    ///
    /// Before playing and not only in the player — whoever knows where they want to go
    /// should not have to start first and then scrub. Without a name a mark is
    /// simply called "Chapter n"; the time is always shown, because it is the
    /// actual promise of the button.
    /// Size of the chapter still frames: 16:9, narrower than an episode card —
    /// nine chapters should stay recognizable as a row, not appear as a second
    /// episode row.
    static let chapterImageSize = CGSize(width: 300, height: 169)

    private func chapterRow(_ chapters: [Chapter]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(app: "detail.chapters")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        let id = "chapter-\(index)"
                        let isFocused = focus == id

                        Button {
                            onPlayFrom?(model.item, chapter.start)
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                // The still frame of the mark — the server extracted it while
                                // scanning. Without an image the card stays
                                // with name and time; a gray placeholder would look
                                // like an error in a whole row.
                                if let image = model.chapterImageURL(
                                    index: index,
                                    tag: chapter.imageTag,
                                    width: ImageSizing.requestWidth(
                                        points: Self.chapterImageSize.width
                                    )
                                ) {
                                    RemoteImage(url: image, displaySize: Self.chapterImageSize)
                                        .frame(
                                            width: Self.chapterImageSize.width,
                                            height: Self.chapterImageSize.height
                                        )
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        )
                                        .focusHighlight(
                                            isFocused, accent: Color(palette, .bright)
                                        )
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    if let title = chapter.title, !title.isEmpty,
                                        !title.lowercased().hasPrefix("chapter")
                                    {
                                        Text(verbatim: title)
                                            .lineLimit(1)
                                    } else {
                                        Text(app: "detail.chapterNumber \(index + 1)")
                                    }
                                    Text(verbatim: PlayerModel.timeLabel(chapter.start))
                                        .foregroundStyle(ColorRole.textQuiet.color)
                                        .monospacedDigit()
                                }
                                .font(TypeLevel.footer.font)
                                .foregroundStyle(
                                    isFocused ? ColorRole.text.color : ColorRole.textMatt.color
                                )
                            }
                            .frame(width: Self.chapterImageSize.width, alignment: .leading)
                        }
                        .bareFocusableButton()
                        .focused($focus, equals: id)
                    }
                }
                .padding(.vertical, 16)
            }
            .scrollClipDisabled()
        }
    }

    /// The "Similar" row — for films and home videos, from the `Similar` endpoint.
    private var similarRow: some View {
        posterRow(titleKey: "detail.similar", items: model.similar, idPrefix: "similar")
    }

    /// The parts of a collection, in release order.
    private var partsRow: some View {
        posterRow(titleKey: "detail.parts", items: model.parts, idPrefix: "part")
    }

    /// A poster row with a heading — the same pattern as the Home shelves:
    /// selecting **opens** the title's detail page instead of
    /// playing it blindly.
    private func posterRow(titleKey: String, items: [MediaItem], idPrefix: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(appKey: titleKey)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(items) { entry in
                        let id = idPrefix + "-" + entry.id

                        Button {
                            onOpen?(entry)
                        } label: {
                            PosterCard(
                                item: entry,
                                imageURL: model.posterURL(for: entry),
                                isFocused: focus == id
                            )
                        }
                        .bareFocusableButton()
                        .focused($focus, equals: id)
                        .disabled(onOpen == nil)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - Seasons

    /// How a season mark is recognized.
    ///
    /// As a value and not twice as a string: the focus name is built in one place
    /// and taken apart again in another. Two copies of the same prefix would drift apart
    /// on the first rename, and the bug would be that moving between seasons silently does nothing any more.
    static let seasonPrefix = "season-"

    private var seasonRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(app: "detail.seasons")
                // As with ``CastRow``: capitals belong in the view (AP25).
                .textCase(.uppercase)
                .font(TypeLevel.footer.font)
                .kerning(3)
                .foregroundStyle(ColorRole.textQuiet.color)

            ScrollViewReader { scroller in
                seasonScroll
                    // **The scroller is grabbed on appearing, not on the
                    // key press.** A season far to the right lies outside the
                    // screen; without the scroller the correction would be a focus on something
                    // you cannot see. The same lesson as with the group list
                    // in the Live area (E20).
                    .onAppear { seasonScroller = scroller }
            }
        }
    }

    /// The season row itself — standalone, so the scroller can enclose it
    /// without indenting the body another level.
    private var seasonScroll: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(model.seasons) { season in
                    let isActive = model.selectedSeason?.id == season.id
                    let id = Self.seasonPrefix + season.id
                    // The highlight follows the correction while one
                    // is running — see ``seasonCorrection``.
                    let lit = drawsFocus(id, correcting: seasonCorrection, inRow: focusIsOnSeason)

                    Button {
                        Task { await model.selectSeason(season) }
                    } label: {
                        Text(verbatim: season.title)
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(
                                lit
                                    ? ColorRole.reason.color
                                    : (isActive ? ColorRole.text.color : ColorRole.textMatt.color)
                            )
                            .padding(.horizontal, 28)
                            .padding(.vertical, 13)
                            .background(
                                lit
                                    ? ColorRole.text.color
                                    : (isActive ? Color(palette) : ColorRole.surface.color),
                                in: Capsule()
                            )
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: id)
                    // **Entry hits the season you are in.**
                    // See ``seasonScope`` — the reason why this does not work
                    // via `defaultFocus` is stated there.
                    .prefersDefaultFocus(isActive, in: seasonScope)
                    .focusHighlight(
                        lit,
                        scale: Tokens.Focus.buttonScale,
                        accent: Color(palette, .bright)
                    )
                }
            }
            .padding(.vertical, 8)
            // The season switches while moving, not only on press — the same
            // rule as with the pill above and in the settings. Whoever goes from
            // season 1 to 2 wants to see season 2.
            .onChange(of: focus) { previous, current in
                // **When the focus is outside, the row holds ahead where an
                // entry belongs** — see ``seasonCorrection``. Held ahead
                // instead of caught up, because the correction demonstrably arrives too late:
                // the focus trace shows the key press three milliseconds
                // AFTER the focus change.
                guard current?.hasPrefix(Self.seasonPrefix) == true else {
                    seasonCorrection = model.selectedSeason.map { Self.seasonPrefix + $0.id }
                    return
                }
                // **Entry from outside is an assignment and not a choice.**
                // Whoever comes down from the button row has not chosen a season —
                // geometry assigned the second one. The
                // rule for this is in ``FocusRules``; here it only says that it
                // comes before the season choice: otherwise the series would first switch to
                // season 2 and right after switch back, and fetching the episodes
                // would run twice.
                if let wanted = Self.seasonOnEntry(
                    previous: previous, current: current,
                    selected: model.selectedSeason?.id
                ) {
                    jumpToSeason(wanted)
                    return
                }
                // Moved or already arrived correctly: from here on the focus itself
                // counts again.
                seasonCorrection = nil
                guard let current else { return }
                guard
                    let season = model.seasons.first(
                        where: { Self.seasonPrefix + $0.id == current }),
                    model.selectedSeason?.id != season.id
                else { return }
                Task { await model.selectSeason(season) }
            }
            // And the hold-ahead stays fresh when the season changes while
            // the focus is up — otherwise on the first press it would point to a
            // season that is long no longer the current one.
            .onChange(of: model.selectedSeason?.id) { _, id in
                guard !focusIsOnSeason else { return }
                seasonCorrection = id.map { Self.seasonPrefix + $0 }
            }
        }
        .scrollClipDisabled()
        .focusScope(seasonScope)
        .focusSection()
        // **Both neighbors are announced here, and both for a reason that
        // geometry does not know.**
        //
        // *Down* the episode you were last at — in Blibiagraik it lies
        // 55 cards to the right, and "all the way at the front" would be no start but a
        // long way (user finding 2026-08-12).
        //
        // *Up* the button row. It lies far left; whoever is on season 7
        // has nothing above them, and the press fizzled out — reproduced in the simulator
        // (2026-08-12), also in the state **before** this package. The
        // separate section from E16 is not enough for that: it says where the focus
        // lands when it hits the row, not that it hits it.
        .onMoveCommand { direction in
            Diagnostics.cursorKey("Detailseite · Staffeln", FocusTrail.name(direction))
            // Before the jump — see the button row.
            lastInputAt = Date()
            switch direction {
            case .down:
                guard let wanted = episodeEntryTarget else { return }
                jumpToEpisode(wanted)
            case .up:
                // Only if the button exists at all — for a series without a
                // play target there is nothing there that could carry it.
                guard model.playbackTarget != nil else { return }
                focus = "play"
            default:
                break
            }
        }
        // **Down leads to the season you are in.**
        //
        // Without this setting geometry decides: in "The Flaihuski Freipri
        // Taspreis" season 2 lies right below the play button and therefore
        // wins every time — whoever is on season 6 had to work their way
        // over every time. Which season is meant is stated by ``DetailModel``;
        // here it only says that it and not the neighborhood counts.
        //
        // **It stays, although it was not enough on the device.** If
        // it works, the correction above is a silent zero pass — if it
        // does not, the correction catches the case. Two nets, of which the
        // lower one costs nothing.
        .defaultFocus($focus, Self.seasonPrefix + (model.selectedSeason?.id ?? ""))
    }

    /// Sets the focus on a season — **first scroll, then grab, then
    /// follow up.**
    ///
    /// The same answer as with the group list in the Live area (E20): the row
    /// is built lazily and scrolls horizontally. A focus on a season that
    /// is not currently on screen fizzles out without error — tvOS then keeps the
    /// target it found itself, and that is exactly what is to be corrected
    /// here.
    private func jumpToSeason(_ id: String) {
        // **First the highlight, then the focus.** Set in this order and
        // in the same pass, there is no frame in which the assigned
        // season stands out bright — see ``seasonCorrection``.
        seasonCorrection = id
        seasonScroller?.scrollTo(id, anchor: .center)
        focus = id
        let startedAt = Date()

        // The episodes' follow-up has no business here any more: the focus
        // should go into the season row, not back into the episodes.
        episodeJump?.cancel()
        seasonJump?.cancel()
        seasonJump = Task { @MainActor in
            // **First wait, then check.** A focus just written reads
            // back immediately, even if tvOS never accepted it; whoever checks in
            // the same breath always gets a yes.
            //
            // Counting runs to the end and not to the first yes: tvOS
            // also reassigns the focus once more during the rebuild, and whoever
            // hands the highlight back at the first hit has moved the flash by
            // a hundred milliseconds instead of switching it off.
            for _ in 1...5 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                // **The operator beats the follow-up** (finding K7): whoever
                // presses themselves during the 250 ms used to have their movement
                // actively reset. `break` and not `return`, so that the
                // highlight below is still handed back — otherwise it would stay
                // on a season where nobody is any more, and
                // two spots would light up.
                if FocusRules.abandonsRetry(startedAt: startedAt, lastInput: lastInputAt) { break }
                if focus != id {
                    seasonScroller?.scrollTo(id, anchor: .center)
                    focus = id
                }
            }
            seasonCorrection = nil
        }
    }

    // MARK: - Episodes

    /// The sentence in place of the episode row.
    ///
    /// **Why a sentence at all.** If the row is missing without a word, a
    /// series page appears without episodes and without a play button — indistinguishable from a bug
    /// of the app. For the provider iptvhost about a fifth of the
    /// series in the panel have no episode entries; "Buhin Briakloul film series" and
    /// "A Seikoca plebra Naunzoukau" were the cases where it was noticed.
    private var episodeGapNote: some View {
        Text(
            app: model.episodeGap == .lookupFailed
                ? "detail.episodesUnreachable" : "detail.noEpisodes"
        )
        .font(TypeLevel.text.font)
        .foregroundStyle(ColorRole.textMatt.color)
        .frame(maxWidth: 860, alignment: .leading)
    }

    private var episodeRow: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(app: "common.episodeCount \(model.episodes.count)")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            ScrollViewReader { scroller in
                episodeScroll
                    .onAppear { episodeScroller = scroller }
            }
        }
    }

    /// The episode row itself — standalone for the same reason as
    /// ``seasonScroll``: so the scroller can enclose it.
    private var episodeScroll: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: MetricsBoard.tv.gutter) {
                ForEach(model.episodes) { episode in
                    Button {
                        stopBackgroundTrailer()
                        onPlay(episode, false)
                    } label: {
                        // On the detail page the episode title counts, not the
                        // series name — that is already above as a heading and
                        // would be the same line once more on every card of the row.
                        // It was shown here anyway, plus a third line
                        // with the episode title in caption2; now the card carries
                        // it itself, see ``EpisodeCard/TitleMode``.
                        EpisodeCard(
                            item: episode,
                            imageURL: model.stillURL(for: episode),
                            // As with the seasons: the highlight follows the
                            // correction while one is running.
                            isFocused: drawsFocus(
                                episode.id, correcting: episodeCorrection,
                                inRow: focusIsOnEpisode
                            ),
                            titleMode: .episode,
                            guardsSpoilers: guardsSpoilers
                        )
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: episode.id)
                    // **Entry hits the episode that is meant** — the
                    // remembered one, otherwise the continue episode (``episodeEntryTarget``).
                    // See ``episodeScope``.
                    .prefersDefaultFocus(episode.id == episodeEntryTarget, in: episodeScope)
                    // **The same gesture, the same menu as in the grid** (roadmap
                    // AP4). For films the long press has opened "mark as
                    // watched" since E10; for episodes it did nothing — although the
                    // model has long been able to do both, only the menu was missing. A
                    // gesture that works in one place and not in the other
                    // teaches people not to try it at all.
                    .contextMenu { episodeMenu(for: episode) }
                }
            }
            .padding(.vertical, 20)
            // **Entry hits the episode you were last at**
            // (user finding 2026-08-12). The rule is in ``FocusRules``, and so is the
            // rationale: with over 300 episodes in a season,
            // "all the way at the front" is no start but a long way.
            .onChange(of: focus) { previous, current in
                // The same hold-ahead as with the seasons, for the same
                // reason — see ``episodeCorrection``.
                guard focusIsOnEpisode else {
                    episodeCorrection = episodeEntryTarget
                    return
                }
                if let wanted = Self.episodeOnEntry(
                    previous: previous, current: current,
                    episodes: model.episodes.map(\.id),
                    resuming: model.playbackTarget?.id,
                    remembered: lastFocusedEpisode
                ) {
                    jumpToEpisode(wanted)
                    return
                }
                episodeCorrection = nil
                // **Remembered here and only here**: the branch above returns on
                // a correction, so the assigned episode never ends up in the memo,
                // but always the corrected one first.
                lastFocusedEpisode = current
            }
            // The hold-ahead follows the season: a switch replaces the whole
            // list, and the old season's continue episode no longer
            // exists then.
            .onChange(of: model.playbackTarget?.id) { _, _ in
                guard !focusIsOnEpisode else { return }
                episodeCorrection = episodeEntryTarget
            }
        }
        .scrollClipDisabled()
        .focusSection()
        // The episodes' own focus area — see ``episodeScope``.
        .focusScope(episodeScope)
        // **Of the three rows the episode row was the only one not to write a trigger**
        // — the buttons do (:443), the seasons too (:983). The
        // finer area name does not disturb the analysis: `hauptbereich()`
        // cuts it back to "Detailseite" (scripts/focus_trace.py:66).
        .onMoveCommand { direction in
            Diagnostics.cursorKey("Detailseite · Folgen", FocusTrail.name(direction))
            lastInputAt = Date()
        }
        // **A season identifier stood here** (AP4 · K5) — in the episode row,
        // where no season lies, and with a comment block that was copied word for
        // word from the season row. The setting could hit nothing. In its place stands now
        // the focus area above, and
        // the episode that is meant announces itself.
    }

    /// Sets the focus on an episode — **first scroll, then grab, then
    /// follow up**, as with the seasons.
    ///
    /// Here scrolling counts double: a season with three hundred episodes is built
    /// two percent, and the one sought is almost never below.
    /// The long-press menu of an episode — watched mark and favorite mark.
    ///
    /// **The same keys as in the grid and on the title:** an action that carries
    /// three names in three places reads as three actions. It is carried out
    /// via ``DetailModel/setPlayed(_:for:)`` — that fetches the episodes
    /// again afterwards, otherwise the tile would stand there unchanged.
    @ViewBuilder
    private func episodeMenu(for episode: MediaItem) -> some View {
        let isWatched = episode.progress?.isWatched == true

        Button {
            // **Only on marking is a question asked, not on undoing.** Whoever
            // removes a mark means this one episode; whoever sets one
            // often means the state up to there.
            guard !isWatched,
                !DetailModel.precedingUnwatched(before: episode, in: model.episodes).isEmpty
            else {
                Task { await model.setPlayed(!isWatched, for: episode) }
                return
            }
            markingEarlierFor = episode
        } label: {
            Label(
                app: isWatched ? "detail.markUnwatched" : "common.markWatched",
                systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
        Button {
            Task { await model.setFavorite(!episode.isFavorite, for: episode) }
        } label: {
            Label(
                app: episode.isFavorite ? "common.unfavorite" : "detail.favorite",
                systemImage: Glyph.favorite.pair.forItem(episode.isFavorite)
            )
        }
    }

    private func jumpToEpisode(_ id: String) {
        episodeCorrection = id
        episodeScroller?.scrollTo(id, anchor: .center)
        focus = id
        let startedAt = Date()

        seasonJump?.cancel()
        episodeJump?.cancel()
        episodeJump = Task { @MainActor in
            for _ in 1...5 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                // The same loop, the same bug — the rationale is at
                // ``jumpToSeason(_:)``.
                if FocusRules.abandonsRetry(startedAt: startedAt, lastInput: lastInputAt) { break }
                if focus != id {
                    episodeScroller?.scrollTo(id, anchor: .center)
                    focus = id
                }
            }
            episodeCorrection = nil
        }
    }
}

extension View {

    /// The trailer in full screen.
    ///
    /// `fullScreenCover` does not exist on the Mac, and this package's checks
    /// also build for macOS — without this switch `Features` does not build there.
    /// The same pattern is at ``playPauseCommand`` in ``PlayerScreen``.
    ///
    /// Full screen and not a sheet: a trailer in a shrunken window above the
    /// detail page would be no more than a postage stamp at three meters distance, and
    /// the player's controls count on the whole screen.
    fileprivate func trailerCover(
        _ target: Binding<PlaybackTarget?>,
        source: any ContentSource,
        quality: StreamQuality,
        mayPlay: @escaping @MainActor (MediaItem) -> Bool
    ) -> some View {
        #if os(tvOS)
            return fullScreenCover(item: target) { target in
                PlayerScreen(
                    target: target, source: source, quality: quality, mayPlay: mayPlay)
            }
        #else
            return self
        #endif
    }
}
