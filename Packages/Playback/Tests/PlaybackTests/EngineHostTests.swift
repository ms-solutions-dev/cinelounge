import Combine
import Core
import Foundation
import Testing

@testable import Playback

/// What is checked is the host, not the engines.
///
/// The checks run on the Mac, where VLCKit is missing. That is exactly why they stand
/// here: the fallback to the system player is no edge case but the normal case of
/// every check — and if it went unnoticed, a green result from the Mac would be taken
/// for a result from the TV.
///
/// The bodies are deliberately without `await`. The host and both engines live on the
/// main actor; without a suspension point no callback can intervene, and the checks
/// see the state immediately after the call.
@MainActor
@Suite("The host of the playback engines")
struct EngineHostTests {

    private func target(
        _ engine: PlaybackEngine,
        startAt: TimeInterval = 0
    ) -> PlaybackTarget {
        PlaybackTarget(
            itemID: "item-1",
            title: "Test piece",
            url: URL(fileURLWithPath: "/tmp/cinelounge-nicht-vorhanden.mkv"),
            decision: PlaybackDecision(
                engine: engine,
                delivery: .directPlay,
                reason: .nativeContainer
            ),
            startAt: startAt
        )
    }

    @Test("Without a target, an engine stands ready that is not running")
    func idleBeforeStart() {
        // ``controller`` is not an optional, so that the view does not have to handle the
        // case "no engine yet". The price would be that a placeholder is taken for a running
        // engine — ``isRunning`` rules that out.
        let host = EngineHost()

        #expect(host.isRunning == false)
        #expect(host.controller.status == .idle)
    }

    @Test("Without a target, the report claims no decision")
    func reportSaysNothingIsLoaded() {
        // The placeholder is the system player, and without a target no choice has been made
        // yet. If "as decided" stood here, one would be claimed: whoever reads the line next
        // to a black picture wrongly rules out the fallback to the system player and looks
        // for the cause in the wrong place.
        let host = EngineHost()

        #expect(host.report.contains("no target loaded"))
        #expect(host.report.contains("as decided") == false)
    }

    @Test("If the decision demands the system player, the system player runs")
    func nativeIsHonoured() {
        // The case in which there is a second engine at all: Dolby Vision. If it went to
        // VLC, the dynamic metadata would be missing — and nobody would see from the picture
        // that the wrong engine is working.
        let host = EngineHost()
        host.start(target(.native))

        #expect(host.isRunning)
    }

    /// **Two checks about the VLC substitute stood here** — and their subject disappeared
    /// with AP8 (2026-09-02): ``PlaybackEngine`` knows only one case now, the host has no
    /// switch any more, and ``EngineHost/isSubstitute`` can no longer become true.
    ///
    /// Keeping them would mean checking a state that no caller can produce any more —
    /// exactly the kind of tautological check that the same finding counts at 59 places.

    @Test("The start point of the target reaches the engine")
    func startPositionIsPassedOn() throws {
        // Resuming is the most common way into playback. If the start point were lost here,
        // every half-watched film would begin from the start again — and the fault would lie
        // not in the engine but in the handoff.
        let host = EngineHost()
        host.start(target(.native, startAt: 942))

        // The host passes the start point through, and the engine seeks immediately — the
        // reasoning is at the engine itself: waiting for the first-time signal meant
        // chunking the beginning that nobody wanted to see.
        let engine = try #require(host.controller as? NativePlaybackEngine)
        #expect(engine.pendingStart == nil)
        #expect(engine.position == 942, "the display is at the target immediately")
    }

    @Test("A start point of zero leaves the engine at the beginning")
    func zeroStartStaysAtBeginning() {
        // A trailer and an unwatched film begin at zero. If the host seeked anyway, the
        // beginning of a film would lose its first seconds.
        let host = EngineHost()
        host.start(target(.native, startAt: 0))

        #expect(host.controller.position == 0)
    }

    @Test("The system player never reports a position before the start")
    func nativeNeverReportsNegativePosition() {
        // The everyday case, not the special case: ten seconds back at second three gives
        // minus seven. Before, the system player accepted any value and published it
        // unchanged — the bar ran past the left edge, and the progress reported to the
        // server would have been negative. On the next opening the viewer would be offered
        // a nonsensical resume position.
        //
        // The VLC engine, by contrast, was already protected. That it was missing here was
        // due to the name of the arithmetic rules: they were called `VLCPlaybackRules` and
        // seemed not to concern the system player.
        let host = EngineHost()
        host.start(target(.native, startAt: 0))

        host.controller.seek(to: -7)

        #expect(host.controller.position >= 0)
    }

    @Test("stop() ends the engine and reports it")
    func stopTearsDown() {
        // Without teardown the time observers keep running and report positions for
        // something that is no longer playing. On the TV one then hears sound to a black
        // picture.
        let host = EngineHost()
        host.start(target(.native))
        host.stop()

        #expect(host.isRunning == false)
        #expect(host.controller.status == .idle)
    }

