import Core
import Features
import SwiftUI

/// In-app language selection.
///
/// On tvOS — unlike on iPhone — there is no way to assign a single app its own
/// language in the system settings. Anyone who should be able to choose the language
/// independently of the device has to build that themselves.
///
/// The way there is the environment locale: SwiftUI looks up every text through the
/// environment's `\.locale`. Set at the root, it switches all labels immediately —
/// without a restart and without tampering with the bundle, as older guides suggest.
///
/// Important: date and number formats hang off the same locale. That is why nothing
/// may be formatted by hand; otherwise it stays in the device language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"
    case turkish = "tr"

    var id: String { rawValue }

    /// Each language names itself — a Turkish user looks for
    /// "Türkçe", not "Türkisch".
    var endonym: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        case .turkish: "Türkçe"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Preselection based on the device language; falls back to English.
    static var deviceDefault: AppLanguage {
        let code = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return AppLanguage(rawValue: String(code)) ?? .english
    }
}

/// Holds the current language — **that of the person who is watching right now** (AP46, decision 4).
///
/// **Until 2026-09-25 it was one per device**, in `UserDefaults`. Where it lives now and in
/// which order it is read is documented at ``Core/AppLanguageSetting``; here it only says who
/// holds it and when it is read again: at startup, at every profile switch and after every
/// written choice — including one that arrives from the phone.
///
/// **Choose through ``select(_:)`` and never through `current`.** An observer that sets
/// `current` when it re-reads would, through a writer in `didSet`, write the device value into
/// the next person's slot — and that person would then have a choice they never made.
@MainActor
final class LanguageStore: ObservableObject {
    @Published private(set) var current: AppLanguage {
        didSet { AppLanguageSetting.applies(current.rawValue) }
    }

    private var observers: [any NSObjectProtocol] = []

    init() {
        current = Self.read()
        AppLanguageSetting.applies(current.rawValue)
        observers = AppLanguageSetting.observe { [weak self] in self?.reread() }
    }

    /// The choice of the person who is watching right now — otherwise the device's, otherwise the system's.
    private static func read() -> AppLanguage {
        AppLanguageSetting.read(
            profile: ProfilePointer.active, keychain: SecureStore(), device: .standard
        )
        .flatMap(AppLanguage.init(rawValue:)) ?? .deviceDefault
    }

    private func reread() {
        let fresh = Self.read()
        if fresh != current { current = fresh }
    }
}

extension LanguageStore: LanguageSelection {

    public var currentCode: String { current.rawValue }

    public var available: [(code: String, endonym: String)] {
        AppLanguage.allCases.map { ($0.rawValue, $0.endonym) }
    }

    public func select(_ code: String) {
        guard let language = AppLanguage(rawValue: code) else { return }
        AppLanguageSetting.write(
            code, profile: ProfilePointer.active, keychain: SecureStore(), device: .standard)
        current = language
    }
}
