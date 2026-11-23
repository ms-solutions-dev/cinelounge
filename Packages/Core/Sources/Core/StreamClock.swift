import CoreMedia
import Foundation

/// Turns a channel's timestamps into a time that always moves forward.
///
/// **Two things go wrong with a stream without an end, and both only after
/// hours** — that is, exactly when nobody is looking any more.
///
/// **The wraparound.** An MPEG timestamp has 33 bits and counts in
/// 90,000ths of a second. That lasts **26 hours and 30 minutes**, then it
/// starts again at zero. Whoever does not catch that hands AVFoundation a
/// point in time far before the last one after 26 hours — the writer
/// refuses, the picture stands, and the cause lies a day back.
///
/// **The break.** A channel switches its feed, an ad block comes from a
/// different source, the line drops for two seconds: then the timestamp
/// jumps without anything being broken. A jump forward would tear a hole in
/// the playlist, a jump back would make the writer discard the rest.
///
/// Both are flattened here. **Outwards there is only one time, which runs
/// evenly** — and the distance between picture and sound stays untouched,
/// because both tracks go through the same clock.
public struct StreamClock: Sendable {

    /// The range of an MPEG timestamp: 2³³ ticks.
    public static let wrapPeriod: Int64 = 1 << 33

    /// From which jump **forward** a break is assumed.
    ///
    /// **Ten seconds**, and the number is a trade-off: smaller, and a delayed
    /// packet would already count as a break — the clock would be adjusted
    /// constantly and the distance between picture and sound would suffer.
    /// Larger, and a real break would stand until the buffer assumes it.
    ///
    /// **From ten to two seconds** (F-016, 2026-09-03, "TR: Ayaz HD\*"): the channel
    /// jumps forward in its stamps by seconds — under ten, so straight through
    /// the clock. The renderer saw "9.6 s of buffer" in 13 frames and the clock
    /// ran into a hole; the segment writer cut segments of 2.2 and 5.3 s. The
    /// argument for ten ("a delayed packet") does not hold for stamps: they carry
    /// the broadcast time, not the arrival — a frame that plays two seconds after
    /// its predecessor is a jump in the programme, whenever it arrives. Two
    /// seconds, as backwards.
    ///
    /// **From two to one second** (F-009, 2026-09-03, "DE: SELA 1 HQ"): three jumps
    /// of one second each in 85 s, without a buffer report — holes under the
    /// threshold that the player skipped and the viewer saw as "hangs now and
    /// then". Not lower: the reordering of B-frames makes the stamps jump
    /// forward in decode order, with sixteen held-back frames and 25 per second
    /// by 0.64 s. One second keeps a distance from that; below it every group of
    /// pictures would become a break.
    public static let discontinuityThreshold: Int64 = 90_000

    /// From which jump **backward** a break is assumed.
    ///
    /// **Tighter than forward, and the difference is the finding of 2026-08-15**
    /// (proven locally on the real channel): this provider's edge delivers the
    /// stream in bursts and starts every new connection a few seconds **before**
    /// the end of the previous one — at the last keyframe. The jump back thus
    /// lay under the ten-second threshold, went unchecked through the clock, and
    /// the writer died of the backward timestamp (`-11800/-16364`) — silently,
    /// because a failed AVAssetWriter swallows everything further. All that was
    /// visible: one segment, then never another. Two seconds leave ample room for
    /// the legitimate interleaving of picture and sound (tenths of a second) and
    /// catch the burst startup.
    public static let backwardThreshold: Int64 = 2 * 90_000

    /// How far the time is advanced at a break.
    ///
    /// One frame interval. Not zero — otherwise the last frame before and the
    /// first after the break would lie on the same instant, and the order could
    /// no longer be decided.
    static let stepAfterBreak: Int64 = 3_000  // one frame at 30 per second

    /// Which track brings a stamp — the break is detected **per track**.
    ///
    /// **The finding** (F-011, 2026-09-04, "DE: TELE MOOS HD"): 18 breaks in 42 s, 61
    /// audio packets discarded, "dropouts and time jumps". The channel muxes the
    /// audio a good second **before** the picture; against the shared mark (the
    /// highest stamp ever assigned, that is, the picture) every audio packet
    /// jumped across the one-second threshold — a break that was none, every two
    /// seconds. Each track runs steadily in itself; only against its own past is
    /// a jump a jump. The offset stays shared, so that picture and sound stay in
    /// step.
    public enum Track: Int, Sendable, CaseIterable {
        case video = 0
        case audio = 1
    }

    private var wraps: Int64 = 0
    private var lastRaw: UInt64?
    private var lastOutput: Int64?
    /// The offset per track. Shared **as a rule** — and separate at the seam:
    /// the break hits the tracks one after the other, and in between stragglers
    /// of one track arrive from the time before (the flush of the last PES
    /// packet). With a shared offset they landed seconds back, poisoned their
    /// track's mark, and the next real stamp of the same track counted as a
    /// second break — picture and sound then stood 0.35 s apart (test "gap
    /// becomes a segment boundary", 2026-09-04). Each track keeps its offset until it
    /// jumps itself; then it takes over the other's if that continues it
    /// steadily, and only otherwise starts its own.
    private var offsets: [Int64] = [0, 0]
    /// The last output value per track — for break detection.
    private var lastByTrack: [Int64?] = [nil, nil]

