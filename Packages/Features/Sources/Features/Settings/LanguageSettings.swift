import Core
import DesignSystem
import SwiftUI

/// **The app language — an area of its own** (AP46, product decision 1, 2026-09-25).
///
/// Until then it stood as the first block in "Appearance", above colour swatches and app
/// icons. But a language is not a question of looks: whoever has changed it by mistake does
/// not look for it under "Appearance" but under its name.
///
/// **Three pills and no cycling**, although decision 6 provides cycling for three values:
/// every press would flip the whole interface into the next language, and whoever only
/// wanted to move on would then stand in one they cannot read. Each pill carries the name
/// the language gives itself: a Turkish user looks for "Türkçe", not for "Turkish".
///
/// **Travels with the profile** (decision 4): the choice lies in the person's slot
/// (``AppLanguageSetting``), and on a switch the shell changes the language.
struct LanguageSettings: View {

    let languages: LanguageSelection

    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    /// The chosen language — **held, because the selection is not observable.**
    /// ``LanguageSelection`` is a contract without `ObservableObject`; the pills would otherwise
    /// show the old choice until the next redraw.
    @State private var chosen: String?

    var body: some View {
        let current = chosen ?? languages.currentCode
        HStack(spacing: 16) {
            ForEach(languages.available, id: \.code) { language in
                ChoiceRow(
                    wording: language.endonym,
                    chosen: language.code == current,
                    card: CardSpec(
                        header: "settings.language",
                        statementWording: language.endonym,
                        explanation: "settings.languageHint",
                        validity: .profile),
                    identifier: "lang-" + language.code,
                    focus: $focus
                ) {
                    languages.select(language.code)
                    chosen = language.code
                }
            }
        }
        .preference(key: SettingsFirstEntryKey.self, value: "lang-" + current)
        .onChange(of: entryRequest) { _, _ in focus = "lang-" + current }
    }
}
