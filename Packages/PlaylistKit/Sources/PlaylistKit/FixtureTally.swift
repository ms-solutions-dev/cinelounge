import Core
import Foundation

/// The tally of the fixture fetch: what each competition answered.
///
/// **The finding it takes on** (concept, E6): A dead league ID could not be
/// told apart from an empty one. TheSportsDB answers both with HTTP 200 and
/// `"events": null` — the recording in the test fixtures contains exactly such
/// a case (league 4482, FA Cup). If an ID is renamed, it returns nothing from
/// that day on, and nobody notices: The line in the trace counts fixtures, and
/// one competition fewer looks like a day without matches. For years.
///
/// That is why the number is given **per competition**, and it distinguishes
/// four cases. The difference between "answered, but nothing" and "did not
/// answer at all" is the whole point; a counter could do everything else too.
public struct FixtureTally: Sendable, Equatable {

    public enum Finding: Sendable, Equatable {
        /// The competition answered and named fixtures.
        case fixtures(Int)
        /// The competition answered and explicitly named nothing —
        /// it does not play on these days. Summer break, international break,
        /// end of season.
        case empty
        /// The source does not know this ID (ESPN: HTTP 400). **This is
        /// the case the tally exists for** — a renamed slug.
        case unknownIdentifier
        /// No network, timeout, server error. Says nothing about the
        /// competition, only about the connection.
        case noResponse

        /// Records the response for one more day.
        func and(day count: Int) -> Finding {
            switch self {
            case .fixtures(let previous): return .fixtures(previous + count)
            case .empty, .noResponse: return count > 0 ? .fixtures(count) : .empty
            case .unknownIdentifier: return .unknownIdentifier
            }
        }

        var count: Int {
            if case .fixtures(let n) = self { return n }
            return 0
        }
    }

    /// Welche Quelle geantwortet hat.
    public let source: SportFixtureProvider
    /// How many days were queried — without the number, "empty" cannot be
    /// interpreted.
    public let days: Int
    private var findings: [String: Finding] = [:]

    public init(source: SportFixtureProvider, days: Int) {
        self.source = source
        self.days = days
    }

    public mutating func set(_ finding: Finding, forItem path: String) {
        findings[path] = finding
    }

    public func finding(forItem path: String) -> Finding? { findings[path] }

    /// Alle Termine zusammen.
    public var total: Int { findings.values.reduce(0) { $0 + $1.count } }

    /// How many competitions answered at all.
    ///
    /// **The fallback depends on this and on nothing else** (addendum of
    /// 2026-08-29): TheSportsDB is queried only if ESPN does not answer — not
    /// if ESPN answers and has nothing to report. A match-free Tuesday
    /// must not wake a second source.
    public var hasAnswered: Int {
        findings.values.count { finding in
            switch finding {
            case .fixtures, .empty: return true
            case .unknownIdentifier, .noResponse: return false
            }
        }
    }

    /// The competitions whose ID the source does not know.
    public var unknown: [String] {
        ordered.filter { $0.finding == .unknownIdentifier }.map(\.name)
    }

    /// The competitions from which no response came at all.
    public var silent: [String] {
        ordered.filter { $0.finding == .noResponse }.map(\.name)
    }

    /// In the order of the board, not in dictionary order — a trace line
    /// that is sorted differently on every run cannot be compared.
    private var ordered: [(name: String, finding: Finding)] {
        SportCompetition.all.compactMap { competition in
            findings[competition.path].map { (competition.name, $0) }
        }
    }

    /// What goes into the trace.
    ///
    /// One sentence, and it names every conspicuous competition. A number
    /// alone would again be the counter that cannot go up.
    public var report: String {
        var message =
            "Fixtures (\(source.rawValue), \(days) days): \(total) from "
            + "\(hasAnswered) of \(SportCompetition.all.count) competitions"
        let clear = ordered.filter { $0.finding == .empty }.map(\.name)
        if !clear.isEmpty { message += " · without a match: \(clear.joined(separator: ", "))" }
        if !unknown.isEmpty {
            message += " · UNKNOWN IDENTIFIER: \(unknown.joined(separator: ", "))"
        }
        if !silent.isEmpty { message += " · no answer: \(silent.joined(separator: ", "))" }
        return message
    }

    /// Whether the line belongs in the trace as a fault.
    ///
    /// An unknown ID always does: It does not heal by itself, and it costs
    /// a whole competition. A missing response counts only if it hits all
    /// of them — otherwise it was the network for a moment.
    public var isFault: Bool {
        !unknown.isEmpty || hasAnswered == 0
    }
}
