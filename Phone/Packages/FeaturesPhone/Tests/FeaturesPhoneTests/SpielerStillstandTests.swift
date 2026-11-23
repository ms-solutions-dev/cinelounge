import Core
import Flows
import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// An engine that plays nothing but answers everything — **position and state are supplied by the
/// check.** Template: `ControllerDouble` in the TV project.
@MainActor
final class EngineDouble: PlaybackController {
    var status: PlaybackStatus = .idle
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    var selectedAudioTrack: PlaybackTrack.ID?
    var selectedSubtitleTrack: PlaybackTrack.ID?
    var bufferedRange: ClosedRange<TimeInterval>?

    func load(_ url: URL, startingAt position: TimeInterval) { self.position = position }
    func play() { status = .playing }
    func pause() { status = .paused }
    func stop() {}
    func seek(to position: TimeInterval) { self.position = position }
    func selectAudioTrack(_ id: PlaybackTrack.ID) { selectedAudioTrack = id }
    func selectSubtitleTrack(_ id: PlaybackTrack.ID?) { selectedSubtitleTrack = id }
    /// Whether the engine supports a speed — off until a check needs it.
    var supportsSpeed = false
    /// Every speed the engine received.
    private(set) var rates: [Double] = []
    func setRate(_ rate: Double) { rates.append(rate) }
}

/// The counters of a repackager, supplied by the check — see ``Core/RepackerPulse``.
final class PulseDouble: RepackerPulse, @unchecked Sendable {
    var receivedBytes = 0
    var produced = 0
    var produzierteSekunden: Double = 0
    var reconnectCount = 0
    var writerFailure: Error?
}

/// **Stall stage 4 across the connection** (2026-09-25, decision 13): from the pulse of the
/// repackager via the tick of ``PlayerModel`` to the board and the error trace.
///
/// The calculation itself is checked by `StallInterpretationTests` in `Core`. What matters here is that
/// it is **connected** — if one takes `take`/`interpret` out of
/// ``PlayerModel/tick(controller:pulse:)``, the first two go red; if one counts the
/// deadline in ticks instead of seconds, the first goes red.
@MainActor
@Suite("Stall on the phone")
struct PlayerStallTests {

    struct Declined: Error {}

    /// A model without a source — **exactly why a witness.** If the tick called ``start()``,
    /// afterwards `.disrupted(.notSetUpYet)` would stand instead of `.isPlaying`.
    private func model() -> PlayerModel {
        PlayerModel(
            job: PlaybackJob(identifier: "4711", origin: .channelList), source: nil,
            networkMonitor: nil)
    }

    /// Ten seconds of healthy operation: position, bytes and chunks grow in step.
    private func isRunning(
        _ model: PlayerModel, _ engine: EngineDouble, _ pulse: PulseDouble?
    ) async {
        engine.status = .playing
        for _ in 0..<10 {
            engine.position += 1
            pulse?.receivedBytes += 625_000
            pulse?.produced += 1
            pulse?.produzierteSekunden += 1
            await model.tick(controller: engine, pulse: pulse)
        }
    }

    @Test("If the provider stays silent, the board flips after twelve seconds, and the trace hears it once")
    func sourceSilent() async {
        let viewModel = model()
        let engine = EngineDouble()
        let pulse = PulseDouble()
        await isRunning(viewModel, engine, pulse)

        // From here on everything stands still: no byte, no chunk, no movement.
        engine.status = .buffering
        for _ in 0..<11 { await viewModel.tick(controller: engine, pulse: pulse) }
        #expect(!viewModel.settled, "eleven seconds are not yet a deadline")

        await viewModel.tick(controller: engine, pulse: pulse)
        #expect(viewModel.settled, "after twelve seconds the board is up")
        #expect(viewModel.stallFinding == .sourceSilent)
        #expect(viewModel.isBarVisible, "the bar comes with the board")
        #expect(viewModel.stallLines.count == 1)
        #expect(viewModel.stallLines.first?.hasPrefix("Stall B") == true)

        // If it keeps running, board and finding go; a second silence writes no
        // second row.
        engine.status = .playing
        engine.position += 1
        await viewModel.tick(controller: engine, pulse: pulse)
        #expect(!viewModel.settled)
        #expect(viewModel.stallFinding == nil)
        engine.status = .buffering
        for _ in 0..<12 { await viewModel.tick(controller: engine, pulse: pulse) }
        #expect(viewModel.stallFinding == .sourceSilent)
        #expect(viewModel.stallLines.count == 1, "once per finding and target")
    }

    @Test("A writer error is case A: reported, on the board, but not handled")
    func writerError() async {
        let viewModel = model()
        let engine = EngineDouble()
        let pulse = PulseDouble()
        await isRunning(viewModel, engine, pulse)

        // The writer is no longer created; the bytes keep arriving.
        pulse.writerFailure = Declined()
        for _ in 0..<12 {
            pulse.receivedBytes += 625_000
            await viewModel.tick(controller: engine, pulse: pulse)
        }

        #expect(viewModel.settled)
        #expect(viewModel.stallFinding == .cutterStalled)
        // Reported immediately on detection and not once more on flipping.
        #expect(viewModel.stallLines.count == 1)
        #expect(viewModel.stallLines.first?.contains("would restart") == true)
        // **No action.** A rebuild would go through `start()`, and without a
        // source that would end in the error screen.
        #expect(viewModel.state == .isPlaying)
    }

