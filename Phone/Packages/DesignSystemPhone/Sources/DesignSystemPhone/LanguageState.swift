import Core
import Foundation
import Observation

/// The app language **as an observable value** — for the root of the UI.
///
/// **Why it is needed** (tvOS roadmap AP46, 2026-09-25): the language is not read at draw
/// time but **held** at the root — as an environment locale. Without observation it would
/// remain that of the previous person after a profile switch; the same counterpart to
/// `LanguageStore` on the TV.
///
/// It listens to ``Core/ProfilePointer/switched`` and ``Core/AppLanguageSetting/changed`` and then
/// re-reads via ``LanguageChoice/chosen(_:keychain:)``. Only a **real** change changes
/// ``identifier`` — and only that rebuilds the UI.
@MainActor
@Observable
public final class LanguageState {

    /// The chosen language of the active profile — empty means "like the system".
    public private(set) var identifier: String

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let keychain: any KeyValueStore

    public init(store: UserDefaults = .standard, keychain: any KeyValueStore = SecureStore()) {
        self.store = store
        self.keychain = keychain
        identifier = LanguageChoice.chosen(store, keychain: keychain)
        LanguageChoice.apply(identifier, to: store)
        observers = AppLanguageSetting.observe { [weak self] in self?.reload() }
    }

    /// The locale for the root.
    public var locale: Locale { AppLanguageSetting.locale }

    /// Re-reads and applies — **only on a real change.**
    public func reload() {
        let fresh = LanguageChoice.chosen(store, keychain: keychain)
        guard fresh != identifier else { return }
        LanguageChoice.apply(fresh, to: store)
        identifier = fresh
    }
}
