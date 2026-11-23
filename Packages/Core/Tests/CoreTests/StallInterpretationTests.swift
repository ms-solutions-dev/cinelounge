import Foundation
import Testing

@testable import Core

/// **The calculation behind the stall board** — stall stage 2, 2026-09-25.
///
/// The eight cases from `design/konzept-stall.md` §6. The most important is the second:
/// on the tunnel the legitimate wait for a keyframe must **never** look like a dead
/// cutter — a false alarm on a slow network would be worse than the
/// silence this stage ends.
@Suite("The stall interpretation")
struct StallInterpretationTests {

    /// Bytes per second of broadcast at 5 Mbit/s.
    static let fiveMbit = 625_000

    /// A sample with playback running.
    static func probe(
        _ time: TimeInterval, bytes: Int, produced: Int, seconds: Double,
        status: PlaybackStatus, position: TimeInterval, error: String?
    ) -> StallInterpretation.Sample {
        StallInterpretation.Sample(
            time: time, status: status, position: position, loadedUntil: nil, hasPlayed: true,
            pulse: PulseState(
                bytes: bytes, produced: produced, seconds: seconds, reconnections: 0,
                writerError: error))
    }

    /// Twenty seconds of healthy operation at 5 Mbit/s, one chunk every half second.
    ///
    /// - Returns: the interpretation and the state at the end — bytes, chunks, broadcast time.
    static func healthy() -> (StallInterpretation, bytes: Int, pieces: Int, seconds: Double) {
        var interpretation = StallInterpretation()
        var pieces = 0
        for step in 1...40 {
            let t = Double(step) * 0.5
            pieces += 1
            let finding = interpretation.take(
                probe(
                    t, bytes: Int(t * Double(fiveMbit)), produced: pieces, seconds: t,
                    status: .playing, position: t, error: nil))
            #expect(finding == nil)
        }
        return (interpretation, 20 * fiveMbit, pieces, 20)
    }

    @Test("Bytes without a piece: nothing at 14.9 s of broadcast, case A at 15.1 s")
    func deadlineInBroadcast() {
        var (interpretation, bytes, pieces, seconds) = Self.healthy()
        let previous = interpretation.take(
            Self.probe(
                20 + 14.9, bytes: bytes + Int(14.9 * Double(Self.fiveMbit)), produced: pieces,
                seconds: seconds, status: .playing, position: 20, error: nil))
        #expect(previous == nil, "before the deadline it is still a keyframe wait")
        bytes += Int(15.1 * Double(Self.fiveMbit))
        let following = interpretation.take(
            Self.probe(
                20 + 15.1, bytes: bytes, produced: pieces, seconds: seconds,
                status: .buffering, position: 20, error: nil))
        #expect(following == .cutterStalled)
        #expect(interpretation.interpret() == .cutterStalled)
    }

    /// **The check against the dreaded false alarm** (§6, case 2).
    ///
    /// 0.3 Mbit/s through the tunnel, a channel at 5 Mbit/s, plus a wait for the
    /// keyframe of twelve seconds of **broadcast time** — that is about 200 s of wall-clock time, in
    /// which bytes arrive without a chunk. Measured in wall-clock time that would long since be
    /// case A; in broadcast time it is not.
    @Test("On the tunnel a long keyframe wait is not case A")
    func tunnelWithoutFalseAlarm() {
        var (interpretation, bytes, pieces, seconds) = Self.healthy()
        let tunnel = 37_500  // 0,3 Mbit/s in Bytes je Sekunde
        var t = 20.0
        let target = bytes + 12 * Self.fiveMbit
        while bytes < target {
            t += 0.5
            bytes = min(target, bytes + tunnel / 2)
            let finding = interpretation.take(
                Self.probe(
                    t, bytes: bytes, produced: pieces, seconds: seconds, status: .buffering,
                    position: 20, error: nil))
            #expect(finding == nil, "nothing may trigger at \(Int(t)) s of clock time")
        }
        #expect(t > 200, "the wait must really have been long")
        #expect(interpretation.interpret() != .cutterStalled)
        // And the measure for stage 3 is there: twelve seconds of broadcast time.
        #expect(abs(interpretation.longestStretchWithoutChunk - 12) < 0.1)
        pieces += 1
        seconds += 0.5
        _ = interpretation.take(
            Self.probe(
                t + 0.5, bytes: bytes, produced: pieces, seconds: seconds, status: .playing,
                position: 20.5, error: nil))
        #expect(abs(interpretation.longestStretchWithoutChunk - 12) < 0.1, "the maximum stays")
    }

    @Test("A piece in between resets the stretch")
    func pieceResets() {
        var (interpretation, bytes, pieces, seconds) = Self.healthy()
        bytes += 10 * Self.fiveMbit
        pieces += 1
        seconds += 0.5
        _ = interpretation.take(
            Self.probe(
                30, bytes: bytes, produced: pieces, seconds: seconds, status: .playing,
                position: 25, error: nil))
        let finding = interpretation.take(
            Self.probe(
                35.1, bytes: bytes + Int(5.1 * Double(Self.fiveMbit)), produced: pieces,
                seconds: seconds, status: .playing, position: 25, error: nil))
        #expect(finding == nil)
    }

