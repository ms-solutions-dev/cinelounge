import Core
import Foundation

/// Where fetched third-party ratings are stored, so that they survive a restart.
///
/// **Why it is needed** (finding of 2026-09-07): AniList answered all queries with
/// `403 — "The AniList API has been temporarily disabled due to severe stability issues."`
/// The service was switched off, the app flawless: right identifier, right endpoint. All
/// that was visible was that numbers were missing — and that reads like an error of one's
/// own app.
///
/// **On the TV it only seemed to "work".** Both projects build their `AniListClient` with
/// the default `InMemoryStore`, so they keep nothing beyond a run. The difference is the
/// lifetime: the TV program holds **one** access for the whole session, and an Apple TV is
/// rarely quit — the memory filled before the outage and held. The phone rebuilt the access
/// at every render.
///
/// **Hence disk instead of memory.** Ratings fetched once thereby survive the outage of a
/// third-party source. The client stores on its own as soon as it gets a persistent store —
/// nothing needs to change in `RatingsKit` for this.
///
/// **`UserDefaults` and not the Keychain.** `SecureStore` fulfills the same contract and
/// would be swapped in with one line, but it is the wrong place for a growing ratings table:
/// the Keychain is for secrets, survives uninstallation and is shared with the TV. A rating
/// is neither.
struct NoteStore: KeyValueStore {

    /// Which store — `nil` is the program's.
    ///
    /// **The name and not the store itself.** `UserDefaults` is not `Sendable`, and
    /// ``Core/KeyValueStore`` requires it; a held instance would be the point at which the
    /// compiler under strict concurrency rightly objects. Foundation returns the same object for
    /// the same name anyway — the lookup costs nothing, and the tests keep their own store.
    private let area: String?

    init(area: String? = nil) {
        self.area = area
    }

    private var store: UserDefaults {
        area.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func set(_ value: String, for key: String) throws {
        store.set(value, forKey: Self.withPrefix(key))
    }

    /// - Throws: ``Missing`` if nothing is stored.
    ///
    /// **A throw and not `nil`** — the contract of ``Core/KeyValueStore`` prescribes it that
    /// way, and the client already catches it as "nothing fetched yet".
    func value(for key: String) throws -> String {
        guard let value = store.string(forKey: Self.withPrefix(key)) else { throw Missing() }
        return value
    }

    func remove(_ key: String) throws {
        store.removeObject(forKey: Self.withPrefix(key))
    }

    /// So that foreign keys do not fall into the general namespace.
    private static func withPrefix(_ key: String) -> String { "noten.\(key)" }

    struct Missing: Error {}
}
