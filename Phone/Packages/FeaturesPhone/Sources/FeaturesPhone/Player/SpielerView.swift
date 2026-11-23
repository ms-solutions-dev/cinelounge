import Core
import DesignSystemPhone
import Flows
import NetworkStatus
import Playback
import PlaylistKit
import SwiftUI

/// The player — **this is where a film runs for the first time.**
///
/// **Every target is 44 × 44, also after fading out.** The most serious finding of the
/// usability review was here: Back was 22 × 22, subtitles, AirPlay and More each
/// 21 × 21, the drag handle of the timeline 12 × 12 — and after three seconds the player
/// hides everything. On a screen held sideways in both hands, this is the place where a
/// mis-grab costs the picture.
///
/// **The bar fades out, but never from under the finger.** The timer runs only while
/// nothing is touched; every touch resets it. And the way back stays **always** visible
/// — it is the only way out, and an invisible exit is none.
///
/// **The only view that rotates.** A film is landscape; everything else in this app is
/// portrait and does not rotate with it. That is why the rotation lives here and
/// nowhere else.
public struct PlayerView: View {

    @State private var model: PlayerModel
    /// **A held state and not a computed property.**
    ///
    /// Until 2026-09-06. `sheetState` built a **new** ``SheetState`` from a `Bool` on every redraw.
    /// The sheet could thereby be opened but not closed: the grip writes into the object
    /// that ``Blattgeruest`` received — and on the next pass a fresh one with `.trackSelection`
    /// in it stood there again.
    ///
    /// **Do not fall back to `sheet(isPresented:)`.** That would bypass detent, grip and
    /// radius from ``Blattgeruest`` and would be the fourth sheet with its own measures.
    /// How far the picture is currently pulled down, 0…1 — see ``SwipeZones/pan``.
    @State private var drag: Double = 0

    /// How the picture currently lies — see ``PinchGesture``.
    ///
    /// **A state of the view and not of the model.** It describes how it is drawn and not
    /// what is running; the model survives a source switch, the drawing surface does not.
    @State private var pictureState: ImageLayout = .fullImage
    /// Counts every snap — the fade-in hangs on this and not on a timer.
    @State private var didSnap = 0
    /// The scaling of the picture while two fingers pinch — see ``PinchGesture/metrics``.
    @State private var pinchScale: Double = 1
    /// Whether a pinch is under way — the ``SwipeZones`` then release their drag.
    @State private var isPinching = false

    /// A sentence that stands briefly above the picture and goes away by itself.
    ///
    /// **The place where the player answers when an action was not carried out.** Until
    /// 2026-09-10 it did not exist, and a rejected Picture in Picture therefore did nothing,
    /// silently (E38). It carries a **key** and not a finished sentence: the message arises
    /// in a button row that knows no language, and translation happens in one place.
    ///
    /// **Not a ``StateBlock``.** That belongs to an error that stops the film; here it
    /// keeps running, and the information is a marginal remark — the same separation that
    /// ``HintCapsule`` describes.
    @State private var briefHint: String?
    @State private var hintRun = 0
    /// Whether the fade-in is currently up.
    @State private var isStateShown = false
    /// The aspect ratio of the drawing surface. **Read from it, not computed from the
    /// device** — on a split screen the computed number would be off.
    @State private var screenFormat: Double = 0
    @State private var sheetState = SheetState()
    @State private var fadeOutTimer: Task<Void, Never>?

    /// Whether the film is currently running in the small window.
    ///
    /// **Held and not queried.** ``PictureInPicture`` reports the change through its two
    /// callbacks; reading it off in the body would mean hoping for a redraw that comes for
    /// another reason.
    @State private var inWindow = false

    /// The volume that last came from the device buttons — see ``VolumeSlider``.
    @State private var buttonLevel: Double?

