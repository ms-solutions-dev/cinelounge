import Foundation
import Testing

@testable import Core

/// When a sync state record says something new — AP1, the line noise.
///
/// **The numbers come from `diagnose/2026-08-23_1804_diagnose.log`**, not from
/// an estimate: 531 sync lines, 521 of them state records; the jitter
/// within a session averages 247 ms and at most 670 ms.
/// Two earlier attempts failed on their own unchecked numbers — here
/// the rule itself is tested.
@Suite("The offset track")
struct OffsetTrackTests {

    /// The first probe is the zero point against which everything else is read.
    @Test("The first sample is always there")
    func firstSample() {
        var track = OffsetTrack()
        #expect(track.report(forItem: 0.12) == 0.12)
    }

    /// **The core:** the jitter of the interleaving is swallowed. This
    /// sequence comes, in order of magnitude, from the recording — a
    /// constant offset that jumps back and forth between 100 and 350 ms
    /// because picture and sound alternately were last in line.
    @Test("The jitter of the interleaving is swallowed")
    func jitterStaysOut() {
        var track = OffsetTrack()
        var rows = 0
        for value in [0.12, 0.35, 0.14, 0.31, 0.11, 0.34, 0.13, 0.29]
        where
            track.report(forItem: value) != nil
        {
            rows += 1
        }

        // Only the first probe — after that none says anything that is not already
        // there.
        #expect(rows == 1)
    }

    /// **And the drifting-away gets through.** That is the case the line
    /// was built for (viewer finding 2026-08-23: Telve 3 UHD feels slightly out of
    /// sync) — a sound that slowly drifts away, long before it breaks the
    /// error threshold of two seconds.
    @Test("A drifting audio track comes through")
    func driftingAwayPassesThrough() {
        var track = OffsetTrack()
        var reported: [Double] = []
        for value in stride(from: 0.05, through: 0.85, by: 0.05) {
            if let m = track.report(forItem: value) { reported.append(m) }
        }

        // There is more than the zero point, and the last value is the
        // largest — the line shows the movement.
        #expect(reported.count >= 4)
        #expect(reported.last ?? 0 > 0.6)
    }

    /// **In both directions.** A rule that reports only record highs would leave
    /// the last line at 800 ms forever, although 100 has long applied.
    @Test("Converging is reported as well")
    func convergingPassesThrough() {
        var track = OffsetTrack()
        _ = track.report(forItem: 0.8)
        _ = track.report(forItem: 0.8)
        _ = track.report(forItem: 0.8)

        #expect(track.report(forItem: 0.05) != nil)
    }

    /// **The window takes the minimum, not the last value.** The
    /// interleaving distance can only increase the magnitude — the two
    /// tracks were never further apart than they once stood together
    /// within this span.
    @Test("The smallest value of the window is reported")
    func windowMinimum() {
        var track = OffsetTrack()
        #expect(track.report(forItem: 0.9) == 0.9)
        // The two tracks stood together — that is the true offset,
        // and it is reported.
        #expect(track.report(forItem: 0.1) == 0.1)
        // A single large spike afterwards is interleaving and not
        // movement: the minimum of the window stays 0.1 s, and no
        // second line appears.
        #expect(track.report(forItem: 0.95) == nil)

        // Only when the window has lost the small value does the larger one
        // apply again — then it is no longer a snapshot but the situation.
        #expect(track.report(forItem: 0.92) == nil)
        #expect(track.report(forItem: 0.93) == 0.92)
    }

    /// The sign belongs to the question "who leads" and not to the question "how
    /// far apart" — the magnitude is measured.
    @Test("The sign does not matter")
    func magnitude() {
        var track = OffsetTrack()
        _ = track.report(forItem: 0.3)
        #expect(track.report(forItem: -0.3) == nil)
    }
}
