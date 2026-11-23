import Foundation

/// Measures the frame cadence from the gaps between consecutive pictures.
///
/// **Why measured and not read from the headers:** The frame rate is in the SPS
/// or VPS — but only as the encoder's *claim*, and the provider transcoders of
/// this project have repeatedly stamped something other than what they announce.
/// The gap between two pictures, on the other hand, is exactly what the player
/// will play later.
///
/// **Why at all:** The engine can only read the frame rate from its own draw
/// rate, and that is wrong during startup. On 2026-08-22 it reported the same channel
/// to the TV as 24, then 25, then 50 Hz within eighteen seconds — with matching
/// enabled that is three mode switches for a single channel. The remuxer knows the
/// number before the player sees the first picture.
///
/// As its own type and not as three fields in the remuxer: The rules — median
/// instead of average, minimum count, outlier limit — are the whole content, and
/// they should be testable without a transport stream.
struct FrameCadence {

    /// How many gaps are needed before a finding comes out.
    ///
    /// **Thirty**, because below that a single outlier determines the median.
    /// At 50 Hz that is a good half second of broadcast — the remuxer has several
    /// seconds behind it by the time the player starts.
    static let minimumSamples = 30

    /// How many gaps are collected at most.
    ///
    /// The cadence does not change within a channel, and a channel runs for
    /// hours — without a cap the list would grow without bound.
    static let maximumSamples = 200

    /// From which deviation from the median a gap counts as an outlier.
    static let outlierTolerance = 0.2

    private(set) var gaps: [Double] = []

    /// Records a gap, in seconds.
    ///
    /// **Implausible values are dropped instead of spoiling the median.** A
    /// burst restart at the provider or a break in the clock produces jumps
    /// that have nothing to do with any frame rate; and a gap of zero arises
    /// where the monotonicity stopgap resolved a timestamp collision.
    ///
    /// **Anyone who needs the distribution must not use ``gaps``.** What is dropped
    /// here — the zero gap and the jump — is exactly what a histogram looks for.
    /// ``MatroskaRemuxer/pictureTimeline`` keeps the raw gaps before they come
    /// here; anyone who loosens this filter instead spoils ``rate`` and ``jitter``
    /// for all readers.
    mutating func add(_ gap: Double) {
        guard gaps.count < Self.maximumSamples, gap > 0.001, gap < 0.5 else { return }
        gaps.append(gap)
    }

    /// The typical picture gap.
    ///
    /// **The median and not the average:** A single jump at a burst boundary
    /// would pull an average up noticeably; the median does not notice it.
    var medianGap: Double? {
        guard gaps.count >= Self.minimumSamples else { return nil }
        let sorted = gaps.sorted()
        return sorted[sorted.count / 2]
    }

    /// The cadence in hertz, to two decimal places — `nil` as long as too little has been
    /// measured. **No basis, no number:** A guessed frame rate would send the
    /// TV into a mode switch, and that is worse than none at all.
    var rate: Double? {
        guard let median = medianGap, median > 0 else { return nil }

        // **The median systematically misses a gridded source**
        // (check agent 2026-08-23). Both provider transcoders and **every
        // Matroska file** stamp onto a millisecond grid; at 59.94 Hz
        // the gaps then alternate between 16 and 17 ms, and the median takes
        // the more frequent of the two:
        //
        // ```
        //   Source                      true      median    trimmed mean
        //   59.94 Hz on ms grid         59.94     58.82     59.94
        //   23.976 Hz on ms grid        23.976    23.81     23.98
        // ```
        //
        // 58.82 Hz does not exist — ``normedRates`` rejects the number, and for
        // 59.94 Hz channels **no** frame rate is announced at all. At
        // 23.976 it would mean 24.0 Hz: a repeated picture every 41.7 seconds.
        //
        // **The median remains the basis regardless**, and that is the point:
        // The average is taken only over the gaps close to it. That way
        // the lesson of 2026-08-11 still holds unchanged — a burst boundary or a
        // gap in the stream is thrown out beforehand instead of pulling the mean.
        // Recomputed on a real capture with 48 missing
        // decode times and on a jump of 0.31 s: both times unchanged at
        // 50.00 and 25.00 Hz respectively.
        let close = gaps.filter { abs($0 - median) / median <= Self.outlierTolerance }
        guard !close.isEmpty else { return (1 / median * 100).rounded() / 100 }
        let trimmed = close.reduce(0, +) / Double(close.count)
        guard trimmed > 0 else { return nil }
        return (1 / trimmed * 100).rounded() / 100
    }

    /// The share of gaps that deviate from the median by more than ``outlierTolerance``.
    ///
    /// **The separating question for stutter** (2026-08-22): If the remuxer's own output
    /// is uneven, the fault is ours. If it is clean and the picture
    /// stutters anyway, the fault is in drawing on the device. Without this number
    /// the two cases cannot be told apart from outside.
    var jitter: Double? {
        guard let median = medianGap, median > 0 else { return nil }
        let outliers = gaps.filter { abs($0 - median) / median > Self.outlierTolerance }.count
        return Double(outliers) / Double(gaps.count)
    }
}