    /// What the swipe surface is currently reporting — **written there, drawn here.**
    ///
    /// See ``SwipeZones/lookahead``: drawing happens on the ``FeedbackStage``, because
    /// only it knows where the buttons are.
    @State private var lookahead: TimeInterval?
    @State private var level: Level?
    @State private var fast = false
    @State private var jumpState: JumpIndicator.State?
    /// What the ``FeedbackStage`` last did not place — see ``FeedbackLayout``.
    @State private var feedbackLayout = FeedbackLayout()
    /// Every grip counts up — **the identifier of the fade-out timer** (finding B5).
    ///
    /// Until 2026-09-25 ``restartClock()`` only set `isBarVisible = true`; if the bar was
    /// already up, nothing changed, and the timer kept running from the first touch.
    @State private var touches = 0

    /// The measured rows of the bar — see ``FeedbackSlots/Buttons``.
    ///
    /// **Three measurements and no common value**, because each row reports its own
    /// geometry; they are assembled in ``buttons``.
    @State private var headerFrame: CGRect?
    @State private var transportFrame: CGRect?
    @State private var barFrame: CGRect?

    /// The channel list over the picture.
    ///
    /// **A held state and not a sheet.** A sheet lies horizontally across the picture; held
    /// in landscape, a strip of two rows would remain for the list — see ``ChannelPicker``.
    @State private var isChannelPickerOpen = false

    /// The model of the channel list — **built once and not per opening.**
    ///
    /// It loads 7,746 channels and their programme from the local store. A model per opening
    /// would mean doing the same work again at every second look at the list.
    @State private var channelSelection: LiveModel?

    private let back: () -> Void
    private let channelSource: (any ChannelListingSource)?

    public init(
        job: PlaybackJob, source: (any PlayerSource)?, networkMonitor: NetworkStatus.NetworkWatch? = nil,
        channelSource: (any ChannelListingSource)? = nil,
        back: @escaping () -> Void = {}
    ) {
        _model = State(
            initialValue: PlayerModel(
                job: job, source: source, networkMonitor: networkMonitor))
        self.channelSource = channelSource
        self.back = back
    }

    /// Whether the channel list is offered.
    ///
    /// **By origin and not by the type of the source.** The same player shows films, portals
    /// and channels; only for a channel is a channel list a way and not a jump into a
    /// foreign catalog. **A recording from the day's schedule is not a channel** (A2): it
    /// has an end, and from it you do not switch onward.
    private var isChannel: Bool {
        model.job?.origin == .channelList && model.job?.kind == .live
            && channelSource != nil
    }

