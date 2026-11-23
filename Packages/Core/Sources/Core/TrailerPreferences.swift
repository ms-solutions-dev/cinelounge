import Foundation

/// Whether the trailer starts by itself in the information column, and after what
/// dwell time.
///
/// **Why this has to be a switch.** On the home network, autoplay is the nicest
/// thing about this column: you browse through the movies, stop on one, and
/// the trailer takes the place of the poster. Through the tunnel a measured
/// 0.3 Mbit/s is available — there every title on which focus rests
/// starts loading a movie that cannot get through anyway. The default is
/// therefore **on**, because the app is mostly used on the home network; it can be switched off
/// because on the road all that would remain otherwise is to put up with it.
///
/// The dwell time is a value and not a number in the code. It balances two things
/// against each other: short enough to feel like a reaction, long
/// enough that not every title starts something while browsing. Anyone who wants to test or
/// shift either side needs it as a value.
public struct TrailerPreferences: Sendable, Equatable {

    /// Whether the trailer starts by itself in the information column.
    public var autostarts: Bool

    /// How long a title has to be in focus before the trailer starts.
    public private(set) var dwell: TimeInterval

    /// Three seconds. For the derivation see the description of the type.
    public static let defaultDwell: TimeInterval = 3

    /// Lower bound of the dwell time.
    ///
    /// Not zero: at zero the trailer starts at the moment of the focus change,
    /// and while browsing that produces exactly the flood of requests the
    /// dwell time exists to prevent. A zero can well come from the store — it is
    /// never produced here, but it is read.
    static let minimumDwell: TimeInterval = 1

    /// Upper bound. Anything longer cannot be told apart from "switched off" —
    /// and the switch should say that, not a number.
    static let maximumDwell: TimeInterval = 30

    public init(autostarts: Bool = true, dwell: TimeInterval = TrailerPreferences.defaultDwell) {
        self.autostarts = autostarts
        // Clamped at construction and not at read time: otherwise every place that uses the
        // duration would have to know the bounds — and one of them would forget.
        self.dwell = min(max(dwell, Self.minimumDwell), Self.maximumDwell)
    }

    // MARK: - Ablage

    static let autostartKey = "trailer.autostart"
    static let dwellKey = "trailer.dwell"

    /// Two keys and no JSON: it is a flag and a number. A
    /// composite entry would only be an advantage if both had to be
    /// written together — **must** be; here the UI only changes the flag.
    public static func load(from store: any KeyValueStore) -> TrailerPreferences {
        // If the entry is missing, the default applies. Only an explicit zero
        // switches off; any other line is read as "on", because an
        // unreadable entry must not silently switch autoplay off —
        // the cause would then be sought in the app and not in the store.
        let stored = try? store.value(for: autostartKey)
        let autostarts = stored.map { $0 != "0" } ?? true

        let dwell = (try? store.value(for: dwellKey)).flatMap(Double.init) ?? defaultDwell

        return TrailerPreferences(autostarts: autostarts, dwell: dwell)
    }

    public func save(to store: any KeyValueStore) {
        // As with the other settings: whatever equals the default is
        // removed instead of written. Otherwise the store fills up with entries that
        // say nothing, and a changed default no longer takes effect for anyone.
        if autostarts {
            try? store.remove(Self.autostartKey)
        } else {
            try? store.set("0", for: Self.autostartKey)
        }

        if dwell == Self.defaultDwell {
            try? store.remove(Self.dwellKey)
        } else {
            try? store.set(String(dwell), for: Self.dwellKey)
        }
    }
}
