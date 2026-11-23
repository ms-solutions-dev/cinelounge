import Core
import Foundation

/// Measures the connection **from the Apple TV**.
///
/// **This is the measurement that has been missing all along.** From a computer on the same
/// network the media server answers in forty milliseconds; in the TV's diagnostic report
/// there are seven to ten seconds to the first byte for the same request.
/// What causes that could not be decided from outside — every explanation remained a
/// guess, and every guess cost a startup attempt.
///
/// So the measurement is taken here, where the problem occurs. Two quantities, because they
/// separate different causes:
///
/// - **Response time** over many small requests. It says whether the path is clean.
///   A healthy wireless link in the home network is under ten milliseconds with little
///   spread. Large spread on small requests means lost packets — then nothing
///   in the app helps any more.
/// - **Throughput** over a real range from a real file. It says whether enough is left
///   for the film at all. It is measured on what is also played,
///   not on a made-up file: that way the server's disk is part of the
///   picture, and it is exactly the one that fluctuates.
public struct ConnectionProbe: Sendable {

    public struct Result: Sendable {
        /// Response times in milliseconds, in the order of measurement.
        public let latencies: [Double]
        /// Throughput in Mbit/s. `nil` if no title was found to measure with.
        public let throughput: Double?
        /// How many of the small requests did not arrive at all.
        public let lost: Int

        public var medianLatency: Double {
            guard !latencies.isEmpty else { return 0 }
            let sorted = latencies.sorted()
            return sorted[sorted.count / 2]
        }

        public var worstLatency: Double { latencies.max() ?? 0 }

        /// How the measurement turned out — as a named case, not as a sentence.
        ///
        /// **So that wording and classification cannot drift apart.** Whoever
        /// wants to read the classification out of ``verdict`` would have to
        /// recognize the sentence; whoever places it alongside writes the same
        /// decision tree a second time, and two versions of the same rule
        /// sooner or later drift apart. The named case can also be tested
        /// without a network — the measurement itself cannot.
        public enum Finding: Sendable, Equatable {
            /// Not a single answer — the server was unreachable.
            case unreachable
            /// Requests did not arrive at all: the path loses packets.
            case packetLoss
            /// The spread of the response times is too large.
            case jitter
            /// Response times are fine, but too little throughput for a film.
            case tooSlow
            /// Nichts zu beanstanden.
            case healthy

            /// Whether the finding names a defect — the question on which the
            /// recording decides whether a checkmark or a cross belongs in it.
            public var isProblem: Bool { self != .healthy }
        }

        /// From this worst response time the spread counts as a sign of
        /// lost packets — half a second for a request that stays under ten
        /// milliseconds in a healthy home network.
        static let jitterThreshold: Double = 500

        /// Below this throughput it is not enough for a film with a high bitrate.
        static let minimumThroughput: Double = 25

        /// The finding, in exactly the order in which the causes hide
        /// one another: whoever does not answer has no spread; whoever loses
        /// packets, their throughput no longer says anything.
        public var finding: Finding {
            if latencies.isEmpty { return .unreachable }
            if lost > 0 { return .packetLoss }
            if worstLatency > Self.jitterThreshold { return .jitter }
            if let throughput, throughput < Self.minimumThroughput { return .tooSlow }
            return .healthy
        }

        /// The finding as a sentence — this is how it appears in the report.
        ///
        /// **The interpretation is part of it.** A series of numbers requires the reader to know
        /// what is normal. Nobody here knew that for a long time.
        public var verdict: String {
            switch finding {
            case .unreachable:
                // **Two lines of the same measurement must not
                // contradict each other** — and "unreachable" directly contradicts a
                // measured throughput right above it. The state is
                // reproducible and no edge case: ``reachable()`` aborts after 5 s,
                // the throughput fetch has its own 30 s. A server that answers between
                // the two limits lets all twelve small requests
                // time out and still pushes the large one through. What then exists
                // is not a dead server but a line that takes long to the first
                // byte — a finding of its own, and a defect it remains either way.
                if let throughput {
                    return "None of the \(ConnectionProbe.latencySamples) small requests came back, but a "
                        + "large fetch did (\(rate(throughput))). The server "
                        + "answers, but too late for the measurement — wait until the "
                        + "first byte, not throughput."
                }
                return "No answer — the server was unreachable."
            case .packetLoss:
                return "\(lost) of \(latencies.count + lost) requests did not arrive at all. "
                    + "The path drops packets — that is not the app's doing."
            case .jitter:
                return "The spread is too large (median \(ms(medianLatency)), "
                    + "worst \(ms(worstLatency))). For small requests that means "
                    + "lost packets and retries — check the wireless link or the cable."
            case .tooSlow:
                return "Response times fine (median \(ms(medianLatency))), but only "
                    + "\(throughput.map { rate($0) } ?? "—") throughput. "
                    + "Too little for a high-bitrate film."
            case .healthy:
                // **No information is no acquittal.** Without a measured throughput only
                // the path is checked, not what matters for the film —
                // ``measureThroughput()`` silently returns `nil` in three of four failure cases,
                // and "connection fine" then acquitted the line
                // without having measured it.
                guard let throughput else {
                    return "Path fine, throughput not measured: median "
                        + "\(ms(medianLatency)), worst \(ms(worstLatency))."
                }
                return "Connection fine: median \(ms(medianLatency)), worst "
                    + "\(ms(worstLatency)), \(rate(throughput)) throughput."
            }
        }

