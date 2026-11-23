import Core
import Flows
import Foundation
import Testing

@testable import Features

/// The counters of a repackager, set up by the check — see ``Core/RepackerPulse``.
final class PulseDouble: RepackerPulse, @unchecked Sendable {
    var receivedBytes = 0
    var produced = 0
    var produzierteSekunden: Double = 0
    var reconnectCount = 0
    var writerFailure: Error?
}

/// **Stall level 2 through the connection** (2026-09-25): from the repackager through the tick
/// to the board and the error trace.
///
/// The calculation itself is checked by `StallInterpretationTests` in `Core`. What matters here is
/// that it is **wired up**: if the call in ``PlayerModel`` is taken out,
/// these checks must go red — otherwise they check the calculation a second time
/// and the connection not at all.
extension PlayerModelTests {

    struct Declined: Error {}

    /// A channel through its own repackager, whose counters the check sets.
    private func stallModel(pulse: PulseDouble) async -> (PlayerModel, HostDouble, RemuxSpy) {
        let remux = RemuxSpy()
        remux.pulse = pulse
        let host = HostDouble()
        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: nil,
                title: "TELE MOOS HQ",
                url: URL(string: "http://anbieter/live/4711.m3u8")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .nativeContainer),
                kind: .live
            ),
            engine: host,
            source: SourceSpy(),
            remux: remux.builder,
            rawStreamStore: InMemoryStore()
        )
        await model.begin()
        await model.engineStartTask?.value
        return (model, host, remux)
    }

    /// Ten seconds of healthy operation: position, bytes and pieces grow in step.
    private func isRunning(_ model: PlayerModel, _ host: HostDouble, _ pulse: PulseDouble) async {
        host.engine.status = .playing
        for _ in 0..<20 {
            host.engine.position += 0.5
            pulse.receivedBytes += 312_500
            pulse.produced += 1
            pulse.produzierteSekunden += 0.5
            await model.tick()
        }
    }

    @Test("If the provider stays silent, the board says so — and the error trail hears it once")
    func sourceSilentReachesBoardAndTrace() async {
        let pulse = PulseDouble()
        let (model, host, remux) = await stallModel(pulse: pulse)
        await isRunning(model, host, pulse)

        // From here on everything stands still: no byte, no piece, no movement.
        host.engine.status = .buffering
        for _ in 0..<PlayerModel.stallTicks { await model.tick() }

        #expect(model.isStalled)
        #expect(model.stallFinding == .sourceSilent)
        #expect(
            PlayerScreen.stalledTitleKey(for: model.target, finding: model.stallFinding)
                == StallWording.key(.sourceSilent))
        #expect(
            PlayerScreen.stalledHintKey(for: model.target, finding: model.stallFinding) == nil,
            "one sentence, no explanation underneath")
        #expect(model.stallLines.count == 1)
        #expect(model.stallLines.first?.hasPrefix("Stall B") == true)
        // **Interpretation, not action.** No rebuild: the session reconnects by itself,
        // and a second connection would be the end with a one-connection account.
        #expect(remux.asked.count == 1)

        // If it continues, board and finding go away; a second silence writes
        // no second line.
        host.engine.status = .playing
        host.engine.position += 0.5
        await model.tick()
        #expect(!model.isStalled)
        #expect(model.stallFinding == nil)
        host.engine.status = .buffering
        for _ in 0...PlayerModel.stallTicks { await model.tick() }
        #expect(model.stallFinding == .sourceSilent)
        #expect(model.stallLines.count == 1, "once per finding and target")
    }

    @Test("A writer error is case A: reported, on the board, but not handled")
    func writerErrorIsCaseA() async {
        let pulse = PulseDouble()
        let (model, host, remux) = await stallModel(pulse: pulse)
        await isRunning(model, host, pulse)

        // The writer is no longer created after a section change; the bytes
        // keep arriving.
        pulse.writerFailure = Declined()
        for _ in 0..<PlayerModel.stallTicks {
            pulse.receivedBytes += 312_500
            await model.tick()
        }

        #expect(model.stallFinding == .cutterStalled)
        #expect(
            PlayerScreen.stalledTitleKey(for: model.target, finding: model.stallFinding)
                == StallWording.key(.cutterStalled))
        // Reported immediately on detection and not again on the flip.
        #expect(model.stallLines.count == 1)
        #expect(model.stallLines.first?.contains("would restart") == true)
        // **Level 3 is not built:** the repackager is not set up anew.
        #expect(remux.asked.count == 1)
    }

    /// **Case A matures after the board** — the board flips after twelve seconds of wall-clock time,
    /// the deadline is at fifteen seconds of broadcast. The sentence then becomes more precise.
    @Test("Case A, which is settled only after the board, takes over its sentence")
    func caseARipensAfterTheBoard() async {
        let pulse = PulseDouble()
        let (model, host, _) = await stallModel(pulse: pulse)
        await isRunning(model, host, pulse)

        // 5 Mbit/s keep arriving, no piece is produced.
        for _ in 0..<PlayerModel.stallTicks {
            pulse.receivedBytes += 312_500
            await model.tick()
        }
        #expect(model.isStalled)
        #expect(model.stallFinding == .undetermined, "after 12 s of broadcast it is not one yet")

        for _ in 0..<8 {
            pulse.receivedBytes += 312_500
            await model.tick()
        }
        #expect(model.stallFinding == .cutterStalled)
        #expect(model.stallLines.map { String($0.prefix(7)) } == ["Stall ?", "Stall A"])
    }

    @Test("Without a counter the board keeps its current sentence")
    func noFindingWithoutCounter() async {
        // A repackager without counters — like every path that holds no ``LiveRemuxSession``.
        let remux = RemuxSpy()
        let host2 = HostDouble()
        let without = PlayerModel(
            target: PlaybackTarget(
                itemID: nil,
                title: "TELE MOOS HQ",
                url: URL(string: "http://anbieter/live/4712.m3u8")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .nativeContainer),
                kind: .live
            ),
            engine: host2,
            source: SourceSpy(),
            remux: remux.builder,
            rawStreamStore: InMemoryStore()
        )
        await without.begin()
        await without.engineStartTask?.value
        host2.engine.status = .playing
        host2.engine.position = 10
        await without.tick()
        for _ in 0..<PlayerModel.stallTicks { await without.tick() }

        #expect(without.isStalled)
        #expect(without.stallFinding == nil)
        #expect(
            PlayerScreen.stalledTitleKey(for: without.target, finding: without.stallFinding)
                == "player.stalledLive")
        #expect(without.stallLines.isEmpty)
    }

    // MARK: - Check 25.09.2026 (H1–H3)

    /// **H1:** A rebuild begins a new run, even if the new repackager sits at
    /// the same address. The double session is here the same object and thus the
    /// case that an `ObjectIdentifier` cannot tell apart: without the fresh start in
    /// `releaseRemux()` the stretch without a piece would keep counting across the rebuild —
    /// ten seconds before and seven after would give case A.
    @Test("After a rebuild at the same address the diagnosis counts from the start")
    func rebuildStartsNewRun() async {
        let pulse = PulseDouble()
        let (model, host, remux) = await stallModel(pulse: pulse)
        await isRunning(model, host, pulse)

        for _ in 0..<20 {
            pulse.receivedBytes += 312_500
            await model.tick()
        }
        #expect(model.stallLines.isEmpty, "ten seconds are not yet case A")

        model.retry()
        await model.engineStartTask?.value
        #expect(remux.asked.count == 2)

        host.engine.status = .playing
        for _ in 0..<14 {
            host.engine.position += 0.5
            pulse.receivedBytes += 312_500
            await model.tick()
        }
        #expect(
            !model.stallLines.contains { $0.hasPrefix("Stall A") },
            "the stretch of the old session does not count in the new one")
    }

    /// **H2:** The board flips after ``PlayerModel/stallLimit``; the interpretation judges over
    /// ``Core/StallInterpretation/window``. If they do not agree, it judges over
    /// a different time than the one the position stood still.
    @Test("The board's deadline is the diagnosis window")
    func stallLimitIsTheInterpretationWindow() {
        #expect(PlayerModel.stallLimit == StallInterpretation.window)
    }

    /// **H3:** After the end, bytes keep coming but nothing is produced any more — case A must not
    /// mature over a finished playback.
    @Test("After the end, case A does not mature further", arguments: [PlaybackStatus.ended, .failed])
    func noCaseAAfterEnd(status: PlaybackStatus) async {
        let pulse = PulseDouble()
        let (model, host, _) = await stallModel(pulse: pulse)
        await isRunning(model, host, pulse)

        host.engine.status = status
        for _ in 0..<40 {
            pulse.receivedBytes += 312_500
            await model.tick()
        }
        #expect(
            !model.stallLines.contains { $0.hasPrefix("Stall A") },
            "Case A over a playback in state \(status)")
    }
}
