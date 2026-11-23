import Core
import DesignSystemPhone
import SwiftUI

/// Area 4 · Playback.
///
/// **The finding of 2026-09-07: both switches of this screen were dead.** The
/// subtitle size lived in `@AppStorage(`player.subtitleSize`)`, the original audio in
/// `@AppStorage(`player.originalAudio`)` — and **nobody read them.** The player did not pass
/// either of the two places; the only readers in the whole source were this
/// screen itself and the value column of the root.
///
/// **The wiring had been there all along, the switch just hung next to it.** The shared
/// `EngineHost` — the TV uses the same one — reads at **every** start
/// `SubtitleStyle.load(from: SecureStore())`. The phone wrote to `UserDefaults` under
/// a different key. Two stores, two names, no hit.
///
/// **That is why the shared type stands here now and not a second version of it.**
/// ``Core/SubtitleStyle`` and ``Core/AudioPreference`` live in `Core`, have been used on the
/// TV all along, and they carry more than the phone had: color,
/// subtitle level, original audio. That is also the answer to decision E4
/// (feature parity) — seven options were missing, three of which this screen closes.
///
/// **Three levels and no slider.** The slider went from 0.7 to 1.6 in steps of 0.1 —
/// ten values, nine of which nobody can tell apart, and none of them the same as on the
/// TV. `SubtitleStyle.Size` knows 80/100/130 %; the numbers there are calculated against the
/// 18-arcminute limit and not guessed.
///
/// **The subtitle preview stands on a black surface and not on the card.** A
/// font size set on a light background is a different one in the dark film — and
/// in both directions: white on grey looks smaller than it is. Whoever does not
/// show the preview where the subtitles later stand makes you set it twice.
///
/// **Per profile, since 2026-09-25** (tvOS roadmap AP46, phone row). Reading and
/// writing go through ``Core/ProfileStore/playback`` — the same store the
/// player reads from and that ``ProfileKit/ProfileCloud`` reconciles. **Writing is per key
/// and never the bundle:** a `save(to:)` would write the inherited device value of the other
/// fields as its own value into the profile's compartment; that would go into
/// the cloud with the timestamp *now* and beat the real choice from the other device.
struct PlaybackView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var subtitles = SubtitleStyle.standard
    @State private var audio = AudioPreference()
    @State private var plain = false
    /// The binge switches (AP85, 2026-11-09) — per profile, as on the TV.
    @State private var binge = BingePreferences()

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard(header: "settings.section.subtitles") {
                        lookahead
                        Separator()
                        levelRow
                        Separator()
                        colorRow
                        Separator()
                        mode
                        Separator()
                        // **ASS as plain text, as on the TV** (decision 27, C13).
                        // The shared ``Core/PlaybackPlan`` has always read the value; only the switch
                        // was missing. It travels with the profile.
                        SwitchRow(
                            title: "settings.plainSubtitlesToggle",
                            message: "settings.playback.plainSubtitlesText",
                            on: Binding(
                                get: { plain },
                                set: {
                                    plain = $0
                                    SubtitleStyle.setPrefersPlainSubtitles(
                                        $0, in: ProfileStore.playback)
                                }))
                    }

                    SettingsCard(header: "player.audio") {
                        SwitchRow(
                            title: "settings.animeOriginal",
                            message: "settings.playback.animeOriginalText",
                            on: Binding(
                                get: { audio.animeOriginal },
                                set: {
                                    audio.animeOriginal = $0
                                    AudioPreference.writeAnimeOriginal($0, in: ProfileStore.playback)
                                }))
                    }

                    SettingsCard(header: "settings.binge") {
                        SwitchRow(
                            title: "settings.skipIntroToggle",
                            message: "settings.skipIntroHint",
                            on: Binding(
                                get: { binge.skipsIntro },
                                set: {
                                    binge.skipsIntro = $0
                                    BingePreferences.writeSkipsIntro($0, in: ProfileStore.playback)
                                }))
                        Separator()
                        SwitchRow(
                            title: "settings.spoilerToggle",
                            message: "settings.spoilerHint",
                            on: Binding(
                                get: { binge.hidesSpoilers },
                                set: {
                                    binge.hidesSpoilers = $0
                                    BingePreferences.writeHidesSpoilers($0, in: ProfileStore.playback)
                                }))
                        Separator()
                        SwitchRow(
                            title: "settings.stillWatchingToggle",
                            message: "settings.stillWatchingHint",
                            on: Binding(
                                get: { binge.stillWatchingAfter > 0 },
                                set: {
                                    let episodes = $0 ? BingePreferences.defaultStillWatching : 0
                                    binge = BingePreferences(
                                        skipsIntro: binge.skipsIntro,
                                        hidesSpoilers: binge.hidesSpoilers,
                                        stillWatchingAfter: episodes)
                                    BingePreferences.writeStillWatchingAfter(
                                        episodes, in: ProfileStore.playback)
                                }))
                    }

                    // **Both settings of this screen have the same answer**,
                    // which is why the origin stands at the card and not at every row.
                    // Since they live in the ``Core/SecureStore``, it applies to the player
                    // **and** to the TV — they are the same store.
                    // **``Footnote`` and no rebuilt text (2026-09-07).** Here, typeface, color and wrapping
                    // stood by hand — the same three lines that
                    // ``Footnote`` carries, only in a place nobody maintains. The
                    // indent came from outside, and since the ``OriginMark`` fetches its
                    // own, it would have been doubled.
                    Footnote(message: "settings.playback.footnote")
                        .origin(.profile)
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task {
            // **Fresh on every appearance and per profile** — ``Core/ProfileStore/playback``
            // asks the pointer at the moment of reading.
            subtitles = SubtitleStyle.load(from: ProfileStore.playback)
            audio = AudioPreference.load(from: ProfileStore.playback)
            plain = SubtitleStyle.prefersPlainSubtitles(from: ProfileStore.playback)
            binge = BingePreferences.load(from: ProfileStore.playback)
        }
    }

    /// The preview — **where the subtitles will later stand.**
    private var lookahead: some View {
        ZStack(alignment: .bottom) {
            // systemfarbe: The preview shows what a subtitle looks like in the film — and
            // there it lies on the picture and not on a surface of the app. A
            // board color would show something here that the viewer never gets to see.
            Color.black
            Text(appKey: "settings.playback.preview")
                // festeschrift: **Stays fixed, and that is right here** (AP5): this row is the
                // preview of the chosen subtitle size. It is meant to show what 80, 100
                // or 130 percent look like — if it additionally grew with the system font, it
                // would show something other than what appears in the film.
                .font(.system(size: 17 * Double(subtitles.size.percent) / 100, weight: .medium))
                .foregroundStyle(color(subtitles.color))
                .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
                .padding(.bottom, 14)
                .padding(.horizontal, Metrics.pillInset)
                .multilineTextAlignment(.center)
        }
        .frame(height: 120)
        .accessibilityHidden(true)
    }

    /// **One segment and not three checkmark rows.** Three levels are a choice among
    /// few equals — exactly the case for which iOS has the segment; three rows
    /// at 59 points would be 177 points for one decision.
    private var levelRow: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Text(app: "settings.subtitleSize")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer(minLength: Metrics.targetSpacing)
            Picker("", selection: tier) {
                ForEach(SubtitleStyle.Size.allCases) { size in
                    Text(verbatim: "\(size.percent) %").tag(size)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 176)
        }
        .padding(.horizontal, Metrics.cardInset)
        .frame(minHeight: Metrics.choiceRow)
    }

    private var colorRow: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Text(app: "common.color")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer(minLength: Metrics.targetSpacing)
            Picker("", selection: colorChoice) {
                ForEach(SubtitleStyle.Color.allCases) { choice in
                    Text(appKey: choice == .white ? "subtitles.white" : "subtitles.yellow").tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 176)
        }
        .padding(.horizontal, Metrics.cardInset)
        .frame(minHeight: Metrics.choiceRow)
    }

    /// When subtitles appear at all — off, forced only, always.
    private var mode: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Text(app: "settings.playback.when")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer(minLength: Metrics.targetSpacing)
            Picker("", selection: modeChoice) {
                ForEach(SubtitleMode.allCases) { scenario in
                    Text(appKey: "subtitles.\(scenario.rawValue)").tag(scenario)
                }
            }
            .pickerStyle(.menu)
            .tint(ColorRole.textMatt.color)
        }
        .padding(.horizontal, Metrics.cardInset)
        .frame(minHeight: Metrics.choiceRow)
    }

    // MARK: - Bindungen

    /// **Saved on toggle and not on leaving.** Every other setting of this
    /// app takes effect when toggled; a screen with a save button would be the only one, and whoever
    /// overlooks it loses their input.
    private var tier: Binding<SubtitleStyle.Size> {
        Binding(
            get: { subtitles.size },
            set: {
                subtitles.size = $0
                SubtitleStyle.writeSize($0, in: ProfileStore.playback)
            })
    }

    private var colorChoice: Binding<SubtitleStyle.Color> {
        Binding(
            get: { subtitles.color },
            set: {
                subtitles.color = $0
                SubtitleStyle.writeColor($0, in: ProfileStore.playback)
            })
    }

    private var modeChoice: Binding<SubtitleMode> {
        Binding(
            get: { audio.subtitles },
            set: {
                audio.subtitles = $0
                $0.save(to: ProfileStore.playback)
            })
    }

    private func color(_ choice: SubtitleStyle.Color) -> Color {
        let (r, g, b, a) = choice.rgba
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
