import Core
import SwiftUI

/// Holds the selected colour scheme and makes sure that the interface picks it up.
///
/// **The second part is the difficult one.** Switching a scheme means changing a global
/// quantity — and SwiftUI does not notice that: colours are read when a
/// view is built, and whatever is not rebuilt keeps its old look. You
/// would get a half-converted app, which looks worse than no conversion at all.
///
/// That is why the root carries an identifier that changes with the scheme
/// (``rebuildID``). When it changes, SwiftUI throws the whole tree away and rebuilds it.
/// That is crude — it costs the scroll positions and the focus —, but it is honest:
/// a colour change is a rare, explicit action, and afterwards everything is in
/// the new design instead of in two.
///
/// The alternative would be to pass the scheme through the environment. Cleaner, but 397
/// call sites wide — the same visible benefit with incomparably more opportunity to
/// overlook one place that nobody looks at afterwards.
public final class ThemeStore: ObservableObject {

    @Published public private(set) var current: Theme

    private let store: any KeyValueStore

    /// **Since AP58 R7 the choice lives in the one store** (``Core/ColorPattern``, finding E5):
    /// until then in the Keychain, while the phone used `UserDefaults`. On the first
    /// build the old choice is fetched over and cleared there.
    ///
    /// **Before the first render** the scheme is in `Theme.current`; otherwise the
    /// first build would still run with the default, and the app would flash up in the wrong
    /// design.
    public init(
        store: any KeyValueStore = FileStore(),
        keychain: any KeyValueStore = SecureStore(),
        device: UserDefaults = .standard
    ) {
        ColorPattern.adoptLegacyCatalog(device: device, keychain: keychain, in: store)
        self.store = store
        self.keychain = keychain
        let saved = Theme.named(Self.chosen(in: store, keychain: keychain))
        self.current = saved
        Theme.current = saved
        // **On a change of person, their colour scheme** — see ``chosen(in:keychain:)``.
        switchObserver = NotificationCenter.default.addObserver(
            forName: ProfilePointer.switched, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadForProfile() }
        }
    }

    private let keychain: any KeyValueStore
    private var switchObserver: (any NSObjectProtocol)?

    /// The colour scheme **of the person** (product decision, 2026-09-28: everything that makes up
    /// a profile belongs in the profile).
    ///
    /// First their own compartment, then — only for a profile from before the move — the choice of the
    /// device. A freshly created profile begins with the base scheme. The note
    /// "fresh" lives in the Keychain, the scheme in the file store; that is why it is
    /// asked for explicitly here.
    nonisolated static func chosen(
        in store: any KeyValueStore, keychain: any KeyValueStore,
        profile: String? = ProfilePointer.active
    ) -> String? {
        guard let profile else { return ColorPattern.chosen(in: store) }
        if let own = ColorPattern.chosen(in: ProfileStore(store, forItem: profile)),
            (try? store.value(for: ProfileStore.bucket(ColorPattern.key, forItem: profile))) != nil
        {
            return own
        }
        return ProfileStore.isFresh(profile, in: keychain) ? nil : ColorPattern.chosen(in: store)
    }

    private func loadForProfile() {
        let fresh = Theme.named(Self.chosen(in: store, keychain: keychain))
        guard fresh != current else { return }
        Theme.current = fresh
        current = fresh
    }

    public func choose(_ theme: Theme) {
        guard theme != current else { return }
        Theme.current = theme
        current = theme
        ColorPattern.select(theme.id, in: ProfileStore(store, forItem: ProfilePointer.active))
    }

    /// What belongs at the root so that the change arrives.
    public var rebuildID: String { current.id }
}
