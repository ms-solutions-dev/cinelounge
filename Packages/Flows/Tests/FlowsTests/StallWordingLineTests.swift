import Core
import Foundation
import Testing

@testable import Flows

/// **One rule for both devices** (AP75): "Connection tight" appears only for a file
/// without a remuxer finding whose engine has measured a tight connection.
@Suite("Stall sentence: line tight")
struct StallWordingLineTests {

    private func target(_ delivery: Delivery, kind: PlaybackTarget.Kind = .recording) -> PlaybackTarget {
        PlaybackTarget(
            itemID: kind == .live ? nil : "film", title: "T",
            url: URL(string: "http://server/film.mp4")!,
            decision: PlaybackDecision(engine: .native, delivery: delivery, reason: .nativeContainer),
            kind: kind)
    }

    @Test("Only file, immediate, tight — and without a finding of its own")
    func rule() {
        let tight = LineFinding(line: 1_000_000, demand: 950_000)
        let ample = LineFinding(line: 5_000_000, demand: 950_000)
        #expect(StallWording.lineTight(target(.directPlay), tight))
        #expect(!StallWording.lineTight(target(.directPlay), ample))
        #expect(!StallWording.lineTight(target(.hls), tight))
        #expect(!StallWording.lineTight(target(.directPlay, kind: .live), tight))
        #expect(!StallWording.lineTight(nil, tight))
        #expect(!StallWording.lineTight(target(.directPlay), nil))

        #expect(
            StallWording.key(nil, target: target(.directPlay), line: tight)
                == "player.stillstandLeitungKnapp")
        #expect(
            StallWording.key(.tooSlow, target: target(.directPlay), line: tight)
                == "player.stillstandLangsam")
        #expect(
            StallWording.key(nil, target: target(.hls), line: tight)
                == "player.stillstandUnbestimmt")
    }
}
