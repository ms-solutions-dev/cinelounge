import Foundation
import WordingKit

/// **The app language travels with the profile** (AP46, owner decision 4 of 2026-09-24:
/// "audio preference, subtitles, language").
///
/// **Four things were missing for it, and they are all here**, because each alone would be a
/// half solution:
///
/// 1. **Where the value lives.** Until 2026-09-25 in `UserDefaults` under `app.language` —
///    one per device. Now the same rule applies as for ``ProfileStore``: first the person's
///    compartment in the Keychain (`app.language.<profile>`), then the device value. The
///    device value **stays in `UserDefaults`**, because that is where it lies for everyone
///    who has already chosen a language; moving it would take everyone's choice away on
///    update.
/// 2. **Who notices when the person switches.** ``ProfilePointer`` was not observable; it now
///    reports its change (``ProfilePointer/switched``), and ``observe(_:)`` attaches the
///    wrapper to both notifications.
/// 3. **Which texts follow.** `Text` reads the environment locale, whereas `String(localized:)`
///    reads the **system language** — around forty places that would have stayed in the old
///    language after a switch. They now read from ``bundles``.
/// 4. **What applies before anyone has chosen.** The value of the device, and without it the
///    system language — also in "Who is watching?", where nobody is chosen yet.
///
/// **Into the cloud** the choice goes via ``ProfileStore/playbackKeys``: ``key``
/// is listed there, and the same sync that carries audio preference and subtitles carries it.
/// Only what the person chose themselves — the device value is not in the compartment.
public enum AppLanguageSetting {

    /// The same name as until 2026-09-25 — in the person's compartment with their ID behind it.
    public static let key = "app.language"

    /// Posted when a language was written — also by the takeover from the phone, which until
    /// here became visible only after a restart.
    public static let changed = Notification.Name("Appsprache.geaendert")

    /// The language that applies right now — **set by the wrapper**, read by ``bundles``.
    ///
    /// **`nonisolated(unsafe)` like ``ProfilePointer``, and for the same reason:** It is written
    /// on the main thread at launch and on a switch; it is read while drawing, which cannot wait
    /// for an actor.
    nonisolated(unsafe) public private(set) static var current: String?

    /// Sets the language that applies. **Only the wrapper calls this** — it holds the choice.
    public static func applies(_ code: String?) {
        current = code
    }

    // MARK: - Ablage

    /// This person's choice, otherwise the device's, otherwise `nil` (then the system applies).
    public static func read(
        profile: String?, keychain: any KeyValueStore, device: UserDefaults
    ) -> String? {
        if let profile, !profile.isEmpty,
            let own = try? keychain.value(for: ProfileStore.bucket(key, forItem: profile))
        {
            return own
        }
        return device.string(forKey: key)
    }

    /// Writes the choice — **into the person's compartment if someone is watching, otherwise to
    /// the device.**
    ///
    /// Changing the device value as well would mean switching the language of everyone else —
    /// exactly what stops with this store. Before the first setup there is no person, and then
    /// the choice is the device's; that way it later applies to everyone who has none of their
    /// own.
    public static func write(
        _ code: String, profile: String?, keychain: any KeyValueStore, device: UserDefaults
    ) {
        if let profile, !profile.isEmpty {
            try? keychain.set(code, for: ProfileStore.bucket(key, forItem: profile))
        } else {
            device.set(code, forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Attaches an action to **both** occasions on which the language must be re-read: a profile
    /// switch and a written choice.
    ///
    /// - Returns: The observers — whoever discards them stops listening.
    public static func observe(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> [any NSObjectProtocol] {
        [ProfilePointer.switched, changed].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
    }

    // MARK: - Texte

    /// The language bundle of the language that applies — **for every `String(localized:)`.**
    ///
    /// Without further information, `String(localized:)` looks in the main bundle for the
    /// **system language**; the in-app choice would bypass it. The `lproj` directory of the
    /// chosen language as a bundle of its own is the way Foundation leaves open for this. If it
    /// is missing — in the check run, which has no app bundle —, the main bundle applies as
    /// before.
    public static var bundles: Bundle { bundles(forItem: current) }

    /// The same for a specific language — **for checks** and for the fallback.
    public static func bundles(forItem code: String?, in main: Bundle = .main) -> Bundle {
        WordingKit.languageBundle(code, in: main)
    }

    /// A sentence from the **shared** catalog (`WordingKit`) in the language that applies.
    ///
    /// For everything a shared package says itself (AP58 R0). ``bundles`` stays for the apps'
    /// catalogs: A key lives either there or here, never in both — the two `strings.py` enforce
    /// that.
    public static func word(_ key: String.LocalizationValue) -> String {
        WordingKit.text(key, language: current)
    }

    /// The same sentence in a **specific** language — for comparisons with names that do not
    /// come from the app (for instance the name of a server library, see
    /// `HomeLayout.isCollectionLibrary`).
    public static func word(_ key: String.LocalizationValue, language: String?) -> String {
        WordingKit.text(key, language: language)
    }

    /// The catalog that holds this key — **the shared one or the app's.**
    ///
    /// For keys that are only determined at runtime and can come from both catalogs: the
    /// sentence of a ``WordingKit`` state next to the error sentence of an app (AP58 R3).
    /// `Text(appKey:)` in both design packages looks up through this. A key that only an
    /// extension catalog carries comes from there (see `WordingKit.register(_:)`).
    public static func catalog(forItem key: String) -> Bundle {
        WordingKit.catalog(holding: key) ?? .main
    }

    /// A sentence with format specifiers in the language that applies — **from the catalog that
    /// holds the key** (AP58 final step).
    ///
    /// The counterpart to `String(localized: …, bundle: AppLanguageSetting.bundles)` for keys that have
    /// been moved into the shared catalog: Which one that is, is written on the key, and a
    /// `String.LocalizationValue` yields it only through its mirrored fields
    /// (``key(from:)``). If that fails, the app's catalog applies — the behavior from
    /// before.
    public static func text(_ value: String.LocalizationValue) -> String {
        if let key = key(from: value), let catalog = WordingKit.catalog(holding: key) {
            return String(localized: value, bundle: WordingKit.languageBundle(current, in: catalog))
        }
        return String(localized: value, bundle: bundles)
    }

    /// The catalog key of a translatable value — `"a.b %lld"` for `"a.b \(3)"`.
    ///
    /// **Via `Mirror`, because Foundation does not make it public.** The check
    /// `AppLanguageTests.keyFromValue` establishes that the mirroring delivers it; if Apple
    /// changes the field, it fails there, and on the device the app's catalog applies until then.
    public static func key(from value: String.LocalizationValue) -> String? {
        Mirror(reflecting: value).children.first { $0.label == "key" }?.value as? String
    }

    /// The language bundle of the catalog that holds this key — **for `NSLocalizedString`**,
    /// which delivers a format string including plural rules.
    public static func bundles(zu key: String) -> Bundle {
        WordingKit.catalog(holding: key).map { WordingKit.languageBundle(current, in: $0) } ?? bundles
    }

    /// A sentence in the language that applies — **from the catalog that holds the key.**
    public static func message(_ key: String) -> String {
        if WordingKit.hasKey(key) { return WordingKit.text(key: key, language: current) }
        return AppLanguageSetting.text(String.LocalizationValue(key))
    }

    /// The locale of the language that applies — for names that the system translates
    /// (languages, countries). Without a choice, the system's.
    public static var locale: Locale {
        current.map(Locale.init(identifier:)) ?? .current
    }
}
