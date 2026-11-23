import Core
import Foundation

/// Which language the app speaks.
///
/// **The finding of 2026-09-07: the choice was decoration.** `app.language` was written in two
/// places — in setup and in settings — and **read nowhere** in the whole source. The
/// checkmark jumped to "Türkçe", and every word stayed German.
/// `App/Sources/AppLanguage.swift` and `LanguageStore.swift` had been comment scaffolds since
/// 2026-09-05 with the line "Not built yet".
///
/// ## Why `AppleLanguages` and not the environment locale
///
/// The obvious choice would have been `\.locale` at the root: it takes effect
/// **immediately**, without a restart, and `Text(_:bundle:)` reads it. But it catches only
/// half — the project contains **65 calls of `String(localized:)` in 35 files**, and those do
/// not read the environment. The result would be an app whose captions are Turkish and whose
/// values are German: worse than one that does not switch at all, because then you mistake
/// the error for your own.
///
/// `AppleLanguages`, by contrast, applies to **everything** the bundle looks up — the 65
/// places included. The price is honest and is named as such: it takes effect at the next
/// launch. An app that terminates itself to adopt a setting is no solution on iOS but a crash
/// with good intentions.
///
/// ## The second path deserves a mention
///
/// Since version 13, iOS keeps a language **per app** in the system settings. Both paths must
/// deliver the same result — exactly what the note in `LanguageStore.swift` already demanded.
/// They do: what is set here ends up in `AppleLanguages`, and that is the same switch the
/// system setting flips. That is why a line goes there, instead of the app pretending to be
/// the only place.
///
/// ## Since 2026-09-25: per profile and immediately
///
/// **The choice belongs to the profile** (tvOS roadmap AP46, decision 4 of 2026-09-24) and is
/// read via ``Core/AppLanguageSetting/read(profile:keychain:device:)`` and written via
/// ``Core/AppLanguageSetting/write(_:profile:keychain:device:)`` — the same paths as on the
/// TV; the cloud syncs `app.language` via ``Core/ProfileStore/playbackKeys``. Without
/// a profile, `UserDefaults` still applies.
///
/// **And it takes effect immediately.** What spoke against the environment locale above — the
/// 65 `String(localized:)` — is fixed: each of these places now reads
/// ``Core/AppLanguageSetting/bundles`` (``LanguageBundleTests`` watches over it), and the root sets
/// the locale from ``Core/AppLanguageSetting/locale``. `AppleLanguages` is still written along, so
/// that what iOS itself looks up also follows at the next launch.

public enum LanguageChoice {

    /// Where the choice is stored. **The same key as before** — a choice already made is not lost
    /// through this change; it is ``Core/AppLanguageSetting/key``.
    public static let storeKey = AppLanguageSetting.key

    /// The switch that iOS itself keeps.
    static let systemKey = "AppleLanguages"

    /// The offered languages. **Empty means "like the system".**
    ///
    /// Each names itself ("Deutsch", "English", "Türkçe") and not in the currently set language:
    /// whoever has set the app to Turkish and wants to switch back would otherwise search for
    /// "Almanca".
    public static let isOffered: [(identifier: String, name: String)] = [
        ("", "System"), ("de", "Deutsch"), ("en", "English"), ("tr", "Türkçe"),
    ]

    /// What is chosen — **for the active profile; empty means: the system's.**
    public static func chosen(
        _ store: UserDefaults = .standard, keychain: any KeyValueStore = SecureStore()
    ) -> String {
        AppLanguageSetting.read(profile: ProfilePointer.active, keychain: keychain, device: store)
            ?? ""
    }

    /// Sets the choice — **for the active profile, and it applies immediately.**
    ///
    /// Without a profile (before the first adoption) it lands on the device, as before. "System"
    /// means on the device: remove the entry; on a profile: an empty entry, so that the choice
    /// "like the system" travels along and does not fall back to the device value.
    public static func set(
        _ identifier: String, in store: UserDefaults = .standard,
        keychain: any KeyValueStore = SecureStore()
    ) {
        if ProfilePointer.active == nil, identifier.isEmpty {
            store.removeObject(forKey: storeKey)
            NotificationCenter.default.post(name: AppLanguageSetting.changed, object: nil)
        } else {
            AppLanguageSetting.write(
                identifier, profile: ProfilePointer.active, keychain: keychain, device: store)
        }
        apply(chosen(store, keychain: keychain), to: store)
    }

    /// Makes the read choice **effective** — immediately for the texts, at the next launch for iOS.
    ///
    /// To be called at startup, after every profile switch and after every choice
    /// (``LanguageState`` does it). **`AppleLanguages` only on a real choice:** "System" removes
    /// the entry, and then iOS takes the order of the system languages again.
    public static func apply(_ identifier: String, to store: UserDefaults = .standard) {
        AppLanguageSetting.applies(identifier.isEmpty ? nil : identifier)
        if identifier.isEmpty {
            store.removeObject(forKey: systemKey)
        } else {
            store.set([identifier], forKey: systemKey)
        }
    }

    /// Which language the app **is speaking right now** — the chosen one, otherwise that of the
    /// bundle.
    public static func running() -> String {
        AppLanguageSetting.current ?? Bundle.main.preferredLocalizations.first ?? ""
    }

    /// Whether the choice takes effect only at the next launch.
    ///
    /// **Since the choice applies immediately, only for "System"**: returning to the system
    /// language changes ``Core/AppLanguageSetting/locale`` to `Locale.current`, and iOS formed that at
    /// launch from `AppleLanguages` — until the next launch, the old choice.
    public static func needsRestart(
        _ store: UserDefaults = .standard, keychain: any KeyValueStore = SecureStore()
    ) -> Bool {
        let choice = chosen(store, keychain: keychain)
        if !choice.isEmpty { return AppLanguageSetting.current != choice }
        let system = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? ""
        return !(Bundle.main.preferredLocalizations.first ?? "").hasPrefix(system)
    }
}
