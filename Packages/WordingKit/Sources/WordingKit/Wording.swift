import Foundation
import Synchronization

/// The strings that shared packages show — **from their own catalog, in the app's language.**
///
/// **Why a separate bundle** (AP58 R0): A shared package that looks things up through `.main`
/// relies on every app that embeds it carrying its keys. Here the catalog sits with the
/// package, and `Bundle.module` finds it in every program that embeds the package — on the
/// TV, on the phone and in the check run.
///
/// **The language comes from outside.** `String(localized:)` without further arguments looks
/// for the system language; the choice made in the app would bypass it. ``text(_:language:)``
/// therefore takes the `lproj` of the chosen language as its own bundle — the same path that
/// `Core.AppLanguageSetting` takes for the app's catalog, and ``languageBundle(_:in:)`` does the same
/// calculation.
public enum WordingKit {

    /// The bundle with the shared catalog — for `Text(_:bundle:)` in the views.
    public static var bundles: Bundle { .module }

    /// The language bundle of a language inside a bundle — or the bundle itself.
    ///
    /// If the `lproj` is missing (no choice made, a language without translation, a check run
    /// without an app bundle), the bundle itself applies, and `String(localized:)` picks by the
    /// system language there.
    public static func languageBundle(_ code: String?, in main: Bundle) -> Bundle {
        guard let code, let path = main.path(forResource: code, ofType: "lproj"),
            let bundles = Bundle(path: path)
        else { return main }
        return bundles
    }

    /// Whether the shared catalog — or a registered extension catalog — carries this key.
    ///
    /// **For keys that travel as a value** (AP58 R3): A state, a rejection or an error picture
    /// hands its key to a view that does not know which catalog it comes from. A key never
    /// appears in both the shared and an app catalog (the `strings.py` checks enforce this), so
    /// the question has exactly one answer.
    ///
    /// **Cached, because every label asks** (AP58 final step): Since `Text(app:)` uses this to
    /// decide which catalog to look in, the question comes up every time a view is built. The
    /// answer only changes when a catalog is registered, and that empties the cache.
    public static func hasKey(_ key: String) -> Bool {
        catalog(holding: key) != nil
    }

    /// The catalog that carries this key: the shared one first, then the extension catalogs in
    /// the order they were registered — `nil` if none does.
    public static func catalog(holding key: String) -> Bundle? {
        let index =
            knownKeys.withLock({ $0[key] })
            ?? {
                let found = lookUp(key)
                knownKeys.withLock { $0[key] = found }
                return found
            }()
        switch index {
        case 0: return .module
        case let i where i > 0: return extensionBundles.dropFirst(i - 1).first
        default: return nil
        }
    }

    /// `0` for the shared catalog, `n` for the n-th extension catalog, `-1` for none.
    private static func lookUp(_ key: String) -> Int {
        if Bundle.module.localizedString(forKey: key, value: isMissing, table: nil) != isMissing {
            return 0
        }
        for (i, bundle) in extensionBundles.enumerated()
        where bundle.localizedString(forKey: key, value: isMissing, table: nil) != isMissing {
            return i + 1
        }
        return -1
    }

    private static let knownKeys = Mutex<[String: Int]>([:])

    /// Catalogs that extensions contribute — sentences for codes the core does not know.
    ///
    /// Registered once at program start (`AppExtensions` in PortalKit). They come **after** the
    /// shared catalog: an extension adds sentences, it does not replace any.
    public static var extensionBundles: [Bundle] { registered.withLock { $0 } }

    private static let registered = Mutex<[Bundle]>([])

    /// Adds an extension catalog. The same bundle twice is ignored.
    public static func register(_ bundle: Bundle) {
        registered.withLock { list in
            if !list.contains(where: { $0.bundleURL == bundle.bundleURL }) { list.append(bundle) }
        }
        knownKeys.withLock { $0.removeAll() }
    }

    /// The fallback value of the lookup in ``hasKey(_:)`` — a character that no string carries.
    private static let isMissing = "\u{0}"

    /// A string from the shared catalog.
    ///
    /// - Parameter sprache: The language that applies in the app (`AppLanguageSetting.current`);
    ///   `nil` means the system language.
    public static func text(_ key: String.LocalizationValue, language: String?) -> String {
        String(localized: key, bundle: languageBundle(language, in: .module))
    }

    /// A string from whichever catalog carries the key — the shared one or an extension's.
    ///
    /// For keys that only come into being at runtime (`"error." + code`). If no catalog carries
    /// it, the shared catalog answers, and that means: the key itself.
    public static func text(key: String, language: String?) -> String {
        let catalog = catalog(holding: key) ?? .module
        return languageBundle(language, in: catalog).localizedString(
            forKey: key, value: nil, table: nil)
    }
}
