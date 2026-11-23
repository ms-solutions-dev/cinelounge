import CoreMedia
import Foundation
import Testing

@testable import Core

/// A channel's clock — and the two bugs that only show up after hours.
///
/// **That is why this test is here and not in the on-device test.** An overflow
/// occurs after 26 hours and 30 minutes; whoever waits for that in order to
/// test it never tests it. Here it takes microseconds.
@Suite("The clock of a channel")
struct StreamClockTests {

    /// One tick is 1/90,000 of a second.
    let second: Int64 = 90_000

    @Test("An ordinary stream passes through unchanged")
    func plainStreamPassesThrough() {
        var clock = StreamClock()
        let start: UInt64 = 1_000_000

        let first = clock.ticks(for: start)
        let later = clock.ticks(for: start + UInt64(second))

        #expect(later - first == second)
        #expect(clock.wrapCount == 0)
        #expect(clock.breakCount == 0)
    }

    /// **After 26 hours and 30 minutes the counter starts again at zero.**
    /// Without catching it, AVFoundation would get a timestamp far before the last one,
    /// the writer would refuse, and the picture would freeze — with a cause
    /// that lies a day back.
    @Test("The overflow after 26 hours is leveled out")
    func wraparoundIsSmoothed() {
        var clock = StreamClock()

        // Shortly before the wrap … (a quarter of a second: the distance across
        // the wrap must stay below the break threshold, otherwise
        // this tests the break instead of the overflow)
        let before = UInt64(StreamClock.wrapPeriod - second / 4)
        let firstTicks = clock.ticks(for: before)
        // … and shortly after.
        let afterTicks = clock.ticks(for: UInt64(second / 4))

        #expect(clock.wrapCount == 1)
        // Half a second apart, not 26 hours backwards.
        #expect(afterTicks - firstTicks == second / 2)
    }

    /// A straggler from the time before the overflow must not jump 26 hours
    /// forward — otherwise it would tear a hole that the buffer never fills.
    @Test("A straggler before the overflow stays where it belongs")
    func stragglerBeforeWrapStaysBehind() {
        var clock = StreamClock()

        let before = UInt64(StreamClock.wrapPeriod - second / 4)
        _ = clock.ticks(for: before)
        _ = clock.ticks(for: UInt64(second / 4))  // Overflow
        let straggler = clock.ticks(for: before + 1000)  // still from the old round

        // It lands near the first one, not 26 hours further on.
        #expect(abs(straggler - (Int64(before) + 1000)) < second)
    }

    /// **A channel switches its feed, and the timestamp jumps.** A
    /// jump forward would tear a hole in the playlist, a jump
    /// back would make the writer discard everything that follows.
    @Test("A forward jump is leveled out")
    func forwardBreakIsSmoothed() {
        var clock = StreamClock()

        let base: UInt64 = 1_000_000
        let first = clock.ticks(for: base)
        // One hour forward — that is not progress, that is a break.
        let after = clock.ticks(for: base + UInt64(3600 * second))

        #expect(clock.breakCount == 1)
        #expect(after - first == StreamClock.stepAfterBreak)
    }

    @Test("A backward jump is leveled out")
    func backwardBreakIsSmoothed() {
        var clock = StreamClock()

        let base: UInt64 = 10 * 3600 * 90_000
        let first = clock.ticks(for: base)
        let after = clock.ticks(for: base - UInt64(3600 * second))

        #expect(clock.breakCount == 1)
        #expect(after > first)
    }

    /// **The provider's burst startup** (2026-08-15, proven locally on the real channel):
    /// the edge delivers the stream in bursts and starts every new
    /// connection a few seconds BEFORE the end of the previous one — at the last
    /// keyframe. The jump back was below the old ten-second
    /// threshold, passed through unchecked, and the writer died on the
    /// backward timestamp — silently: one chunk, then never another.
    @Test("A small backward step — the burst startup — is a break")
    func shortBackwardJumpIsABreak() {
        var clock = StreamClock()

        let base: UInt64 = 10 * 3600 * 90_000
        let first = clock.ticks(for: base)
        // Four seconds back: too small for the old threshold, backward
        // enough to kill the writer.
        let after = clock.ticks(for: base - UInt64(4 * second))

        #expect(clock.breakCount == 1)
        #expect(after > first, "time keeps moving forward despite the backward step")
    }

    /// **The normal case must not be a break.** Picture and sound alternate,
    /// and the sound regularly lies behind the most recently seen picture. Whoever takes that
    /// for a break readjusts the clock on every second packet — and the
    /// sound runs away from the picture.
    @Test("Interleaved picture and sound trigger no break")
    func interleavedTracksAreNotABreak() {
        var clock = StreamClock()
        let base: UInt64 = 5_000_000

        // Picture at 0.0 / 0.5 / 1.0 — sound 0.2 seconds behind each.
        var results: [Int64] = []
        for step in 0..<6 {
            let videoPTS = base + UInt64(Int64(step) * second / 2)
            results.append(clock.ticks(for: videoPTS))
            let audioPTS = videoPTS - UInt64(second / 5)
            results.append(clock.ticks(for: audioPTS))
        }

        #expect(clock.breakCount == 0)
        // And the distance between picture and sound is preserved exactly.
        #expect(results[0] - results[1] == second / 5)
        #expect(results[8] - results[9] == second / 5)
    }