    @Test("A second start does not let two engines run at once")
    func secondStartReplacesTheFirst() {
        // The fault from the evidence: the old engine still had the audio open, and one
        // heard two audio tracks on top of each other while only the new one's picture was
        // visible. Both are checked — that a different engine is working and that the old
        // one is actually silent.
        let host = EngineHost()
        host.start(target(.native))
        let first = host.controller

        host.start(target(.native))
        let second = host.controller

        #expect(first !== second)
        #expect(first.status == .idle)
        #expect(host.isRunning)
    }

    @Test("An engine switch keeps no old engine behind")
    func switchingEnginesStopsTheOldOne() {
        // Between trailer and main film the engine actually changes: the one container goes
        // native, the other does not. If the first engine stayed alive, the same double
        // sound would occur as on the second start of the same engine.
        let host = EngineHost()
        host.start(target(.native))
        let first = host.controller

        host.start(target(.native))

        #expect(first !== host.controller)
        #expect(first.status == .idle)
    }

    /// **The trap for which a forwarding once existed — and the check that remains of
    /// it.**
    ///
    /// Until 2026-09-11 (AP32) host and engine were `ObservableObject`, and an
    /// `ObservableObject` **inside** another reports nothing outward: the progress bar
    /// would stand at zero while the film plays — without an error message, without a
    /// hint in the source. The host therefore listened to the engine's
    /// `objectWillChange` and sent its own afterwards.
    ///
    /// **With `@Observable` the trap no longer exists**, because reporting happens on the
    /// **property** and not on the class. What is checked is therefore no longer the
    /// means but the purpose: whoever reads through the host gets the change.
    @Test("Timestamps of the engine reach the view")
    func engineChangesAreForwarded() {
        let host = EngineHost()
        host.start(target(.native))

        let changes = ChangeCounter()
        withObservationTracking {
            // Exactly the access a view makes — through the host to the engine.
            _ = host.controller.status
        } onChange: {
            MainActor.assumeIsolated { changes.count += 1 }
        }

        // Via `pause()` and not via `seek()`: a seek is rightly discarded while the length
        // is still unknown and then publishes nothing. The notification would thus be
        // measured against a side condition instead of itself.
        host.controller.pause()

        #expect(changes.count > 0)
    }

    /// **A replaced engine no longer moves the view.**
    ///
    /// **Until 2026-09-11 this check was called "After teardown the old engine reports
    /// nothing further", and that assurance no longer exists** — ``stop()`` expressly
    /// leaves the engine standing and queryable, and whoever reads `controller.position`
    /// after the end reads exactly it. That is right so: the display would then not be
    /// wrong but current.
    ///
    /// **What remains is the concern behind it** — that a *replaced* engine still moves
    /// the view and sets the bar to a state that does not belong to the new target. That
    /// is exactly what is checked here, and it applies for a different reason than
    /// before: not because a forwarding was solved, but because the host points at a
    /// different engine.
    @Test("A superseded engine no longer moves the view")
    func supersededEngineReportsNothing() {
        let host = EngineHost()
        host.start(target(.native))
        let old = host.controller
        host.start(target(.native))
        #expect(old !== host.controller)

        let changes = ChangeCounter()
        withObservationTracking {
            _ = host.controller.status
        } onChange: {
            MainActor.assumeIsolated { changes.count += 1 }
        }

        old.pause()

        #expect(changes.count == 0)
    }
}

/// Counter for the change notifications. As a class, because the callback must
/// increment it without changing the check itself.
@MainActor
private final class ChangeCounter {
    var count = 0
}

/// The engine's computations, checked without an engine.
///
/// They stand outside `#if os(tvOS)` and therefore next to the host's checks: if the
/// computation stayed in the engine, none of them would be reachable on the Mac — and
/// exactly what stands out in everyday viewing would stay unchecked.
@Suite("The engine's calculations")
struct PlaybackRulesTests {

    @Test("Ten seconds back at the start of the movie land on zero, not below")
    func rewindBeforeStartClampsToZero() {
        // The everyday case and not the special case: at second three the seek gives minus
        // seven. Unfiltered the bar would run past the left edge, and the progress reported
        // to the server would be negative — on the next opening a nonsensical resume
        // position would be on offer.
        #expect(PlaybackRules.seekTarget(-7, duration: 5400) == 0)
    }

    @Test("A jump past the end lands on the end")
    func seekBeyondEndClampsToDuration() {
        // Thirty seconds forward with ten seconds of remaining running time. Without a
        // limit the engine would report a position behind the film: the bar would run out
        // on the right and the reported share would exceed a hundred percent.
        #expect(PlaybackRules.seekTarget(5430, duration: 5400) == 5400)
    }

    @Test("Without a known length, no jump takes place")
    func noSeekWithoutDuration() {
        // As long as the length is unknown, no seek goes. If the position were taken anyway,
        // the bar would show a position where the film is not — the normal case right after
        // opening and permanently for a running channel.
        #expect(PlaybackRules.seekTarget(942, duration: 0) == nil)
        #expect(PlaybackRules.seekTarget(942, duration: -1) == nil)
        #expect(PlaybackRules.seekTarget(942, duration: .infinity) == nil)
    }
}
