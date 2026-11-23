import SwiftUI

/// The path to the downloads that every state view may offer.
///
/// **Six states name it — "Until then, to Downloads", "Open downloads" —, and until
/// 2026-09-08 none of them went there.** The button did not even appear: ``StateBlock`` draws
/// none without a handler, and `secondaryAction` was set at none of the fourteen call
/// sites. Built that way it was correct, since a button that leads nowhere is worse than none —
/// only the downloads did not exist back then.
///
/// **Why an environment value and not a field on every view.** The state view
/// appears in Home, Library, Live, Portals, Search and the player; none of these
/// views knows the ``Navigator``, and none should. A value that the shell sets
/// **once** reaches them all — and whoever builds a seventh view gets it
/// without having to think of it.
///
/// **`nil` is the normal case and not a gap.** Without set-up downloads there is
/// nothing to open; then the quiet button stays away, as before.
public struct OpenDownloadsKey: EnvironmentKey {
    public static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {

    /// Siehe ``OpenDownloadsKey``.
    public var openDownloads: (@MainActor () -> Void)? {
        get { self[OpenDownloadsKey.self] }
        set { self[OpenDownloadsKey.self] = newValue }
    }
}
