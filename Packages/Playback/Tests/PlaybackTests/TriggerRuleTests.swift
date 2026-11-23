import Foundation
import Testing

@testable import Playback

/// **The clock is kicked when AVPlayer does not get going on a tight connection**
/// (AP69, 2026-10-11). Diagnosis F-017: 50 s of still frame at a 0.5 MB/s connection
/// and 0.5 MB/s bitrate; the probe on the Mac showed 41 s of buffer and still
/// `likelyToKeepUp == false`. What is checked is the decision, not AVPlayer — only the
/// device sees that.
@Suite("Trigger rule")
struct TriggerRuleTests {

    private func triggers(
        readySince: TimeInterval? = 2.5, leadTime: TimeInterval? = 4, waiting: Bool = true,
        isFile: Bool = true, alreadyTriggered: Bool = false
    ) -> Bool {
        TriggerRule.shouldTrigger(
            readySince: readySince, leadTime: leadTime, waiting: waiting, isFile: isFile,
            alreadyTriggered: alreadyTriggered)
    }

    @Test("File, ready, waiting, lead there: trigger")
    func theCase() {
        #expect(triggers())
    }

    @Test("Too early: AVPlayer may only estimate after two seconds")
    func tooEarly() {
        #expect(!triggers(readySince: 1.9))
        #expect(triggers(readySince: 2.0))
    }

    @Test("Too little material: under three seconds would be an immediate stall")
    func tooLittleLeadTime() {
        #expect(!triggers(leadTime: 2.9))
        #expect(!triggers(leadTime: nil))
        #expect(triggers(leadTime: 3.0))
    }

    @Test("Only once per target — after that the stall guard decides")
    func onlyOnce() {
        #expect(!triggers(alreadyTriggered: true))
    }

    @Test("A jump is a new startup: counting is from the jump")
    func jumpCountsAsNew() {
        let ready = Date(timeIntervalSince1970: 1_000)
        let jump = Date(timeIntervalSince1970: 1_600)
        let now = Date(timeIntervalSince1970: 1_601)
        #expect(TriggerRule.readySince(ready: ready, jump: jump, now: now) == 1)
        #expect(TriggerRule.readySince(ready: ready, jump: nil, now: now) == 601)
        // The start seek ends with readiness — the later of the two marks counts.
        #expect(TriggerRule.readySince(ready: jump, jump: ready, now: now) == 1)
        #expect(TriggerRule.readySince(ready: nil, jump: jump, now: now) == nil)
    }

    @Test("HLS and live: AVPlayer estimates the tier itself")
    func noFile() {
        #expect(!triggers(isFile: false))
    }

    @Test("Playing or paused: nothing to do")
    func notWaiting() {
        #expect(!triggers(waiting: false))
    }

    @Test("Not ready yet: trigger nothing")
    func notReady() {
        #expect(!triggers(readySince: nil))
    }

    @Test("The diagnostics line names lead, reason and capacity")
    func row() {
        let row = TriggerRule.row(
            readySince: 12.4, leadTime: 7.25, waitReason: "AVPlayerWaitingToMinimizeStallsReason",
            carries: false, full: false)
        #expect(row.contains("ready for 12 s"))
        #expect(
            row.contains("7.2 s lead") || row.contains("7,2 s lead")
                || row.contains("7.3 s lead"))
        #expect(row.contains("ToMinimizeStallsReason"))
        #expect(!row.contains("AVPlayerWaiting"))
        #expect(row.contains("carries no"))
        #expect(
            TriggerRule.row(readySince: nil, leadTime: nil, waitReason: nil, carries: false, full: true)
                .contains("nothing loaded"))
    }

    @MainActor
    @Test("On loading nothing has been triggered yet")
    func freshlyLoaded() {
        let engine = NativePlaybackEngine()
        engine.load(URL(string: "http://iptvhost.example:2086/series/u/p/361595.mp4")!, startingAt: 0)
        #expect(!engine.clockKicked)
        engine.stop()
    }
}
