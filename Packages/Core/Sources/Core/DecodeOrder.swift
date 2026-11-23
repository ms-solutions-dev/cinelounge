import Foundation

/// Reconstructs the decode timestamps that an MKV file does not supply.
///
/// **This is the one point where MKV is fundamentally harder than a transport
/// stream.** A channel writes both times into every packet header: when
/// a picture is decoded and when it is shown. MKV knows only the second. The
/// first follows from the order in which the blocks appear — and that is
/// the decode order.
///
/// ## Why the two diverge
///
/// A B-frame looks forward: it needs a picture that is shown later.
/// So that later picture has to be decoded **first**. In the file the order is
/// therefore 0, 209, 125, 42, 83, 167 — real timestamps from a test file, in
/// milliseconds. Shown in order is 0, 42, 83, 125, 167, 209.
///
/// **Without decode times the writer mistakes the one order for the
/// other.** It sees times that jump backwards and rejects them — or,
/// worse, it accepts them and writes a file that stutters.
///
/// ## How they are reconstructed
///
/// The decode times are the same values, merely sorted by size: the
/// i-th decoded picture gets the i-th smallest presentation time. This is no
/// approximation but follows from the fact that every picture is decoded exactly once and
/// shown once.
///
/// So that no decode time ends up **behind** its presentation time, the
/// whole timeline is shifted back by ``delay`` — by the largest
/// reordering that occurs in the stream. The audio has to move by the same amount,
/// otherwise it drifts against the picture.
public struct DecodeOrder {

    /// A picture with both times, both already shifted.
    public struct Timing: Sendable, Equatable {
        public let presentation: Int64
        public let decode: Int64
    }

    /// How far ahead to look before the first picture is released.
    ///
    /// **Sixteen pictures**, a good half second. In practice, reordering spans
    /// two to eight pictures; sixteen is the safety margin
    /// against a B-pyramid, as modern encoders build them. Choosing larger
    /// costs only startup time, choosing smaller costs correctness.
    public static let defaultWindow = 16

    private let window: Int
    /// Presentation times in decode order — the queue.
    private var queue: [Int64] = []
    /// The same values, sorted by size — the pool of decode times.
    private var sorted: [Int64] = []

    /// By how much the whole timeline is shifted back.
    ///
    /// **The audio has to move by the same amount.** Whoever shifts only the picture has
    /// a file in which the lips run ahead by two pictures — visible, but
    /// so slightly that people look for the fault in the picture and not in the audio.
    public private(set) var delay: Int64 = 0

    /// Whether ``delay`` has been determined.
    ///
    /// **No audio may come out before that.** The shift applies to picture and audio
    /// alike; whoever lets the audio through earlier has offset it against the picture
    /// — by exactly the amount that later arrives at the picture.
    public private(set) var isCalibrated = false

    /// How often a time had to be adjusted after the fact.
    ///
    /// **A measure of the quality of the look-ahead, not an error.** Greater than zero
    /// means: the reordering in the stream reaches further than the window sees.
    public private(set) var correctionCount = 0

    private var lastDecode: Int64?

    /// - Parameter delay: A shift that is already known.
    ///
    ///   **Needed as soon as a film is repackaged in pieces.** Calibrating each piece
    ///   on its own would yield a separate shift per piece — and thus
    ///   jumps at every piece boundary, showing up as stutter and as drifting
    ///   audio. Calibration happens once, at the start, and the value applies to the
    ///   whole film.
    public init(window: Int = DecodeOrder.defaultWindow, delay: Int64? = nil) {
        self.window = max(1, window)
        if let delay {
            self.delay = delay
            isCalibrated = true
        }
    }

    /// Takes the presentation time of the next picture in decode order.
    ///
    /// What comes out is whatever was completed by it — usually nothing until the window
    /// is full, after that one per call. **The order stays the
    /// decode order**, so the caller can simply assign its frames
    /// in sequence.
    public mutating func push(_ presentation: Int64) -> [Timing] {
        queue.append(presentation)
        insert(presentation)

        guard queue.count > window else { return [] }
        calibrateIfNeeded()
        return [emit()]
    }

