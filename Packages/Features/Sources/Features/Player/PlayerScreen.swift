import Core
import DesignSystem
import Flows
import Playback
import SwiftUI

/// Playback — picture, controls and everything that lies over it.
///
/// Structure follows the template: the film runs to the edge, over it a gradient
/// downwards, on it the controls inside the overscan-safe area. Everything else —
/// skip, next episode, info area, track choice — appears only when it
/// is needed. A film without controls is the normal case of this view, not
/// the exception.
public struct PlayerScreen: View {

    /// **`@State` instead of `@StateObject`** (AP32, 2026-09-11) — the way for
    /// ``Observation`` models. The one difference: `@StateObject` builds its value
    /// only when it is needed, `@State` immediately. **For this view that changes
    /// nothing:** the host is created outside the wrapper here anyway (see
    /// ``init``), and ``PlayerModel/init`` does nothing but set fields.
    @State private var host: EngineHost
    @State private var model: PlayerModel

    /// One shared focus state for **all** layers.
    ///
    /// Necessary because on tvOS focus only moves reliably between siblings:
    /// the control bar, the skip button and the info area lie on top of each other
    /// as separate layers and are therefore not neighbours. Anyone who relies on the
    /// system's focus guidance here has buttons on screen that cannot
    /// be reached. That is why focus is set explicitly as soon as
    /// the situation changes — see ``wantedFocus``.
    @FocusState private var focus: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Where focus was when an overlay opened — it goes back there.
    @State private var focusBeforeOverlay: String?
    /// When focus last moved — a step that the running
    /// press has already taken does not count twice.
    @State private var focusMovedAt = Date.distantPast

    /// After switching up, the slider should get focus, not Play.
    @State private var wantsRail = false

    private var focusMovedJustNow: Bool {
        Date().timeIntervalSince(focusMovedAt) < 0.25
    }

    /// Channels and programme — only present in the live area.
    private let live: LivePlayerContext?

    /// Where a person's career comes from — see ``FilmographyContext``.
    /// `nil` means: the cast in the information column stays there for viewing only.
    private let filmography: FilmographyContext?

    /// The person whose career currently lies over the film.
    @State private var shownPerson: Person?
    /// Counts the menu presses that are meant for the career — see
    /// ``FilmographySheet/exitToken``.
    @State private var filmographyExit = 0

    /// Which overlay is open.
    @State private var overlay: LiveOverlay.Side?

    /// When someone last did something in the overlay.
    @State private var overlayTouchedAt = Date.now

    /// How long an overlay stays up without input.
    ///
    /// **Longer than the control bar** (``PlayerModel/barTimeout``, four
    /// seconds), and that is no oversight: the bar is **glanced at** — a
    /// remaining time, a progress —, the overlay is **read**. Someone checking
    /// the programme to see what is on at half past eight presses no
    /// key for minutes, and a list that slides away while you read is worse than
    /// one that stays.
    ///
    /// Twelve seconds from the last key press; every movement resets it.
    ///
    /// `nonisolated`, like every rule in this project: a view is bound to the
    /// main thread, and its calculations inherit that — they could then
    /// only be tested with a running UI.
    nonisolated static let overlayTimeout: TimeInterval = 12

    /// Whether the overlay closes after the timeout.
    ///
    /// As a pure calculation, so the timeout is tested and does not have to
    /// be waited out on the TV — the same approach as with
    /// ``PlayerModel/shouldHideBar(shownAt:now:status:)``.
    nonisolated static func shouldCloseOverlay(touchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(touchedAt) >= overlayTimeout
    }

    /// Which group the channel list is restricted to.
    ///
    /// **Here and not in the overlay**, because the overlay is torn down on closing
    /// and takes its state with it. The choice belongs to the session in front of the
    /// TV: whoever picks a group, watches it and opens the list again
    /// wants to find the same group. The full rationale is at
    /// ``LiveOverlay/GroupChoice``.
    @State private var liveGroup: LiveOverlay.GroupChoice = .ofCurrentChannel

    /// How subtitles are drawn — loaded once on opening. The
    /// viewer does not change the setting in the middle of a film; in return
    /// one storage access per redraw is saved.
    private let subtitleStyle = SubtitleStyle.load(from: ProfileStore.playback)

    public init(
        target: PlaybackTarget,
        source: (any ContentSource)?,
        quality: StreamQuality,
        interfaceLanguage: String = "en",
        neighbourChannel: (@MainActor (URL, Int) -> PlaybackTarget?)? = nil,
        live: LivePlayerContext? = nil,
        filmography: FilmographyContext? = nil,
        channelFavorite: (@MainActor () -> Bool)? = nil,
        setChannelFavorite: (@MainActor (Bool) -> Void)? = nil,
        mayPlay: @escaping @MainActor (MediaItem) -> Bool
    ) {
        self.live = live
        self.filmography = filmography
        // **The return from the picture-in-picture window** (AP8): for the same
        // target the view gets engine and model back from the holder; a
        // different target ends what the window held.
        if let held = PictureInPictureKeeper.shared.claim(for: target) {
            _host = State(wrappedValue: held.host)
            _model = State(wrappedValue: held.model)
            return
        }
        PictureInPictureKeeper.shared.discard()
        // The host is created here and handed straight on to the model. It must
        // not be created twice: two hosts mean two engines, and you hear both
        // audio tracks on top of each other — exactly the case from the evidence in E0.
        let host = EngineHost()
        _host = State(wrappedValue: host)
        _model = State(
            wrappedValue: PlayerModel(
                target: target,
                engine: host,
                source: source,
                quality: quality,
                interfaceLanguage: interfaceLanguage,
                neighbourChannel: neighbourChannel,
                channelFavorite: channelFavorite,
                setChannelFavorite: setChannelFavorite,
                mayPlay: mayPlay
            )
        )
    }

