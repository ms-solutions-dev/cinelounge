import Core
import DesignSystem
import Playback
import SwiftUI

/// The control bar at the bottom edge — title, scrubber, button row.
///
/// Dimensions from the design template: 72 points above the bottom edge, inset at the sides
/// by the overscan area, the button row centred with buttons 88 points in diameter. The
/// layout is designed for a TV viewed from three metres away, not for a desk — hence the
/// large surfaces and the few buttons.
struct TransportBar: View {

    let model: PlayerModel
    /// Height of the second line — **derived, not copied** (roadmap AP11). It used to be 30
    /// points, and the comment next to it fixed that value; but the line carries text at the
    /// size ``Styling/TypeLevel/footer``, and that needs 35. Too short does not mean
    /// "tight" here but clipped: descenders get cut off, and that looks like a character bug.
    static var secondLineHeight: CGFloat {
        TypeLevel.lineHeight(zu: TypeLevel.footer.points)
    }

    @FocusState.Binding var focus: String?

    /// Where directions go that the scrubber does not need itself.
    ///
    /// **Because `onMoveCommand` has no return value.** The closure returns `Void` — there is
    /// nothing to report "not handled" with, and on the focused element every direction stays
    /// where it is. So directions are passed on explicitly, to the same rule that also serves
    /// the player's movement commands.
    let onUnhandledMove: @MainActor (MoveCommandDirection) -> Void

    @Environment(\.accentPalette) private var palette