        public var summary: String {
            // **Two lines of the same measurement must not contradict each other.**
            // Without a single answer, ``medianLatency`` and ``worstLatency``
            // both returned zero — so the report showed the best possible
            // response time directly above "the server was unreachable".
            var lines: [String] = []
            if latencies.isEmpty {
                lines.append("Response time: no answer at all (\(lost) requests without a reply)")
            } else {
                lines.append(
                    "Response time: median \(ms(medianLatency)), worst \(ms(worstLatency))")
                if lost > 0 { lines.append("Unanswered: \(lost)") }
            }
            if let throughput { lines.append("Throughput: \(rate(throughput))") }
            lines.append(verdict)
            return lines.joined(separator: "\n")
        }

        private func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
        private func rate(_ value: Double) -> String { String(format: "%.0f Mbit/s", value) }
    }

    /// How many small requests for the response time.
    ///
    /// Twelve: enough that a single outlier does not shift the middle, and few
    /// enough that the measurement is done in a few seconds.
    public static let latencySamples = 12

    /// How many bytes are fetched for the throughput.
    ///
    /// 16 MB — a good second on a healthy line, and on a bad one long
    /// enough that a single dip does not determine the whole result.
    public static let throughputBytes = 16 * 1024 * 1024

    private let source: JellyfinSource
    private let trustStore: CertificateTrustStore

    /// The throughput measurement's session — its own, short-lived and without cache, **but
    /// with the same certificate trust as the sign-in** (setup check, E10,
    /// 2026-09-27). Without the delegate it failed on every confirmed, self-issued
    /// certificate and silently delivered no measurement.
    static func measuringSession(trustStore: CertificateTrustStore) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(
            configuration: config, delegate: TrustingSessionDelegate(trustStore: trustStore),
            delegateQueue: nil)
    }

    public init(source: JellyfinSource, trustStore: CertificateTrustStore = CertificateTrustStore()) {
        self.trustStore = trustStore
        self.source = source
    }

    public func run() async -> Result {
        var latencies: [Double] = []
        var lost = 0

        // **Each request on its own session**, so that no reused
        // connection flatters or spoils the result. What is to be measured is the
        // path, not the state of a connection pool.
        for _ in 0..<Self.latencySamples {
            let started = Date()
            if await source.reachable() {
                latencies.append(Date().timeIntervalSince(started) * 1000)
            } else {
                lost += 1
            }
        }

        let throughput = await measureThroughput()

        let result = Result(latencies: latencies, throughput: throughput, lost: lost)
        // The trace is kept on the main thread — it is also displayed there.
        //
        // **A defect goes in as a defect** (finding 2026-08-24): A line that
        // loses packets or stays under 25 Mbit/s used to go into the trace as a checkmark —
        // and without the diagnostics switch turned on it was not in there at all. The
        // measurement that names the fault was thus silent precisely when
        // it was needed.
        await MainActor.run {
            Diagnostics.probe(result.summary, verdict: result.finding.isProblem ? .problem : .plain)
        }
        return result
    }

    private func measureThroughput() async -> Double? {
        guard let url = await source.probeStreamURL() else { return nil }

        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(Self.throughputBytes - 1)", forHTTPHeaderField: "Range")
        // Own, short-lived session without cache: A second run should
        // go over the network again and not answer from memory.
        let session = Self.measuringSession(trustStore: trustStore)
        defer { session.invalidateAndCancel() }

        let started = Date()
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }
        // **An error body is not throughput.** Without this check,
        // two hundred bytes of error text in fifty milliseconds became 0.03 Mbit/s. The
        // value is valid for six hours (``ThroughputMemory``), caps every engine choice
        // to the lowest tier during that time — and the diagnostics then accuse
        // the line that was in truth never measured.
        guard (200...299).contains(http.statusCode) else {
            await MainActor.run {
                Diagnostics.probe(
                    "Throughput measurement: response \(http.statusCode) instead of partial content — no reading",
                    verdict: .problem)
            }
            return nil
        }
        // **And the amount must be held against the requested one** (AP6 · Q4,
        // second half). The status code alone is not enough: A server that
        // ignores the range request and delivers a 200-byte file with `200`
        // produces the same nonsense as an error body — 0.03
        // Mbit/s, valid for six hours, every engine choice at the lowest tier.
        //
        // A quarter of the requested amount as the lower bound: Less is not a
        // measurement, and demanding more would mean excluding a line that is
        // really slow — that one should be measured, not concealed.
        guard data.count * 4 >= Self.throughputBytes else {
            await MainActor.run {
                Diagnostics.probe(
                    "Throughput measurement: only \(data.count) of \(Self.throughputBytes) bytes "
                        + "delivered — no reading",
                    verdict: .problem)
            }
            return nil
        }

        let seconds = Date().timeIntervalSince(started)
        guard seconds > 0 else { return nil }

        return Double(data.count) * 8 / seconds / 1_000_000
    }
}