    /// Releases what is still in the window — for the end of a file.
    public mutating func flush() -> [Timing] {
        calibrateIfNeeded()
        var result: [Timing] = []
        while !queue.isEmpty { result.append(emit()) }
        return result
    }

    // MARK: - Innen

    /// Determines the shift from what the window currently sees.
    ///
    /// **Once, and then never again.** A shift that changes along the way
    /// would shift the audio against the picture — in the middle of the film.
    ///
    /// **What is measured is how far a picture falls behind the newest timestamp seen so far.**
    /// This is not the smallest possible
    /// shift, but always a sufficient one — and the decisive
    /// difference: it is fixed after a few pictures, whereas the exact measure
    /// would need a sorting that is not yet settled in the window. The
    /// price is a few milliseconds more offset, which nobody notices.
    private mutating func calibrateIfNeeded() {
        guard !isCalibrated, !queue.isEmpty else { return }
        isCalibrated = true

        var newest = Int64.min
        var largest: Int64 = 0
        for time in queue {
            newest = max(newest, time)
            largest = max(largest, newest - time)
        }

        // **What is in the window says nothing about the rest of the film** — and
        // that is exactly where it failed (on-device finding 2026-08-23, "Blupriatio Gufaidia
        // does not play smoothly, picture stutters").
        //
        // This episode's intro is encoded **without** reordering: the first
        // seventeen timestamps run strictly upward, `largest` becomes zero, and
        // the shift stood at zero for the whole film. The rest of the
        // file, however, reorders by up to three pictures (126 ms). In the end,
        // about **every fifth picture carried the same display time as its
        // neighbor** — re-measured on the real file: 386 of 1645 intervals
        // were exactly 0 ms. In practice: every six pictures one picture stays twice
        // as long and the next is never shown, four to five times per
        // second, across the whole film.
        //
        // And **no counter fired**: zero dropouts, zero buffer reports,
        // zero dropped frames. The player received flawless packets and did
        // exactly what was in them.
        //
        // **So it is no longer guessed but calculated.** This tool cannot sort further than
        // its window anyway; a shift of one window length is therefore **always** sufficient,
        // whatever is in the intro. The frame duration for that is in the window
        // itself — the mean of the intervals in sorted order.
        //
        // The price is a larger offset of the whole timeline. It costs
        // nothing: audio and picture move together, the decode times stay
        // where they are, and so do the seams between the pieces.
        delay = max(largest, Int64(window) * frameStep())
    }

    /// The interval between two pictures, estimated from the calibration window.
    ///
    /// The **median** of the intervals in sorted order and not their
    /// mean: a single outlier — a gap in the stream, a duplicate
    /// timestamp — would pull the mean away, not the median.
    private func frameStep() -> Int64 {
        let ordered = queue.sorted()
        guard ordered.count > 1 else { return 0 }
        let gaps = zip(ordered, ordered.dropFirst()).map { $1 - $0 }.sorted()
        return gaps[gaps.count / 2]
    }

    private mutating func emit() -> Timing {
        var presentation = queue.removeFirst() + delay
        var decode = sorted.removeFirst()

        // **Two last-resort fixes that never trigger in the normal case** — and whose
        // order matters. Upward-running decode times are the
        // non-negotiable condition; where it collides with "not behind the presentation",
        // the presentation moves up. A picture one
        // millisecond later is invisible, a backward-running
        // timestamp aborts the recording.
        if let last = lastDecode, decode <= last {
            decode = last + 1
            correctionCount += 1
        }
        if decode > presentation {
            // **This is no last-resort fix, it is an alarm.** If it triggers, this
            // picture carries another picture's time — and the display timeline
            // has a hole. As long as ``delay`` reaches a full window length,
            // this can no longer happen; if it occurs anyway, the file reorders
            // further than this window sees, and that should be
            // reported instead of silently compensated.
            presentation = decode
            correctionCount += 1
        }
        lastDecode = decode
        return Timing(presentation: presentation, decode: decode)
    }

    private mutating func insert(_ value: Int64) {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value { low = middle + 1 } else { high = middle }
        }
        sorted.insert(value, at: low)
    }
}
