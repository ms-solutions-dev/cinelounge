import Foundation

/// Decides when a sync state record says something new.
///
/// **The finding** (AP1, noise table): `Gleichlauf` appears 531 times in the
/// recording of 2026-08-23 — 521 state records and 10 incidents. A quarter of the log
/// is noise, and anyone searching in it finds nothing.
///
/// **Why the line cannot simply be throttled.** Two attempts tried this and failed
/// on their own numbers. The reason lies deeper: The measured value is not the
/// offset at all, but for the most part the **distance of the interleaving**.
/// Picture and audio arrive alternately; anyone who compares the latest timestamps
/// of both tracks after every packet mainly measures which track was up last.
/// Measured on the recording, the value fluctuates within a session by **247 ms**
/// on average, 670 ms at most — with a reporting threshold of two seconds and a
/// range worth observing from forty.
///
/// A gate on the value itself has to fail: It either lets the jitter through (at
/// 100 ms steps 325 of 521 lines remain) or swallows exactly the range the line
/// was built for (at 500 ms steps 110 lines remain, but a drift from 40 to 240 ms
/// is invisible).
///
/// **That is why the minimum of a window.** The interleaving distance can only
/// **increase** the magnitude — the two tracks were never further apart than they
/// once stood together within this time span. The minimum of the last three
/// samples is therefore the best estimate of the real offset, and it is
/// conservative: It does not invent a drift, it only hides the jitter.
///
/// Measured on the same recording: **521 → 125 lines (−76 %)**, and what remains is
/// the movement rather than the snapshot.
public struct OffsetTrack: Sendable, Equatable {

    /// How many samples go into the window.
    ///
    /// Three, that is thirty seconds of media time. With six samples 92 lines remain
    /// instead of 125 — but then a drift needs a minute before it shows. Three is the
    /// shortest span in which the interleaving reliably shows both tracks together
    /// once.
    public static let window = 3

    /// By how much the value has to change for the line to be written.
    ///
    /// One hundred milliseconds: below that the difference is smaller than the jitter
    /// that was just calculated out, and the line would claim an accuracy the
    /// measurement does not have.
    public static let threshold: Double = 0.1

    private var samples: [Double] = []
    private var reported: Double?

    public init() {}

    /// The value to report — or `nil` if it says nothing new.
    ///
    /// **In both directions**, explicitly: An offset that converges again is as much of
    /// a statement as one that drifts away. A rule that reports only record highs would
    /// leave the last line standing at 800 ms forever although 100 has long applied.
    ///
    /// - Parameter versatz: The measured offset in seconds, with sign.
    /// - Returns: The magnitude of the window minimum, if it is to be written.
    public mutating func report(forItem offset: Double) -> Double? {
        samples.append(abs(offset))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
        guard let smallest = samples.min() else { return nil }

        // The first sample is always a statement: It is the zero point against which
        // everything else is read.
        guard let reported else {
            self.reported = smallest
            return smallest
        }
        guard abs(smallest - reported) >= Self.threshold else { return nil }
        self.reported = smallest
        return smallest
    }
}
