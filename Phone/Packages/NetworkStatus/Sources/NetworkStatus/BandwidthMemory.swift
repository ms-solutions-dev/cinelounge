import Foundation

/// What the line carried last.
///
/// **Bound to the network path, not to the clock.** On the TV a measured value is valid
/// for six hours; for a device that leaves the home, that is the wrong binding.
/// A measurement on home Wi-Fi says nothing about the Wi-Fi in the café — and both are
/// called "Wi-Fi".
///
/// The way out is the counter from ``NetworkWatch``: A value is valid as long as the path
/// has not changed. If it changes, the measurement is invalid — not old, but
/// **about something else**.
public struct BandwidthMemory: Sendable, Equatable {

    private struct BandwidthNote: Sendable, Equatable {
        let mbit: Double
        let changeCount: Int
    }

    private var notes: [NetworkPath: BandwidthNote] = [:]

    public init() {}

    /// Remembers a measurement for the path on which it was taken.
    public mutating func memorize(_ mbit: Double, route: NetworkPath, changeCount: Int) {
        guard mbit > 0 else { return }
        notes[route] = BandwidthNote(mbit: mbit, changeCount: changeCount)
    }

    /// What was last measured — or `nil` if something else has applied since.
    public func value(route: NetworkPath, changeCount: Int) -> Double? {
        guard let note = notes[route], note.changeCount == changeCount else { return nil }
        return note.mbit
    }

    /// Discards everything. After a change of provider or channel list.
    public mutating func forget() {
        notes.removeAll()
    }

    /// Whether a resolution tier is acceptable at this state.
    ///
    /// Without a measurement **nothing is guessed**: The answer is then `nil`, and the call
    /// site says "not yet measured" instead of inventing a number. The design promises exactly
    /// that in several places.
    public func carries(_ mbit: Double, route: NetworkPath, changeCount: Int) -> Bool? {
        guard let measured = value(route: route, changeCount: changeCount) else { return nil }
        return measured >= mbit
    }
}
