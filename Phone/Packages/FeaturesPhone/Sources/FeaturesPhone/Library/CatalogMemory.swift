import Foundation

/// Which catalog was open last.
///
/// **The client's finding of 2026-09-09:** After going to the library, closing the
/// application completely and opening it again, it should reopen the last opened
/// library. Until then the choice lived only in the working memory of the
/// library model; after every cold start it fell back to the **first** catalog in
/// server order — an alphabetical answer to a personal question.
///
/// **The two neighbors have long existed.** ``CategoryMemory`` remembers the category,
/// ``SortMemory`` the order — both per catalog. Of all things, the level above,
/// on which the other two depend, was forgotten: Whoever wants to find the remembered
/// category of the series has to land at the series again first.
///
/// **A single value and no dictionary**, unlike the two neighbors. The
/// question "which catalog?" has exactly one answer; a dictionary would need a
/// key, and it would be merely invented here.
///
/// **The identifier carries origin and kind along** (``Catalog/Identifier``) and is thus
/// stable across restarts — the same reason it already carries the keys of the two
/// memories next door. What disappears when an access is removed is caught by the
/// model: It then falls back to the first catalog.
///
/// **On disk and not in the Keychain**, and `@unchecked Sendable` for the same
/// reason as with the neighbors: `UserDefaults` is documented by Apple as
/// thread-safe but does not carry the annotation.
public struct CatalogMemory: @unchecked Sendable {

    private let store: UserDefaults
    private static let key = "library.lastStock"

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    /// The remembered catalog — `nil` on the very first launch.
    public var last: Catalog.Identifier? {
        store.string(forKey: Self.key).map(Catalog.Identifier.init(rawValue:))
    }

    public func memorize(_ catalog: Catalog.Identifier) {
        store.set(catalog.rawValue, forKey: Self.key)
    }
}
