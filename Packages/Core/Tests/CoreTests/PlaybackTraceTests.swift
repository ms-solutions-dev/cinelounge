import Foundation
import Testing

@testable import Core

/// **The gap through which the stuttering of 2026-08-22 fell.**
///
/// A dozen channels visibly stuttered on the TV, and the summary of this class
/// reported for every single one "0 dropouts, 0 buffer reports, ran through". Both
/// were right: stall and lead presuppose a standing or jumping **position**, and an
/// engine that throws pictures away keeps the position in perfect order. Dropped
/// frames are the only quantity that names this case — what is checked here is that
/// they are counted, added up correctly and not silently turned into zero.
@Suite("The trace also counts what nobody sees standing")
struct PlaybackTraceTests {

    /// Two samples per second, the way the playback tick does it.
    private func run(
        _ trace: PlaybackTrace, seconds: Int, droppedPerSample: [Int?], start: Date = Date()
    ) -> Date {
        trace.begin("check run", at: start)
        var now = start
        for index in 0..<(seconds * 2) {
            now = start.addingTimeInterval(Double(index + 1) * 0.5)
            trace.sample(
                position: Double(index + 1) * 0.5,
                isPlaying: true,
                isBuffering: false,
                date: now,
                droppedFrames: droppedPerSample[min(index, droppedPerSample.count - 1)]
            )
        }
        return now
    }

    /// **No information, no acquittal.** An engine that says nothing about dropped
    /// frames must not pass as "zero dropped" — exactly this mix-up stood six times in
    /// the diagnosis on 2026-08-22.
    @Test("If the engine stays silent, the finding says so — instead of “ran through”")
    func silenceIsNotAnAcquittal() {
        let trace = PlaybackTrace()
        let end = run(trace, seconds: 10, droppedPerSample: [nil])
        let summary = trace.summary(at: end)

        #expect(summary.contains("does not report dropped pictures"))
        #expect(!summary.contains("ran through"))
        #expect(!summary.contains("pictures dropped"))
    }

    /// If the engine reports zero, "ran through" is proven and may be called that.
    @Test("Zero reported dropped frames still means: ran through")
    func reportedZeroStaysClean() {
        let trace = PlaybackTrace()
        let end = run(trace, seconds: 10, droppedPerSample: [0])
        let summary = trace.summary(at: end)

        #expect(summary.contains("0 pictures dropped"))
        #expect(summary.contains("ran through"))
    }

    /// The case of 2026-08-22: the position runs flawlessly, the picture stutters.
    @Test("Dropped frames beat every other finding")
    func droppedFramesOutrankEverything() {
        let trace = PlaybackTrace()
        // 25 pictures gone every half second — at 50 Hz that is every second one.
        let counters = (0..<20).map { $0 * 25 }
        let end = run(trace, seconds: 10, droppedPerSample: counters)
        let summary = trace.summary(at: end)

        #expect(summary.contains("dropped pictures"))
        #expect(summary.contains("stuttering WITHOUT stalls"))
        #expect(!summary.contains("ran through"))
    }

    /// **The counter is a reading per section, not a total.** When the engine starts a
    /// new entry in the access log, it begins at zero again. Whoever reads the raw
    /// number as a total sees it jump back in the middle of playback and then counts
    /// wrongly — when in doubt it reports less than was dropped.
    @Test("If the counter jumps back, the old section is still counted")
    func counterResetKeepsTheEarlierSection() {
        let trace = PlaybackTrace()
        // 0 → 300, then a new entry: 0 → 200. Together 500.
        let counters = [0, 100, 200, 300, 0, 50, 100, 150, 200, 200]
        let end = run(trace, seconds: 5, droppedPerSample: counters)
        let summary = trace.summary(at: end)

        #expect(summary.contains("500 pictures dropped"))
    }

