import Foundation

/// The iCloud key-value store, as it carried watchlist, theme and
/// reading time until E51 — now only for the **transition**: read once, write to the zone,
/// remove the key. In operation `NSUbiquitousKeyValueStore.default`,
/// in tests a box in memory.
public protocol KeyStore: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyStore {}

/// A key in the old store that a package picks up on first launch with E52.
/// ``data()``/``text()`` read, ``remove()`` clears — after that the key
/// exists nowhere any more, and the other device finds nothing at its own transition
/// (it has its state locally anyway and the zone brings the rest).
public struct LegacyData {
    public let storage: any KeyStore
    public let key: String

    public init(_ storage: any KeyStore, key: String) {
        self.storage = storage
        self.key = key
    }

    public func data() -> Data? { storage.data(forKey: key) }
    public func text() -> String? { storage.string(forKey: key) }

    public func remove() {
        storage.removeObject(forKey: key)
        storage.synchronize()
    }
}

/// A box in memory — for tests and the preview.
public final class MockStore: KeyStore, @unchecked Sendable {
    public var values: [String: Any] = [:]

    public init(_ values: [String: Any] = [:]) { self.values = values }

    public func data(forKey key: String) -> Data? { values[key] as? Data }
    public func string(forKey key: String) -> String? { values[key] as? String }
    public func removeObject(forKey key: String) { values[key] = nil }
    public func synchronize() -> Bool { true }
}

extension ProfileZone {

    /// The whole mirror as readable JSON — "Exportieren" in the sheet "iCloud & Geräte":
    /// What lies in the zone belongs to the reader, and they should be able to take it along.
    public func export() -> Data? {
        struct Output: Encodable {
            /// Stored keys keep their original (German) names — renaming them would
            /// make data written by earlier versions unreadable (AP85 B4).
            private enum CodingKeys: String, CodingKey {
                case zone
                case asOf = "stand"
                case records = "datensaetze"
            }

            let zone: String?
            let asOf: Date
            let records: [CloudRecord]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let all = types().sorted().flatMap { read($0) }
        let withoutSeal = all.map { message in
            var s = message
            s.seal = nil
            return s
        }
        return try? encoder.encode(Output(zone: zone?.name, asOf: Date(), records: withoutSeal))
    }

    /// How many records per type lie in the mirror — the line "312 Sitzungen, 14 Merkeinträge".
    public func count(_ contentType: String) -> Int { read(contentType).count }
}
