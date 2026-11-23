import Core
import DesignSystem
import Flows
import SwiftUI

/// The choice of audio track and subtitles.
///
/// **Tracks are not ready immediately.** VLC only determines them while
/// playback starts up; whoever asks right after the start gets an empty list. That
/// is how the contract of ``PlaybackController`` states it and the reason for two
/// decisions here: the list is re-read from the engine on every tick
/// (see ``PlayerModel/tick()``), and focus initially lies on the button for
/// closing. That one is always present — if the list grows later, focus
/// does not lose its target and tvOS does not put it at an arbitrary place.
///
/// As long as nothing is available it says "being determined" and not "no tracks":
/// the second sentence is a statement about the file and would be wrong in the first seconds
/// of every film.
struct TrackChooser: View {

    let model: PlayerModel
    @FocusState.Binding var focus: String?

    @Environment(\.accentPalette) private var palette

    static let width: CGFloat = 620

    var body: some View {
        HStack {
            Spacer()
            panel
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.vertical, TVMetrics.topMargin)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            closeButton
                .padding(.bottom, 26)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.audioTracks.isEmpty && model.subtitleTracks.isEmpty {
                        // **Spinner only while the engine is opening** (F-029: with
                        // VOD content it turned endlessly). If the picture runs and the
                        // engine names no tracks, there are none — and that is said.
                        if model.status == .opening || model.status == .buffering {
                            pending
                        } else {
                            none
                        }
                    } else {
                        if !model.audioTracks.isEmpty {
                            heading("player.audio")
                            ForEach(model.audioTracks) { track in
                                TrackRow(
                                    id: "audio-\(track.id)",
                                    label: track.displayName(),
                                    isOn: model.selectedAudioTrack == track.id,
                                    focus: $focus
                                ) {
                                    model.selectAudioTrack(track.id)
                                }
                            }
                        }

                        heading("player.subtitles")
                        // "Off" is shown even when the file carries no subtitles:
                        // otherwise burned-in or side-loaded tracks lack
                        // the way to switch them off again.
                        TrackRow(
                            id: "sub-off",
                            labelKey: "player.subtitlesOff",
                            isOn: model.selectedSubtitleTrack == nil,
                            focus: $focus
                        ) {
                            model.selectSubtitleTrack(nil)
                        }
                        ForEach(model.subtitleTracks) { track in
                            TrackRow(
                                id: "sub-\(track.id)",
                                label: track.displayName(),
                                isOn: model.selectedSubtitleTrack == track.id,
                                focus: $focus
                            ) {
                                model.selectSubtitleTrack(track.id)
                            }
                        }
                    }

                    rate
                    sleep
                    sources
                }
                .padding(.bottom, 12)
            }
            // **Limited and clipped — both on purpose** (finding 2026-08-07:
            // for a film with thirty subtitle tracks the board grew beyond
            // the edge of the screen and looked like a broken list). Without a
            // limit a scroll area takes as much height as its content wants —
            // it then never scrolls. And `scrollClipDisabled` painted the
            // overhanging rows across the video; here the overflow should
            // scroll, not protrude.
            .frame(maxHeight: 840, alignment: .top)
        }
        .padding(34)
        .frame(width: Self.width, alignment: .leading)
        .background(
            ColorRole.surface.color.opacity(0.97),
            in: RoundedRectangle(cornerRadius: MetricsBoard.tv.sheetRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MetricsBoard.tv.sheetRadius, style: .continuous)
                .stroke(ColorRole.line.color, lineWidth: 2)
                // **Must be pass-through.** An overlay lies over the content and
                // takes part in determining the focus target. Exactly this one line
                // once covered the whole surface in the media bar: the
                // focus landed on the first button and could not be moved on.
                // Here that would mean focus sits on "Done" and no
                // track row can be reached any more — the audio track could not be switched
                // although the list is visibly below it.
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.7), radius: 44, y: 20)
        .focusSection()
        .task { await model.loadSourceChoice() }
    }

    /// **The playback speed — here and not on the long press** (AP31, 2026-09-11).
    ///
    /// ``Core/PlaybackController/supportsSpeed`` and ``Core/PlaybackController/setRate(_:)``
    /// had always been in the contract and were implemented in the system player — **nobody
    /// called them.**
    ///
    /// **Why not the long press**, which the phone uses: an edge press only
    /// arrives as an event of its own from the 2021 remote on. In this project nine places
    /// have already died on that, and a second household uses the older one. An
    /// item in this board reaches every remote.
    ///
    /// **And it stands last.** Audio and subtitles are the questions you open the
    /// board for; speed is the rare case. Focus comes from above and thus meets
    /// the frequent one first.
    @ViewBuilder
    private var rate: some View {
        if model.supportsSpeed {
            heading("player.speed")
            ForEach(PlayerModel.speedSteps, id: \.self) { tier in
                TrackRow(
                    id: "speed-\(tier)",
                    label: Self.caption(tier),
                    isOn: model.rate == tier,
                    focus: $focus
                ) {
                    model.setRate(tier)
                }
            }
        }
    }

    /// "1×", "1.5×" — **with the decimal separator of the UI.**
    ///
    /// A hard-coded point would be wrong in German and in Turkish too; the
    /// formatter takes the separator of the configured language. Whole numbers stay
    /// without a decimal place — "1.00×" reads like a measurement.
    /// **The sleep timer** (AP85) — under the speed, the same rows.
    @ViewBuilder
    private var sleep: some View {
        heading("player.sleepTimer")
        ForEach(PlaybackCore.sleepChoices, id: \.self) { choice in
            TrackRow(
                id: "sleep-\(PlaybackWording.sleepIdentifier(choice))",
                label: PlaybackWording.sleep(
                    choice, minutesLeft: model.sleepChoice == choice ? model.sleepMinutesLeft : nil),
                isOn: model.sleepChoice == choice,
                focus: $focus
            ) {
                model.setSleep(choice)
            }
        }
    }

    static func caption(_ tier: Double) -> String {
        SpeedChoice.caption(tier)
    }

    /// The sources of a portal title — **new on the TV** (AP58 G1, A9).
    ///
    /// **A flat list and not three questions as on the phone.** On the phone a
    /// finger taps through three rows; here every row costs a path with the remote, and
    /// an episode rarely has more than a dozen rows. Each row names host and
    /// version (``Flows/SourcePickerFlow/caption(_:)``), so that "HOSTA" does not stand
    /// four times underneath each other. Locked ones are missing — they could be pressed and would do nothing.
    @ViewBuilder
    private var sources: some View {
        if model.sourceChoice.isWorthwhile {
            heading("player.source")
            ForEach(model.sourceChoice.selectable) { row in
                TrackRow(
                    id: "source-\(row.id)",
                    label: SourcePickerFlow.caption(row),
                    isOn: model.sourceChoice.running == row.id,
                    focus: $focus
                ) {
                    Task { await model.switchSource(zu: row) }
                }
            }
            // **An expired address says so** (AP77): addresses from portal sources are valid
            // for 300 s. Instead of a dead link after the pause it says "resolve again" here —
            // the same answer as in the phone's source sheet.
            if model.sourceChoice.expired(),
                let running = model.sourceChoice.selectable.first(where: {
                    $0.id == model.sourceChoice.running
                })
            {
                TrackRow(
                    id: "source-resolve",
                    label: AppLanguageSetting.message("player.sourceResolve"),
                    isOn: false,
                    focus: $focus
                ) {
                    Task { await model.switchSource(zu: running) }
                }
            }
        }
    }

    private var closeButton: some View {
        let isFocused = focus == "chooser-close"

        return Button {
            model.isChoosingTracks = false
        } label: {
            HStack(spacing: 16) {
                Text(app: "player.tabTracks")
                    .font(TypeLevel.header.font)
                Spacer(minLength: 20)
                Text(app: "common.done")
                    .font(TypeLevel.footer.font)
            }
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 24)
            .frame(height: 68)
            .background(
                isFocused ? ColorRole.text.color : ColorRole.text.color.opacity(0.12),
                in: Capsule()
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: "chooser-close")
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
    }

    private var none: some View {
        Text(app: "player.tracksNone")
            .font(TypeLevel.text.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .padding(.vertical, 20)
    }

    private var pending: some View {
        HStack(spacing: 18) {
            ProgressView()
            Text(app: "player.tracksPending")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .padding(.vertical, 20)
    }

    private func heading(_ key: LocalizedStringKey) -> some View {
        Text(app: key)
            .font(TypeLevel.footer.font)
            .kerning(3)
            .foregroundStyle(ColorRole.textQuiet.color)
            .padding(.top, 14)
    }

}

/// One row of the track choice.
///
/// A type of its own because it is needed in two places: in the choice over the
/// bar and on the "Audio & Subtitles" index card in the info area. Built twice,
/// the two would drift apart over time, and the viewer would see two presentations
/// for the same thing.
///
/// The label comes either from the language file or from
/// ``PlaybackTrack/displayName(locale:)`` — never built by hand. The engine names its
/// tracks "Track 2" or nothing at all, and nobody in the living room reads "deu".
struct TrackRow: View {

    let id: String
    var label: String?
    var labelKey: String?
    let isOn: Bool
    @FocusState.Binding var focus: String?
    let action: () -> Void

    @Environment(\.accentPalette) private var palette

    var body: some View {
        let isFocused = focus == id

        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 30))
                    .foregroundStyle(isOn ? Color(palette, .bright) : ColorRole.textQuiet.color)

                if let labelKey {
                    Text(appKey: labelKey)
                } else {
                    Text(verbatim: label ?? "")
                }

                Spacer(minLength: 0)
            }
            .font(TypeLevel.text.font)
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(height: 64)
            .background(
                isFocused ? ColorRole.text.color : .clear,
                in: RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous)
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        // The track carries either a key ("Off") or its raw name from the
        // server ("Deutsch (AC3 5.1)"). Both are the same row.
        .info(
            labelKey.map { Text(appKey: $0) } ?? Text(verbatim: label ?? ""),
            .chosen(isOn))
    }
}