    @Test("Without a pulse the board is still up, but without finding and without line")
    func withoutPulse() async {
        let viewModel = model()
        let engine = EngineDouble()
        await isRunning(viewModel, engine, nil)

        engine.status = .buffering
        for _ in 0..<12 { await viewModel.tick(controller: engine, pulse: nil) }

        #expect(viewModel.settled)
        #expect(viewModel.stallFinding == nil)
        #expect(viewModel.stallLines.isEmpty)
        #expect(
            StallWording.key(viewModel.stallFinding)
                == "player." + "stillstandUnbestimmt")
    }

    @Test("Paused is not a stall, even after half a minute")
    func pause() async {
        let viewModel = model()
        let engine = EngineDouble()
        let pulse = PulseDouble()
        await isRunning(viewModel, engine, pulse)

        engine.status = .paused
        for _ in 0..<30 { await viewModel.tick(controller: engine, pulse: pulse) }

        #expect(!viewModel.settled)
        #expect(viewModel.stallLines.isEmpty)
    }

    /// **Before the first frame, waiting is startup.** The player has the loading state for that;
    /// a board on top would say the same thing twice.
    @Test("Before the first frame nothing flips")
    func beforeFirstFrame() async {
        let viewModel = model()
        let engine = EngineDouble()
        engine.status = .opening
        for _ in 0..<30 { await viewModel.tick(controller: engine, pulse: nil) }
        #expect(!viewModel.settled)
    }

    /// **H1: The handle is an address, and addresses come back.** If the new
    /// repackager gets the same address as the old one after teardown, the handle recognized no
    /// new run — and the old set (bytes per broadcast second) calculated against the bytes of a
    /// channel with ten times the bitrate that is waiting for its first keyframe. The result was
    /// a case A after three seconds.
    @Test("After teardown a repackager at the same address starts from zero")
    func newRunAfterTeardown() async {
        let viewModel = model()
        let engine = EngineDouble()
        let pulse = PulseDouble()
        await isRunning(viewModel, engine, pulse)
        await viewModel.finish()

        pulse.receivedBytes = 0
        pulse.produced = 0
        pulse.produzierteSekunden = 0
        engine.status = .playing
        for _ in 0..<3 {
            engine.position += 1
            pulse.receivedBytes += 6_250_000
            await viewModel.tick(controller: engine, pulse: pulse)
        }
        #expect(viewModel.stallLines.isEmpty, "\(viewModel.stallLines)")
    }

    /// **H1, the second way: a restart on the same title** — source switch, "Resolve
    /// again", re-fetching the address. The interpretation stays (its lock applies per target), but
    /// the handle must drop; otherwise a repackager at the same address recognizes no new
    /// run. Checked on ``PlayerModel/resetStall()``, through which each of these
    /// paths goes via ``PlayerModel/start()``.
    @Test("A restart on the same title begins the run anew")
    func restartOnSameTitle() async {
        let viewModel = model()
        let engine = EngineDouble()
        let pulse = PulseDouble()
        viewModel.resetStall()
        await isRunning(viewModel, engine, pulse)
        viewModel.resetStall()

        pulse.receivedBytes = 0
        pulse.produced = 0
        pulse.produzierteSekunden = 0
        engine.status = .playing
        for _ in 0..<3 {
            engine.position += 1
            pulse.receivedBytes += 6_250_000
            await viewModel.tick(controller: engine, pulse: pulse)
        }
        #expect(viewModel.stallLines.isEmpty, "\(viewModel.stallLines)")
    }

    /// **H3: After the end there is nothing to interpret.** The interpretation was fed before the
    /// switch and kept maturing in the error and end states; a repackager that still
    /// receives bytes then reported case A for a title that is long since over.
    @Test("In the error and end state the interpretation does not mature further")
    func noRipeningAfterEnd() async {
        for status in [PlaybackStatus.ended, .failed] {
            let viewModel = model()
            let engine = EngineDouble()
            let pulse = PulseDouble()
            await isRunning(viewModel, engine, pulse)

            engine.status = status
            for _ in 0..<20 {
                pulse.receivedBytes += 625_000
                await viewModel.tick(controller: engine, pulse: pulse)
            }
            pulse.writerFailure = Declined()
            await viewModel.tick(controller: engine, pulse: pulse)
            #expect(viewModel.stallLines.isEmpty, "\(status): \(viewModel.stallLines)")
        }
    }

    /// **Every finding has its sentence, and every sentence is in the catalog in three languages.**
    /// The keys are assembled here — otherwise the test suite for the
    /// language keys would count this file as a usage.
    ///
    /// **Since AP58 R3 in the shared catalog** (``StallWording``): Until then both
    /// app catalogs carried the five sentences, and both devices copied the assignment per finding.
    @Test("The board has a sentence in the catalog for every finding")
    func boardSentences() throws {
        let expected: [StallInterpretation.Finding: String] = [
            .cutterStalled: "Schneider", .sourceSilent: "Quelle", .tooSlow: "Langsam",
            .engineRefuses: "Motor", .undetermined: "Unbestimmt",
        ]
        for finding in StallInterpretation.Finding.allCases {
            let key = StallWording.key(finding)
            #expect(key == "player." + "stillstand" + (expected[finding] ?? "?"))
            let catalog = AppLanguageSetting.catalog(forItem: key)
            #expect(catalog != .main, "\(key) is not in the shared catalog")
            for language in ["de", "en", "tr"] {
                let bundles = AppLanguageSetting.bundles(forItem: language, in: catalog)
                let message = bundles.localizedString(forKey: key, value: "∅", table: nil)
                #expect(message != "∅" && message != key, "\(key) is missing for \(language)")
            }
        }
    }
}