    public var body: some View {
        ZStack {
            // systemfarbe: The ground behind a film is black and not popcorn-cream. It is not
            // part of the UI, but what a picture with a different aspect ratio leaves free at
            // top and bottom — and there no brand colour belongs, but what a cinema hall has
            // there.
            Color.black.ignoresSafeArea()

            switch model.state {
            case .isLoading:
                // **``PlaybackPhase/loadingStart`` and not `LoadingState(message:)` by hand.**
                // Until 2026-09-06 the state had not a single producer, while ten views rebuilt its
                // content next to it. And its second tier —
                // ``PlaybackPhase/loadingLong``, "the same spinner, four seconds later" —
                // is reached by ``LoadingState`` by itself: exactly what the player needs on the
                // tunnel, where nine seconds until the first picture are the normal case.
                StateView(
                    state: .loadingStart, action: { Task { await model.start() } })
                backPath
            case .disrupted(let state):
                // **The loud button tries again, the way back stands next to it.**
                //
                // Until 2026-09-06 the loud button here was the **only** exit, and it led out instead of
                // trying once more (contradiction W4 from the review): the view carries neither a
                // navigation bar nor a tab bar nor a swipe way back. A state whose only button says
                // "Try again" and in truth aborts, lies twice.
                StateView(
                    state: state, action: { Task { await model.start() } })
                backPath
                // **The way to the other source, right here** (2026-09-16). The source button sits in
                // the header bar, and that exists only over a running picture. If the first mirror did
                // not carry, you stood until then before "Try again" — which took the same dead source
                // once more — and the way back. Only where there is something to choose;
                // ``loadSelection()`` has fetched the list since the same day even without a successful
                // start.
                if model.choice.isWorthwhile {
                    otherSource
                }
            case .isPlaying:
                // **The picture follows the finger when pulling down** — and comes back if the pull
                // was too short. Without the movement the gesture would be an invisible threshold.
                Group {
                    image
                    controls
                }
                // **On the stack and not on the picture** — the swipe zones lie over the picture and
                // caught every touch; see ``PinchGesture``.
                .withPinch(
                    image: model.imageFormat ?? 0,
                    screen: screenFormat,
                    state: $pictureState,
                    metrics: $pinchScale,
                    isPinching: $isPinching,
                    inWindow: inWindow,
                    didSnap: { fresh in memorize(fresh) }
                )
                .offset(y: drag * 160)
                .opacity(1 - drag * 0.4)
                .animation(drag == 0 ? Motion.expand : nil, value: drag)
            }
        }
        .movieOnly()
        // **Neither navigation bar nor tab bar.** Seen on screen: above the black picture
        // stood the system's "‹ Back", below the five tabs — on a screen that is only meant to
        // show the film. The player carries its way back itself, and a tab switch in the
        // middle of a film is not a way but a slip.
        .withoutNavigationBar()
        .withoutTabBar()
        // **The fade-in hangs on the counter and not on the state.** The same state twice —
        // there and back — is two events; on the state alone the second fade-in would depend
        // on the first and not happen.
        .task(id: didSnap) {
            guard didSnap > 0 else { return }
            withAnimation(Motion.expand) { isStateShown = true }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.expand) { isStateShown = false }
        }
        .task { await model.start() }
        // **The subtitles move with the crop.** Otherwise the fill cuts away exactly what it
        // is there for — the calculation is in ``SubtitleLayout``, so that it can be
        // recalculated without a player.
        .task(id: visibleFraction) {
            model.host.controller.setSubtitlePosition(visibleFraction: visibleFraction)
        }
        // **The small window belongs to the system.** As long as it is up, it determines the
        // surface; a pinch gesture and the command of the screen-reader aid would grip into
        // the void there — see ``PinchGesture`` and ``GestureCommands``.
        .onAppear {
            model.host.pictureInPicture.onStarted = { inWindow = true }
            model.host.pictureInPicture.onStopped = { inWindow = false }
        }
        // **With the title and only once.** ``PlayerModel/loadSelection()`` does not fetch again
        // if something is already there; the `id` makes sure that the question is asked at all
        // after an episode switch. Until 2026-09-16 it hung on the **successful** start
        // (`job?.identifier`) — so on the error screen there was no choice, precisely where
        // another source is needed.
        .task(id: model.identifier) { await model.loadSelection() }
        .onDisappear {
            Task { await model.finish() }
            // **And the brightness back, if it comes from here** — see
            // ``Brightness/resetValue(outcome:isSet:now:)``. A phone that stays dark after
            // the film looks broken.
            Brightness.reset()
        }
        .sheet(sheetState) { identifier in sheetContent(identifier) }
        // **Only here.** `Rotation` ties the allowed orientations to exactly this view; anyone
        // who leaves it out gets a portrait player with black bars.
        .withRotation()
    }

    // MARK: - Picture and controls

    private var image: some View {
        // **The aspect ratio of the surface comes from the surface.** Computing it fixed
        // would mean guessing the device — and on a split screen or in another window the
        // number would be off.
        GeometryReader { space in
            VideoSurface(host: model.host, state: pictureState)
                // **First scale, then crop.** Without the crop the picture would grow beyond the
                // surface during the gesture and lie over the controls. The gesture itself hangs on the
                // stack, see ``PinchGesture``.
                .scaleEffect(pinchScale)
                .clipped()
                // **The remembered setting comes as soon as the format is known** — and not on
                // appearing: there the player knows nothing yet, and the memory would be looked up
                // under a format that does not exist.
                .task(id: model.imageFormat) {
                    guard let format = model.imageFormat else { return }
                    pictureState = PictureFill.shared.state(forItem: format)
                }
                .onAppear { screenFormat = aspectRatio(space.size) }
                .onChange(of: space.size) { _, fresh in screenFormat = aspectRatio(fresh) }
        }
        .ignoresSafeArea()
        // **The gestures get their lines** — and they hang on the picture, because the
        // gestures lie there. See ``GestureCommands``.
        .withGestureCommands(
            rate: speedGesture, close: back,
            pictureState: stateIsWorthwhile && !inWindow ? pictureState : nil,
            setPictureState: { fresh in
                guard fresh != pictureState else { return }
                pictureState = fresh
                memorize(fresh)
            })
    }

    /// After a switch of the picture fit — **remembered under the format of the picture**,
    /// not under the title: anyone who fills 21:9 wants that for every 21:9 film. Plus the
    /// fade-in and a fresh fade-out timer. Gesture and command of the screen-reader aid take
    /// the same path.
    private func memorize(_ fresh: ImageLayout) {
        if let format = model.imageFormat {
            PictureFill.shared.set(fresh, forItem: format)
        }
        didSnap += 1
        restartClock()
    }

    /// Width over height — 0 if that does not yield a number.
    ///
    /// **A function of its own and not a calculation in the body** (AP7): it occurs in two
    /// places, and a division by zero does not belong in a view body.
    private func aspectRatio(_ size: CGSize) -> Double {
        size.height > 0 ? size.width / size.height : 0
    }

    /// Whether the picture fit is a choice at all.
    ///
    /// **Gone instead of greyed out** — the same rule as at ``CommandButtons``. If the
    /// picture fits the surface exactly, there is nothing to fill; a command for it would be
    /// an invitation whose answer is the same every time. With the direct renderer
    /// ``imageFormat`` is `nil`, and the factor therefore becomes 1 — nothing appears there
    /// either.
    private var stateIsWorthwhile: Bool {
        PictureFill.fillFactor(image: model.imageFormat ?? 0, screen: screenFormat) > 1.02
    }

    /// Which share of the picture height is visible — 1 as long as nothing is cropped.
    ///
    /// **Only in the filled state is anything gone at all.** With the whole picture
    /// everything lies in the surface, and the subtitles stand where they should; then no
    /// rule has to overrule the viewer who has set larger subtitles in the system.
    private var visibleFraction: Double {
        guard pictureState == .fillsScreen, let format = model.imageFormat else { return 1 }
        return SubtitleLayout.visibleFraction(image: format, screen: screenFormat)
    }

    /// The long press on the speed — `nil` where it can do nothing.
    ///
    /// **Two conditions, and both are information rather than guesses:** the engine itself
    /// says ``supportsSpeed``, and a runtime above zero distinguishes the film from the channel.
    /// On a channel, double speed would be a run towards the live edge, after which the
    /// stream stands.
    ///
    /// **Once released, the chosen speed applies again** and not 1 (AP58 G1, A6) — see
    /// ``PlayerModel/holdSpeed(_:)``.
    private var speedGesture: ((Double) -> Void)? {
        guard model.speedOffered, model.duration > 0 else { return nil }
        return { model.holdSpeed($0 != 1) }
    }

    /// The time axis of the bar and the swipe surface — **the runtime, or for a channel the
    /// window in the buffer** (AP58 G1, A1). A channel without a buffer has none.
    private var timeline: (start: TimeInterval, duration: TimeInterval) {
        if let window = model.timeShiftWindow { return (window.start, window.length) }
        return (0, model.job?.kind == .live ? 0 : model.duration)
    }

    /// Lets ``briefHint`` appear and go again.
    ///
    /// **Two seconds and not one.** The level and the ``JumpIndicator`` confirm something
    /// that has just happened — a glance is enough. Here a sentence is shown that explains
    /// why something did **not** happen, and that one has to be able to read.
    private func showBriefHint(_ key: String) {
        briefHint = key
        hintRun += 1
        let run = hintRun
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if hintRun == run { briefHint = nil }
        }
    }

    @ViewBuilder
    private var controls: some View {
        ZStack {
            // **The swipe zones lie under the bar, not over it.** Otherwise an invisible surface
            // swallows the buttons on it.
            SwipeZones(
                duration: timeline.duration, location: model.location - timeline.start,
                skip: {
                    model.set(location: $0 + timeline.start); restartClock()
                },
                brightness: { Brightness.update(um: $0) },
                volume: { Volume.update(um: $0) },
                handleInput: { toggleBar() },
                // **The same path as the transport row.** `jump(_:)` clamps at start and end; a
                // calculation path of its own here would be the second place where a jump could run
                // past the end of the film.
                jumpBy: {
                    model.jump($0); restartClock()
                },
                released: {
                    Brightness.release()
                    Volume.release()
                },
                pan: { drag = $0 },
                finish: back,
                buttonLevel: buttonLevel,
                // **Only where the engine can do it and it means something.** The remuxer feeds its
                // queue at the pace of the stream, and a channel has no end to hurry towards — there
                // the gesture hints at nothing.
                rate: speedGesture,
                // **Two fingers belong to the pinch gesture** — see ``PinchGesture``.
                isPinching: isPinching,
                lookahead: $lookahead, level: $level, fast: $fast,
                jumpState: $jumpState)
            #if canImport(UIKit)
                // The system control for the volume — invisible, but in the hierarchy, and thereby
                // also the suppression of the system display. What the device buttons move comes back
                // via `changed` and appears as the same bar as when swiping.
                VolumeSlider(changed: { buttonLevel = $0 })
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            #endif

            // **The bar always lies in the stack and only becomes invisible.** Until 2026-09-25 it
            // dropped out when fading; then there were no measured buttons either, and a message
            // after a rotation with the bar down would have fallen back on the frame of the old
            // orientation. Invisible, it catches no touch and does not exist for the screen-reader
            // aid — for the viewer that is the same as gone.
            VStack(spacing: 0) {
                PlayerHeader(
                    host: model.host,
                    title: model.job?.title ?? "",
                    // **The note of a truncated file stands in the second line**, as on the TV (AP58 R4).
                    beside: Self.secondLine(model.job?.beside, model.fileHint),
                    // **Since AP58 G1 the sheet also carries the speed tiers** — the button therefore also
                    // stands where there are no subtitles but a speed.
                    hasSubtitles: !(model.job?.subtitles.isEmpty ?? true)
                        || model.speedOffered,
                    back: back,
                    trackSelection: { sheetState.open(.trackSelection) },
                    // **The button stands only where there is something to choose.** With a single row
                    // the choice is none — the same rule as with the subtitle button next to it.
                    sourceChoice: model.choice.isWorthwhile
                        ? { sheetState.open(.sourcesPortal) } : nil,
                    channelList: isChannel ? { openChannelPicker() } : nil,
                    infoBoard: model.hasBoard ? { sheetState.open(.infoBoard) } : nil,
                    // **Back from the small window means: the bar is up again.** iOS expects an
                    // acknowledgement on the way back; without it a window remains that can no longer be
                    // closed.
                    exitPictureInPicture: { model.isBarVisible = true },
                    report: showBriefHint
                )
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.stage))
                } action: {
                    headerFrame = $0
                }
                .padding(.top, MetricsBoard.phone.gutter)

                Spacer(minLength: 0)

                TransportRow(
                    isRunning: model.isRunning,
                    jump: {
                        model.jump($0); restartClock()
                    },
                    setEnabled: {
                        model.togglePlayback(); restartClock()
                    },
                    isSeekable: model.isSeekable,
                    chapters: model.hasChapters
                        ? { forward in
                            model.skipChapter(forward: forward); restartClock()
                        } : nil,
                    toLive: model.isBehindLive
                        ? {
                            model.backToLive(); restartClock()
                        } : nil
                )
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.stage))
                } action: {
                    transportFrame = $0
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: MetricsBoard.phone.gutter) {
                    // **A channel without a buffer has no bar** — it would stand at zero and say
                    // nothing.
                    if timeline.duration > 0 {
                        Timeline(
                            location: model.location - timeline.start, duration: timeline.duration,
                            jump: {
                                model.set(location: $0 + timeline.start); restartClock()
                            },
                            links: model.timeShiftWindow == nil
                                ? nil
                                : AppLanguageSetting.text(
                                    model.isBehindLive ? "player.behindLive" : "player.live"),
                            lookahead: model.trickplay.map { raster in
                                { time in JellyfinDetailSource.slice(from: raster, at: time) }
                            })
                    } else {
                        Spacer(minLength: 0).frame(height: Metrics.target)
                    }
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.stage))
                } action: {
                    barFrame = $0
                }
                .padding(.bottom, MetricsBoard.phone.gutter)
            }
            .background {
                // A gradient from top and bottom, so that white text stays legible on a bright
                // picture — a continuous surface would cover the film.
                VStack {
                    LinearGradient(
                        colors: [.black.opacity(0.7), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 140)
                    Spacer(minLength: 0)
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 160)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .opacity(model.isBarVisible ? 1 : 0)
            .allowsHitTesting(model.isBarVisible)
            .accessibilityHidden(!model.isBarVisible)
            // **No way back when the bar is down** (2026-09-07, on-device feedback: the Back button at
            // the top is always visible, which is annoying during a live broadcast). Until then it
            // stood as the only element over the picture, on the grounds that an invisible exit is
            // none. As of today there is the second exit that everyone knows: pull down. A tap
            // brings the bar — and with it the button — back at any time.
        }
        .animation(Motion.expand, value: model.isBarVisible)
        .task(
            id: BarClock(
                isVisible: model.isBarVisible, settled: model.settled, touches: touches)
        ) { await runClock() }
        .onChange(of: model.settled) { _, settled in
            guard settled else { return }
            AccessibilityNotification.Announcement(
                AppLanguageSetting.message(StallWording.key(model.stallFinding))
            ).post()
        }
        .overlay { feedbackOverlay }
        .overlay(alignment: .bottomTrailing) { offers }
        .overlay {
            // **Over everything, it holds the picture** (AP85).
            if model.asksStillWatching {
                StillWatching(onContinue: { model.keepWatching() }, onStop: back)
            }
        }
        .coordinateSpace(.named(Self.stage))
        .overlay { channelPickerSurface }
    }

    /// **Skip and next episode, also over a lowered bar** (AP58 R4).
    ///
    /// Both offers have a window, and it runs out whether the bar is up or not — a counter
    /// running down invisibly would tear the viewer into the next episode without warning.
    /// That is why they lie over the picture, bottom right as on the TV, and move up over the
    /// bar when it is up.
    @ViewBuilder
    private var offers: some View {
        VStack(alignment: .trailing, spacing: MetricsBoard.phone.gutter) {
            if let section = model.skipOffer {
                SkipButton(kind: section.kind) {
                    model.skip()
                    restartClock()
                }
            } else if let section = model.autoSkipHint {
                SkipButton(kind: section.kind, isUndo: true) {
                    model.undoAutoSkip()
                    restartClock()
                }
            }
            if let title = model.offerTitle, let offer = model.nextOffer {
                NextEpisode(
                    title: title, image: model.offerImage, state: offer,
                    similar: model.next == nil, stay: model.stay
                ) {
                    Task { await model.playNext() }
                }
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, model.isBarVisible ? 88 : MetricsBoard.phone.gutter)
        .animation(Motion.expand, value: model.nextOffer == nil)
        .animation(Motion.expand, value: model.skipOffer?.id)
    }

    /// The second line of the header — `nil` if nothing is there.
    nonisolated static func secondLine(_ split: String?...) -> String? {
        let present = split.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    /// The name of the space in which buttons and feedback are measured.
    nonisolated private static let stage = "playerStage"

    /// The measured rows — `nil` until all three have reported once.
    private var buttons: FeedbackSlots.Buttons? {
        guard let headerFrame, let transportFrame, let barFrame else { return nil }
        return FeedbackSlots.Buttons(
            header: headerFrame, transport: transportFrame, bar: barFrame)
    }

    /// **Everything the player reports over the picture, on one surface.**
    ///
    /// ``FeedbackSlots`` calculates the places from the measured buttons: the time while
    /// scrubbing stands above the timeline, the jump on its side next to or above its
    /// button, board, speed and picture fit under the header, the short note above the bar.
    /// None of them catches a touch.
    private var feedbackOverlay: some View {
        FeedbackStage(buttons: buttons, state: feedbackLayout) {
            if model.settled {
                StallBoard(
                    finding: model.stallFinding, target: model.job?.target,
                    line: model.lineFinding
                )
                .feedback(.stall, state: feedbackLayout)
            }
            if let jumpState {
                JumpIndicator(state: jumpState)
                    .feedback(jumpState.forward ? .skipForward : .skipBack, state: feedbackLayout)
            }
            if let lookahead {
                HintCapsule(
                    wording: Timeline.time(lookahead) + "  "
                        + SwipeZones.distanceText(lookahead - (model.location - timeline.start))
                )
                .feedback(.time, state: feedbackLayout)
            }
            if let level {
                LevelIndicator(
                    icon: level.audio ? Glyph.volume.name : Glyph.brightness.name,
                    value: level.value
                )
                .feedback(level.audio ? .levelRight : .levelLeft, state: feedbackLayout)
            }
            // **As long as it is pressed.** A note that goes after one second would leave open
            // whether the speed still applies.
            if fast {
                HintCapsule(wording: SwipeZones.speedText)
                    .feedback(.rate, state: feedbackLayout)
            }
            // **The fade-in says what has just happened.** Without it nobody understands the pinch
            // gesture: it has no control from which the new state could be read, and anyone who does
            // not know that they are seeing a crop looks for the fault in the film.
            if isStateShown {
                Text(appKey: pictureState.label)
                    .font(TypeLevel.label.font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.horizontal, MetricsBoard.phone.gutter)
                    .padding(.vertical, 9)
                    .background(Material.chromeBar, in: Capsule())
                    .edge()
                    .transition(.opacity)
                    .feedback(.pictureState, state: feedbackLayout)
            }
            if let briefHint {
                HintCapsule(message: briefHint)
                    .feedback(.hint, state: feedbackLayout)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.expand, value: model.settled)
        .animation(Motion.expand, value: jumpState)
        .animation(Motion.expand, value: level)
        .animation(Motion.expand, value: fast)
        .animation(Motion.expand, value: briefHint)
    }

    /// **Over everything and not next to the bar.** It covers half the picture width; if it
    /// lay under the bar, the player's buttons would stand on the list.
    @ViewBuilder
    private var channelPickerSurface: some View {
        if isChannelPickerOpen, let channelSelection {
            ChannelPicker(
                model: channelSelection,
                runningChannel: model.job?.identifier,
                select: { channels in
                    isChannelPickerOpen = false
                    Task { await model.switchTo(toChannel: channels.id) }
                },
                close: { isChannelPickerOpen = false }
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    /// **The model is built on first opening and then kept.** Building in the body would
    /// create a new one on every redraw — the same trap as with the ``SheetState`` above, and
    /// here with 7,746 channels in tow.
    private func openChannelPicker() {
        if channelSelection == nil { channelSelection = LiveModel(source: channelSource) }
        withAnimation(Motion.expand) { isChannelPickerOpen = true }
        model.isBarVisible = true
    }

    /// **The way back while loading and on an error** — there is no bar that could carry
    /// it, and no gesture that leads out.
    ///
    /// Over the running film it has stood since 2026-09-07. **only in the bar**: on-device, a
    /// button that stayed over every live broadcast was disturbing. The exit without a bar is
    /// pulling down from the middle (``SwipeZones``).
    /// The quiet button under the error screen: choose another source.
    private var otherSource: some View {
        VStack {
            Spacer(minLength: 0)
            Button {
                sheetState.open(.sourcesPortal)
            } label: {
                Text(app: "player.other_source")
            }
            .buttonStyle(.quiet)
            .padding(.bottom, 96)
        }
    }

    private var backPath: some View {
        VStack {
            HStack {
                Button(action: back) {
                    Image(systemName: Glyph.back.name)
                }
                .buttonStyle(.rounded)
                .accessibilityLabel(Text(app: "common.back"))
                .opacity(0.55)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.top, MetricsBoard.phone.gutter)
            Spacer(minLength: 0)
        }
    }

    /// Which sheet is shown.
    ///
    /// **A `switch` and not a fixed view.** Until 2026-09-06 this said `{ _ in trackSelection }` — the
    /// identifier was thrown away, and a second sheet would have shown the first.
    @ViewBuilder
    private func sheetContent(_ identifier: SheetID) -> some View {
        switch identifier {
        case .infoBoard:
            InfoBoardSheet(board: model.board) { title in
                sheetState.close()
                Task { await model.matches(title) }
            }
            .task { await model.loadBoard() }
        case .sourcesPortal:
            SourceSheetPortal(
                choice: model.choice,
                chosen: model.runningSource,
                validUntil: model.job?.validUntil,
                select: { target in
                    sheetState.close()
                    Task { await model.switchTo(zu: target) }
                },
                resolveAgain: {
                    sheetState.close()
                    Task { await model.resolveAgain() }
                })
        default:
            trackSelection
        }
    }

    @ViewBuilder
    private var trackSelection: some View {
        if let job = model.job {
            TrackPicker(
                audioTracks: job.audioTracks,
                subtitles: job.subtitles,
                selectedAudio: model.host.controller.selectedAudioTrack,
                selectedSubtitle: model.host.controller.selectedSubtitleTrack,
                selectAudio: { model.select(audioTrack: $0) },
                selectSubtitle: { model.select(subtitles: $0) },
                rate: model.rate,
                selectSpeed: model.speedOffered ? { model.setRate($0) } : nil,
                sleep: model.sleepChoice,
                sleepMinutesLeft: model.sleepMinutesLeft,
                selectSleep: { model.setSleep($0) })
        }
    }

    // MARK: - Ausblenden

    private func toggleBar() {
        model.isBarVisible.toggle()
    }

    /// Resets the timer without hiding the bar — **via the counter** that is in the
    /// timer's identifier (``BarClock``).
    private func restartClock() {
        model.noteViewer()
        model.isBarVisible = true
        touches += 1
    }

    /// **Four seconds, and only while nothing is touched.**
    ///
    /// Three would be too short — the review criticised exactly that; six would leave the bar
    /// over the film while you are already watching again. `task(id:)` cancels as soon as the
    /// visibility changes and then starts anew: thus every grip resets the timer, without a
    /// second place being needed for it.
    ///
    /// **Not while the stall board is up** (finding B4): the bar comes with the board,
    /// because it carries the way out and the other source — until 2026-09-25 it was gone
    /// again after four seconds, while the picture kept standing.
    private func runClock() async {
        guard
            BarClock.fadesOut(
                isVisible: model.isBarVisible, isRunning: model.isRunning, settled: model.settled)
        else { return }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        model.isBarVisible = false
    }

}

/// When the fade-out timer of the bar starts anew — **every change is a fresh start.**
///
/// `task(id:)` cancels on a new identifier and begins from scratch. Until 2026-09-25 the
/// identifier was only the visibility: a grip with the bar up did not reset the timer
/// (B5), and the board did not stop it (B4).
struct BarClock: Hashable {
    let isVisible: Bool
    let settled: Bool
    let touches: Int

    /// Whether the timer fades the bar out after its timeout.
    nonisolated static func fadesOut(isVisible: Bool, isRunning: Bool, settled: Bool) -> Bool {
        isVisible && isRunning && !settled
    }
}