    /// After a break the distance between picture and sound must be the same
    /// as before — otherwise the break would be healed and lip sync
    /// broken.
    @Test("A break does not shift picture and sound against each other")
    func breakKeepsTracksTogether() {
        var clock = StreamClock()
        let base: UInt64 = 1_000_000

        _ = clock.ticks(for: base)
        _ = clock.ticks(for: base - UInt64(second / 5))

        // Break: one hour forward, picture first.
        let newBase = base + UInt64(3600 * second)
        let video = clock.ticks(for: newBase)
        let audio = clock.ticks(for: newBase - UInt64(second / 5))

        #expect(clock.breakCount == 1)
        #expect(video - audio == second / 5)
    }

    @Test("The time is delivered as CMTime with the stream's timescale")
    func timeUsesStreamTimescale() {
        var clock = StreamClock()
        let time = clock.time(for: 90_000)

        #expect(time.timescale == SampleAssembly.timescale)
        #expect(time.seconds == 1.0)
    }
}

/// The break is detected per track — the lesson of TELE MOOS HD (F-011).
@Suite("The clock per track")
struct PerTrackClockTests {
    private let second: Int64 = 90_000

    @Test("Sound running one and a half seconds ahead of the picture is not a break")
    func audioAheadIsNoBreak() {
        var clock = StreamClock()
        var video: Int64 = 10 * second
        var audio: Int64 = video + second * 3 / 2
        for _ in 0..<50 {
            _ = clock.ticks(for: UInt64(video), track: .video)
            _ = clock.ticks(for: UInt64(audio), track: .audio)
            video += 3600  // 40 ms
            audio += 3600
        }
        #expect(clock.breakCount == 0)
    }

    @Test("A real jump is leveled out once, not per track")
    func realBreakIsSmoothedOnce() {
        var clock = StreamClock()
        let v0 = clock.ticks(for: UInt64(10 * second), track: .video)
        _ = clock.ticks(for: UInt64(10 * second - 9000), track: .audio)  // 0,1 s hinter dem Bild
        _ = clock.ticks(for: UInt64(10 * second + 3600), track: .video)
        // The channel jumps five seconds forward — first the picture, then the sound.
        let vJump = clock.ticks(for: UInt64(15 * second + 7200), track: .video)
        let aJump = clock.ticks(for: UInt64(15 * second + 7200 - 9000), track: .audio)
        #expect(clock.breakCount == 1)
        // The picture continues one step behind the last mark …
        #expect(vJump == v0 + 3600 + StreamClock.stepAfterBreak)
        // … and the sound keeps its distance of 0.1 s from the picture.
        #expect(aJump == vJump - 9000)
    }
}

/// The breaks in their wording — track and direction.
@Suite("The breaks in wording")
struct BreakNotesTests {
    @Test("A forward jump of the picture reads \"Picture +5.0 s\"")
    func noteNamesTrackAndSize() {
        var clock = StreamClock()
        _ = clock.ticks(for: UInt64(10 * 90_000), track: .video)
        _ = clock.ticks(for: UInt64(15 * 90_000), track: .video)
        #expect(clock.breakNotes == ["Picture +5.0 s"])
        let row = TransportRemuxer.clockBalance(
            breaks: 5, wraps: 0, audioBehind: 0, notes: clock.breakNotes)
        #expect(row == "Clock: 5 breaks smoothed out (Picture +5.0 s, …)")
    }

    /// **The offset of 2026-10-03** (F-018): at the seam the picture jumped 0.9 s, the
    /// sound 1.0 s. Decided per track, the picture stayed put and the sound was pulled —
    /// one second of offset until the switchover. Closed together, the distance is preserved.
    @Test("A burst seam does not shift picture and sound against each other")
    func seamKeepsPictureAndAudioTogether() {
        var clock = StreamClock()
        let start: UInt64 = 1_000_000
        // Before the seam: picture and sound at a 25 Hz beat, sound 40 ms ahead of the picture.
        var image: Int64 = 0
        var audio: Int64 = 0
        for i in 0..<50 {
            image = clock.ticks(for: start + UInt64(i * 3_600), track: .video)
            audio = clock.ticks(for: start + UInt64(i * 3_600 + 3_600), track: .audio)
        }
        _ = audio

        // The seam: next picture 0.9 s behind the last. The sound before the new
        // keyframe dropped out, it resumes 0.17 s after it — its jump is over
        // a second, that of the picture below it. Exactly the situation of 2026-10-03.
        let lastFrame = start + UInt64(49 * 3_600)
        let rawPicture = lastFrame + 81_000
        let rawAudio = rawPicture + 15_000
        clock.closeSeam(ticks: 81_000)
        let pictureAfter = clock.ticks(for: rawPicture, track: .video)
        let audioAfter = clock.ticks(for: rawAudio, track: .audio)

        #expect(
            audioAfter - pictureAfter == Int64(rawAudio - rawPicture),
            "picture and sound stand as in the stream")
        #expect(pictureAfter - image == StreamClock.stepAfterBreak, "the gap is closed")
        #expect(clock.breakCount == 0, "a closed seam is not a break")
    }
}
