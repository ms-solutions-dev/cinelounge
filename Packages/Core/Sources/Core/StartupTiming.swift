import Foundation

/// How long it takes until a picture stands — measured in three sections.
///
/// **Why this measurement exists at all** (device finding 2026-08-08: HEVC
/// channels take too long, UHF does not): the cause can be argued about
/// endlessly — line, provider, container, engine — and in this session
/// exactly that happened three times, each time with a plausible and wrong
/// answer. Without numbers every optimisation is a guess, and a guessed
/// optimisation costs more time than the measurement.
///
/// **The split is the actual purpose.** A single total only says that it
/// takes long; it does not say *why*. The three sections separate exactly the
/// suspicions that have to be kept apart:
///
/// - **Until the engine is ready**: connection to the provider, handshake,
///   first data. Depends on the line and the provider, not the engine.
/// - **Until the first picture stands**: buffering and decoding. Here — and
///   only here — it is decided whether another engine would help.
/// - **Together**: the number the viewer feels.
///
/// If the time lies mostly in the first section, a second engine would be
/// ineffective, and the whole dispute about KSPlayer and FFmpeg would be
/// settled. If it lies in the second, it is the right question.
public struct StartupTiming: Sendable, Equatable {

    /// What playback was opened with — engine and delivery path, for the table.
    public let opening: String
    public let startedAt: Date

    public private(set) var readyAt: Date?
    public private(set) var firstFrameAt: Date?
    /// The remuxer's marks, if one was involved — for the breakdown (AP7 · 1).
    /// See ``StartupMarks``.
    public var remux: StartupMarks?

    /// From which span the middle section is a measurement at all.
    ///
    /// **The core must not believe the caller.** Startup is sampled every 50 ms,
    /// and both marks got the same `now` from the same sample — that produced the
    /// 156 of 156 zeros for "first picture". What lies below is not a duration
    /// but a single observation that was reported twice.
    public static let sectionResolution: TimeInterval = 0.001

    public init(opening: String, startedAt: Date) {
        self.opening = opening
        self.startedAt = startedAt
    }

    /// The engine reports that it can start.
    ///
    /// **Only the first report counts.** During playback the state switches back
    /// to "ready" several times — every buffering looks like that. Without this
    /// lock the mark would wander along and in the end measure something
    /// arbitrary.
    ///
    /// **And not after the first picture.** A readiness that arrives afterwards is
    /// no startup mark any more; it would yield a negative duration, and a
    /// negative duration in a measurement table devalues the whole table.
    public mutating func markReady(at date: Date) {
        guard readyAt == nil, firstFrameAt == nil else { return }
        readyAt = date
    }

    /// The first picture stands. Likewise only the first time.
    ///
    /// **The picture only records itself.** This spot used to pull a missing
    /// readiness to the same point in time. That invented a mark no engine had
    /// reported and wrote the middle section to zero. If the report is missing,
    /// exactly that is the finding — about the engine, not about the startup
    /// time. The guard in ``markReady(at:)`` now stands against negative
    /// durations.
    public mutating func markFirstFrame(at date: Date) {
        guard firstFrameAt == nil else { return }
        firstFrameAt = date
    }

    /// Whether the measurement is complete.
    public var isComplete: Bool { firstFrameAt != nil }

    /// Verbindung, Handschlag, erste Daten.
    public var timeToReady: TimeInterval? {
        readyAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Buffering and decoding — the section where an engine switch could change
    /// something.
    ///
    /// Below ``sectionResolution`` there is no number here: two marks that close
    /// together come from a single observation, and a computed zero looks like a
    /// measured best value.
    public var timeToFirstFrame: TimeInterval? {
        guard let firstFrameAt, let readyAt else { return nil }
        let span = firstFrameAt.timeIntervalSince(readyAt)
        guard span >= Self.sectionResolution else { return nil }
        return span
    }

    /// What the viewer feels.
    public var total: TimeInterval? {
        firstFrameAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// One line for the diagnostic trace.
    ///
    /// Deliberately one line and ordered machine-readably: the measurement
    /// consists of many runs, and those one wants to lay side by side, not read
    /// one by one.
    public var line: String {
        func ms(_ value: TimeInterval?) -> String {
            guard let value else { return "—" }
            return String(format: "%.0f ms", value * 1000)
        }
        return "Startup [\(opening)]  ready: \(ms(timeToReady))"
            + "  first frame: \(ms(timeToFirstFrame))\(missingFrameReason)"
            + "  total: \(ms(total))" + breakdown
    }

    /// " = provider 610 · keyframe 40 · downloads 230 · player 240" — the
    /// accounting of where the time went; only with remuxer and first picture.
    var breakdown: String {
        guard let remux, let firstFrameAt else { return "" }
        let text = remux.breakdown(start: startedAt, end: firstFrameAt)
        return text.isEmpty ? "" : "  = " + text
    }

    /// Why "first picture" shows a dash although a picture was there.
    ///
    /// A dash without a reason reads like "not measured". The reason separates two
    /// different repairs: an engine that never reports readiness on its own,
    /// versus a sampling interval too coarse to tell the two marks apart.
    private var missingFrameReason: String {
        guard timeToFirstFrame == nil, firstFrameAt != nil else { return "" }
        return readyAt == nil
            ? " (readiness never reported on its own)"
            : " (below the resolution — not separable)"
    }
}
