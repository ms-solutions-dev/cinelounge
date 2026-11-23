import Foundation

/// Which sports the schedule shows — adjustable under `Settings → Live`
/// (requirement 2026-08-16: whoever watches only football and basketball does not need
/// the other sixteen).
///
/// **It filters the list and not only the chips** (open decision 4 of the sports
/// concept, decided 2026-09-02): whoever switches off tennis gets neither the chip nor
/// the rows — a filter that leaves the filtering to the view would more honestly
/// be called "which chips".
///
/// **One key for both devices since AP58 R5 (finding L4, 2026-09-26).** Until
/// then the phone stored its choice under `live.hiddenSports` in
/// ``LivePreferences`` — a second field for the same question, which the phone's
/// schedule moreover never read until 2026-09-26. ``load(from:)`` migrates it once.
///
/// What is remembered is what is SWITCHED OFF: a new sport in the code is thereby
/// switched on by itself, instead of starting invisible with every addition.
public struct SportFilterSettings: Sendable, Equatable, Codable {

    public private(set) var disabled: Set<String> = []

    public init() {}

    // No "sport." prefix — reasoning at ``SportReminderList/key``.
    static let key = "spielplan.filterwahl.v1"

    public func isEnabled(_ kind: SportKind) -> Bool {
        !disabled.contains(kind.rawValue)
    }

    public mutating func toggle(_ kind: SportKind) {
        if disabled.contains(kind.rawValue) {
            disabled.remove(kind.rawValue)
        } else {
            disabled.insert(kind.rawValue)
        }
    }

    /// All or none — the two collective commands above the phone's chip field.
    public mutating func setAll(enabled: Bool) {
        disabled = enabled ? [] : Set(SportKind.allCases.map(\.rawValue))
    }

    /// Reads the choice — **and migrates the phone's old one once.**
    ///
    /// The migration applies only as long as nothing stands under the new key;
    /// afterwards the old entry is deleted. That way a later choice can never be
    /// overwritten by an older one.
    public static func load(from store: any KeyValueStore) -> SportFilterSettings {
        if let json = try? store.value(for: key),
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(SportFilterSettings.self, from: data)
        {
            return decoded
        }
        guard let old = try? store.value(for: LivePreferences.sportsKey) else {
            return SportFilterSettings()
        }
        var adopted = SportFilterSettings()
        adopted.disabled = Set(old.split(separator: "\n").map(String.init))
        adopted.save(to: store)
        try? store.remove(LivePreferences.sportsKey)
        return adopted
    }

    public func save(to store: any KeyValueStore) {
        guard let data = try? JSONEncoder().encode(self),
            let json = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(json, for: Self.key)
    }
}

/// Whether the schedule taps the online kickoff times (stage 3 of the matching) —
/// switchable under `Settings → Live`, for everyone who does not want requests to
/// a third-party source. Default: on.
public struct SportSyncSettings: Sendable, Equatable, Codable {

    public var isEnabled = true

    public init() {}

    static let key = "spielplan.abgleich.v1"

    public static func load(from store: any KeyValueStore) -> SportSyncSettings {
        guard let json = try? store.value(for: key),
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(SportSyncSettings.self, from: data)
        else { return SportSyncSettings() }
        return decoded
    }

    public func save(to store: any KeyValueStore) {
        guard let data = try? JSONEncoder().encode(self),
            let json = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(json, for: Self.key)
    }
}