    @Test("When the bytes stand still the source is silent — and that means no action")
    func sourceSilent() {
        let (start, bytes, pieces, seconds) = Self.healthy()
        var interpretation = start
        for step in 1...24 {
            let finding = interpretation.take(
                Self.probe(
                    20 + Double(step) * 0.5, bytes: bytes, produced: pieces, seconds: seconds,
                    status: .buffering, position: 20, error: nil))
            #expect(finding == nil, "a silent provider is never case A")
        }
        #expect(interpretation.interpret() == .sourceSilent)
        #expect(interpretation.text(forItem: .sourceSilent).hasPrefix("Stall B"))
    }

    @Test("If production grows while buffering, the line is too slow")
    func tooSlow() {
        var (interpretation, bytes, pieces, seconds) = Self.healthy()
        for step in 1...24 {
            bytes += 20_000
            if step % 8 == 0 {
                pieces += 1
                seconds += 0.5
            }
            _ = interpretation.take(
                Self.probe(
                    20 + Double(step) * 0.5, bytes: bytes, produced: pieces, seconds: seconds,
                    status: .buffering, position: 20, error: nil))
        }
        #expect(interpretation.interpret() == .tooSlow)
    }

    @Test("If production grows while the engine wants to play, it does not accept")
    func engineRefuses() {
        var (interpretation, bytes, pieces, seconds) = Self.healthy()
        for step in 1...24 {
            bytes += Self.fiveMbit / 2
            pieces += 1
            seconds += 0.5
            _ = interpretation.take(
                Self.probe(
                    20 + Double(step) * 0.5, bytes: bytes, produced: pieces, seconds: seconds,
                    status: .playing, position: 20, error: nil))
        }
        #expect(interpretation.interpret() == .engineRefuses)
    }

    @Test("Pause and startup are not interpreted, not even with a writer error")
    func pauseAndStartup() {
        var interpretation = StallInterpretation()
        let pause = interpretation.take(
            Self.probe(
                1, bytes: 10, produced: 0, seconds: 0, status: .paused, position: 0, error: "broken"))
        #expect(pause == nil)
        var startup = Self.probe(
            2, bytes: 10, produced: 0, seconds: 0, status: .opening, position: 0, error: "broken")
        startup.hasPlayed = false
        let beforePicture = interpretation.take(startup)
        #expect(beforePicture == nil, "before the first picture the startup watchers decide")
    }

    @Test("A named writer error is case A without a deadline")
    func writerErrorImmediately() {
        let (start, bytes, pieces, seconds) = Self.healthy()
        var interpretation = start
        let finding = interpretation.take(
            Self.probe(
                20.5, bytes: bytes, produced: pieces, seconds: seconds, status: .playing,
                position: 20.5, error: "unsupportedAudio"))
        #expect(finding == .cutterStalled)
        let text = interpretation.text(forItem: .cutterStalled)
        #expect(text.contains("Reason: unsupportedAudio"))
        #expect(text.contains("would restart"), "level 2 reports, level 3 acts")
    }

    @Test("Each finding appears once per target in the error trace, even across rebuilds")
    func oncePerTarget() {
        var interpretation = Self.healthy().0
        let first = interpretation.report(forItem: .sourceSilent)
        #expect(first != nil)
        let second = interpretation.report(forItem: .sourceSilent)
        #expect(second == nil)
        interpretation.newRun()
        let afterRebuild = interpretation.report(forItem: .sourceSilent)
        #expect(afterRebuild == nil, "the lock applies per target, not per session")
        let other = interpretation.report(forItem: .tooSlow)
        #expect(other != nil, "a different kind of finding has its own lock")
    }

    private final class SeamPulse: RepackerPulse {
        var receivedBytes = 0
        var produced = 0
        var produzierteSekunden = 0.0
        var reconnectCount = 0
        var writerFailure: Error? { nil }
        var discardedBytes = 0
    }

    /// **The false alarm before every seam** (AP64, F-018): the overlap — 18–23 s
    /// of broadcast time that the repackager deliberately discards — looked like a cutter that
    /// is stalled. The pulse subtracts it.
    @Test("The discarded overlap at a seam is not case A")
    func seamIsNoStall() {
        let healthy = Self.healthy()
        var interpretation = healthy.0
        let bytes = healthy.bytes
        let pulse = SeamPulse()
        pulse.produced = healthy.pieces
        pulse.produzierteSekunden = healthy.seconds
        // 20 s of broadcast time come in and are all discarded as duplicates.
        let overlap = 20 * Self.fiveMbit
        pulse.receivedBytes = bytes + overlap
        pulse.discardedBytes = overlap
        let finding = interpretation.take(
            StallInterpretation.Sample(
                time: 40, status: .playing, position: 20, loadedUntil: nil, hasPlayed: true,
                pulse: pulse.pulseState))
        #expect(pulse.pulseState.bytes == bytes)
        #expect(finding == nil, "discarded data is not a stalled cutter")
    }
}