    /// How often the clock has wrapped around — for diagnostics.
    public private(set) var wrapCount = 0
    /// How often a break was flattened — for diagnostics.
    public private(set) var breakCount = 0
    /// The first breaks in words ("video +3.2 s", "audio −1.4 s") — so that the
    /// trace says **what** jumps there (TELE MOOS HD, F-034: eleven breaks in
    /// seventy seconds, and nobody knew which track and which way).
    public private(set) var breakNotes: [String] = []
    static let breakNotesLimit = 4
    /// The most recent break in words — for the line that goes into the ledger
    /// immediately.
    public private(set) var lastBreak: String?

    public init() {}

    /// Closes the gap at a burst seam — by the same amount for both tracks.
    ///
    /// **The offset of 2026-10-03** (F-018, Telve 1 HQ): after the seam trim,
    /// playback continues at the next keyframe, here 0.9 s behind the old end.
    /// The picture jumped by 0.9 s — under the threshold, it stayed. The sound
    /// jumped by 1.0 s — just above, counted as a break and was pulled to the old
    /// end. After that the sound ran one second ahead of the picture, until
    /// switching away. Decided per track, the same gap was once a jump and once
    /// none.
    ///
    /// Here it is decided **once**, before either track sees the new burst: both
    /// offsets move back by the same ticks, so the distance between picture and
    /// sound stays exactly as it was. What remains is one frame interval — as
    /// after every flattened break.
    ///
    /// - Parameter takte: How far the first picture of the new burst lies behind
    ///   the last one sent, in 90 kHz ticks.
    public mutating func closeSeam(ticks: Int64) {
        let gap = ticks - Self.stepAfterBreak
        guard gap > 0 else { return }
        offsets[0] -= gap
        offsets[1] -= gap
        seamGapTicks += gap
    }

    /// How much programme was pushed together at seams — for tests and
    /// diagnostics.
    public private(set) var seamGapTicks: Int64 = 0

    /// Converts a raw timestamp into the straightened time.
    ///
    /// **Picture and sound must go through the same clock**, otherwise they shift
    /// against each other at the first wraparound: both tracks carry the same
    /// 33-bit count, but they do not wrap at the same instant — whoever keeps two
    /// clocks counts one up earlier than the other and gets an offset of 26 hours
    /// for a good second.
    public mutating func time(for raw: UInt64, track: Track = .video) -> CMTime {
        CMTime(value: CMTimeValue(ticks(for: raw, track: track)), timescale: SampleAssembly.timescale)
    }

    /// The same computation in ticks — for tests and diagnostics.
    public mutating func ticks(for raw: UInt64, track: Track = .video) -> Int64 {
        // ── Wraparound ──
        //
        // The comparison is against the most recently seen stamp, whichever track it
        // came from: picture and sound lie at most seconds apart, a wraparound jumps
        // by hours. The two cannot be confused.
        if let lastRaw {
            let half = Self.wrapPeriod / 2
            if Int64(lastRaw) - Int64(raw) > half {
                wraps += 1
                wrapCount += 1
            } else if Int64(raw) - Int64(lastRaw) > half {
                // A straggler from the time before the wraparound — the previous round
                // still applies to it. Without this case the last packets before the
                // wraparound would jump 26 hours forward.
                wraps -= 1
            }
        }
        lastRaw = raw

        let extended = Int64(raw) + wraps * Self.wrapPeriod

        // ── Break ──
        //
        // **Against the own track**, not against the shared mark (see ``Track``). A
        // lag of the sound behind the picture is thereby no longer visible at all;
        // what remains is the real jump in the programme.
        let mine = track.rawValue
        var result = extended + offsets[mine]
        if let previous = lastByTrack[mine] {
            let gap = result - previous
            if gap < -Self.backwardThreshold || gap > Self.discontinuityThreshold {
                // If the other track has already flattened the jump, its offset continues
                // this one steadily — then picture and sound afterwards stand in the same
                // relation as before.
                let other = offsets[1 - mine]
                let adopted = extended + other
                let adoptedGap = adopted - previous
                if other != offsets[mine], adoptedGap >= 0, adoptedGap <= Self.discontinuityThreshold {
                    offsets[mine] = other
                    result = adopted
                } else {
                    // It starts behind the shared mark: the other track should not fall behind
                    // what has already gone out.
                    let anchor = max(lastOutput ?? previous, previous)
                    offsets[mine] = anchor + Self.stepAfterBreak - extended
                    result = anchor + Self.stepAfterBreak
                    // The break in the programme is counted — once, not per track.
                    breakCount += 1
                    let note =
                        (track == .video ? "Picture " : "Audio ")
                        + String(format: "%+.1f s", Double(gap) / 90_000)
                    lastBreak = note
                    if breakNotes.count < Self.breakNotesLimit { breakNotes.append(note) }
                }
            }
        } else if lastByTrack[1 - mine] != nil, lastOutput != nil {
            // The first mark of a track when the other is already running: it takes
            // that one's offset — both tracks carry the same count.
            offsets[mine] = offsets[1 - mine]
            result = extended + offsets[mine]
        }
        lastByTrack[mine] = result

        // **Forward only.** Within a frame, sound and picture arrive in any order;
        // the mark therefore stays the highest point in time assigned so far, not
        // the one assigned last.
        lastOutput = max(lastOutput ?? result, result)
        return result
    }
}
