import Foundation

/// Records what actually happens during a running playback.
///
/// **This class exists because a complaint and a guess are not the same thing.**
///
/// The viewer describes it precisely: "a short dropout, then the picture jumps
/// one and a half to two seconds ahead and keeps going". That is a very precise
/// observation — and up to here there was not a single means of measuring it. Guessing
/// was used instead: first the buffer, then the clock, then the disk. Every guess
/// cost a startup and a delivery, and none could be proven in the end.
///
/// Therefore exactly the two events the viewer sees are recorded:
///
/// - **Stall** — the position in the film does not move although playback is running.
/// - **Jump** — the position jumps further than could have been
///   played in the elapsed time. This is the "lead", and it is the real
///   clue: a buffer that runs empty produces a stall **without** a jump. If the
///   jump is added, the clock kept running while no pictures were there — then
///   it is not the buffer but the timing or the source.
///
/// At the end there is a summary that goes into the diagnostics report: how many
/// dropouts, how long in total, how much skipped. That is the difference
/// between "does not play smoothly" and "14 dropouts, 23 seconds in total, of which 9
/// seconds skipped".
public final class PlaybackTrace: @unchecked Sendable {

    /// An event as it appears in the report.
    ///
    /// Deliberately not public: the report goes out as text, not as a
    /// series of numbers. A second route to the same data would have no reader
    /// outside this file — the checks reach it via `@testable import Core`.
    struct Event: Sendable, Equatable {
        enum Kind: String, Sendable {
            /// The picture stood still although playback was running.
            case stall
            /// The position jumped further than could be played.
            case jump
            /// The engine reported buffering.
            case buffering
        }

        let kind: Kind
        /// Wo im Film, in Sekunden.
        let at: TimeInterval
        /// How long the stall lasted or how far the jump went.
        let amount: TimeInterval
    }

    /// From which deviation a jump counts as a jump.
    ///
    /// The query does not run accurate to the millisecond, and the engine reports its
    /// position in steps. Half a second of tolerance absorbs that; the observed
    /// jump is one and a half to two seconds and thus well above it.
    public static let jumpThreshold: TimeInterval = 0.5

    /// From which duration a stall is reported.
    ///
    /// Shorter than the query itself would be pointless, and a single skipped frame
    /// nobody sees. Half a second is the limit from which it is noticeable as stutter.
    public static let stallThreshold: TimeInterval = 0.5

    /// How many dropped frames are needed at all before it is mentioned.
    ///
    /// A few frames are lost at every startup — when the TV's refresh rate
    /// switches, for example, the output stands still briefly. Below
    /// this limit it is noise and not a finding.
    public static let droppedFloor = 25

    /// From which rate the viewer sees it, in dropped frames per second.
    ///
    /// **One per second**, and the number is deliberately low: at 50 Hz that is
    /// one skipped frame in fifty — even that the eye perceives as stutter during
    /// a camera pan. The case of 2026-08-22 was orders of magnitude
    /// above (every second frame), but the limit should also
    /// name the mild case instead of burying it under "ran through".
    public static let droppedRateThreshold = 1.0

    /// From which lead a jump counts as the viewer seeking.
    ///
    /// What is measured is the **lead** of a jump (skipped time minus
    /// elapsed time), not the raw jump width. The observed
    /// break is one and a half to two seconds, a resume or a
    /// chapter jump is minutes — there is plenty of room in between. For a channel
    /// the limit does not apply: nobody seeks there, there every jump remains a break.
    public static let seekThreshold: TimeInterval = 30

    /// How close a buffering report must be to a stall for it to explain it.
    ///
    /// Measured in the **position in the film** and not in wall-clock time: the position stands
    /// still during a stall, so both events carry the same position.
    /// A buffering report six minutes further on does not explain a stall at 0:00 —
    /// which is exactly what it did until 2026-08-24.
    public static let bufferingProximity: TimeInterval = 5

    private let lock = NSLock()
    private var events: [Event] = []
    private var lastPosition: TimeInterval?
    private var lastSampledAt: Date?
    private var standingSince: (position: TimeInterval, at: Date)?
    private var startedAt: Date?
    /// How it started — URL, engine, options. Appears in the report above the events.
    private var opening: String = ""

    /// The bookkeeping of dropped frames.
    ///
    /// **The engine's counter is not a sum, but a state per event.**
    /// `AVPlayerItemAccessLog` starts a new entry with every change of the
    /// delivery route, and its counter starts at zero again. Whoever reads the raw
    /// number as a sum sees the counter jump back in the middle of playback
    /// and counts wrongly afterwards. What is counted is therefore the **increase**
    /// per section, and the sections are added up.
    private var droppedAtSectionStart: Int?
    private var droppedLatest: Int?
    private var droppedFromEarlierSections = 0

