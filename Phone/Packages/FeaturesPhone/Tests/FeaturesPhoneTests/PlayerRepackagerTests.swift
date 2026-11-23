import Core
import Flows
import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The repackager on the phone through the shared setup** (AP58 R4, report A S3): protection
/// against a too-short file, list with start mark and last attempt come from
/// ``Flows/RemuxStart``. The chain itself is checked by `RemuxerStartTests`; what matters here
/// is that it is **connected**.
@MainActor
@Suite("Repackager on the phone")
struct PlayerRepackagerTests {

    /// The corrected start position and the hint arrive in the run — otherwise the
    /// engine would jump to the end of a truncated file.
    @Test("Start position and hint travel with the run")
    func runCarriesCorrection() {
        let handle = NSObject()
        let run = RepackagerRun.Run(
            RemuxStart.Started(
                address: URL(string: "http://127.0.0.1:1/liste.m3u8")!, handle: handle, finish: {},
                startAt: 0, hint: "abgeschnitten"))
        #expect(run.startAt == 0)
        #expect(run.hint == "abgeschnitten")
        // **Pin down first, then compare** — a `===` in the macro crashes the compiler
        // (same trap as in `PlayerChainTests`).
        let held = ObjectIdentifier(run.session)
        #expect(held == ObjectIdentifier(handle))
    }

    @Test("The player goes through the shared chain and applies the correction")
    func connected() throws {
        let model = SourceText.strippingCommentLines(
            try SourceText.read("SpielerModel.swift", in: .featuresPhone))
        #expect(model.contains("RemuxStart.fallback("))
        #expect(model.contains("case .lastAttempt"))
        #expect(model.contains("run.startAt"))
        let run = SourceText.strippingCommentLines(
            try SourceText.read("RepackagerRun.swift", in: .featuresPhone))
        #expect(run.contains("RemuxStart.build("))
        #expect(run.contains("RemuxStart.needsStartMark("))
        #expect(!run.contains("MatroskaFileSession("), "no second file path")
    }
}
