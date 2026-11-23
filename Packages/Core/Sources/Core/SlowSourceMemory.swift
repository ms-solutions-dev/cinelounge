import Foundation

/// Remembers channels whose delivery was measured as tight.
///
/// **On-device finding 2026-08-16, ALPA SPORT+:** the provider delivers some channels
/// only in real time — 75 buffering reports in 79 seconds, on both paths.
/// No app can cure that; it can mitigate it: a channel known to be tight gets a
/// larger startup reserve on the next start — a start a few seconds later in
/// exchange for a cushion that absorbs the fluctuations.
///
/// Built the same as ``RawStreamMemory`` — same key shape, same threshold, same
/// curability.
public struct SlowSourceMemory: Sendable {

    static let key = "live.slowSources"
    static let limit = 200

    /// From how many buffering reports a playback counts as tight.
    ///
    /// Six, not three: a startup stutter and an ad cut are normal — six reports in
    /// one session are a pattern.
    ///
    /// **From six to two** (F-004, 2026-09-03): with the short segments a channel starts
    /// after 1.5 s of broadcast — with a provider that delivers only in real time
    /// that is tight, and Telve 2 HQ as well as NEBULA HD stood still after four
    /// seconds ("buffer empty"). Six reports would mean stuttering six times before
    /// the rule takes effect; two are a pattern and not chance.
    public static let stallThreshold = 2

    private var addresses: [String]

    public init(addresses: [String] = []) {
        self.addresses = addresses
    }

    static func key(for url: URL) -> String {
        url.deletingPathExtension().absoluteString
    }

    public var count: Int { addresses.count }

    /// Whether this channel needs the large startup reserve.
    public func needsGenerousWarmup(_ url: URL) -> Bool {
        addresses.contains(Self.key(for: url))
    }

    public mutating func remember(_ url: URL) {
        let entry = Self.key(for: url)
        addresses.removeAll { $0 == entry }
        addresses.insert(entry, at: 0)
        if addresses.count > Self.limit {
            addresses.removeLast(addresses.count - Self.limit)
        }
    }

    /// Forgets a channel — if it runs smoothly again, it should start fast again too.
    public mutating func forget(_ url: URL) {
        addresses.removeAll { $0 == Self.key(for: url) }
    }

    // MARK: - Ablage

    public static func load(from store: any KeyValueStore) -> SlowSourceMemory {
        guard let joined = try? store.value(for: key) else { return SlowSourceMemory() }
        return SlowSourceMemory(addresses: joined.split(separator: "\n").map(String.init))
    }

    public func save(to store: any KeyValueStore) {
        try? store.set(addresses.joined(separator: "\n"), for: Self.key)
    }
}