    public init() {}

    /// - Parameter isLive: Whether a channel is running. **Without this information the
    ///   report misinterprets**: with a channel nobody seeks, so a jump there
    ///   is not a seek but a break (review agent 2026-08-23 — the sentence
    ///   "not an error" stood twice above a real error).
    public func begin(_ description: String, at date: Date, isLive: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.isLive = isLive
        events = []
        lastPosition = nil
        lastSampledAt = nil
        standingSince = nil
        startedAt = date
        opening = description
        droppedAtSectionStart = nil
        droppedLatest = nil
        droppedFromEarlierSections = 0
    }

    /// Takes a sample. Called from the playback tick.
    ///
    /// - Parameters:
    ///   - position: The position in the film, in seconds.
    ///   - isPlaying: Whether playback is running at all. A pause is not a stall.
    ///   - isBuffering: Whether the engine reports buffering.
    ///   - date: Now. Passed in and not fetched itself, so that the evaluation
    ///     stays testable without waiting.
    ///   - droppedFrames: The counter reading of dropped frames, if the engine
    ///     keeps one. `nil` means "no information" and is not counted as zero.
    public func sample(
        position: TimeInterval,
        isPlaying: Bool,
        isBuffering: Bool,
        date: Date,
        droppedFrames: Int? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        defer {
            lastPosition = position
            lastSampledAt = date
        }

        note(droppedFrames)

        if isBuffering {
            record(.init(kind: .buffering, at: position, amount: 0))
        }

        guard isPlaying, let previous = lastPosition, let since = lastSampledAt else {
            standingSince = nil
            return
        }

        let elapsed = date.timeIntervalSince(since)
        guard elapsed > 0 else { return }
        let advanced = position - previous

        // **Backwards means: somebody seeked.** That is not a finding, and the
        // evaluation has to start over — otherwise the next comparison
        // counts the entire jump back as a stall.
        if advanced < -Self.jumpThreshold {
            standingSince = nil
            return
        }

        if advanced > elapsed + Self.jumpThreshold {
            // The lead: more film was skipped than time has passed.
            record(.init(kind: .jump, at: position, amount: advanced - elapsed))
            standingSince = nil
            return
        }

        if advanced < 0.05 {
            // Stands still. It is reported only once it has stood still long enough — and then once,
            // not with every sample.
            if let standing = standingSince {
                let duration = date.timeIntervalSince(standing.at)
                if duration >= Self.stallThreshold {
                    record(.init(kind: .stall, at: standing.position, amount: duration))
                    standingSince = nil
                }
            } else {
                standingSince = (position, since)
            }
        } else {
            standingSince = nil
        }
    }

    /// Carries the counter reading forward — see ``droppedAtSectionStart``.
    private func note(_ counter: Int?) {
        guard let counter else { return }
        guard let start = droppedAtSectionStart, let latest = droppedLatest else {
            droppedAtSectionStart = counter
            droppedLatest = counter
            return
        }
        if counter < latest {
            // The counter jumped back: a new entry in the log.
            // The old section is closed, the new one begins here.
            droppedFromEarlierSections += latest - start
            droppedAtSectionStart = counter
        }
        droppedLatest = counter
    }

    /// How many frames have been dropped since ``begin(_:at:)`` — `nil` as long as
    /// no engine has given any information.
    private var droppedTotal: Int? {
        guard let start = droppedAtSectionStart, let latest = droppedLatest else { return nil }
        return droppedFromEarlierSections + max(0, latest - start)
    }

    /// Whether the recorded playback was a channel — see
    /// ``begin(_:at:isLive:)``.
    private var isLive = false

    private func record(_ event: Event) {
        // An upper limit, otherwise the report grows unreadable with a long film.
        guard events.count < 400 else { return }
        events.append(event)
    }

    /// The summary together with its verdict.
    ///
    /// **Why the verdict belongs with it** (AP1, 2026-09-02): the summary used to go
    /// out as ``Diagnostics/probe(_:verdict:)`` with `.plain`, and
    /// `.plain` stores something only with the debug switch flipped. A session
    /// with dropouts thus produced **zero** error lines — the diagnostics knew
    /// the defect only if you already suspected it. "A defect does not wait for
    /// a switch" has long been the rule in the project in three other places;
    /// what was missing here was that the summary itself can say whether it reports
    /// one. The branches knew all along, they kept it to themselves.
    public struct Finding: Sendable, Equatable {
        public let text: String
        /// Whether the text reports a defect — then it goes out without a switch.
        public let isDefect: Bool

