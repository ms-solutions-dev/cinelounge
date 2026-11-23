import Foundation

/// What a running remuxer reveals about itself — the counters from which a
/// stall can be interpreted (stall stage 2, `design/konzept-stall.md`
/// §5).
///
/// **As a protocol and not a class**, because the holder in the player is
/// `AnyObject` and the tests there insert a double. With the fixed type
/// ``LiveRemuxSession``, the connection "remuxer stands → board says so" could
/// only be tested with a real channel, and so not at all.
///
/// **The counters were all there already** (concept §1.3): bytes, segments or
/// frames, reconnects, the writer error. They were just never compared with
/// each other.
public protocol RepackerPulse: AnyObject {
    /// How many bytes the fetch has delivered in total.
    var receivedBytes: Int { get }
    /// How much has been produced — segments in HLS operation, frames with the
    /// renderer.
    ///
    /// Only the **increase** counts; the unit is the same to the reader.
    var produced: Int { get }
    /// How much programme the produced output carries, in seconds.
    var produzierteSekunden: Double { get }
    /// How often the connection was rebuilt.
    var reconnectCount: Int { get }
    /// The named reason when the writer is not created — see
    /// ``TransportRemuxer/writerFailure``.
    var writerFailure: Error? { get }
    /// What arrived at a burst seam and was discarded as a duplicate.
    var discardedBytes: Int { get }
}

extension RepackerPulse {

    /// Whoever knows no seams discards nothing.
    public var discardedBytes: Int { 0 }

    /// The counters at this moment, as a value.
    ///
    /// **Read once, then compute.** Each property takes its own lock; the
    /// interpretation should work with one set of numbers and not with five
    /// moments.
    public var pulseState: PulseState {
        PulseState(
            // **Without the discarded** (AP64, F-018): before every seam there stood
            // "stall A, 6 MB without a segment" — that was the overlap the remuxer
            // discards on purpose, not a stuck cutter.
            bytes: receivedBytes - discardedBytes,
            produced: produced,
            seconds: produzierteSekunden,
            reconnections: reconnectCount,
            writerError: writerFailure.map { "\($0)" })
    }
}

/// A remuxer's counters at one point in time — see ``RepackerPulse``.
public struct PulseState: Sendable, Equatable {
    public var bytes: Int
    public var produced: Int
    public var seconds: Double
    public var reconnections: Int
    /// The writer error as text — an `Error` is neither `Equatable` nor
    /// `Sendable`.
    public var writerError: String?

    public init(
        bytes: Int, produced: Int, seconds: Double, reconnections: Int,
        writerError: String?
    ) {
        self.bytes = bytes
        self.produced = produced
        self.seconds = seconds
        self.reconnections = reconnections
        self.writerError = writerError
    }
}

/// Interprets a stall in the running live player — **without acting**
/// (stall stage 2, `design/konzept-stall.md` §2–§4 and §7).
///
/// **A pure value, time comes in.** The phone ticks at one second, the TV at
/// half a second; the deadlines therefore hang on seconds and on programme,
/// never on tick counts. Tested without waiting and without a channel, in the
/// design of ``MatroskaFileSession/audioMessage(_:piece:claim:)``: the
/// computation decides, the holder only announces.
///
/// **Case A counts in programme and not in clock time** (§3.2). On the tunnel
/// at 0.3 Mbit/s the legitimate wait for a keyframe takes around 160 s of
/// clock time, and in all that time bytes grow without a segment. A deadline
/// in clock time would certainly misfire there; one in programme reaches a
/// slow line correspondingly late, and a dead cutter on a full line after
/// about fifteen seconds.
///
/// **Stage 3 — the reset on case A — is deliberately not here.** It waits for
/// the measurement on the device (decision 11): whether "would reset" ever
/// occurred on a channel that recovered. This stage delivers exactly that
/// data.
public struct StallInterpretation: Sendable {

    /// What a stall is — the cases from concept §2.
    public enum Finding: String, Sendable, Equatable, CaseIterable {
        /// **A** — bytes arrive, nothing is produced. The only case for which an
        /// action is considered (stage 3).
        case cutterStalled = "schneiderSteht"
        /// **B** — no byte arrives. The session already reconnects on its own.
        case sourceSilent = "quelleSchweigt"
        /// **C** — something is produced, but slower than it is played.
        case tooSlow = "zuLangsam"
        /// **D** — something is produced, and the engine does not take it.
        case engineRefuses = "motorNimmtNicht"
        /// None of the signatures matches unambiguously.
        case undetermined = "unbestimmt"

