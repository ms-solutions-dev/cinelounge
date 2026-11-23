import Core
import DesignSystem
import SwiftUI

/// What applies during playback: preferred audio track and the anime rule.
///
/// **Subtitles have had an area of their own since 2026-09-25**
/// (``SubtitleSettings``, owner decision 1) — one entry point per topic.
///
/// The choice takes effect at the **start** of a playback — it determines which track
/// the server packs in before a menu was ever opened. In the player you can
/// still switch per title; this is the default, not a
/// constraint.
struct PlaybackSettings: View {

    @State private var preference = AudioPreference.load(from: ProfileStore.playback)
    /// The binge switches (AP85, 2026-11-09) — per profile like the audio preference.
    @State private var binge = BingePreferences.load(from: ProfileStore.playback)
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest
    @Environment(\.enterCard) private var enterCard

    /// The offered audio languages. `nil` stands for "as the file specifies".
    ///
    /// Deliberately a short list instead of all ISO languages: what is offered is what occurs in the
    /// catalog and can still be taken in at a glance on a remote.
    /// The names come from the locale — they translate with the app language
    /// by themselves, without keys of their own per language.
    nonisolated static let languages: [String?] = [nil, "deu", "eng", "tur", "jpn"]

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            // **One row instead of five pills, the choice is on the right** (AP46, decision 6):
            // from four values on the card becomes enterable. The press enters it on the
            // chosen language.
            DisclosureRow(
                title: "settings.audioLanguage",
                value: Self.languageName(preference.language),
                card: Self.audioCard(chosen: preference.language) { code in
                    preference.language = code
                    AudioPreference.writeLanguage(code, in: ProfileStore.playback)
                },
                identifier: "audio",
                focus: $focus
            ) {
                enterCard(Self.languageIdentifier(preference.language))
            }
            .preference(key: SettingsFirstEntryKey.self, value: "audio")
            .onChange(of: entryRequest) { _, _ in focus = "audio" }

            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader("settings.animeOriginal", hint: "settings.animeOriginalHint")

                SwitchRow(
                    title: "settings.animeOriginalToggle",
                    on: Binding(
                        get: { preference.animeOriginal },
                        set: { fresh in
                            preference.animeOriginal = fresh
                            AudioPreference.writeAnimeOriginal(fresh, in: ProfileStore.playback)
                        }),
                    card: .toggle(
                        header: "settings.animeOriginalToggle",
                        on: preference.animeOriginal,
                        explanation: "settings.animeOriginalHint",
                        validity: .profile),
                    identifier: "anime",
                    focus: $focus)
            }

            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader("settings.binge", hint: "settings.bingeHint")

                SwitchRow(
                    title: "settings.skipIntroToggle",
                    on: Binding(
                        get: { binge.skipsIntro },
                        set: { fresh in
                            binge.skipsIntro = fresh
                            BingePreferences.writeSkipsIntro(fresh, in: ProfileStore.playback)
                        }),
                    card: .toggle(
                        header: "settings.skipIntroToggle",
                        on: binge.skipsIntro,
                        explanation: "settings.skipIntroHint",
                        validity: .profile),
                    identifier: "skip-intro",
                    focus: $focus)

                SwitchRow(
                    title: "settings.spoilerToggle",
                    on: Binding(
                        get: { binge.hidesSpoilers },
                        set: { fresh in
                            binge.hidesSpoilers = fresh
                            BingePreferences.writeHidesSpoilers(fresh, in: ProfileStore.playback)
                        }),
                    card: .toggle(
                        header: "settings.spoilerToggle",
                        on: binge.hidesSpoilers,
                        explanation: "settings.spoilerHint",
                        validity: .profile),
                    identifier: "spoilers",
                    focus: $focus)

                SwitchRow(
                    title: "settings.stillWatchingToggle",
                    on: Binding(
                        get: { binge.stillWatchingAfter > 0 },
                        set: { fresh in
                            let episodes = fresh ? BingePreferences.defaultStillWatching : 0
                            binge = BingePreferences(
                                skipsIntro: binge.skipsIntro, hidesSpoilers: binge.hidesSpoilers,
                                stillWatchingAfter: episodes)
                            BingePreferences.writeStillWatchingAfter(episodes, in: ProfileStore.playback)
                        }),
                    card: .toggle(
                        header: "settings.stillWatchingToggle",
                        on: binge.stillWatchingAfter > 0,
                        explanation: "settings.stillWatchingHint",
                        validity: .profile),
                    identifier: "still-watching",
                    focus: $focus)
            }
        }
    }

    /// The card for the audio preference — **enterable**, with all languages as pills (AP46,
    /// decision 6: from four values).
    ///
    /// **The statement is the chosen language**, no longer the one under the focus: there is
    /// only one row now, and the choice is on the right. There the card shows every language
    /// as a pill; the chosen one is filled.
    ///
    /// **Moves with the profile** (owner decision 4): `AudioPreference` lives in the
    /// ``ProfileStore``, and the player reads from there. Checked in
    /// `PlaybackPreferenceTests`.
    nonisolated static func audioCard(
        chosen: String?, select: @escaping @MainActor @Sendable (String?) -> Void
    ) -> CardSpec {
        CardSpec(
            header: "settings.audioLanguage",
            statementWording: languageName(chosen),
            explanation: "settings.audioLanguageHint",
            pills: languages.map {
                CardPill(languageName($0), chosen: $0 == chosen, identifier: languageIdentifier($0))
            },
            optionCount: languages.count,
            validity: .profile,
            selection: CardSelection(row: "audio") { identifier in
                select(identifier == languageIdentifier(nil) ? nil : identifier)
            })
    }

    /// The identifier of an audio language in the card — 'auto' for 'as the file specifies'.
    nonisolated static func languageIdentifier(_ code: String?) -> String { code ?? "auto" }

    /// The wording of an audio language: the name from the system, 'Automatic' from the
    /// catalog.
    nonisolated static func languageName(_ code: String?) -> String {
        code.map { displayName(for: $0) } ?? word("settings.audioLanguageAuto")
    }

    /// A language key as finished wording — for the value column and pills.
    nonisolated static func word(_ key: String) -> String {
        AppLanguageSetting.text(String.LocalizationValue(key))
    }

    /// The name of a language, capitalised as is usual at the start of a row.
    nonisolated static func displayName(
        for code: String, locale: Locale = AppLanguageSetting.locale
    ) -> String {
        (locale.localizedString(forLanguageCode: code) ?? code).localizedCapitalized
    }
}
