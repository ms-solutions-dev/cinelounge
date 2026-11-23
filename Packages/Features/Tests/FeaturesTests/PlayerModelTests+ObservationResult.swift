import Core
import Foundation
import Observation
import Testing

@testable import Features

/// **Reporting happens on the property and not on the class** — AP32, 2026-09-11.
///
/// The finding that triggered this rework: the project had **zero** `@Observable`
/// and 104 `@Published`, and Combine reports on the **class**. Concretely that meant:
/// ``TrackChooser`` and ``PlayerInfoPanel`` do not read ``PlayerModel/position`` at all,
/// but rebuilt themselves **twice per second** as long as they were open — the panel
/// including a `ForEach` over the cast with one picture per person.
///
/// **This check pins down the gain**, because it is invisible from outside: without it
/// the whole rework would be a claim that silently decays at the next `@Published`.
extension PlayerModelTests {

    /// A wake flag.
    ///
    /// **As a class, because `onChange` comes from outside.** The callback of
    /// ``withObservationTracking(_:onChange:)`` counts as concurrent; a captured
    /// variable could not be set there. The notifications all still come from the
    /// main thread — the same pattern as the counter in ``EngineHostTests``.
    @MainActor
    final class WakeFlag {
        var woken = false
    }

    /// **Whoever does not read the position is not woken by it.**
    @Test("A position tick wakes only whoever reads it")
    func onlyReadersAreWoken() async {
        let (model, host, _) = make()
        host.engine.status = .playing
        host.engine.duration = 3600
        await model.tick()

        // Two readers: one like the track board (state only), one like the bar.
        let board = WakeFlag()
        withObservationTracking {
            _ = model.status
            _ = model.isChoosingTracks
        } onChange: {
            MainActor.assumeIsolated { board.woken = true }
        }

        let bar = WakeFlag()
        withObservationTracking {
            _ = model.position
        } onChange: {
            MainActor.assumeIsolated { bar.woken = true }
        }

        host.engine.position = 42
        await model.tick()

        #expect(bar.woken)
        #expect(!board.woken)
    }

    /// **And conversely the state wakes both** — otherwise it would not be that less is reported,
    /// but simply nothing.
    @Test("A state change reaches its readers")
    func stateWakesItsReaders() async {
        let (model, host, _) = make()
        host.engine.status = .playing
        await model.tick()

        let memo = WakeFlag()
        withObservationTracking {
            _ = model.status
        } onChange: {
            MainActor.assumeIsolated { memo.woken = true }
        }

        host.engine.status = .paused
        await model.tick()

        #expect(memo.woken)
    }

    /// **The engine reports through the host.**
    ///
    /// Until 2026-09-11 an explicit forwarding in ``EngineHost`` hung on this:
    /// an `ObservableObject` **inside** another reports nothing outward, and
    /// the consequence would be *"a progress bar that stands at zero while the movie
    /// plays"*. With ``Observation`` the nesting works by itself — and exactly that
    /// is pinned down here, so that the dropped forwarding does not go missing unnoticed.
    @Test("The engine's position reaches the reader across two levels")
    func acrossTwoLevels() async {
        let (model, host, _) = make()
        host.engine.status = .playing
        await model.tick()

        let memo = WakeFlag()
        withObservationTracking {
            _ = model.position
        } onChange: {
            MainActor.assumeIsolated { memo.woken = true }
        }

        // The engine at the bottom, the reader at the top — host and model in between.
        host.engine.position = 17
        await model.tick()

        #expect(memo.woken)
        #expect(model.position == 17)
    }
}