        /// The letter from the concept — for the error trace.
        public var identifier: String {
            switch self {
            case .cutterStalled: "A"
            case .sourceSilent: "B"
            case .tooSlow: "C"
            case .engineRefuses: "D"
            case .undetermined: "?"
            }
        }
    }

    /// One observation per tick.
    public struct Sample: Sendable, Equatable {
        /// Seconds on an arbitrary, steadily rising clock.
        public var time: TimeInterval
        public var status: PlaybackStatus
        public var position: TimeInterval
        /// The upper bound of what is loaded, when the engine knows it.
        public var loadedUntil: TimeInterval?
        /// Whether a picture has played since loading — before that the case belongs
        /// to the startup watchdogs (concept §2, "Two boundaries").
        public var hasPlayed: Bool
        public var pulse: PulseState

        public init(
            time: TimeInterval, status: PlaybackStatus, position: TimeInterval,
            loadedUntil: TimeInterval?, hasPlayed: Bool, pulse: PulseState
        ) {
            self.time = time
            self.status = status
            self.position = position
            self.loadedUntil = loadedUntil
            self.hasPlayed = hasPlayed
            self.pulse = pulse
        }
    }

    /// How much programme without a single segment counts as "cutter stuck".
    ///
    /// **Fifteen seconds, composed and not plucked** (§3.2): at most 10 s
    /// keyframe interval on the UHD channels, plus 2 s wait for the audio
    /// (`audioGracePeriod`), plus 3 s reserve for the bitrate spread — a keyframe
    /// is large, and the mean underestimates it. That puts the deadline before
    /// the ≈ 20 s after which the queue overflow writes a line anyway. **To be
    /// measured on the device** (AP57): the longest healthy stretch —
    /// ``longestStretchWithoutChunk`` delivers it.
    public static let deadline: TimeInterval = 15

    /// Over which window cases B, C and D judge when the board flips.
    ///
    /// The twelve seconds of the board (`stallTicks` in the TV player): when it
    /// flips, the position has stood that long, and exactly over that time the
    /// question is what bytes and production did.
    public static let window: TimeInterval = 12

    public init() {}

    /// The last observations, at most one ``window`` back.
    private var history: [Sample] = []
    /// State of the bytes when something was last produced.
    private var bytesAtLastProduction: Int?
    /// State of the production at the last increase.
    private var lastProduction: Int?
    /// Bytes per broadcast second, **frozen** at the last increase.
    ///
    /// Frozen, because the running rate itself grows along during case A: the
    /// bytes rise, the programme does not — the threshold moved along, and under
    /// fifteen seconds of programme one never reached it.
    private var message: Double?
    /// Which findings for this target are already in the error trace.
    private var reported: Set<Finding> = []

    /// The longest stretch of bytes without a segment in this run, in seconds of
    /// programme.
    ///
    /// **The measured quantity for stage 3** (concept §8.1): it carries the twelve
    /// seconds of the deadline, and so far it is measured only as the cadence of
    /// the UHD channels.
    public private(set) var longestStretchWithoutChunk: Double = 0

    /// Begins a new run of the same target — after every rebuild of the remuxer.
    ///
    /// **The lock stays**: it applies per target, not per session. The counters,
    /// on the other hand, start at zero in every session, and an old rate against
    /// new bytes would yield nonsense.
    public mutating func newRun() {
        history = []
        bytesAtLastProduction = nil
        lastProduction = nil
        message = nil
        longestStretchWithoutChunk = 0
    }

    /// Takes in an observation.
    ///
    /// - Returns: ``Finding/cutterStalled`` as soon as its signature is met —
    ///   **even before the board**, because case A announces itself through bytes
    ///   and not through the stuck position (§4: "immediately on detection").
    ///   Otherwise `nil`.
    public mutating func take(_ probe: Sample) -> Finding? {
        // A pause is a decision of the viewer, and before the first picture the
        // startup watchdogs decide. In both cases there is nothing to interpret.
        guard probe.hasPlayed, probe.status != .paused else {
            history = []
            return nil
        }
        let pulse = probe.pulse
        if pulse.produced != lastProduction {
            lastProduction = pulse.produced
            bytesAtLastProduction = pulse.bytes
            if pulse.seconds > 0, pulse.bytes > 0 {
                message = Double(pulse.bytes) / pulse.seconds
            }
        }
        history.append(probe)
        history.removeAll { probe.time - $0.time > Self.window }
        if let stretch = stretchWithoutChunk(pulse) {
            longestStretchWithoutChunk = max(longestStretchWithoutChunk, stretch)
        }
        return cutterStalled(pulse) ? .cutterStalled : nil
    }

