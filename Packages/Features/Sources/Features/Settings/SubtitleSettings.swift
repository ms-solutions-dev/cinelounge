import Core
import DesignSystem
import SwiftUI

/// **Subtitles — a section of their own** (AP46, product decision 1, 2026-09-25).
///
/// When they appear, how large, in which colour, and whether subtitles of a character set keep their
/// own typeface. **Until 2026-09-25 all of this was in "Playback"**, and
/// the mock-up `EB` also listed a section "Subtitles" on the left — two entry points
/// for one thing, and this package is built against exactly that. Now there is one.
///
/// **Everything here travels with the profile** (decision 4): the values live in the
/// ``ProfileStore``, and the player reads them from there (`PlaybackPreferenceTests`).
struct SubtitleSettings: View {

    @State private var mode = SubtitleMode.load(from: ProfileStore.playback)
    @State private var style = SubtitleStyle.load(from: ProfileStore.playback)
    @State private var plain = SubtitleStyle.prefersPlainSubtitles(from: ProfileStore.playback)
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest
    /// Under "Picture & Sound" below the audio track (AP59 N7) — then this view reports no
    /// entry of its own; the audio track above it has one.
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            // **Before the appearance, not after.** First the question of whether a row
            // appears, then how it looks — the second is moot without the first.
            // **Three values: cycle through** (decision 6).
            ToggleRow(
                title: "settings.subtitleMode",
                options: SubtitleMode.allCases.map {
                    .init(
                        identifier: $0.rawValue,
                        wording: PlaybackSettings.word("settings.subtitleMode." + $0.rawValue))
                },
                chosen: mode.rawValue,
                explanation: "settings.subtitleModeHint",
                validity: .profile,
                identifier: "submode",
                focus: $focus
            ) { identifier in
                guard let fresh = SubtitleMode(rawValue: identifier) else { return }
                mode = fresh
                fresh.save(to: ProfileStore.playback)
            }
            .preference(key: SettingsFirstEntryKey.self, value: embedded ? nil : "submode")
            .onChange(of: entryRequest) { _, _ in if !embedded { focus = "submode" } }

            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader("settings.subtitleStyle", hint: "settings.subtitleStyleHint")

                // The preview in front of the buttons: "Small" and "Large" are empty words
                // without something to look at — here the row appears as it later appears in the film,
                // and changes with every press.
                Text(app: "settings.subtitlePreview")
                    // festeschrift: The preview shows the set subtitle size in percent.
                    .font(.system(size: 29 * CGFloat(style.size.percent) / 100))
                    .foregroundStyle(previewColor)
                    // **Not a settings row but a sample** — hence neither
                    // capsule nor focus colour: the subtitle later appears on black.
                    .padding(.horizontal, SettingsMetrics.horizontal)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 860, alignment: .center)
                    .background(
                        .black,
                        in: RoundedRectangle(
                            cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous)
                    )
                    .padding(.bottom, 24)

                // **Two and three values: cycle through.** The sample above changes
                // with every press — you see what you have chosen without searching for where
                // the pill is.
                VStack(alignment: .leading, spacing: SettingsView.entrySpacing) {
                    ToggleRow(
                        title: "settings.subtitleSize",
                        options: SubtitleStyle.Size.allCases.map {
                            .init(
                                identifier: $0.rawValue,
                                wording: PlaybackSettings.word(
                                    "settings.subtitleSize." + $0.rawValue))
                        },
                        chosen: style.size.rawValue,
                        explanation: "settings.subtitleStyleHint",
                        validity: .profile,
                        identifier: "subsize",
                        focus: $focus
                    ) { identifier in
                        guard let size = SubtitleStyle.Size(rawValue: identifier) else { return }
                        style.size = size
                        SubtitleStyle.writeSize(size, in: ProfileStore.playback)
                    }
                    ToggleRow(
                        title: "common.color",
                        options: SubtitleStyle.Color.allCases.map {
                            .init(
                                identifier: $0.rawValue,
                                wording: PlaybackSettings.word(
                                    "settings.subtitleColor." + $0.rawValue))
                        },
                        chosen: style.color.rawValue,
                        explanation: "settings.subtitleStyleHint",
                        validity: .profile,
                        identifier: "subcolor",
                        focus: $focus
                    ) { identifier in
                        guard let color = SubtitleStyle.Color(rawValue: identifier) else { return }
                        style.color = color
                        SubtitleStyle.writeColor(color, in: ProfileStore.playback)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader("settings.plainSubtitles", hint: "settings.plainSubtitlesHint")

                SwitchRow(
                    title: "settings.plainSubtitlesToggle",
                    on: Binding(
                        get: { plain },
                        set: { fresh in
                            plain = fresh
                            SubtitleStyle.setPrefersPlainSubtitles(fresh, in: ProfileStore.playback)
                        }),
                    card: .toggle(
                        header: "settings.plainSubtitlesToggle",
                        on: plain,
                        explanation: "settings.plainSubtitlesHint",
                        validity: .profile),
                    identifier: "plainsubs",
                    focus: $focus)
            }
        }
    }

    /// The preview colour — the same values that the engine gets.
    private var previewColor: Color {
        let rgba = style.color.rgba
        return Color(red: rgba.red, green: rgba.green, blue: rgba.blue)
    }
}
