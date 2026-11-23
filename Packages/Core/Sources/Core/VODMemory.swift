import Foundation

/// Where you were last in "Movies & Series" — per list and per kind.
///
/// **This is not a convenience but the navigation itself** (product decision
/// 2026-08-22). With 27,558 films and 7,419 series, it is not a clever start view that
/// decides whether the area is usable, but whether you end up again where you
/// left off: "If I was at DE Cinema, I land at DE Cinema again."
///
/// **Separate per list and per kind**, and both are needed: Two providers have
/// their own categories, and Xtream keeps **separate number ranges** for films and
/// series — the same identifier means a different category for the other kind. A
/// shared memory slot would, after switching to a category that does not exist
/// there, show an empty grid although categories exist.
///
/// The same job as ``LiveMemory`` for the last-seen channel, and deliberately the
/// same scope.
public enum VODMemory {

    /// The storage. As a parameter, so that the checks run without the Keychain.
    nonisolated(unsafe) public static var store: KeyValueStore = SecureStore()

    private static func kindKey(_ provider: String) -> String { "vod.kind." + provider }
    private static func categoryKey(_ provider: String, _ kind: Library.Kind) -> String {
        "vod.category." + provider + "." + kind.rawValue
    }

    // MARK: - Die Art

    /// Which kind applied last. Without an entry: films.
    ///
    /// Films as the fallback because every provider has them; some have no series at
    /// all, and an area that opens empty looks like an error.
    public static func kind(forProvider provider: String) -> Library.Kind {
        guard let raw = try? store.value(for: kindKey(provider)),
            let kind = Library.Kind(rawValue: raw)
        else { return .movies }
        return kind
    }

    public static func setKind(_ kind: Library.Kind, forProvider provider: String) {
        try? store.set(kind.rawValue, for: kindKey(provider))
    }

    // MARK: - Die Sparte

    /// Which category applied last — `nil` if nobody has been there yet.
    ///
    /// For the caller `nil` explicitly means **not** "none" but "the first of this
    /// kind". A remembered category that no longer exists — the provider reorganizes
    /// its catalog — falls back to the same path at the caller.
    public static func category(forProvider provider: String, kind: Library.Kind) -> String? {
        let stored = try? store.value(for: categoryKey(provider, kind))
        return (stored?.isEmpty ?? true) ? nil : stored
    }

    public static func setCategory(
        _ category: String, forProvider provider: String, kind: Library.Kind
    ) {
        try? store.set(category, for: categoryKey(provider, kind))
    }

    /// Forgets everything about a list — when the access is deleted.
    public static func forget(provider: String) {
        try? store.remove(kindKey(provider))
        for kind in [Library.Kind.movies, .series] {
            try? store.remove(categoryKey(provider, kind))
        }
    }
}
