import Foundation

/// **What the line carries and what the film needs** — the information behind the sentence
/// "Connection to the provider tight" (AP69, concept 2026-10-11).
///
/// Diagnosis F-017: The viewer saw a still frame and no reason. The reason was
/// iptvhost at 4.0 Mbit/s for an episode that needs 4.0 Mbit/s at the start — not a fault,
/// but a state that can be named. Two numbers, both measured and not guessed:
/// the **line** (bytes arriving per second) and the **demand** (bytes that one
/// second of film costs, where loading is currently taking place).
///
/// **Tight means: less than 15 % headroom.** Below that the buffer hardly grows, and AVPlayer
/// will, after the kick-off, sooner or later rebuffer — exactly the case the notice
/// explains. With more headroom it plays through, and the notice would be a false report.
public struct LineFinding: Sendable, Equatable {
    /// Bytes per second coming from the provider.
    public let line: Double
    /// Bytes per second of film at the position currently being loaded.
    public let demand: Double

    public static let headroomMinimum = 1.15

    public init(line: Double, demand: Double) {
        self.line = line
        self.demand = demand
    }

    public var tight: Bool { demand > 0 && line < demand * Self.headroomMinimum }

    public var lineMbit: Double { line * 8 / 1_000_000 }
    public var demandMbit: Double { demand * 8 / 1_000_000 }

    /// `4,0` — one decimal place, with the separator of the current language.
    public static func mbit(_ value: Double, locale: Locale = AppLanguageSetting.locale) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }
}

/// Measures ``LineFinding`` from samples: bytes delivered up to that point, and
/// seconds of film loaded up to that point.
///
/// **From the loader, not from AVPlayer's access log:** For an item via the
/// ResourceLoader it holds `-1` for everything that counts (probe 2026-10-11: `requests -1,
/// transfer -1.00 s`). The loader, on the other hand, knows to the byte what it has served, and
/// `loadedTimeRanges` says how many seconds that became. The quotient of the increments is
/// the demand; the increment per wall-clock second is the line.
///
/// **Only from an honest window on**: below two seconds of film and 256 KB every number would be
/// noise — then there is no finding, and the board stays with its previous sentence.
public struct LineMeter: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var time: TimeInterval
        public var deliveredBytes: Int64
        public var loadedSeconds: TimeInterval
        public init(time: TimeInterval, deliveredBytes: Int64, loadedSeconds: TimeInterval) {
            self.time = time
            self.deliveredBytes = deliveredBytes
            self.loadedSeconds = loadedSeconds
        }
    }

    public static let windowSeconds: TimeInterval = 2
    public static let windowBytes: Int64 = 256 * 1024

    private var first: Sample?
    private var last: Sample?

    public init() {}

    /// Takes a sample; a backward jump of the bytes (new stream after a jump)
    /// starts the measurement anew.
    public mutating func take(_ probe: Sample) {
        if let first, probe.deliveredBytes >= first.deliveredBytes,
            probe.loadedSeconds >= first.loadedSeconds
        {
            last = probe
        } else {
            first = probe
            last = nil
        }
    }

    public var finding: LineFinding? {
        guard let first, let last else { return nil }
        let bytes = Double(last.deliveredBytes - first.deliveredBytes)
        let film = last.loadedSeconds - first.loadedSeconds
        let wall = last.time - first.time
        guard film >= Self.windowSeconds, bytes >= Double(Self.windowBytes), wall > 0 else { return nil }
        return LineFinding(line: bytes / wall, demand: bytes / film)
    }
}