    /// A few frames are lost at every startup — when the frame rate is switched, the
    /// output stands still briefly. That is not a finding.
    @Test("A few dropped frames stay under the threshold")
    func aHandfulIsNotAVerdict() {
        let trace = PlaybackTrace()
        let counters = [0, 0, 3, 6, 8, 9, 10, 10, 10, 10]
        let end = run(trace, seconds: 5, droppedPerSample: counters)
        let summary = trace.summary(at: end)

        #expect(summary.contains("10 pictures dropped"))
        #expect(summary.contains("ran through"))
    }
    /// **An idling buffer reports buffering.** Where there is no buffer report, it
    /// cannot have run empty — and the sentence "the source delivers too slowly" points
    /// in the wrong direction.
    ///
    /// Check agent 2026-08-23: all four incidents of the run were at 0:00 with zero buffer
    /// reports, and all four got the source sentence.
    @Test("A stall without a buffering report does not blame the source")
    func stallWithoutBufferingIsNotTheSource() {
        let trace = PlaybackTrace()
        let start = Date(timeIntervalSince1970: 0)
        trace.begin("check", at: start)
        // Stands at 0.0 s: three samples at the same position, then it continues. Without
        // the third, the stall is never recorded.
        for step in 0...2 {
            trace.sample(
                position: 0, isPlaying: true, isBuffering: false,
                date: start.addingTimeInterval(Double(step)), droppedFrames: 0)
        }
        trace.sample(
            position: 1, isPlaying: true, isBuffering: false,
            date: start.addingTimeInterval(3), droppedFrames: 0)

        let summary = trace.summary(at: start.addingTimeInterval(30))
        #expect(!summary.contains("liefert zu langsam"))
        #expect(summary.contains("settling time") || summary.contains("did not run empty"))
    }

    /// **Nobody seeks on a channel.** A jump without input is a break there, not a seek
    /// — the sentence "no error" stood twice above a real error.
    @Test("A jump on a channel does not count as a seek")
    func jumpOnLiveIsNoSeek() {
        let trace = PlaybackTrace()
        let start = Date(timeIntervalSince1970: 0)
        trace.begin("check", at: start, isLive: true)
        trace.sample(
            position: 0, isPlaying: true, isBuffering: false, date: start,
            droppedFrames: 0)
        trace.sample(
            position: 5, isPlaying: true, isBuffering: false,
            date: start.addingTimeInterval(1), droppedFrames: 0)

        let summary = trace.summary(at: start.addingTimeInterval(30))
        #expect(summary.contains("jump without any action"))
        #expect(!summary.contains("kein Fehler"))
    }

    /// **No information, no accusation either.** The counter is `Int?`, and `nil` fell
    /// through both checks to zero, down to the last branch — which then asserted a
    /// drop that no engine had reported. That is the flip side of "No information, no
    /// acquittal".
    @Test("A jump without information about dropped frames claims no drops")
    func jumpWithoutACounterAccusesNobody() {
        let trace = PlaybackTrace()
        let start = Date(timeIntervalSince1970: 0)
        trace.begin("check", at: start)
        trace.sample(
            position: 0, isPlaying: true, isBuffering: false, date: start,
            droppedFrames: nil)
        // Lead 4 s: below ``seekThreshold``, so it counts as a break and not as a seek. No
        // stall.
        trace.sample(
            position: 5, isPlaying: true, isBuffering: false,
            date: start.addingTimeInterval(1), droppedFrames: nil)

        let summary = trace.summary(at: start.addingTimeInterval(30))
        #expect(!summary.contains("pictures are dropped"))
        #expect(summary.contains("does not report"))
    }

    /// **A wide lead in a file is a seek.** On 2026-08-23 two jumps of 237 s and 178 s got
    /// the sentence "That is the source, not the decoding" — that was the viewer on the
    /// remote, and the stall afterwards was the buffer refilling.
    @Test("A stall at the jump target does not blame the source")
    func stallAtASeekTargetIsNotTheSource() {
        let trace = PlaybackTrace()
        let start = Date(timeIntervalSince1970: 0)
        trace.begin("check", at: start)
        func sample(_ position: TimeInterval, _ second: Double, buffering: Bool = false) {
            trace.sample(
                position: position, isPlaying: true, isBuffering: buffering,
                date: start.addingTimeInterval(second), droppedFrames: 0)
        }
        sample(15, 0)
        sample(253, 1)  // Lead 237 s — a seek
        sample(253, 2, buffering: true)
        sample(253, 3)  // steht seit Sekunde 1 an derselben Stelle
        sample(254, 4)

        let summary = trace.summary(at: start.addingTimeInterval(60))
        #expect(summary.contains("by seeking"))
        #expect(summary.contains("after a seek"))
        #expect(!summary.contains("Das ist die Quelle"))
    }

