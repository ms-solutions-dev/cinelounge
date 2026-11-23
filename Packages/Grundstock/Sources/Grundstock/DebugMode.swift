import Foundation

/// Whether the app records verbosely.
///
/// **Why this exists.** The trace holds fifty entries and was meant for failures. For
/// hunting a stutter that is not enough: there you want to know what
/// happened the whole time, not only what went wrong. Recording everything all the time
/// would be just as wrong — a Home screen fills the fifty slots in seconds, and the
/// one line that matters falls off the end.
///
/// Hence a switch. Off means: only failures and conspicuously slow requests,
/// as before. On means: additionally every playback with samples, every
/// connection measurement and every marker set.
///
/// It lives in Settings under "Diagnostics" and is explicitly **not** meant
/// to be permanent. The reminder of that sits at the switch itself.
public struct DebugMode: Sendable, Equatable {

    public var isOn: Bool

    public init(isOn: Bool = false) {
        self.isOn = isOn
    }

    static let storageKey = "diagnostics.debug"

    public static func load(from store: any KeyValueStore) -> DebugMode {
        DebugMode(isOn: (try? store.value(for: storageKey)) == "1")
    }

    /// Loads the stored state and makes it the effective one — at app launch.
    ///
    /// **The bug that was here:** The only writer of ``current`` was the
    /// tap in Settings. After every restart the value was therefore back
    /// at Off, whatever the store said — the switch showed On, and the
    /// app recorded sparsely. A setting that does not survive its restart
    /// is not one; that is why this call belongs at launch, before the first
    /// recording occurs.
    public static func activate(from store: any KeyValueStore) {
        current = load(from: store)
    }

    public func save(to store: any KeyValueStore) {
        try? store.set(isOn ? "1" : "0", for: Self.storageKey)
    }

    /// The currently effective state, for places that have no access to the store.
    ///
    /// The same reasoning as for ``Theme/current``: it is read in many places and
    /// only read, written in exactly one. The guarantee is not "doesn't matter"
    /// but "is set by one thread".
    public nonisolated(unsafe) static var current = DebugMode()
}
