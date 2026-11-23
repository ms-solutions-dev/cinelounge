import Foundation

/// Which category was open last — per catalog.
///
/// **"If I was at DE Kino, I land at DE Kino again."** In the sibling project this is an
/// explicit user decision and is justified there not as a convenience but as the
/// navigation itself: with 108 categories, what decides whether the area is usable is
/// not the initial view but whether you get back out where you left off.
///
/// **And the Home screen reads along.** Its provider shelf shows the category you last
/// browsed — the only selection out of 32,532 titles that knows something about the
/// viewer. The alternative would be the provider's first category, and that is
/// alphabetical, not personal.
///
/// **On disk and not in the Keychain.** A category identifier is not a secret; it lives
/// in `UserDefaults`, like the order of the shelves and the remembered language.
/// **`@unchecked Sendable`, and justified:** `UserDefaults` is documented by Apple as
/// thread-safe but does not carry the annotation. Without it, this value would have to
/// be bound to the main actor — for two dictionary accesses that block nothing.
public struct CategoryMemory: @unchecked Sendable {

    private let store: UserDefaults
    private static let key = "library.lastCategory"

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    public func last(zu catalog: Catalog.Identifier) -> String? {
        board[catalog.rawValue]
    }

    public func memorize(_ category: String, zu catalog: Catalog.Identifier) {
        var incoming = board
        incoming[catalog.rawValue] = category
        store.set(incoming, forKey: Self.key)
    }

    private var board: [String: String] {
        store.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