    /// **Proximity decides, not the mere count.** On 2026-08-23 a stall at 0:00 got the
    /// source sentence because there was buffering once six minutes later — the check
    /// was made against the whole session instead of against the position.
    @Test("A buffering report at a completely different spot does not explain a stall at the start")
    func bufferingElsewhereExplainsNothing() {
        let trace = PlaybackTrace()
        let start = Date(timeIntervalSince1970: 0)
        trace.begin("check", at: start)
        for step in 0...2 {
            trace.sample(
                position: 0, isPlaying: true, isBuffering: false,
                date: start.addingTimeInterval(Double(step)), droppedFrames: 0)
        }
        // Buffer report at 6:07, far from the stall at 0:00.
        trace.sample(
            position: 367, isPlaying: false, isBuffering: true,
            date: start.addingTimeInterval(4), droppedFrames: 0)

        let summary = trace.summary(at: start.addingTimeInterval(60))
        #expect(summary.contains("settling time"))
        #expect(!summary.contains("liefert zu langsam"))
    }

    /// **Hundreds of drops over a long film miss the rate** and fell through until then —
    /// "ran through" then stood above a line that showed them.
    @Test("Hundreds of dropped frames do not give “ran through”")
    func manyDroppedFramesAreNoAcquittal() {
        let trace = PlaybackTrace()
        // 200 drops in 600 s: 0.33 per second — above ``droppedFloor``, below
        // ``droppedRateThreshold``.
        let end = run(trace, seconds: 600, droppedPerSample: [0, 200])
        let summary = trace.summary(at: end)

        #expect(summary.contains("200 pictures dropped"))
        #expect(!summary.contains("ran through"))
        #expect(summary.contains("spread out and not continuous"))
    }

    // MARK: - Das Urteil der Zusammenfassung

    /// **The core of AP1.** The summary went out as `.plain`, and `.plain` only stores
    /// something with the debug switch flipped — a session with dropouts thereby
    /// produced **zero** error lines. It can now say itself whether it reports a defect;
    /// the branches knew it all along and kept it to themselves.
    @Test("An acquittal is not a defect")
    func acquittalIsNoDefect() {
        let trace = PlaybackTrace()
        let end = run(trace, seconds: 10, droppedPerSample: [0])

        #expect(!trace.finding(at: end).isDefect)
    }

    /// Dropped frames are the case for which the whole quantity was introduced — and the
    /// finding about it must go out without a switch.
    @Test("Dropped frames are a defect")
    func droppedAreDefects() {
        let trace = PlaybackTrace()
        let end = run(trace, seconds: 10, droppedPerSample: [0, 60, 120, 180, 240])

        let finding = trace.finding(at: end)
        #expect(finding.isDefect)
        #expect(finding.text.contains("dropped pictures"))
    }

    /// **The idling buffer too.** This is the session that carried the point: dropouts,
    /// and not a single error line in the diagnosis.
    @Test("A stall with a buffering report is a defect")
    func stallIsDefect() {
        let trace = PlaybackTrace()
        let start = Date()
        trace.begin("check run", at: start)
        var now = start
        for index in 0..<20 {
            now = start.addingTimeInterval(Double(index + 1) * 0.5)
            // The position stands still, and the buffer reports — the buffer runs empty, the
            // source delivers too slowly.
            trace.sample(
                position: 5, isPlaying: index < 4, isBuffering: index >= 4, date: now,
                droppedFrames: 0)
        }

        let finding = trace.finding(at: now)
        #expect(finding.isDefect)
    }

    /// **A seek is not a defect.** The control case to the verdict: whoever declares
    /// every jump a defect turns every remote into a bug — exactly the error the source
    /// has avoided since 2026-08-24.
    @Test("A seek is not a defect")
    func seekingIsNoDefect() {
        let trace = PlaybackTrace()
        let start = Date()
        trace.begin("check run", at: start, isLive: false)
        var now = start
        for index in 0..<10 {
            now = start.addingTimeInterval(Double(index + 1) * 0.5)
            trace.sample(
                position: Double(index) * 0.5, isPlaying: true, isBuffering: false, date: now,
                droppedFrames: 0)
        }
        // A wide jump forward — the viewer on the remote.
        now = now.addingTimeInterval(0.5)
        trace.sample(
            position: 300, isPlaying: true, isBuffering: false, date: now, droppedFrames: 0)
        for index in 0..<10 {
            now = now.addingTimeInterval(0.5)
            trace.sample(
                position: 300 + Double(index) * 0.5, isPlaying: true, isBuffering: false,
                date: now, droppedFrames: 0)
        }

        let finding = trace.finding(at: now)
        #expect(!finding.isDefect)
        #expect(finding.text.contains("a seek"))
    }

    /// Ohne Wiedergabe gibt es nichts zu beklagen.
    @Test("An empty trace is not a defect")
    func emptyIsNoDefect() {
        #expect(!PlaybackTrace().finding(at: Date()).isDefect)
    }
}
