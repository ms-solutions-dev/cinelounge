import Foundation
import Testing

@testable import Core

/// This rule decides what the server learns about playback. If it turns out wrong,
/// either the server is flooded with requests or it shows a state that no longer
/// exists in the living room — and the resume position stops being right, which is
/// immediately noticeable on two devices.
@Suite("Reports to the server")
struct PlaybackReporterTests {

    @Test("The start is reported exactly once")
    func startOnce() {
        // Without sign-in the playback does not appear on the phone, and without the limit
        // to one, the server creates another session at every frame change.
        var reporter = PlaybackReporter()

        #expect(reporter.consider(position: 0, status: .playing)?.kind == .start)
        #expect(reporter.consider(position: 1, status: .playing) == nil)
        #expect(reporter.consider(position: 2, status: .playing) == nil)
    }

    @Test("Nothing is reported within the interval, afterwards it is")
    func intervalHolds() {
        // The engine reports several times per second. Passed on unthrottled, that adds up
        // to five-digit numbers of requests over two hours of film.
        var reporter = PlaybackReporter(interval: 10)

        #expect(reporter.consider(position: 0, status: .playing)?.kind == .start)
        #expect(reporter.consider(position: 9.9, status: .playing) == nil)

        let report = reporter.consider(position: 10, status: .playing)
        #expect(report?.kind == .progress)
        #expect(report?.position == 10)

        // The interval counts from the last report, not from the start.
        #expect(reporter.consider(position: 15, status: .playing) == nil)
        #expect(reporter.consider(position: 20, status: .playing)?.kind == .progress)
    }

    @Test("A pause goes out immediately, without waiting for the interval")
    func pauseIsImmediate() {
        // Otherwise the server keeps showing "playing" for up to ten seconds, and on the
        // phone it is not clear why the picture is frozen.
        var reporter = PlaybackReporter(interval: 10)
        _ = reporter.consider(position: 0, status: .playing)

        let report = reporter.consider(position: 3, status: .paused)
        #expect(report?.kind == .pause)
        #expect(report?.position == 3)

        // As long as it stays paused, nothing is reported repeatedly.
        #expect(reporter.consider(position: 3, status: .paused) == nil)
        #expect(reporter.consider(position: 3, status: .paused) == nil)
    }

    @Test("Resuming also goes out immediately")
    func resumeIsImmediate() {
        // If it stayed with the interval, the title would show as paused on the phone for
        // seconds after it continues.
        var reporter = PlaybackReporter(interval: 10)
        _ = reporter.consider(position: 0, status: .playing)
        _ = reporter.consider(position: 3, status: .paused)

        #expect(reporter.consider(position: 3, status: .playing)?.kind == .resume)
        // After that the interval applies again.
        #expect(reporter.consider(position: 4, status: .playing) == nil)
    }

    @Test("Buffering is not a pause")
    func bufferingIsNotPause() {
        // The viewer is waiting, they have not stopped. Whoever reports both the same
        // sends a resume afterwards that nobody triggered — and in the overview a title
        // shows as paused that is just loading.
        var reporter = PlaybackReporter(interval: 10)
        _ = reporter.consider(position: 0, status: .playing)

        #expect(reporter.consider(position: 4, status: .buffering) == nil)
        #expect(reporter.consider(position: 4, status: .opening) == nil)
        #expect(reporter.consider(position: 4, status: .idle) == nil)

        // After buffering it continues without a resume being reported.
        #expect(reporter.consider(position: 12, status: .playing)?.kind == .progress)
    }

    @Test("The end is reported exactly once")
    func stopOnce() {
        // A second sign-out may end a session on the server that now belongs to the next
        // title.
        var reporter = PlaybackReporter()
        _ = reporter.consider(position: 0, status: .playing)

        let report = reporter.consider(position: 1377, status: .ended)
        #expect(report?.kind == .stop)
        #expect(report?.position == 1377)

        #expect(reporter.consider(position: 1377, status: .ended) == nil)
        #expect(reporter.consider(position: 1377, status: .playing) == nil)
        #expect(reporter.consider(position: 1377, status: .paused) == nil)
    }

    @Test("An error reports the stop just like a regular end")
    func failureStops() {
        // Without a sign-out the session stays on the server for hours as running and
        // blocks the "Now Playing" display.
        var reporter = PlaybackReporter()
        _ = reporter.consider(position: 0, status: .playing)

        #expect(reporter.consider(position: 42, status: .failed)?.kind == .stop)
    }

    @Test("If it aborts while opening, the stop is still reported")
    func failureBeforeStart() {
        // The session comes into existence on the server already when the address is
        // requested. Whoever signs out only from the first picture leaves a ghost session
        // behind at every failed attempt.
        var reporter = PlaybackReporter()

        #expect(reporter.consider(position: 0, status: .failed)?.kind == .stop)
    }

    @Test("No pause is reported before the start")
    func noPauseBeforeStart() {
        // A pause for a session that does not exist yet creates an entry on the server that
        // nobody ever signs out.
        var reporter = PlaybackReporter()

        #expect(reporter.consider(position: 0, status: .paused) == nil)
        #expect(reporter.consider(position: 0, status: .playing)?.kind == .start)
    }

