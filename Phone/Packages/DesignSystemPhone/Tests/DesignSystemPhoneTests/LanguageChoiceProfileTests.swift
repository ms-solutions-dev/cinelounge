import Core
import Foundation
import Testing

@testable import DesignSystemPhone

/// **The app language belongs to the profile** — tvOS roadmap AP46, 2026-09-25.
///
/// Until today it lay in `UserDefaults` on the device (`app.language`), and since 2026-09-25 the
/// cloud syncs `app.language` via ``Core/ProfileStore/playbackKeys`` — that is, the
/// compartment **of the person** in the Keychain. What is tested here is that reading and
/// writing arrive where the cloud looks, and that a profile switch takes the language along.
@MainActor
@Suite("App language per profile", .serialized)
struct LanguageChoiceProfileTests {

    private func device() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test("The choice lands in the active profile's slot, not on the device")
    func choiceInProfile() throws {
        let vault = InMemoryStore()
        let store = device()
        defer { AppLanguageSetting.applies(nil) }
        ProfilePointer.als("profile-a") {
            LanguageChoice.set("tr", in: store, keychain: vault)
            #expect(LanguageChoice.chosen(store, keychain: vault) == "tr")
            #expect(AppLanguageSetting.current == "tr", "the choice does not apply immediately")
        }
        #expect(
            (try? vault.value(for: ProfileStore.bucket(AppLanguageSetting.key, forItem: "profile-a")))
                == "tr")
        #expect(store.string(forKey: AppLanguageSetting.key) == nil, "written to the device")
        #expect(ProfileStore.playbackKeys.contains(LanguageChoice.storeKey))
    }

    @Test(
        "Without a choice of its own the device's applies; without a profile the choice is written to the device"
    )
    func fallbackToDevice() {
        let vault = InMemoryStore()
        let store = device()
        defer { AppLanguageSetting.applies(nil) }
        ProfilePointer.als(nil) { LanguageChoice.set("en", in: store, keychain: vault) }
        #expect(store.string(forKey: AppLanguageSetting.key) == "en")
        ProfilePointer.als("profile-b") { #expect(LanguageChoice.chosen(store, keychain: vault) == "en") }
    }

    /// **The connection:** a profile switch re-reads the language — and only a real change
    /// changes the identifier on which the UI is rebuilt.
    @Test("After a profile switch the new profile's language applies")
    func switchCarriesLanguage() {
        let vault = InMemoryStore()
        let store = device()
        defer { AppLanguageSetting.applies(nil) }
        try? vault.set("tr", for: ProfileStore.bucket(AppLanguageSetting.key, forItem: "profile-a"))
        try? vault.set("de", for: ProfileStore.bucket(AppLanguageSetting.key, forItem: "profile-b"))
        let state = ProfilePointer.als("profile-a") { LanguageState(store: store, keychain: vault) }
        #expect(state.identifier == "tr")
        ProfilePointer.als("profile-b") { state.reload() }
        #expect(state.identifier == "de")
        #expect(AppLanguageSetting.current == "de")
        #expect(store.stringArray(forKey: "AppleLanguages") == ["de"])
    }
}
