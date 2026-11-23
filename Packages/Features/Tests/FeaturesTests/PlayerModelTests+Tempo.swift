import Core
import Foundation
import Testing

@testable import Features

/// **The playback tempo** — AP31, 2026-09-11.
///
/// ``Core/PlaybackController/supportsSpeed`` and ``Core/PlaybackController/setRate(_:)``
/// had always been in the contract and were implemented in the system player — **nobody
/// called them.** The same kind of find as the network guard, the series poster and
/// ``Core/AccountState/showsMediaBar``: built, justified, without a reader.
extension PlayerModelTests {

    /// **The steps are six and not twenty.**
    ///
    /// Here one presses, and every step costs a press. Below half, speech
    /// becomes unintelligible, above double too — in between the pitch
    /// correction of the system carries it.
    @Test("The speed steps are bounded and ordered")
    func speedSteps() {
        let slots = PlayerModel.speedSteps
        #expect(slots.first == 0.5)
        #expect(slots.last == 2)
        #expect(slots.contains(1))
        #expect(slots == slots.sorted())
        #expect(slots.count <= 6)
    }

    /// **The label takes the decimal separator of the UI.**
    ///
    /// A hard-written point would be wrong in German and in Turkish too.
    /// Whole numbers stay without a decimal place — "1,00×" reads like a measurement.
    @Test("The step reads as a number with a multiplication sign")
    func speedLabel() {
        #expect(TrackChooser.caption(1).hasSuffix("×"))
        #expect(!TrackChooser.caption(1).contains("0"))
        #expect(TrackChooser.caption(1.5).dropLast().count == 3)
    }

    /// **What the engine cannot do is not offered.**
    ///
    /// A control that does nothing is worse than none: one presses and looks for the
    /// fault in oneself.
    @Test("Without the engine's capability there is no switch")
    func speedWithoutCapability() {
        let (model, host, _) = make()
        host.engine.supportsSpeed = false

        #expect(!model.supportsSpeed)
        model.setRate(1.5)
        #expect(model.rate == 1)
        #expect(host.engine.rates.isEmpty)
    }

    /// **The choice goes to the engine and shows in the display.**
    @Test("A chosen step reaches the engine — exactly once")
    func speedReachesTheEngine() {
        let (model, host, _) = make()

        model.setRate(1.5)
        #expect(model.rate == 1.5)
        #expect(host.engine.rates == [1.5])

        // **The same step again is not a command.** It would otherwise cost an
        // assignment to `rate` — and `rate` is, with the system player, also the
        // switch for start and stop.
        model.setRate(1.5)
        #expect(host.engine.rates == [1.5])
    }

    /// **The chosen tempo survives a stop.**
    ///
    /// `rate` is also the switch for start and stop: on resuming it is back
    /// at 1. Without re-applying it, the viewer would see normal speed after every stop,
    /// while the display keeps claiming "1,5×" — two truths about the
    /// same question.
    @Test("After resuming, the chosen speed applies again")
    func speedSurvivesStopping() async {
        let (model, host, _) = make()
        host.engine.status = .playing
        await model.tick()

        model.setRate(2)
        #expect(host.engine.rates == [2])

        host.engine.status = .paused
        await model.tick()
        host.engine.status = .playing
        await model.tick()

        #expect(host.engine.rates == [2, 2])
        #expect(model.rate == 2)
    }

    /// **Without a choice of its own the tick does not intervene.**
    ///
    /// Whoever never switched should get no rate set on any state change —
    /// that would be a command without occasion on exactly the switch that carries start and
    /// stop.
    @Test("Normal speed applies nothing")
    func speedWithoutChoice() async {
        let (model, host, _) = make()

        host.engine.status = .playing
        await model.tick()
        host.engine.status = .paused
        await model.tick()

        #expect(host.engine.rates.isEmpty)
        #expect(model.rate == 1)
    }
}
