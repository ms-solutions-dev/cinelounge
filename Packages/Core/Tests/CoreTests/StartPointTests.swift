import Foundation
import Testing

@testable import Core

/// Where a playback begins — **a rule that TV and phone both call.**
///
/// The cases "midway", "almost at the end", "just looked in" and "watched" stood until
/// 2026-09-26 as `FortsetzstelleTests` in the phone (AP58 W1, finding S2); they still
/// apply here unchanged.
@Suite("Start point")
struct StartPointTests {

    private func progress(
        _ position: TimeInterval, from duration: TimeInterval = 1000, watched: Bool = false
    ) -> PlaybackProgress {
        PlaybackProgress(position: position, duration: duration, isWatched: watched)
    }

    @Test("Resumes in the middle")
    func inTheMiddle() {
        #expect(PlaybackProgress.startPoint(state: progress(400), length: nil) == 400)
    }

    @Test("Almost at the end starts over")
    func almostAtTheEnd() {
        #expect(PlaybackProgress.startPoint(state: progress(970), length: nil) == 0)
    }

    @Test("A one-second peek starts over")
    func peekedInBriefly() {
        #expect(PlaybackProgress.startPoint(state: progress(1), length: nil) == 0)
    }

    @Test("Watched starts over, no progress does too")
    func watchedOrNot() {
        #expect(PlaybackProgress.startPoint(state: progress(400, watched: true), length: nil) == 0)
        #expect(PlaybackProgress.startPoint(state: nil, length: 1000) == 0)
    }

    /// The gap from wave 1: the state fits a longer version of the same file.
    /// Measured by the state alone, 3000 of 5400 seconds would be midway; but the title
    /// is only 2800 long now, and the movie ended almost as soon as it opened.
    @Test("Progress beyond the end of the title starts over")
    func progressBeyondTheEnd() {
        #expect(PlaybackProgress.startPoint(state: progress(3000, from: 5400), length: 2800) == 0)
    }

    @Test("The length of the title takes precedence over the one in the progress")
    func lengthOfTheTitle() {
        #expect(PlaybackProgress.startPoint(state: progress(2700, from: 5400), length: 2800) == 0)
        #expect(PlaybackProgress.startPoint(state: progress(1000, from: 5400), length: 2800) == 1000)
    }

    /// Whoever chooses the chapter "Credits" wants the credits — even in the last five percent.
    @Test("A fixed position near the end stays where it is")
    func fixedPositionNearTheEnd() {
        #expect(PlaybackProgress.startPoint(fixed: 5300, state: nil, length: 5400) == 5300)
    }

    @Test("A fixed position at or beyond the end starts over")
    func fixedPositionBeyondTheEnd() {
        #expect(PlaybackProgress.startPoint(fixed: 5400, state: nil, length: 5400) == 0)
        #expect(PlaybackProgress.startPoint(fixed: 7200, state: nil, length: 5400) == 0)
        #expect(PlaybackProgress.startPoint(fixed: 7200, state: progress(400, from: 5400), length: nil) == 0)
    }

    /// "From here" means neither the beginning nor the resume point.
    @Test("A fixed position takes precedence over the progress, without a length it applies as is")
    func fixedPositionBeforeProgress() {
        #expect(PlaybackProgress.startPoint(fixed: 120, state: progress(400), length: 1000) == 120)
        #expect(PlaybackProgress.startPoint(fixed: 120, state: nil, length: nil) == 120)
        #expect(PlaybackProgress.startPoint(fixed: -3, state: nil, length: nil) == 0)
    }
}