    /// How much programme has come in since the last segment — `nil` while the
    /// rate is unknown.
    private func stretchWithoutChunk(_ pulse: PulseState) -> Double? {
        guard let message, message > 0, let baseline = bytesAtLastProduction else { return nil }
        return Double(pulse.bytes - baseline) / message
    }

    /// The signature of case A.
    ///
    /// **A named reason is no suspicion** (§3.2, "Additionally and immediately"):
    /// if the error from the writer build is present, A applies without a
    /// deadline.
    private func cutterStalled(_ pulse: PulseState) -> Bool {
        if pulse.writerError != nil { return true }
        guard let stretch = stretchWithoutChunk(pulse) else { return false }
        return stretch > Self.deadline
    }

    /// Interprets the stall at the tick in which the board flips (§3.3).
    ///
    /// **Only for the sentence, never for an action.** B, C and D differ in what
    /// bytes and production did in the window; they call for no intervention.
    public func interpret() -> Finding {
        guard let last = history.last, let first = history.first else { return .undetermined }
        if cutterStalled(last.pulse) { return .cutterStalled }
        if last.pulse.bytes == first.pulse.bytes { return .sourceSilent }
        let grown = last.pulse.produced > first.pulse.produced
        guard grown else { return .undetermined }
        let isLoading = (last.loadedUntil ?? 0) > (first.loadedUntil ?? 0)
        if last.status == .playing || isLoading { return .engineRefuses }
        if last.status == .buffering { return .tooSlow }
        return .undetermined
    }

    /// The line for the error trace — **once per finding and target**, otherwise
    /// `nil`.
    ///
    /// The same lock as ``MatroskaFileSession/FileReportGate``: by kind of
    /// finding, not by time. A channel that first stays silent and then delivers
    /// too slowly gets two lines; one that stays silent ten times, one.
    public mutating func report(forItem finding: Finding) -> String? {
        guard reported.insert(finding).inserted else { return nil }
        return text(forItem: finding)
    }

    /// The wording of the line, without lock — for the tests and the congestion
    /// report.
    public func text(forItem finding: Finding) -> String {
        let header = "Stall \(finding.identifier)"
        guard let last = history.last else { return header + ": no observation" }
        let pulse = last.pulse
        let first = history.first ?? last
        let span = max(0, last.time - first.time)
        func seconds(_ value: Double) -> String { String(format: "%.1f", value) }
        switch finding {
        case .cutterStalled:
            var split = ["Stall A (cutter stopped)"]
            if let baseline = bytesAtLastProduction {
                split.append("\((pulse.bytes - baseline) >> 10) KB without a chunk")
            }
            if let stretch = stretchWithoutChunk(pulse) {
                split.append("≈ \(seconds(stretch)) s of broadcast")
            }
            if let reason = pulse.writerError { split.append("Reason: \(reason)") }
            return split.joined(separator: ", ")
                + " — would restart (stage 3 awaits the measurement)"
        case .sourceSilent:
            return "Stall B (source silent): no byte for \(seconds(span)) s, "
                + "\(pulse.reconnections) reconnections"
        case .tooSlow:
            let fresh = pulse.seconds - first.pulse.seconds
            let mbit = span > 0 ? Double(pulse.bytes - first.pulse.bytes) * 8 / span / 1_000_000 : 0
            return "Stall C (too slow): \(seconds(fresh)) s of broadcast in \(seconds(span)) s, "
                + "delivery \(seconds(mbit)) Mbit/s"
        case .engineRefuses:
            let fresh = pulse.seconds - first.pulse.seconds
            return "Stall D (engine does not accept): \(seconds(fresh)) s of broadcast produced, "
                + "position stuck at \(seconds(last.position)) s, state \(last.status.rawValue)"
        case .undetermined:
            return "Stall ? (undetermined): \((pulse.bytes - first.pulse.bytes) >> 10) KB "
                + "in \(seconds(span)) s, production \(first.pulse.produced) → \(pulse.produced), "
                + "state \(last.status.rawValue)"
        }
    }
}
