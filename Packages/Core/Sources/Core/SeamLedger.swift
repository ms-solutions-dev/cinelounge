import Foundation

/// How often a recurring line may enter the diagnostic log: the first five in full,
/// after that every tenth — with the running number, so that nothing seems lost
/// that is merely throttled.
///
/// **Why throttle at all** (AP64, 2026-10-03): in burst mode the connection breaks
/// every 10–20 s. One line per seam would be 30–60 lines in ten minutes, and the
/// ring buffer would lose exactly the beginning, where the error is recognized.
struct ReportBeat {
    static let total = 5
    static let beat = 10

    private(set) var count = 0

    /// Counts an event and says whether it gets a line.
    mutating func tally() -> Bool {
        count += 1
        return count <= Self.total || count % Self.beat == 0
    }
}

/// What happens at the seams of a live stream — the diagnosis for AP64.
///
/// **The finding that was invisible without this book** (2026-10-02, Telve on the TV):
/// "20 s of broadcast, 8 s back, again 20 s" — and nothing in the diagnostic log.
/// The break was in there only with verbose recording, the clock reported its
/// breaks only at session end, and how far back the new burst started, nobody wrote
/// down. Now every seam is there: where the new burst started (before or after the
/// end), what came twice and was discarded, and where it went on.
struct SeamLedger {

    private var beat = ReportBeat()
    private var breakBeat = ReportBeat()
    private(set) var overlaps = 0
    private(set) var gaps = 0
    private(set) var discarded = 0
    private var backwardSum = 0.0
    private var backwardMax = 0.0
    private var forwardMax = 0.0

    var seams: Int { beat.count }

    /// A seam is closed: the first keyframe after the end has arrived.
    ///
    /// - Parameters:
    ///   - zurueck: How far before the end the new burst started (s), `nil`
    ///     without overlap.
    ///   - verworfen: How many pictures came twice in the process.
    ///   - weiter: Where it continues, measured against the end (s); negative means it
    ///     lies more than a minute back — a new time base.
    /// - Returns: The line for the diagnostic log, or `nil` if throttled.
    mutating func seam(back: Double?, discarded count: Int, next: Double) -> String? {
        if let back {
            overlaps += 1
            backwardSum += back
            backwardMax = max(backwardMax, back)
        } else if next > 1 {
            gaps += 1
        }
        discarded += count
        forwardMax = max(forwardMax, next)
        guard beat.tally() else { return nil }

        var row = "Seam no. \(beat.count): "
        if let back {
            row +=
                "new burst started \(Self.s(back)) before the end, "
                + "\(count) pictures discarded twice, continued \(Self.s(next)) after the end"
        } else if next < 0 {
            row += "new burst \(Self.s(-next)) before the end — new timeline, the clock smooths it out"
        } else {
            row +=
                "new burst started \(Self.s(next)) after the end"
                + (next > 1 ? " — gap" : "")
        }
        if beat.count > 1 { row += " · so far \(tally)" }
        return row
    }

    /// The clock has smoothed out a break — counted in ``StreamClock``.
    mutating func recordBreak(number: Int, note: String?) -> String? {
        guard breakBeat.tally() else { return nil }
        return "Clock: break no. \(number) smoothed out" + (note.map { " (\($0))" } ?? "")
    }

    /// The sum for the session end — only if there were seams.
    var balance: String? {
        guard seams > 0 else { return nil }
        return "Seams: \(tally)"
    }

    private var tally: String {
        var split = ["\(seams) seams"]
        if overlaps > 0 {
            split.append(
                "\(overlaps) with overlap (avg \(Self.s(backwardSum / Double(overlaps))), "
                    + "max. \(Self.s(backwardMax)), \(discarded) pictures discarded)")
        }
        if gaps > 0 { split.append("\(gaps) with gap (max. \(Self.s(forwardMax)))") }
        return split.joined(separator: ", ")
    }

    private static func s(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }
}

extension TransportRemuxer {

    /// The shorter way from `from` to `until` in the 33-bit circle, in 90 kHz ticks —
    /// positive forwards, negative backwards.
    static func circularTicks(from: UInt64, until: UInt64) -> Int64 {
        let circle: UInt64 = 1 << 33
        let forward = (until &- from) & (circle - 1)
        return forward < circle / 2 ? Int64(forward) : -Int64(circle - forward)
    }

    /// Dasselbe in Sekunden.
    static func circularDistance(from: UInt64, until: UInt64) -> Double {
        Double(circularTicks(from: from, until: until)) / 90_000
    }
}
