import Foundation

/// Collects the startup times of a session and says whether they are even.
///
/// **The finding it exists for** (AP12, viewer finding 2026-08-11): Sometimes the audio comes
/// before the picture, sometimes both take a while; once it is running, it runs stably.
/// That is a statement about the **spread**, and exactly that is what the diagnostics could
/// not make: ``StartupTiming`` writes one line per start, and whoever wanted to know whether
/// startup fluctuates had to lay the lines side by side by hand. A number that you first have
/// to compute yourself is not in the report.
///
/// **Why separated by delivery route.** An unmodified stream from the server and a channel
/// remuxed by ourselves have nothing to do with each other; thrown into one pot, every
/// session in which both occurred would look uneven — and that is every session.
///
/// **And the abort counts.** A start that never showed a picture is not a missing
/// measurement but the worst one: Whoever leaves it out makes a session look good in which
/// every third channel stayed black.
public final class StartupTally: @unchecked Sendable {

    /// The shared tally of the running session.
    ///
    /// Process-wide, because every playback has its own ``PlayerModel``: The question "does
    /// startup fluctuate?" cannot be asked of a single start.
    public static let shared = StartupTally()

    private let lock = NSLock()
    private var times: [String: [TimeInterval]] = [:]
    private var aborts: [String: Int] = [:]

    /// How many values are kept per route.
    ///
    /// A long session with a hundred channel switches should not fill the memory; for median and
    /// range the last sixty are by far enough.
    public static let retentionLimit = 60

    /// From how many values the evenness is judged at all.
    ///
    /// **Three starts are not a spread, but three numbers.** Whoever concludes "uneven" from two
    /// reports the normal case as a defect: The first start of a session is regularly the
    /// slowest, because downloads and connections are not yet in place.
    public static let minimumSamples = 4

    /// From which ratio of largest to smallest value startup counts as uneven.
    ///
    /// **Two, and in addition an absolute minimum gap.** The ratio alone would be worthless for
    /// fast routes: 180 ms against 420 ms is a factor of 2.3 and no viewer notices it. The second
    /// next to it is the size from which someone says "sometimes fast, sometimes slow".
    public static let spreadFactor: Double = 2
    /// How far apart the largest and smallest value must be at least.
    public static let spreadDistance: TimeInterval = 1

    public init() {}

    /// Records a complete measurement.
    ///
    /// Incomplete ones do not go in: Without a first picture there is no duration that could be
    /// compared with others — that is what ``recordAbort(route:)`` is for.
    public func take(_ timing: StartupTiming) {
        guard let total = timing.total else { return }
        lock.lock()
        defer { lock.unlock() }
        var list = times[timing.opening, default: []]
        list.append(total)
        if list.count > Self.retentionLimit { list.removeFirst(list.count - Self.retentionLimit) }
        times[timing.opening] = list
    }

    /// Notes a start that never showed a picture.
    public func recordAbort(route: String) {
        lock.lock()
        defer { lock.unlock() }
        aborts[route, default: 0] += 1
    }

    /// What came out for a route.
    public struct Row: Sendable, Equatable {
        public let route: String
        public let count: Int
        public let median: TimeInterval
        public let smallest: TimeInterval
        public let largest: TimeInterval
        public let aborts: Int

        /// Whether the values diverge — see ``StartupTally/spreadFactor``.
        public var isUneven: Bool {
            guard count >= StartupTally.minimumSamples, smallest > 0 else { return false }
            return largest - smallest >= StartupTally.spreadDistance
                && largest >= smallest * StartupTally.spreadFactor
        }

        public var row: String {
            func ms(_ value: TimeInterval) -> String { String(format: "%.0f ms", value * 1000) }
            var text =
                "Startup [\(route)]  \(count) start\(count == 1 ? "" : "s")"
                + "  Median \(ms(median))  Range \(ms(smallest))–\(ms(largest))"
            if aborts > 0 {
                text += "  gave up without a frame: \(aborts)"
            }
            if isUneven {
                text += "  — uneven"
            }
            return text
        }
    }

    /// All routes, ordered by frequency — the most used first.
    ///
    /// Routes without a single successful measurement appear too: They are the hardest finding
    /// this tally knows.
    public var rows: [Row] {
        lock.lock()
        defer { lock.unlock() }

        let routes = Set(times.keys).union(aborts.keys)
        return
            routes
            .map { route -> Row in
                let values = times[route, default: []].sorted()
                return Row(
                    route: route,
                    count: values.count,
                    median: values.isEmpty ? 0 : values[values.count / 2],
                    smallest: values.first ?? 0,
                    largest: values.last ?? 0,
                    aborts: aborts[route, default: 0]
                )
            }
            .sorted { ($0.count + $0.aborts, $0.route) > ($1.count + $1.aborts, $1.route) }
    }

    /// The lines for the report — empty as long as nothing was measured.
    public var report: [String] {
        rows.map(\.row)
    }

    /// Empties the tally. For the checks and for "Delete recording".
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        times.removeAll()
        aborts.removeAll()
    }
}