    /// Diameter of a button and gap between two buttons.
    static let buttonSize: CGFloat = 88
    static let buttonGap: CGFloat = 30
    /// Width of the two time labels. Fixed and not growing, so that the scrubber does not
    /// jump when going from `59:59` to `1:00:00`.
    static let timeWidth: CGFloat = 108
    static let railHeight: CGFloat = 10
    static let knobSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 0) {
                // While the scrubber is being searched, the title and the second line make way for the
                // trickplay preview: near the start and end it is clamped to the scrubber edge and sat
                // exactly on top of both — title and preview image were unreadable at the same time, and
                // that is exactly where you look when scrubbing. Hidden instead of removed, so that the
                // bar does not reflow and the scrubber stays in place.
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.target.title)
                        .font(TypeLevel.section.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(1)
                        .padding(.bottom, 6)

                    secondLine
                        .padding(.bottom, 26)
                }
                .opacity(model.scrubPosition == nil ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: model.scrubPosition == nil)

                // In the error case the notice takes the place of the scrubber and the button row
                // instead of overlaying them. Showing both side by side would be pointless: there is
                // nothing to pause and nothing to scrub, and two focusable areas stacked on top of each
                // other are the sure way to a focus nobody can find again on tvOS.
                if model.hasFailed {
                    failure
                        .padding(.top, 8)
                } else {
                    if model.isSeekable {
                        scrub
                        // **Down from the slider lands on Play — without a detour.** tvOS assigns focus by
                        // geometry and first hit the button below the knob (F-008: "first audio track, then
                        // Play"); this invisible strip is the nearest target and passes the focus on
                        // immediately.
                        if focus == "rail" {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 2)
                                .focusable()
                                .focused($focus, equals: "rail-catcher")
                                .accessibilityHidden(true)
                        }
                    }

                    controls
                        .padding(.top, 34)
                }
            }
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.bottom, 72)
        .onChange(of: focus) { _, current in
            // If the focus leaves the scrubber without a commit, the seek counts as cancelled.
            // Without this line the display would stay at the targeted position while the film plays
            // elsewhere.
            if current != "rail" { model.cancelScrub() }
            if current == "rail-catcher" { focus = "play" }
        }
    }

    // MARK: - Second row

    @ViewBuilder
    private var secondLine: some View {
        HStack(spacing: 14) {
            // Before everything else, because it is the only hint why the picture is currently
            // standing still. Over a thin connection — a measured 0.3 Mbit/s through the tunnel —
            // buffering is the rule, not the exception; without this line it looks like a pause you
            // triggered yourself, and you press around on the remote while the connection is working.
            if model.isBuffering {
                HStack(spacing: 12) {
                    // Fixed space and reduced size instead of full size: on tvOS the spinner is clearly taller
                    // than this line (``secondLineHeight``). Unchecked it draws beyond the title above —
                    // `frame` fixes the space, `scaleEffect` does not change it.
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 30, height: 30)
                    Text(app: "player.buffering")
                        .foregroundStyle(ColorRole.textMatt.color)
                }
                .font(TypeLevel.footer.font)
            }
            if model.target.kind == .live {
                // **In the buffer the badge reads "Time-shifted"** (AP58 G1, A1): a red "Live" above a
                // broadcast from three minutes ago would be untrue.
                Text(app: model.isBehindLive ? "player.behindLive" : "player.live")
                    .font(TypeLevel.lowercased.font)
                    .fontWeight(.bold)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(
                        model.isBehindLive
                            ? ColorRole.text.color.opacity(0.24) : ColorRole.live.color,
                        in: Capsule())
            }
            if let subtitle = model.target.subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(1)
            }
        }
        // The height stays even without content: otherwise the whole bar slides down by one line
        // height for a film without a second line, and the buttons no longer sit where they sit in
        // the template.
        .frame(height: Self.secondLineHeight, alignment: .leading)
    }

    // MARK: - Rail

    private var scrub: some View {
        HStack(spacing: 22) {
            Text(verbatim: model.elapsedLabel)
                .frame(width: Self.timeWidth, alignment: .leading)

            rail

            // Without a known length the space stays empty instead of showing `−00:00` —
            // that would look as if the film had ended.
            Text(verbatim: model.remainingLabel ?? "")
                .frame(width: Self.timeWidth, alignment: .trailing)
        }
        // Monospaced digits: otherwise the time shifts back and forth by a few points every
        // second. Barely visible at a desk, on a TV a twitching that pulls the eye away from the
        // picture.
        .font(TypeLevel.footer.font.monospacedDigit())
        .foregroundStyle(ColorRole.textMatt.color)
    }

    /// What a directional press on the scrubber means.
    ///
    /// **The third case is the reason for this computation.** `onMoveCommand` consumes **all**
    /// directions on the focused element, including those not handled here — they arrive
    /// nowhere. From a `default: break` it was impossible to tell from the outside whether a
    /// direction is not needed or is swallowed; as its own case the difference is a value and
    /// testable.
    enum RailMove: Equatable {
        /// By how many steps the targeted position moves.
        case scrub(Int)
        /// Out of the scrubber, onto the middle button.
        case toControls
        /// Is none of the scrubber's business — the caller decides.
        case pass
    }

    /// `default` and not `case .up`: `MoveCommandDirection` is not `@frozen`, so an
    /// exhaustive `switch` would break on a new direction in the SDK.
    nonisolated static func railMove(_ direction: MoveCommandDirection) -> RailMove {
        switch direction {
        case .left: .scrub(-1)
        case .right: .scrub(1)
        // **Down must be set explicitly.** Without this case the focus is stuck on the
        // scrubber: the button row below is visible and can no longer be reached, and the only
        // way out would be the Menu button, which ends the film.
        //
        // To the middle button and not the nearest one: the scrubber runs across the whole width,
        // so there is no geometric target — and whoever leaves the scrubber wants to pause.
        case .down: .toControls
        default: .pass
        }
    }

    private var rail: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let filled = width * model.fraction

            Button {
                model.commitScrub()
            } label: {
                ZStack(alignment: .leading) {
                    Capsule().fill(ColorRole.text.color.opacity(0.24))
                    Capsule()
                        .fill(Color(palette, .bright))
                        .frame(width: filled)

                    // The chapter marks — dark notches on the scrubber, so that the skip buttons have a
                    // visible target. Decoration without focus: the scrubber remains the only target of this
                    // line.
                    ForEach(model.chapterFractions, id: \.self) { fraction in
                        Capsule()
                            .fill(ColorRole.reason.color.opacity(0.8))
                            .frame(width: 4, height: Self.railHeight)
                            .offset(x: width * fraction - 2)
                    }
                }
                .frame(height: Self.railHeight)
                // The hit area is taller than the scrubber: ten points would be a thread on the TV, and
                // the focus should hit the whole line.
                .contentShape(Rectangle().inset(by: -20))
            }
            .bareFocusableButton()
            .focused($focus, equals: "rail")
            .overlay(alignment: .leading) {
                knob(at: filled)
            }
            .overlay(alignment: .topLeading) {
                preview(at: filled, railWidth: width)
            }
            .onMoveCommand { direction in
                switch Self.railMove(direction) {
                case .scrub(let steps): model.moveScrub(by: steps)
                case .toControls: focus = "play"
                case .pass: onUnhandledMove(direction)
                }
            }
        }
        .frame(height: Self.railHeight)
    }

    private func knob(at offset: CGFloat) -> some View {
        Circle()
            .fill(ColorRole.text.color)
            .frame(width: Self.knobSize, height: Self.knobSize)
            .shadow(color: Color(palette).opacity(0.55), radius: 8)
            .shadow(color: .black.opacity(0.7), radius: 22, y: 8)
            .scaleEffect(focus == "rail" ? 1.2 : 1)
            .offset(x: offset - Self.knobSize / 2)
            // The handle is decoration and must not intercept focus — otherwise the scrubber itself
            // can no longer be selected.
            .allowsHitTesting(false)
    }

    /// The preview above the handle while seeking.
    @ViewBuilder
    private func preview(at offset: CGFloat, railWidth: CGFloat) -> some View {
        if model.scrubPosition != nil, let trickplay = model.trickplay {
            ScrubPreview(trickplay: trickplay, time: model.displayPosition)
                // At the edge the preview does not move past the scrubber: at position zero half of its
                // width would lie outside the picture.
                .offset(
                    x: min(max(0, offset - ScrubPreview.size.width / 2), railWidth - ScrubPreview.size.width),
                    y: -(ScrubPreview.size.height + 26)
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: - When the engine gives up

    /// Height of the button that leads out of playback.
    static let exitButtonHeight: CGFloat = 74

    /// The notice together with the way out.
    ///
    /// **Why it has to exist:** when the engine fails, until now only the progress counter
    /// reported off to the server. On screen the title and bar stayed over black at 00:00 —
    /// with no reason and no hint that the Menu button helps. That looks like a film about to
    /// start, and you wait.
    ///
    /// **And why it does not simply close:** a view that disappears by itself cannot be told
    /// apart from a swallowed key press. The viewer starts the same title again right away and
    /// gets the same result.
    private var failure: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                // **A channel is not a file**, and the message was therefore wrong: "The file cannot be
                // played" sends you to the server or the disk, while in truth the provider stopped
                // delivering (viewer finding 2026-08-11, at night: "broadcasts break off in the middle").
                Text(app: model.target.kind == .live ? "player.channelFailed" : "player.failed")
            }
            .font(TypeLevel.header.font)
            .foregroundStyle(ColorRole.text.color)

            // Names the Menu button explicitly. It leads out here anyway — it is just that nobody
            // knows that if the interface does not say so.
            Text(appKey: failureHintKey)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .lineLimit(3)

            // **The retry now sits where it is promised** (AP5 · B5). It sits **first**, because it is
            // the more frequent action, and carries the identifier "play": ``PlayerScreen`` names it
            // while the bar is at rest, and the focus should land on the button you mean. The way out
            // is one step to the right.
            HStack(spacing: 20) {
                retryButton
                // **Another source, right here** (AP58 G1, A9) — the same place as on the phone. If the
                // mirror does not hold, "Try again" is the same dead source once more.
                if model.sourceChoice.isWorthwhile {
                    sourceButton
                }
                exitButton
            }
            .task { await model.loadSourceChoice() }
            .padding(.top, 6)
        }
    }

    /// Try once more — see ``PlayerModel/retry()``.
    private var retryButton: some View {
        let isFocused = focus == "play"

        return Button {
            model.retry()
        } label: {
            Text(app: "common.retry")
                .font(TypeLevel.header.font)
                .fontWeight(.semibold)
                .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
                .padding(.horizontal, 44)
                .frame(height: Self.exitButtonHeight)
                .background(
                    isFocused ? ColorRole.text.color : ColorRole.text.color.opacity(0.15),
                    in: Capsule()
                )
        }
        .bareFocusableButton()
        .focused($focus, equals: "play")
    }

    /// Opens the track board in which the sources are listed.
    private var sourceButton: some View {
        let isFocused = focus == "failure-source"

        return Button {
            model.isChoosingTracks = true
        } label: {
            Text(app: "player.other_source")
                .font(TypeLevel.header.font)
                .fontWeight(.semibold)
                .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
                .padding(.horizontal, 44)
                .frame(height: Self.exitButtonHeight)
                .background(
                    isFocused ? ColorRole.text.color : ColorRole.text.color.opacity(0.15),
                    in: Capsule()
                )
        }
        .bareFocusableButton()
        .focused($focus, equals: "failure-source")
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
    }

    /// Which explanation appears under the message.
    ///
    /// Two cases: channel and everything else. The third — the pinned engine — disappeared
    /// with the VLC removal (product decision 2026-08-16).
    private var failureHintKey: String {
        model.target.kind == .live ? "player.channelFailedHint" : "player.failedHint"
    }

    private var exitButton: some View {
        // **The identifier "play" has moved to the retry button** (AP5 · B5). ``PlayerScreen``
        // works out where the focus belongs and, while the bar is at rest, names this identifier —
        // it belongs to the button you mean, and since 2026-09-02 that is the retry. This one here is
        // the neighbour to the right and carries a name of its own; it stays reachable because the
        // focus may move between two neighbours.
        let isFocused = focus == "failure-exit"

        return Button {
            model.close()
        } label: {
            Text(app: "common.back")
                .font(TypeLevel.header.font)
                .fontWeight(.semibold)
                .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
                .padding(.horizontal, 44)
                .frame(height: Self.exitButtonHeight)
                .background(
                    isFocused ? ColorRole.text.color : ColorRole.text.color.opacity(0.15),
                    in: Capsule()
                )
        }
        .bareFocusableButton()
        .focused($focus, equals: "failure-exit")
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
    }

    // MARK: - Button row

    private var controls: some View {
        HStack(spacing: Self.buttonGap) {
            // Chapters outside, second jumps inside: the fine jumps are the frequent grip and stay in
            // their familiar place next to the pause. The buttons appear only where the title has
            // chapters — permanently they would sit there pointlessly on every film without chapters.
            if model.hasChapters {
                button(
                    id: "chapterBack", symbol: Glyph.chapterBack.name,
                    label: "player.chapterBack"
                ) {
                    model.jumpToChapter(forward: false)
                }
            }

            if model.isSeekable {
                button(
                    id: "back10", symbol: "gobackward.10",
                    label: "player.back10"
                ) {
                    model.skip(by: -10)
                }
            }

            // Via ``PlayerModel/isPlaying`` and not via the state itself: "buffering" is ongoing
            // playback, just without supply. With a direct comparison against `.playing` the symbol
            // jumped to play on a stall, and the same button then called `play()` instead of `pause()`
            // — being unable to pause while the picture is frozen is the bug behind that.
            button(
                id: "play", symbol: model.isPlaying ? "pause.fill" : "play.fill",
                // **The label says what the press DOES, the value what APPLIES.** "Pause / playing" is
                // the right pairing; "Playing" alone would conceal what the button does.
                label: model.isPlaying ? "common.pause" : "common.play",
                state: model.isPlaying ? "a11y.player.playing" : "common.paused"
            ) {
                model.togglePause()
            }

            if model.isSeekable {
                button(
                    id: "forward30", symbol: "goforward.30",
                    label: "player.forward30"
                ) {
                    model.skip(by: 30)
                }
            }

            if model.hasChapters {
                button(
                    id: "chapterNext", symbol: Glyph.chapterForward.name,
                    label: "player.chapterNext"
                ) {
                    model.jumpToChapter(forward: true)
                }
            }

            button(
                id: "cc", symbol: "captions.bubble.fill",
                label: "a11y.player.subtitles"
            ) {
                model.isChoosingTracks = true
            }

            // **Back to Live** (AP9) — only for a channel with a disk ring.
            if model.hasLiveTimeShift {
                button(
                    id: "live", symbol: Glyph.backToLive.name,
                    label: "player.toLive"
                ) {
                    model.jumpToLive()
                }
            }

            // **Picture in Picture** (AP8) — only if the system offers a window.
            if model.canPictureInPicture {
                button(
                    id: "pip", symbol: "pip.enter",
                    label: "a11y.player.pip"
                ) {
                    model.startPictureInPicture()
                }
            }

            // **AirPlay** (AP8): the system's route picker, triggered from here — see
            // ``AirPlayRouting``.
            button(
                id: "airplay", symbol: "airplayvideo",
                label: "a11y.player.airplay"
            ) {
                model.noteViewer()
                if !AirPlayRouting.shared.present() {
                    Diagnostics.playbackStep("AirPlay: no route picker to press", since: nil)
                }
            }

            // **The channel can be bookmarked while you watch it.** That is exactly when the decision
            // is made — not earlier in the list, where you do not know it yet. Only for channels: for
            // films and episodes the mark sits on the detail page, and that is where it belongs,
            // because that is where you find it again.
            if model.canFavoriteChannel {
                button(
                    id: "favorite",
                    symbol: Glyph.favorite.pair.forItem(model.isChannelFavorite),
                    label: "a11y.player.favorite",
                    state: model.isChannelFavorite
                        ? "a11y.state.favorite" : "a11y.state.notFavorite"
                ) {
                    model.toggleChannelFavorite()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// - Parameters:
    ///   - beschriftung: What this button **does** — as a language key.
    ///   - zustand: What currently **applies**, if the button carries a state.
    ///
    /// **The player bar is the second place after the sidebar** (AP30, 2026-09-11), and the
    /// reason is the same as everywhere in this package: there is no finger moving across a
    /// surface — there is the focus. **Here the screen is dark anyway**, the bar comes and
    /// goes, and the buttons carry nothing but a glyph: `pause.fill` versus `play.fill` means
    /// nothing at all to the screen reader.
    ///
    /// **One parameter on the factory instead of eleven handles on eleven buttons** — the same
    /// split as with the two factories from AP26.
    private func button(
        id: String, symbol: String, label: String, state: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == id

        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(
                    isFocused ? ColorRole.text.color : ColorRole.text.color.opacity(0.15),
                    in: Circle()
                )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .info(appKey: label, .key(state))
        // 1.08 instead of ``Tokens/Focus/buttonScale``, and that is defensible here: the value is
        // given like this in the template, and the highlight on these buttons carries the
        // inversion of background and text anyway. Where a scale-up alone has to account for the
        // focus, 1.08 is too little from three metres — see the reasoning at
        // ``Tokens/Focus/cardScale``.
        .focusHighlight(isFocused, scale: 1.08, accent: Color(palette, .bright))
    }
}
