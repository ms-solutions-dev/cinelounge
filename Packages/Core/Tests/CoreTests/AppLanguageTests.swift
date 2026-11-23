import Foundation
import Testing

@testable import Core

/// **The app language travels with the profile** (AP46, owner decision 4).
@Suite("The app language per profile")
struct AppLanguageTests {

    private func device() -> UserDefaults {
        UserDefaults(suiteName: "applanguage-" + UUID().uuidString)!
    }

    /// **Without their own choice the device applies** — nobody loses their language on
    /// update.
    @Test("The person first, then the device")
    func personBeforeDevice() {
        let keychain = InMemoryStore()
        let device = device()
        device.set("tr", forKey: AppLanguageSetting.key)

        #expect(AppLanguageSetting.read(profile: "a", keychain: keychain, device: device) == "tr")
        AppLanguageSetting.write("de", profile: "a", keychain: keychain, device: device)
        #expect(AppLanguageSetting.read(profile: "a", keychain: keychain, device: device) == "de")
        #expect(AppLanguageSetting.read(profile: "b", keychain: keychain, device: device) == "tr")
        #expect(AppLanguageSetting.read(profile: nil, keychain: keychain, device: device) == "tr")
    }

    /// **One person's choice switches nobody else** — that is the whole point.
    @Test("Whoever chooses as a person leaves the device alone; without a person the device chooses")
    func writesIntoCorrectSlot() {
        let keychain = InMemoryStore()
        let device = device()
        AppLanguageSetting.write("en", profile: "a", keychain: keychain, device: device)
        #expect(device.string(forKey: AppLanguageSetting.key) == nil)

        AppLanguageSetting.write("tr", profile: nil, keychain: keychain, device: device)
        #expect(device.string(forKey: AppLanguageSetting.key) == "tr")
        #expect(AppLanguageSetting.read(profile: "a", keychain: keychain, device: device) == "en")
    }

    /// **Into the cloud only what the person chose** — via the same reconciliation as
    /// audio preference and subtitles.
    @Test("The own choice goes to the cloud, the device value does not")
    func travelsAlong() {
        let keychain = InMemoryStore()
        let device = device()
        device.set("tr", forKey: AppLanguageSetting.key)
        #expect(ProfileStore(keychain, forItem: "a").own()[AppLanguageSetting.key] == nil)

        AppLanguageSetting.write("de", profile: "a", keychain: keychain, device: device)
        #expect(ProfileStore(keychain, forItem: "a").own()[AppLanguageSetting.key] == "de")

        // And what comes from the cloud, the wrapper reads as the choice of this person.
        ProfileStore(keychain, forItem: "b").adopt([AppLanguageSetting.key: "en"])
        #expect(AppLanguageSetting.read(profile: "b", keychain: keychain, device: device) == "en")
    }

    /// **The switch of person has to reach the wrapper** — the pointer was not
    /// observable, and after the switch the language stayed that of the previous person.
    @MainActor
    @Test("A profile switch reports to whoever holds the language")
    func changeIsReported() async {
        let counter = TallyCounter()
        let observers = AppLanguageSetting.observe { counter.value += 1 }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        ProfilePointer.als(nil) { ProfilePointer.show(to: "switch-" + UUID().uuidString) }
        await Task.yield()
        #expect(counter.value >= 1, "The profile switch did not reach the language")
    }

    /// **Without a language directory the main bundle applies** — in the check run there
    /// is none, and a fallback into nothing would mean: keys instead of text.
    @Test("The language bundle of the choice, otherwise the main bundle")
    func bundles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "applanguage-" + UUID().uuidString)
        let de = folder.appending(path: "de.lproj")
        try FileManager.default.createDirectory(at: de, withIntermediateDirectories: true)
        try "\"greeting\" = \"Hallo\";".write(
            to: de.appending(path: "Localizable.strings"), atomically: true, encoding: .utf8)
        let main = try #require(Bundle(path: folder.path))

        let german = AppLanguageSetting.bundles(forItem: "de", in: main)
        #expect(String(localized: "greeting", bundle: german) == "Hallo")
        #expect(AppLanguageSetting.bundles(forItem: "tr", in: main) == main)
        #expect(AppLanguageSetting.bundles(forItem: nil, in: main) == main)
    }

    /// **The key of a translatable value** — via reflection, because Foundation does not
    /// hand it out. If this check fails, Apple has renamed the field; then
    /// ``AppLanguageSetting/text(_:)`` reads everything from the app's catalog, and the shared
    /// sentences show their keys.
    @Test("The catalog key comes from the value, also with format specifiers")
    func keyFromValue() {
        let count = 3
        let name = "Anna"
        #expect(AppLanguageSetting.key(from: "a.b") == "a.b")
        #expect(AppLanguageSetting.key(from: "a.c \(count) \(name)") == "a.c %lld %@")
        // Assembled at runtime — this is how `sport.kind.*` and the settings areas travel.
        let composed = "sport.kind." + "football"
        #expect(AppLanguageSetting.key(from: String.LocalizationValue(composed)) == composed)
    }

    /// A key of the shared catalog comes from there, one of the app stays as it was.
    @Test("The sentence comes from the catalog that holds it")
    func textFromTheLeadingCatalog() {
        #expect(AppLanguageSetting.text("player.subtitleForced") != "player.subtitleForced")
        #expect(AppLanguageSetting.text("does.not.exist") == "does.not.exist")
    }
}

@MainActor
private final class TallyCounter {
    var value = 0
}