    @Test("A jump forward is reported immediately")
    func forwardSeek() {
        // Otherwise the server shows the old position, and whoever continues on the phone
        // ends up where they already were.
        var reporter = PlaybackReporter(interval: 10)
        _ = reporter.consider(position: 0, status: .playing)

        let report = reporter.consider(position: 600, status: .playing)
        #expect(report?.kind == .progress)
        #expect(report?.position == 600)
    }

    @Test("A jump back is reported immediately")
    func backwardSeek() {
        // The case that fails a check for "more than the interval has passed": the
        // difference is negative, nothing would be reported for up to ten seconds, and a
        // second device resumes at the wrong place.
        var reporter = PlaybackReporter(interval: 10)
        _ = reporter.consider(position: 600, status: .playing)

        let report = reporter.consider(position: 120, status: .playing)
        #expect(report?.kind == .progress)
        #expect(report?.position == 120)
    }

    @Test("Small fluctuations of the position do not count as a jump")
    func jitterIsIgnored() {
        // VLC does not report the position strictly ascending; individual reports are off
        // by a second. If each of them counted as a jump, the limiting of the reports
        // would have no effect.
        var reporter = PlaybackReporter(interval: 10)
        _ = reporter.consider(position: 600, status: .playing)

        #expect(reporter.consider(position: 598.6, status: .playing) == nil)
        #expect(reporter.consider(position: 601.2, status: .playing) == nil)
    }

    @Test("An interval of zero does not flood the server")
    func intervalIsClamped() {
        // A passed-through value of zero — from a setting that was never set, say — would
        // result in one report per frame change, exactly the case this counter is built
        // against.
        var reporter = PlaybackReporter(interval: 0)
        _ = reporter.consider(position: 0, status: .playing)

        #expect(reporter.interval >= 1)
        #expect(reporter.consider(position: 0.2, status: .playing) == nil)
    }

    // MARK: - Gesehen und Fortsetzen

    @Test("From ninety percent on a title counts as watched")
    func watchedThreshold() {
        // The credits are rarely watched to the end. Whoever sets the threshold higher
        // collects series that never finish.
        #expect(PlaybackReporter.isWatched(position: 1296, duration: 1440))
        #expect(!PlaybackReporter.isWatched(position: 1295, duration: 1440))
    }

    @Test("A position beyond the end counts as watched")
    func beyondEnd() {
        // Happens when the server reports a different runtime than the file actually has.
        // Without this case the title would stay open forever.
        #expect(PlaybackReporter.isWatched(position: 1500, duration: 1440))
    }

    @Test("Without a known runtime nothing counts as watched")
    func unknownDuration() {
        // For live channels the server reports zero. A "watched" mark takes the title out
        // of "Continue Watching", and the position then cannot be found again.
        #expect(!PlaybackReporter.isWatched(position: 100, duration: 0))
        #expect(!PlaybackReporter.isWatched(position: 100, duration: -30))
    }

    @Test("A negative position does not count as watched")
    func negativePosition() {
        // Some engines briefly report a value below zero on opening.
        #expect(!PlaybackReporter.isWatched(position: -5, duration: 1440))
    }

    @Test("In the middle of a title it resumes at the reported position")
    func resumeInTheMiddle() {
        #expect(PlaybackReporter.resumePosition(position: 851, duration: 1440) == 851)
    }

    @Test("A watched title starts again from the beginning")
    func watchedRestarts() {
        // Otherwise it would stay permanently under "Continue Watching" at ninety-nine
        // percent and could only be got rid of by seeking.
        #expect(PlaybackReporter.resumePosition(position: 1400, duration: 1440) == nil)
    }

    @Test("A title only glanced at starts from the beginning")
    func barelyStarted() {
        // Ten seconds are not progress but an accident — resuming there looks like a bug of
        // the app. Since 2026-09-28 Jellyfin's threshold (1 %) applies, so for an episode
        // of 24 minutes about 14 seconds.
        #expect(PlaybackReporter.resumePosition(position: 10, duration: 1440) == nil)
    }

    @Test("Without a runtime there is no resume position")
    func resumeWithoutDuration() {
        #expect(PlaybackReporter.resumePosition(position: 500, duration: 0) == nil)
    }

    @Test("The resume position and the Continue Watching row never contradict each other")
    func consistentWithProgress() {
        // Two rules for the same question drift apart over time, and then a title stands in
        // the row that starts from the beginning when opened. That is why the parity is
        // checked over the whole range.
        let duration: TimeInterval = 1440

        for step in 0...144 {
            let position = TimeInterval(step) * 10
            let watched = PlaybackReporter.isWatched(position: position, duration: duration)
            let progress = PlaybackProgress(position: position, duration: duration, isWatched: watched)
            let resume = PlaybackReporter.resumePosition(position: position, duration: duration)

            #expect((resume != nil) == progress.isResumable, "at \(position) seconds")
        }
    }
}
