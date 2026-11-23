import Foundation

/// The most recently measured throughput to the server — basis of the
/// automatic quality choice.
///
/// **The rule only applies when it has something to say.** The levels end at
/// twenty megabit; a healthy home-network measurement of three hundred must
/// never cap playback — otherwise of all lines the best one would be
/// trimmed to the highest *level* and a UHD title transcoded that it carries
/// with ease. A measurement therefore counts only when it is **tight** (below
/// twice the highest level) and **fresh** (networks change — a tunnel
/// measurement from yesterday must not ruin movie night on the home
/// network).
public enum ThroughputMemory {

    /// From when a measurement counts as tight: twice the highest level. Below
    /// it, it has a say; above it, it stays silent.
    public static let concernThreshold: Double = 40

    /// How long a measurement is valid. Six hours: survives a TV evening, but
    /// not the change of place from the tunnel to the home network the next day.
    public static let maxAge: TimeInterval = 6 * 60 * 60

    static let storageKey = "playback.measuredThroughput"

    /// Remembers a measurement in Mbit/s together with its point in time.
    public static func save(
        mbps: Double,
        at date: Date = Date(),
        to store: any KeyValueStore
    ) {
        try? store.set(
            "\(mbps)|\(Int(date.timeIntervalSince1970))",
            for: storageKey
        )
    }

    /// The limit for the engine choice in bits per second — or `nil` when the
    /// measurement is missing, old, or has nothing to object to.
    public static func constrainingBitrate(
        from store: any KeyValueStore,
        now: Date = Date()
    ) -> Int? {
        guard let raw = try? store.value(for: storageKey) else { return nil }
        let parts = raw.split(separator: "|")
        guard parts.count == 2,
            let mbps = Double(parts[0]),
            let epoch = TimeInterval(parts[1])
        else { return nil }

        guard now.timeIntervalSince(Date(timeIntervalSince1970: epoch)) < maxAge else {
            return nil
        }
        guard mbps > 0, mbps < concernThreshold else { return nil }
        return Int(mbps * 1_000_000)
    }
}