    public var body: some View {
        ZStack {
            // systemfarbe: The bars of a film are black, in every colour scheme.
            Color.black.ignoresSafeArea()
            // The invisible route picker for the AirPlay button — see ``AirPlayRouting``.
            AirPlayPickerAnchor()
            // **Fixed identity, and it carries everything here.** Without it SwiftUI
            // sees a changed structure when a layer is added and rebuilds the
            // siblings along with it — including this surface. VLC then draws into
            // a view that is no longer on screen: audio plays, picture is black.
            // That is the third finding from E0, and it applies not only to the
            // surface itself but to everyone who puts something next to it.
            //
            // With a fixed identifier it stays the same view, no matter what changes around it.
            VideoSurface(host: host)
                .id("video-surface")

            scrim
            pauseCatcher

            // The own subtitle renderer. **Always in the tree, even without a
            // line:** a layer that is added only when needed would drag the
            // video surface into the rebuild (the E0 finding from above) —
            // without text the layer is simply transparent. The level must
            // be named because the UIKit video surface does not take its order
            // from the declaration order.
            subtitleOverlay
                .zIndex(5)

            // Via ``PlayerModel/showsBar`` and not via `isBarVisible`: with
            // the info area or the track choice open, the latter deliberately
            // stays set, but the bar must not be drawn then — it showed through
            // as ghost text through the panel gradient that is only 86 % opaque.
            // And not under a live overlay either: channel list or
            // programme over bar AND banner produced three layers of text
            // on top of each other (finding 2026-08-08 on the native live picture) — whoever
            // browses the channels does not need the transport buttons.
            if model.showsBar, overlay == nil {
                TransportBar(model: model, focus: $focus, onUnhandledMove: handleMove)
                    .transition(.opacity)
                // The hint only where there is something below. For a channel
                // "down for info" was on screen and led nowhere — a
                // promise the app does not keep.
                if model.hasInfoPanel { hint }
            }

            // The offers do not go under an open panel either: "Skip intro"
            // showed through there just like the bar. Their state lives in the model,
            // after closing they are back, provided their window is still running.
            if !hasOpenPanel {
                offers
            }
            panels
            // **Over everything, it holds the picture** (AP85).
            if model.asksStillWatching {
                StillWatchingPrompt(
                    episodeTitle: model.target.title,
                    focus: $focus,
                    onContinue: { model.keepWatching() },
                    onStop: { model.close() }
                )
                .zIndex(30)
            }
            stallNotice
                .zIndex(20)

            // **The startup measurement, but only with diagnostics switched on.**
            //
            // It is shown on screen and not merely in the report, because a series of measurements
            // consists of many runs: whoever had to go into the settings
            // after every channel makes three measurements instead of thirty.
            // Top right, where neither bar nor overlays lie.
            startupReadout
                .zIndex(21)

            // **In the stack and with an explicit level.**
            //
            // Two attempts each solved one half and broke the other:
            // as a child of the stack the overlay was visible, but dragged the
            // video surface into the rebuild — black picture. As an overlay on the
            // stack the picture stayed, but it lay behind the UIKit surface and was
            // not visible. Both together only work like this: the surface keeps its
            // identifier and is therefore not rebuilt, and the overlay states
            // explicitly that it lies on top.
            //
            // The level must be named because a UIKit view in the stack does not take its
            // order from the declaration order alone. The same applies to
            // the message above it, otherwise it disappears behind the overlay.
            liveOverlay
                .zIndex(10)
        }
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.22), value: model.isBarVisible)
        // Own animation for the overlay: without it its transition does not run,
        // and a transition that does not run leaves the view where it
        // should begin.
        .animation(.easeOut(duration: 0.2), value: overlay)
        .onMoveCommand { direction in
            // **Before the gate and not behind it** — as in the live area: what the
            // gate discards as an echo has been pressed all the same.
            Diagnostics.cursorKey("Player", FocusTrail.name(direction))
            guard gate.accepts(direction, .now, from: .command) else { return }
            handleMove(direction)
        }
        // **The second way in, for the old remote** (AP4 · K3).
        //
        // The player only had `onMoveCommand`. On the glass-surface remote
        // (2015–2020) swiping produces no move command — and above and
        // below the running picture there is nothing the focus engine could
        // move, so none is produced there either. That made channel list,
        // programme, channel switching and the info area unreachable. **That is
        // "works on one device, not on another household's."**
        //
        // Three latches, and each catches a case of its own:
        //
        // 1. `vertical: true` — only here, where no focus neighbour handles
        //    up and down. In a list every swipe would otherwise run two rows.
        // 2. `overlay == nil` — the overlay brings its **own**
        //    recogniser, and both hang in the same full screen. Two recognisers
        //    on one view report the same stroke; whoever does not stay silent here
        //    while the overlay is open moves it and the player
        //    at the same time.
        // 3. `focus == "screen"` — if a control consumes the movement
        //    (bar, panel), it belongs to it. Without this latch, on the
        //    **new** remote a mere focus shift to the left opened the
        //    channel list: the command would never reach the root, the trailing
        //    gesture would.
        .onRemoteSwipe("Player", vertical: true) { swipe in
            guard overlay == nil, focus == "screen" else { return }
            guard gate.accepts(swipe.asMove, .now, from: .gesture) else { return }
            handleMove(swipe.asMove)
        }
        // **Always intercept and decide yourself** — not attach and detach
        // by condition: re-attaching changes the structure above the
        // video surface, and at the moment of change the key fell through — with
        // the track choice open it closed the whole player instead of the panel
        // (reproduced in the simulator, 2026-08-06). The way back is preserved
        // because the else branch explicitly closes.
        .focusTrail("Player", focus)
        // **Back from the overlay to where it opened** (F-008:
        // "going left I land on the slider instead of the favourite").
        .onChange(of: overlay) { previous, current in
            guard previous != nil, current == nil else { return }
            if let back = focusBeforeOverlay, barHasFocusID(back) {
                focus = back
            }
            focusBeforeOverlay = nil
        }
        .onChange(of: model.isBarVisible) { _, isVisible in
            if !isVisible { wantsRail = false }
            Diagnostics.verbose(
                "Bar: \(isVisible ? "visible" : "hidden") — status \(model.status), "
                    + "seeking \(model.isSeekable ? "yes" : "no")")
        }
        .onExitCommand {
            // **Without showing the bar** — otherwise Back would only ever hide it again.
            model.noteViewer(showsBar: false)
            if model.asksStillWatching {
                model.close()
                return
            }
            if hasOpenPanel {
                closeTopPanel()
            } else if model.isBarVisible {
                // **Back closes the bar first** (user request 2026-09-04);
                // leaving the programme takes the second press.
                model.hideBar()
            } else {
                dismiss()
            }
        }
        .onChange(of: scenePhase) { previous, current in
            if current == .background {
                model.noteBackground()
            } else if current == .active, previous != .active {
                model.noteForeground()
            }
        }
        .playPauseCommand {
            model.noteViewer()
            model.togglePause()
        }
        .task {
            focus = wantedFocus
            // **The player registers with the remote** (AP8) — the listener
            // itself has been running since app launch, so that an idle TV
            // stays reachable.
            RemoteControl.shared.adopt(model)
            await model.begin()
        }
        .onChange(of: wantedFocus) { _, wanted in
            focus = wanted
        }
        .onChange(of: focus) { _, _ in
            focusMovedAt = .now
            // A focus change is an input and resets the bar's timeout.
            // Only while the bar is up: on hiding, focus switches by force
            // to the picture surface, and without this condition exactly that switch would
            // bring the bar straight back — it could never be hidden.
            if model.isBarVisible { model.noteViewer() }
        }
        // **What is running is the most recently seen channel** (viewer finding
        // 2026-09-02: "when I then open another channel and leave and go back
        // in, it does not notice that I had opened another channel").
        //
        // Here and not at everything that can trigger a switch: the
        // arrow keys wrote the memory forward, the channel choice in the
        // overlay did not — but both run through the same target. Whoever
        // builds a third path in future is already covered.
        .onChange(of: model.target.sourceURL) { _, address in
            guard model.target.kind == .live else { return }
            live?.remember(address)
        }
        // If the bar disappears by itself, the hold is moot: the
        // catcher is then standing alone again anyway.
        .onChange(of: model.isBarVisible) { _, isVisible in
            if !isVisible { isScreenHolding = false }
        }
        .onChange(of: model.shouldClose) { _, wanted in
            // When that point is reached is decided by the model and not by this view:
            // at the end of an episode with a successor it switches instead of closing,
            // and a dismissed offer leaves a successor behind that nobody
            // wants to play any more. A black screen with the bar standing looks like
            // an error, and the way back could only be guessed via the menu button.
            // For the full condition see ``PlayerModel/shouldClose``.
            if wanted { dismiss() }
        }
        .onDisappear {
            // **The player signs off, the listener stays** (AP8): a phone
            // that presses "continue watching on the TV" would otherwise hit exactly then a
            // TV that is playing nothing.
            RemoteControl.shared.release()
            // There is no `deinit` that could do this: Swift 6 refuses access
            // to engine and observer there. Without this line the audio keeps running
            // after the picture has disappeared.
            //
            // **Unless the window has taken over** (AP8): then the view leaves,
            // and the engine keeps playing in picture-in-picture.
            if PictureInPictureKeeper.shared.isHolding(model) {
                Diagnostics.playbackStep("Picture in Picture: view goes, the window stays", since: nil)
            } else {
                model.finish()
            }
        }
        // The window is up — the view makes way.
        .onChange(of: model.leavesForPictureInPicture) { _, leaves in
            if leaves { dismiss() }
        }
        // After the return from the window: the window may close, the surface
        // shows again — the new surface attached itself during setup.
        .onAppear {
            if PictureInPictureKeeper.shared.isHolding(model) {
                host.pictureInPicture.stop()
            }
        }
    }

    // MARK: - Layers

    /// The gradient under the controls.
    ///
    /// Visible only with the bar and explicitly without hit testing: an
    /// overlay takes part in it and blocks the focus beneath — the
    /// skip button would then be visible and still unreachable.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(model.isBarVisible ? 0.9 : 0), location: 0),
                .init(color: .black.opacity(model.isBarVisible ? 0.45 : 0), location: 0.26),
                .init(color: .clear, location: 0.52),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The subtitle line — drawn by the app, not by the engine.
    ///
    /// Bottom centre on a dark tile, like the preview in the settings.
    /// Base size 38 points: that matches what the system draws on a
    /// TV, and is scaled by the settings percentage.
    /// With the bar visible the line moves above it instead of
    /// disappearing behind it.
    private var subtitleOverlay: some View {
        // As long as the track is still being prepared on the server, the tile says
        // so honestly — on the very first access per file that takes minutes,
        // and a silent choice looks like a broken one (exactly how it was
        // reported). The hint line is smaller and muted: it is a
        // message from the app, not a subtitle — and it comes via `Text(app:)`,
        // so the in-app language choice applies.
        let isPreparing =
            model.subtitleLine == nil && model.subtitleBitmaps.isEmpty
            && model.isPreparingSubtitle

        return ZStack {
            // **Image subtitles, position-true.** PGS tracks bring position and
            // canvas with them (Blu-ray: 1920×1080); scaling is uniform onto
            // the picture surface — the video fills it in the same aspect ratio.
            GeometryReader { proxy in
                ForEach(model.subtitleBitmaps, id: \.cue.start) { bitmap in
                    let scale = proxy.size.width / CGFloat(bitmap.cue.canvasWidth)
                    Image(decorative: bitmap.image, scale: 1)
                        .resizable()
                        .frame(
                            width: CGFloat(bitmap.cue.width) * scale,
                            height: CGFloat(bitmap.cue.height) * scale
                        )
                        .position(
                            x: (CGFloat(bitmap.cue.x) + CGFloat(bitmap.cue.width) / 2) * scale,
                            y: (CGFloat(bitmap.cue.y) + CGFloat(bitmap.cue.height) / 2) * scale
                        )
                }
            }

            textLane(isPreparing: isPreparing)
            topLane
        }
        .allowsHitTesting(false)
        // No fading in and out per line or image: subtitles change at
        // one-second pace, and the stack's default animation would let every
        // line glide in only when the next one is already due.
        .animation(nil, value: model.subtitleLine)
    }

    /// The line **above** the picture — signs and captions from ASS tracks.
    ///
    /// **A tile of its own and not a second one below.** The same file carries the
    /// dialogue below and the translated caption above; merged below,
    /// they would be unreadable. That is exactly what the conversion to WebVTT
    /// failed on, and exactly why ASS has so far needed the second engine.
    @ViewBuilder
    private var topLane: some View {
        if let line = model.subtitleTopLine {
            VStack {
                // festeschrift: The viewer sets the size under "Subtitles", in percent.
                Text(line)
                    .font(
                        .system(
                            size: 34 * CGFloat(subtitleStyle.size.percent) / 100,
                            weight: .medium
                        )
                    )
                    // systemfarbe: The upper line is a subtitle over the picture — white as in the film.
                    .foregroundStyle(SwiftUI.Color.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 60)
                Spacer()
            }
        }
    }

    /// The text tile of the renderer — line or preparation hint.
    private func textLane(isPreparing: Bool) -> some View {
        VStack {
            Spacer()
            Group {
                if let line = model.subtitleLine {
                    // festeschrift: The viewer sets the size under "Subtitles", in percent.
                    Text(line)
                        .font(
                            .system(
                                size: 38 * CGFloat(subtitleStyle.size.percent) / 100,
                                weight: .medium
                            )
                        )
                        .foregroundStyle(
                            SwiftUI.Color(
                                red: subtitleStyle.color.rgba.red,
                                green: subtitleStyle.color.rgba.green,
                                blue: subtitleStyle.color.rgba.blue
                            )
                        )
                } else if model.subtitleUnavailable {
                    // systemfarbe: Hints appear where the subtitle is, over the
                    // running picture, and look like it — white as in the film, not the
                    // text colour of the colour scheme.
                    Text(app: "player.subtitleUnavailable")
                        .font(.system(size: TypeLevel.text.points, weight: .medium))
                        .foregroundStyle(SwiftUI.Color.white.opacity(0.7))
                } else {
                    // systemfarbe: like the branch above.
                    Text(app: "player.subtitlePreparing")
                        .font(.system(size: TypeLevel.text.points, weight: .medium))
                        .foregroundStyle(SwiftUI.Color.white.opacity(0.7))
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .opacity(model.subtitleLine != nil || isPreparing || model.subtitleUnavailable ? 1 : 0)
            .padding(.bottom, model.showsBar ? 300 : 40)
        }
    }

    /// An invisible button over the whole picture.
    ///
    /// It carries the focus while the bar is hidden, and thereby pauses on
    /// **one** press of the select button. Without it you would first have to bring up the bar
    /// and then hit the pause button — two key presses for the
    /// most common thing needed during a film.
    @ViewBuilder
    private var pauseCatcher: some View {
        if Self.showsCatcher(
            barVisible: model.isBarVisible, isPanelOpen: hasOpenPanel, isHolding: isScreenHolding)
        {
            Button {
                // **The pressed button stays under the thumb** (AP4 · K2).
                //
                // `togglePause()` calls `noteInteraction()`, which brings the bar
                // up — and with that the button the thumb had
                // just pressed disappeared, and the play button took its place.
                // Whoever thought the first press had no effect and pressed once more
                // operated a **different** control than the first
                // time. That is "not clearly clean" in its purest form.
                //
                // The mark is set **before** toggling, in the same
                // pass: a value that only stands in the model's next tick
                // (`status`) would arrive up to half a second late and
                // produce two focus jumps instead of none — exactly the
                // flash class from K5.
                isScreenHolding = true
                model.togglePause()
            } label: {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
            }
            .bareFocusableButton()
            .focused($focus, equals: "screen")
            .ignoresSafeArea()
        }
    }

    /// Skip and next episode.
    ///
    /// Never both at once: both appear at the end — the credits are exactly
    /// the section that triggers the next episode. Side by side there would be two
    /// buttons on screen that mean the same, and focus would have to move between two
    /// layers, which does not work reliably on tvOS.
    /// What stands at the bottom right — **never both**, and the rule for it stands once.
    ///
    /// **It stood twice**, here and for the focus, and the comment next to it
    /// already named this trap. Two copies of the same decision
    /// drift apart at the first refactoring: focus would then point at a
    /// button that does not exist, or a button would stand without focus.
    ///
    /// **And the next-episode offer wins, even during the credits.** That
    /// is intentional and answers the roadmap entry "credits no longer
    /// appear": the trigger point for the next episode **is** the start of the
    /// credits (see ``NextUpPrompt``), so for every episode
    /// with a successor the credits lie entirely behind it. Two offers at the same spot
    /// would be a choice nobody wants to make — "Skip credits" and
    /// "Next episode" end at the same point.
    enum Offer: Equatable {
        case nextUp
        case skip
        /// "Intro skipped · Back" for a few seconds after skipping by itself (AP85).
        case undoSkip
        case none
    }

    static func offer(
        hasNextUp: Bool, hasNextEpisode: Bool, hasSkip: Bool, hasUndo: Bool = false
    ) -> Offer {
        if hasNextUp, hasNextEpisode { return .nextUp }
        if hasSkip { return .skip }
        return hasUndo ? .undoSkip : .none
    }

    private var currentOffer: Offer {
        Self.offer(
            hasNextUp: model.nextUp != nil,
            hasNextEpisode: model.nextEpisode != nil,
            hasSkip: model.skipOffer != nil,
            hasUndo: model.autoSkipHint != nil
        )
    }

    @ViewBuilder
    private var offers: some View {
        if currentOffer == .nextUp, let state = model.nextUp, let episode = model.nextEpisode {
            NextUpOffer(
                episode: episode,
                state: state,
                isSimilar: model.nextIsSimilar,
                stillURL: model.imageURL(
                    for: episode.id,
                    width: ImageSizing.requestWidth(points: MetricsBoard.tv.episode.width)),
                focus: $focus,
                onPlay: {
                    model.noteViewer()
                    Task { await model.advance() }
                },
                onDismiss: {
                    model.noteViewer()
                    model.dismissNextUp()
                }
            )
        } else if currentOffer == .skip, let segment = model.skipOffer {
            SkipOffer(
                segment: segment,
                focus: $focus,
                onSkip: {
                    model.noteViewer()
                    model.skipCurrentSegment()
                }
            )
        } else if currentOffer == .undoSkip, let segment = model.autoSkipHint {
            SkipOffer(
                segment: segment,
                isUndo: true,
                focus: $focus,
                onSkip: {
                    model.noteViewer()
                    model.undoAutoSkip()
                }
            )
        }
    }

    @ViewBuilder
    private var panels: some View {
        // **The menu button is intercepted by every panel itself.** On the root stack of
        // the cover it demonstrably never arrives — there, instead, the
        // system dismissal of the full-screen cover closed the whole player as soon as a
        // panel was open (proven in the simulator, 2026-08-07). On the panel itself
        // the handler is safely in the response path of the focused content, and it
        // hangs without a re-attach trap: it appears and disappears with the panel.
        if model.isChoosingTracks {
            TrackChooser(model: model, focus: $focus)
                .onExitCommand {
                    model.isChoosingTracks = false
                    model.noteViewer()
                }
        }

        if model.isInfoVisible {
            PlayerInfoPanel(
                model: model,
                focus: $focus,
                onSelectPerson: filmography == nil ? nil : { shownPerson = $0 }
            )
            .transition(.move(edge: .bottom))
            .task { await model.loadInfoIfNeeded() }
            .onExitCommand {
                model.isInfoVisible = false
                model.noteViewer()
            }
            // Disabled while the filmography lies above it — otherwise focus falls
            // back into the cast row it came from. The
            // full rationale is at the same place in ``DetailView``.
            .disabled(shownPerson != nil)
        }

        // **Above the information column, not in its place.** The film keeps
        // running, and whoever looked up the name is afterwards back where
        // they were. The menu button closes only the window — that it hangs on the panel
        // itself and not on the root stack has the same reason as above.
        if let person = shownPerson, let filmography {
            FilmographySheet(
                person: person,
                source: filmography.source,
                library: filmography.library,
                exitToken: filmographyExit,
                onOpen: { itemID in
                    shownPerson = nil
                    filmography.open(itemID)
                },
                onClose: {
                    shownPerson = nil
                    model.noteViewer()
                }
            )
            .transition(.opacity)
            .zIndex(2)
            // **The key is intercepted here, as with every panel** — the
            // rationale is at ``panels`` above and has been proven since 2026-08-07.
            // What it means is decided by the window: the counter
            // carries it in, and there the staging profile → list →
            // closed runs. Without this line one press closed the whole film
            // (viewer finding 2026-08-12).
            .onExitCommand {
                filmographyExit += 1
                model.noteViewer()
            }
        }
    }

    /// Channels on the left, programme on the right — both only with a running channel.
    @ViewBuilder
    private var liveOverlay: some View {
        if let live, let side = overlay, model.target.kind == .live {
            LiveOverlay(
                side: side,
                context: live,
                current: currentChannel,
                groupChoice: $liveGroup,
                onSelect: { channel, stock in
                    // **Adopt the catalog first, then play.** Whoever changes the group in the
                    // overlay afterwards runs with a
                    // channel the old catalog does not know — and without this
                    // line the arrow keys, the highlight, the group
                    // and the programme would drop out again. The full rationale is
                    // at ``LivePlayerContext/adopt``.
                    live.adopt(stock)
                    // The switch runs through the same target as the arrow keys: one
                    // engine, one stream. The overlay closes in the process — you have
                    // chosen, and the picture should be free.
                    overlay = nil
                    model.play(live.target(channel))
                },
                onDeeper: {
                    // **Left once more: the groups.** Left is deeper,
                    // right is back — the same everywhere, see
                    // ``LiveOverlay/move(_:)``.
                    if side == .channels { overlay = .groups }
                },
                onClose: {
                    // One level back, not straight to closed: from the groups
                    // you get to the channels, from the channels to the picture.
                    overlay = side == .groups ? .channels : nil
                },
                onActivity: { overlayTouchedAt = .now }
            )
            // **The timeout runs in the view and not in the player's tick.**
            // Unlike the control bar the overlay does not belong to the
            // model: it is a state of this view, and an alarm in the
            // model would first have to learn about it. `task(id:)` goes away with it
            // — there is no timer that keeps running when nothing
            // is open any more.
            .task(id: side) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    if Self.shouldCloseOverlay(touchedAt: overlayTouchedAt, now: .now) {
                        overlay = nil
                        return
                    }
                }
            }
        }
    }

    /// The channel that is currently playing.
    ///
    /// Via the address and not via an identifier: a playback target deliberately carries none for
    /// a channel — there is nothing to remember. The address is
    /// unambiguous, it is the stream itself.
    ///
    /// Via ``Channel/plays(_:)`` and not via an equality test: on
    /// fallback to the raw stream the running address differs from the
    /// registered one. The full rationale is there.
    ///
    /// **And via ``PlaybackTarget/sourceURL`` and not via `url`.** Otherwise
    /// `plays(_:)` finds nothing either, since the remuxer moved the address to
    /// `127.0.0.1` — and without a running channel everything in the overlay that needs it
    /// dropped out: the programme, the highlight, the cursor
    /// on the right row and the group the list opens in
    /// (viewer finding 2026-08-11).
    private var currentChannel: Channel? {
        live?.channels().first { $0.plays(model.target.sourceURL) }
    }

    /// The information given when nothing progresses any more.
    ///
    /// **Instead of a spinner that turns forever.** The concept of this app
    /// explicitly states that every wait ends in a result or a message —
    /// and this was exactly the exception: neither VLC nor the system player report
    /// anything when they make no progress, they report nothing at all.
    ///
    /// The information differs by kind because the cause does. For a
    /// channel it is almost always the provider — it delivers nothing, does not have the channel
    /// in its package, or the one permitted connection is still occupied. For a
    /// recording it is the server or the file. A shared text would mean telling the
    /// viewer the wrong half in both cases.
    /// Which of the three explanations applies.
    ///
    /// **The third is new** (AP3 · V3b, 2026-09-02). If the remuxer fails on
    /// a container AVFoundation does not read — Matroska —, the
    /// app as a last resort tries the system engine on the raw file. That attempt is
    /// **by construction** doomed to fail; the source text itself calls it
    /// elsewhere "a sham fallback". Until here the text said
    /// "The server is not delivering, or the file cannot be read from this
    /// position" — both wrong, and both send the viewer
    /// looking for an error that does not exist.
    ///
    /// Read off the target and not off the state: `containerNotNativelySupported`
    /// **and** immediate delivery means exactly this case.
    ///
    /// **With a finding the board speaks one sentence** (stall level 2,
    /// decision 12: "a sentence without jargon"). The old live sentence — "The channel
    /// delivers nothing", the provider may not have it in its package — is a
    /// **startup** sentence. Over a channel that ran for ten minutes and then stood still, it
    /// sends the viewer to the package although the cause is the remuxer or the connection.
    /// Without a finding, that is without its own remuxer or before the first picture, it stays with
    /// the previous wording. **The sentence per finding** has lived in
    /// ``StallWording`` for both devices since AP58 R3.
    static func stalledTitleKey(
        for target: PlaybackTarget, finding: StallInterpretation.Finding?, line: LineFinding? = nil
    ) -> String {
        if let finding { return StallWording.key(finding) }
        if target.kind == .live { return "player.stalledLive" }
        if lineTight(target, line) { return "player.stillstandLeitungKnapp" }
        return isApparentFallback(target) ? "player.stalledContainer" : "player.stalled"
    }

    /// The explanation under the heading — `nil` when the finding's sentence stands
    /// alone.
    static func stalledHintKey(
        for target: PlaybackTarget, finding: StallInterpretation.Finding?, line: LineFinding? = nil
    ) -> String? {
        if finding != nil { return nil }
        if target.kind == .live { return "player.stalledLiveHint" }
        if lineTight(target, line) { return nil }
        return isApparentFallback(target) ? "player.stalledContainerHint" : "player.stalledHint"
    }

    /// **Tight connection on a file** (AP69, 2026-10-11): the engine has measured that the
    /// provider barely delivers more than the film needs — then the picture does not stand because of
    /// an error but because it is loading ahead. The board says so with both numbers
    /// (``connectionTightHint(_:)``). A finding of the app's own remuxer takes precedence; it is
    /// more precise.
    static func lineTight(_ target: PlaybackTarget, _ line: LineFinding?) -> Bool {
        StallWording.lineTight(target, line)
    }

    /// The sentence with the two numbers — "%@ Mbit/s" arrive, "%@ Mbit/s" the film needs.
    static func connectionTightHint(_ line: LineFinding) -> Text {
        Text(
            app:
                "player.stillstandLeitungKnappHint \(LineFinding.mbit(line.lineMbit)) \(LineFinding.mbit(line.demandMbit))"
        )
    }

    static func isApparentFallback(_ target: PlaybackTarget) -> Bool {
        target.decision.delivery == .directPlay
            && target.decision.reason == .containerNotNativelySupported
    }

    /// The measured startup times — a tool, not a display for everyday use.
    @ViewBuilder
    private var startupReadout: some View {
        if DebugMode.current.isOn, let timing = model.startupTiming {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: timing.opening)
                    .foregroundStyle(ColorRole.textMatt.color)
                // **The reason belongs with it, not only the path.** "native/hls"
                // says what happened, but not why — and that is exactly
                // the question as soon as a title does not take the remuxer. Without it
                // only guessing remains, and guessing in this corner has already twice
                // produced the wrong cause (2026-08-11).
                Text(verbatim: Self.why(model.target.decision))
                    .foregroundStyle(ColorRole.textQuiet.color)
                Text(verbatim: Self.readout(timing))
                    .foregroundStyle(ColorRole.text.color)
            }
            // festeschrift: Measured values in debug mode, equal-width digits — a tool, not text.
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(ColorRole.reason.color.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(TVMetrics.topMargin)
            .allowsHitTesting(false)
        }
    }

    /// Why this path — reason and, if it applied, the bandwidth limit.
    static func why(_ decision: PlaybackDecision) -> String {
        var text = decision.reason.rawValue
        if decision.isBandwidthLimited {
            let limit = decision.maxBitrate.map { "\($0 / 1_000_000)M" } ?? "?"
            text += " · Grenze \(limit)"
        }
        return text
    }

    /// "0.8 s → 1.7 s → 2.5 s" — connection, buffer, total.
    ///
    /// In seconds with one decimal place instead of milliseconds: from three
    /// metres away "2.5 s" can be read, "2517 ms" cannot.
    static func readout(_ timing: StartupTiming) -> String {
        func seconds(_ value: TimeInterval?) -> String {
            guard let value else { return "—" }
            return String(format: "%.1f s", value)
        }
        return seconds(timing.timeToReady) + " → " + seconds(timing.timeToFirstFrame)
            + " → " + seconds(timing.total)
    }

    @ViewBuilder
    private var stallNotice: some View {
        if model.isStalled {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 46))
                    .foregroundStyle(ColorRole.textMatt.color)
                Text(
                    appKey: Self.stalledTitleKey(
                        for: model.target, finding: model.stallFinding, line: model.lineFinding)
                )
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
                if let hint = Self.stalledHintKey(
                    for: model.target, finding: model.stallFinding, line: model.lineFinding)
                {
                    Text(appKey: hint)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 1100)
                } else if model.stallFinding == nil, let line = model.lineFinding,
                    Self.lineTight(model.target, line)
                {
                    Self.connectionTightHint(line)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 1100)
                }
            }
            .padding(40)
            .background(ColorRole.reason.color.opacity(0.86), in: RoundedRectangle(cornerRadius: 20))
            // Decoration and without hit testing: the message lies over the controls,
            // and the way back is via the menu button — it must not
            // intercept that. The same trap as four times before in this project.
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// The hint at the info area, at the bottom edge as in the template.
    private var hint: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "chevron.down")
                Text(app: "player.infoHint")
            }
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.textQuiet.color)
            .padding(.bottom, 18)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Focus and remote

    /// Whether the overlays are available at all.
    ///
    /// Only with a running channel and only if the live area has contributed something.
    /// As one calculation because it is needed in four places — four copies
    /// drift apart as soon as one of them is touched.
    private var canOverlay: Bool {
        live != nil && model.target.kind == .live
            && !model.isInfoVisible && !model.isChoosingTracks
    }

    /// Whether focus is on a button of the bar — then left and
    /// right belong to the bar, not to the overlays. The identifiers are those of the
    /// ``TransportBar``; a new button belongs here too.
    private var barHasFocus: Bool {
        model.isBarVisible && barHasFocusID(focus)
    }

    private func barHasFocusID(_ id: String?) -> Bool {
        [
            "chapterBack", "back10", "play", "forward30", "chapterNext", "cc", "live", "pip",
            "airplay", "skip", "favorite",
        ]
        .contains(id ?? "")
    }

    /// The leftmost button of the bar — from there left is free again
    /// for the channel list. The order is that of the ``TransportBar``.
    private var barLeftmost: String {
        model.hasChapters ? "chapterBack" : model.isSeekable ? "back10" : "play"
    }

    /// The rightmost button — from there right is free again for
    /// the programme.
    private var barRightmost: String {
        model.canFavoriteChannel ? "favorite" : "airplay"
    }

    private var hasOpenPanel: Bool {
        model.isInfoVisible || model.isChoosingTracks || overlay != nil
    }

    /// Whether the skip button is currently on screen.
    ///
    /// The same condition as in ``offers``, and therefore as one calculation: two
    /// places drift apart, and focus would then point at a button that does
    /// not exist — tvOS then puts it at an arbitrary place, and nobody
    /// finds it again.
    /// The skip button or, after skipping by itself, its "Back" — the same place, the same
    /// focus rule.
    private var isSkipOffered: Bool { currentOffer == .skip || currentOffer == .undoSkip }

    /// Where focus belongs as soon as the situation changes.
    ///
    /// As **one** calculation and not as scattered assignments: otherwise two
    /// places set focus against each other, and it jumps back and forth on every
    /// picture change. The order is that of urgency — what is open takes precedence.
    private var wantedFocus: String {
        if model.asksStillWatching { return "still-continue" }
        if model.isChoosingTracks { return "chooser-close" }
        if model.isInfoVisible { return "info-tab-\(InfoTab.info.rawValue)" }
        if model.nextUp != nil { return "nextup-play" }
        // **The skip button before the bar**, even when it is up. It lies in
        // a layer of its own in the ZStack and is thus no neighbour of the button row —
        // without this line it would stand visibly on screen while focus
        // sticks to the bar, and could not be selected for the four seconds until it hides. Exactly
        // then is when you press it. The way back to the bar is left, see
        // ``handleMove(_:)``; and when the button disappears, the same calculation brings
        // focus back by itself.
        if isSkipOffered { return "skip" }
        if model.isBarVisible {
            if isScreenHolding { return "screen" }
            return wantsRail && model.isSeekable ? "rail" : "play"
        }
        return "screen"
    }

    /// Whether the catcher is built over the picture surface.
    ///
    /// **Three states, and the third is new** (AP4 · K2): it also stands with
    /// the bar visible, as long as the picture surface holds focus — otherwise
    /// the control that was just pressed would disappear under the
    /// thumb.
    static func showsCatcher(barVisible: Bool, isPanelOpen: Bool, isHolding: Bool) -> Bool {
        guard !isPanelOpen else { return false }
        return !barVisible || isHolding
    }

    /// Whether the picture surface holds focus although the bar is up.
    ///
    /// Set on a press on the surface, released on the operator's first own
    /// movement and when the bar disappears by itself.
    /// **No time window**, and that is deliberate: a timeout would need a clock
    /// in the view, and its expiry would move focus on without anyone doing anything — yet
    /// another jump nobody triggered.
    @State private var isScreenHolding = false

    /// Keeps the two reports of the same hand movement apart — command and
    /// gesture. See ``MoveGate``.
    @State private var gate = MoveGate()

    private func handleMove(_ direction: MoveCommandDirection) {
        // Whoever presses a direction themselves wants to leave the picture surface — the
        // hold from K2 is thereby done.
        isScreenHolding = false
        // Movements that a focused element consumes itself — the switch
        // between two buttons — do not arrive here. So what arrives is only
        // what nobody wanted, and that may bring up the controls.
        switch direction {
        // **With a channel there is nothing to expand.** Cast, further episodes
        // and track choice all refer to a file; a running channel has
        // none of it. The area slid out anyway and stood empty on screen —
        // and because it pulled focus, it looked as if playback hung.
        // Up and down belong to channel switching there, see below.
        // **With a channel, up and down belong to channel switching.** That is the
        // movement known from every TV, and it is free here because a
        // channel has no info area. Without neighbours nothing happens — then it is
        // a single channel, and a switch would go in a circle.
        // Left and right bring in what the live area contributes: the channels
        // and the programme.
        //
        // **Closing happens with the direction that points away from what was brought in.** The
        // list came from the left, so you push it back to the left — by pressing
        // right. That is the same movement as bringing it in, just reversed,
        // and it is the only one that is free: a press towards its own side
        // means "further in" inside a list and belongs to it.
        //
        // **On the bar, left and right belong to the buttons — all the way to the
        // edge** (device findings 2026-09-03): first "right opens the programme, the
        // audio-track button is skipped" (Telve 2 UHD), then, after the
        // lock, "left opens the channel list only once the bar is gone"
        // — twelve presses to the left in five seconds are recorded for that in F-009.
        // Both are right: between the buttons the focus moves, and at the
        // outermost button, where there is no neighbour any more, the overlay comes.
        // **Focus has already moved at the time of the command** (F-020: "play → back10
        // +26 ms after ←", then the command, then the channel list). If it has only
        // been at the edge since this press, the press has already taken the step
        // — the overlay belongs to the next one.
        case .left
        where canOverlay && overlay == nil && (!barHasFocus || (focus == barLeftmost && !focusMovedJustNow)):
            overlayTouchedAt = .now
            focusBeforeOverlay = focus
            overlay = .channels
        case .right
        where canOverlay && overlay == nil && (!barHasFocus || (focus == barRightmost && !focusMovedJustNow)):
            overlayTouchedAt = .now
            focusBeforeOverlay = focus
            overlay = .guide
        // **From here on the overlay takes the directions itself** — it knows
        // its level and its list ends. These two branches remain as a net
        // for the case that nothing in it holds focus at all.
        case .right where canOverlay && overlay != nil && overlay != .guide:
            overlay = nil
        case .left where canOverlay && overlay == .guide:
            overlay = nil

        // **Not while the bar is up** (user request 2026-09-04): then
        // up and down belong to the controls, and the channel switch waits until
        // the bar is gone.
        // **The channel switch runs through the bar** (user request
        // 2026-09-04): without the bar, up and down switch as before. With the
        // bar up, it goes **down** from the button row to the next channel —
        // the cursor stays on Play, the next press switches on — and
        // **up** from the slider to the previous one, the cursor stays on the slider.
        // In between (button → slider, slider → Play) focus moves as
        // before. That way you can keep pressing up or down continuously without
        // first pushing the bar away.
        case .up where model.canSwitchChannel && !hasOpenPanel && overlay == nil && !model.isBarVisible:
            model.switchChannel(by: -1)
        case .down where model.canSwitchChannel && !hasOpenPanel && overlay == nil && !model.isBarVisible:
            model.switchChannel(by: 1)
        case .down where model.canSwitchChannel && !hasOpenPanel && overlay == nil && barHasFocus:
            wantsRail = false
            model.switchChannel(by: 1)
            focus = "play"
        // Here too: if focus has only moved to the slider with this press
        // (Play → slider), the press has taken its step —
        // only the next one switches (F-029: "I can no longer get to the
        // slider").
        case .up
        where model.canSwitchChannel && !hasOpenPanel && overlay == nil
            && ((focus == "rail" && !focusMovedJustNow) || (barHasFocus && !model.isSeekable)):
            // After switching up, focus belongs on the slider — the bar
            // of the new channel would otherwise put it on Play (F-030).
            wantsRail = model.isSeekable
            model.switchChannel(by: -1)

        case .down where !hasOpenPanel && model.hasInfoPanel:
            model.isInfoVisible = true

        // **The way back out of the info area.** It only had the menu button, and that
        // is not what you reach for on the remote when something slides in
        // from below: you press up, towards where the film is still
        // visible. If no answer came from there, you were stuck.
        //
        // An `.up` only arrives if nobody inside the area consumed it —
        // focus is then already on the index cards, that is, at
        // the top edge. Exactly there closing is the right answer.
        case .up where model.isInfoVisible && !model.isChoosingTracks:
            model.isInfoVisible = false
        // Between the button row and the skip button focus must be set
        // explicitly: both lie in separate layers of a ZStack and are
        // thus no neighbours — geometric focus guidance does not find its way from one layer
        // into the other.
        //
        // Both cases name the button the jump starts from, and not merely the
        // direction. Otherwise a press to the right would pull focus out of the middle of the
        // row too, and the three remaining buttons could no longer be reached
        // while the skip button is up.
        case .left where focus == "skip" && model.isBarVisible && !hasOpenPanel:
            focus = "play"
        case .right where focus == "cc" && isSkipOffered:
            focus = "skip"
        default:
            break
        }
        // Every movement that arrives is an input and resets the bar's timeout
        // — including those handled above. Otherwise it hides in the middle of a movement
        // the viewer is just making.
        model.noteViewer()
    }

    private func closeTopPanel() {
        if overlay != nil {
            overlay = nil
        } else if model.isChoosingTracks {
            model.isChoosingTracks = false
        } else {
            model.isInfoVisible = false
        }
        model.noteViewer()
    }
}

extension View {

    /// The play button of the remote.
    ///
    /// Only present on tvOS. The host machine also compiles the tests of this package,
    /// and `onPlayPauseCommand` does not exist there — without this switch
    /// `Features` does not build on macOS.
    fileprivate func playPauseCommand(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
            return onPlayPauseCommand(perform: action)
        #else
            return self
        #endif
    }
}
