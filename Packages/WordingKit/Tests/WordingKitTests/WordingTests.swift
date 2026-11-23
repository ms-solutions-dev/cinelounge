import Foundation
import Testing

@testable import WordingKit

/// The probe from report B, step 3 — **whether a package catalog works at all.**
///
/// What is verified here is the check run on the Mac (`swift test`). That `Bundle.module`
/// also resolves inside the bundle of the tvOS and iOS apps is verified by the full run: both
/// programs compile the package, and `Core` looks up `player.subtitleForced` through it.
@Suite("Wording")
struct WordingTests {

    @Test("The shared catalog lies in the package bundle, in all three languages")
    func catalogInBundle() {
        let languages = Set(WordingKit.bundles.localizations)
        #expect(languages.isSuperset(of: ["de", "en", "tr"]))
    }

    /// The app's language choice has to apply here too — otherwise, after a switch, the track
    /// choice would show Turkish and "Forced" would show German.
    @Test(
        "The chosen language also applies to the shared catalog",
        arguments: [("de", "Erzwungen"), ("en", "Forced"), ("tr", "Zorunlu")])
    func languageApplies(language: String, expected: String) {
        #expect(WordingKit.text("player.subtitleForced", language: language) == expected)
    }

    @Test("A language without a translation falls back to the package bundle, not to the key")
    func unknownLanguage() {
        #expect(WordingKit.languageBundle("xx", in: WordingKit.bundles) == WordingKit.bundles)
        #expect(WordingKit.text("fehler.netz", language: "xx") != "fehler.netz")
    }

    /// The path a SwiftUI view takes: a key with bundle and locale instead of a finished string.
    /// On the device, `Text` takes the locale from the environment, which the shell sets on
    /// every language switch.
    @Test("A key with bundle and locale resolves in the package catalog")
    func resourceWithLocale() {
        let resource = LocalizedStringResource(
            "fehler.zugang", locale: Locale(identifier: "tr"),
            bundle: .atURL(WordingKit.bundles.bundleURL))
        #expect(String(localized: resource) == "Sağlayıcı bu erişime izin vermiyor.")
    }

    /// **Which catalog carries a key decides where to look it up**
    /// (AP58 R3): A state passes its key as a value to a view that does not know the catalog.
    @Test("The shared catalog knows which keys it carries")
    func hasKey() {
        #expect(WordingKit.hasKey("fehler.netz"))
        #expect(WordingKit.hasKey("state.xtream.busy.title"))
        #expect(!WordingKit.hasKey("login.connect"))
    }
}
