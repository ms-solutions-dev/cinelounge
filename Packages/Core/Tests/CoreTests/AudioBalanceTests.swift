import AVFoundation
import Foundation
import Testing

@testable import Core

/// **The audio path of the file must vouch for itself** (AP31 · "DTS in the
/// app", followed up on 2026-09-24).
///
/// The finding: a transcoder is accepted on the **first** frame. If every
/// further one fails afterwards, the file played with picture and without sound — and the
/// diagnosis said not a word. The two aborts that ``MatroskaRemuxer``
/// reports hit only the first frame; the line after that stood alone in the
/// verbose log, exactly where nobody looks with a silent movie — it had not
/// flipped the switch beforehand.
///
/// ``TransportRemuxer`` has kept this tally for channels since 2026-08-22. What is checked
/// here is the whole chain: that the repackager counts on the real sound, that
/// ``AudioTally`` forms the verdict from it, and that a poisoned DTS track
/// really comes out as silent.
@Suite("Audio balance: the pipeline attests itself")
struct AudioBalanceTests {

    // MARK: - Die Zählung am echten Ton

    // MARK: - Das Urteil

    private func balance(
        seconds: Double, packets: Int, rejected: Int? = nil, reason: String? = nil
    ) -> AudioTally {
        AudioTally(
            codec: "DTS",
            framesIn: Int(seconds * 48000 / 512),
            packetsOut: packets,
            secondsIn: seconds,
            channels: 6,
            rejectedFrames: rejected,
            reason: reason)
    }

    @Test("One second of sound in and no packet out means silent")
    func noPacketMeansSilent() throws {
        let muted = balance(seconds: 1.6, packets: 0, rejected: 150, reason: "DTS frame in 14-bit form")
        #expect(muted.staysSilent)
        let finding = try #require(muted.silenceFinding)
        // The sentence must answer the follow-up question as well: did the decoder
        // reject, or did the encoder yield nothing? Two findings, two ways out.
        #expect(finding.contains("150 frames rejected"))
        #expect(finding.contains("14-bit form"))
        #expect(finding.contains("0 AAC packets out"))
        #expect(finding.contains("1.6 s"))
    }

    /// **The normal case must not count as an error.** A DTS frame carries
    /// 512 samples, an AAC packet 1024 — the first frames yield
    /// nothing by design. Whoever judged without a deadline would report every startup.
    @Test("Below the deadline no verdict is made")
    func underTheDeadlineNoVerdict() {
        #expect(balance(seconds: 0.02, packets: 0).staysSilent == false)
        #expect(balance(seconds: AudioTally.verdictFrom - 0.01, packets: 0).staysSilent == false)
        #expect(balance(seconds: AudioTally.verdictFrom, packets: 0).staysSilent)
    }

    /// The deadline must **fit inside a chunk**: every chunk gets its
    /// own repackager, and the counters start at zero with it. If it lay at
    /// the chunk length, the watchdog would fire only by chance.
    @Test("The deadline fits into one piece of the writer")
    func deadlineFitsInOnePiece() {
        #expect(AudioTally.verdictFrom < FragmentWriter.segmentDuration.seconds)
    }

    @Test("Where packets come out, the balance stays silent")
    func withPacketsNoFinding() {
        let isRunning = balance(seconds: 9, packets: 400)
        #expect(isRunning.staysSilent == false)
        #expect(isRunning.silenceFinding == nil)
        #expect(isRunning.row.contains("400 AAC packets out"))
        #expect(isRunning.row.contains("6 channels"))
    }

    // MARK: - Der Fall, den der Befund benennt

    // MARK: - Die Meldung

    static func muted() -> AudioTally {
        AudioTally(
            codec: "DTS", framesIn: 200, packetsOut: 0, secondsIn: 2.1,
            channels: 6, rejectedFrames: nil, reason: nil)
    }

    static func healthy() -> AudioTally {
        AudioTally(
            codec: "DTS", framesIn: 200, packetsOut: 98, secondsIn: 2.1,
            channels: 6, rejectedFrames: nil, reason: nil)
    }

    /// **The connection and not the calculation:** a silent chunk reaches the
    /// error log. If this check stayed green when the report is missing in the holder, it would check
    /// nothing — exactly that was the open point of the counter-check.
    @Test("A silent piece lands in the error trace")
    func silentLandsInTheErrorTrack() {
        var gate = MatroskaFileSession.FileReportGate()
        let report = MatroskaFileSession.audioMessage(Self.muted(), piece: 3) { gate.claim($0) }
        guard case .problem(let text) = report else {
            Issue.record("expected: error trace, got: \(report)")
            return
        }
        #expect(text.hasPrefix("Piece 3"))
    }

    /// **Once per file and not per chunk.** A movie of 3600 chunks would otherwise write
    /// 3600 identical lines into the error log, and the one that counts would be drowned in them.
    @Test("The error trace hears it once per file")
    func oncePerFile() {
        var gate = MatroskaFileSession.FileReportGate()
        _ = MatroskaFileSession.audioMessage(Self.muted(), piece: 1) { gate.claim($0) }
        let second = MatroskaFileSession.audioMessage(Self.muted(), piece: 2) { gate.claim($0) }
        guard case .row = second else {
            Issue.record("the second silent piece reported again: \(second)")
            return
        }
    }

    /// And a healthy chunk never goes into the error log.
    @Test("A healthy piece stays behind the switch")
    func healthyStaysQuiet() {
        var gate = MatroskaFileSession.FileReportGate()
        let report = MatroskaFileSession.audioMessage(Self.healthy(), piece: 1) { gate.claim($0) }
        guard case .row = report else {
            Issue.record("healthy sound reported: \(report)")
            return
        }
        #expect(MatroskaFileSession.audioMessage(nil, piece: 1) { gate.claim($0) } == .none)
    }
}