        public init(text: String, isDefect: Bool) {
            self.text = text
            self.isDefect = isDefect
        }
    }

    /// The summary for the report.
    ///
    /// As text and not as a series of numbers: it is read on a TV and sent in
    /// a report. Whoever reads it should see without converting whether there is
    /// a problem and of what kind.
    public func summary(at date: Date) -> String { finding(at: date).text }

    public func finding(at date: Date) -> Finding {
        lock.lock()
        defer { lock.unlock() }

        /// What is assembled at the end — text and verdict in one.
        var isDefect = false

        guard let startedAt else {
            return Finding(text: "Keine Wiedergabe aufgezeichnet.", isDefect: false)
        }
        let watched = date.timeIntervalSince(startedAt)

        let stalls = events.filter { $0.kind == .stall }
        let jumps = events.filter { $0.kind == .jump }
        let bufferings = events.filter { $0.kind == .buffering }

        // **A wide lead in a file is a seek, not a finding.**
        // On 2026-08-23 two jumps of 237 s and 178 s got the sentence "That is the
        // source, not the decoding" — that was the viewer at the remote.
        // For the interpretation therefore only the breaks count; the seeks stay in
        // the header so that nothing disappears.
        func isSeek(_ event: Event) -> Bool {
            !isLive && event.amount >= Self.seekThreshold
        }
        let seeks = jumps.filter(isSeek)
        let breaks = jumps.filter { !isSeek($0) }

        let stallTime = stalls.reduce(0) { $0 + $1.amount }
        let jumpTime = jumps.reduce(0) { $0 + $1.amount }

        let dropped = droppedTotal
        // Per second, because the bare number says something different for two seconds of
        // watching than for two minutes.
        let dropRate = (dropped.map { watched > 0 ? Double($0) / watched : 0 }) ?? 0

        var lines = [opening]
        lines.append(
            "\(Int(watched)) s watched, \(stalls.count) stalls (\(round(stallTime)) s in total), "
                + "\(jumps.count) jumps (\(round(jumpTime)) s skipped in total"
                + (seeks.isEmpty ? "" : ", \(seeks.count) of them by seeking") + "), "
                + "\(bufferings.count) buffering reports"
                + (dropped.map { ", \($0) pictures dropped (\(round(dropRate)) per second)" } ?? "")
        )

        // **The interpretation belongs with it**, otherwise it has to be derived anew every time.
        //
        // Dropped frames come **before** all other findings, and that is the
        // lesson of 2026-08-22: the viewer reported extreme stuttering, the
        // summary said "ran through", and both were right. An engine
        // that throws away frames keeps position and buffer in perfect order — every
        // other quantity here is then clean, and the report acquits someone
        // who is not innocent.
        if let dropped, dropped >= Self.droppedFloor, dropRate >= Self.droppedRateThreshold {
            lines.append(
                "Finding: \(dropped) dropped pictures — this is stuttering WITHOUT stalls. "
                    + "The delivery is fine, the drawing cannot keep up: "
                    + "check picture size and picture codec against what this "
                    + "device decodes in hardware."
            )
            isDefect = true
        } else if breaks.isEmpty && stalls.isEmpty {
            // **Without information no acquittal.** "Ran through" stood there on 2026-08-22 for
            // every single stuttering channel.
            if dropped == nil {
                lines.append(
                    "Finding: no stalls — this engine does not report dropped pictures."
                )
            } else if let dropped, dropped >= Self.droppedFloor {
                // **Hundreds of drops over a long film miss the rate**
                // and fell through until here — "ran through" then stood above a
                // line that showed them. Deliberately here and not as a priority above,
                // so that this addition does not hide a real stall.
                lines.append(
                    "Finding: no stalls, but \(dropped) dropped pictures at "
                        + "\(round(dropRate)) per second — spread out and not continuous. "
                        + "No acquittal: check whether they pile up at one spot."
                )
                isDefect = true
            } else {
                lines.append("Finding: ran through.")
            }
            // Deliberately added here: since the seeks are out of ``breaks``,
            // a playback in which only seeking happened ends up in
            // this branch. Without this line the sentence that marks it as
            // harmless would disappear — the header alone says it too quietly.
            if !seeks.isEmpty {
                lines.append(
                    "Finding: \(seeks.count) jumps with more than \(Int(Self.seekThreshold)) s "
                        + "lead — that is a seek (resume, chapter, scrubbing) "
                        + "and not an error."
                )
            }
        } else if breaks.isEmpty {
            // **A buffer running empty reports buffering** — and where no
            // buffering report exists, it cannot have run empty (review agent
            // 2026-08-23). All four incidents of the run were at **0:00** with
            // **zero** buffering reports; the sentence below still pointed to
            // the source. The same type of error as with the Blupriatio Gufaidia finding above: the
            // branch decided without the number standing right next to it.
            //
            // And a stall at the seek target is the aftermath of seeking: the
            // buffer refills there. ``allSatisfy`` instead of ``contains``, so that
            // a single explained stall does not cover up nine unexplained ones.
            let allStallsAtASeekTarget = stalls.allSatisfy { stall in
                seeks.contains { abs($0.at - stall.at) <= Self.bufferingProximity }
            }
            let bufferedNearAStall = stalls.contains { stall in
                bufferings.contains { abs($0.at - stall.at) <= Self.bufferingProximity }
            }
            if allStallsAtASeekTarget {
                lines.append(
                    "Finding: stall at the position that was jumped to — the buffer "
                        + "refills after a seek. No finding about the source."
                )
            } else if !bufferedNearAStall, stalls.allSatisfy({ $0.at < 1 }) {
                lines.append(
                    "Finding: a stall right at the start, without a single "
                        + "buffering report — that is the engine's settling time and "
                        + "not the source."
                )
            } else if !bufferedNearAStall {
                lines.append(
                    "Finding: stall without lead and without a buffering report — the buffer "
                        + "did not run empty. The cause is not the delivery."
                )
                isDefect = true
            } else {
                lines.append(
                    "Finding: stall without lead — the buffer runs empty, the source "
                        + "delivers too slowly. Playback catches up on nothing."
                )
                isDefect = true
            }
        } else if stalls.isEmpty {
            // **The counter in the same line beats the suspicion.**
            //
            // Only the lower sentence stood here, and it contradicted the number above
            // it: "0 frames dropped … finding: frames are being dropped"
            // (device diagnostics 2026-08-23, Blupriatio Gufaidia). The branch asked only about
            // stall and ignored the measured drops. A
            // finding that contradicts its own measurement is worse than
            // none — it steers the search, and in the wrong direction.
            //
            // A jump without a stall **and without** dropped frames is the
            // normal case of a seek: resume, chapter jump, scrubbing.
            //
            // **Without information also no accusation.** ``dropped`` is
            // ``Int?``, and `nil` fell through both checks as zero into the
            // last branch — which then claimed a drop that no engine
            // had reported. That is the flip side of the same doctrine.
            if dropped == nil {
                lines.append(
                    isLive
                        ? "Finding: jump without any action on a channel — a break in the "
                            + "timestamps or a switch at the provider, not a "
                            + "seek. This engine does not report dropped pictures."
                        : "Finding: jumps without a stall — this engine does not report "
                            + "dropped pictures, so a seek cannot be told apart from dropping "
                            + "here."
                )
            } else if dropped == 0, isLive {
                // **With a channel nobody seeks** (review agent 2026-08-23): the
                // sentence "that is a seek and not an error" stood twice
                // above a running channel. A jump without any action is there
                // a break in the timestamps or a switch at the
                // provider — and a "not an error" on a real error is
                // more expensive than no line at all.
                lines.append(
                    "Finding: jump without any action on a channel — a break in the "
                        + "timestamps or a switch at the provider, not a seek."
                )
            } else if dropped == 0 {
                lines.append(
                    "Finding: jumps without a stall at zero dropped pictures — that is "
                        + "a seek (resume, chapter, scrubbing) and not an error."
                )
            } else {
                lines.append(
                    "Finding: jumps without a stall — pictures are dropped without the "
                        + "picture freezing first. That points to decoding, not to the network."
                )
                isDefect = true
            }
        } else {
            lines.append(
                "Finding: stall **and** lead — the clock keeps running while no "
                    + "pictures arrive, and the backlog is made up by skipping. "
                    + "That is the source, not decoding."
            )
            isDefect = true
        }

        // The first events in detail, so that you can see whether they pile up or
        // are evenly distributed — with a disk that jumps between two readers,
        // they come in waves.
        for event in events.prefix(12) {
            lines.append(
                "  \(minutes(event.at))  \(event.kind.rawValue)"
                    + (event.amount > 0 ? "  \(round(event.amount)) s" : "")
            )
        }
        if events.count > 12 {
            lines.append("  … and \(events.count - 12) more")
        }

        return Finding(text: lines.joined(separator: "\n"), isDefect: isDefect)
    }

    private func round(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
