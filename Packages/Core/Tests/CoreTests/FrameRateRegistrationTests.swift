import Foundation
import Testing

@testable import Core

/// Which frame rate is registered — and when no longer (AP2 · U5).
///
/// **The subject of the check is a measured number:** "The Reed King", 61 seconds,
/// **46 registrations** between 23.976 / 24.0 / 25.0. Each of them would, after U2,
/// be a mode switch of the TV with HDMI negotiation and a black picture.
@Suite("Frame rate registration")
struct FrameRateRegistrationTests {

    // MARK: - Die Norm-Rate

    /// **No number is better than a wrong one.** 58.82 Hz (1000/17) was registered three
    /// times — the repackager's millisecond resolution on a 59.94 Hz channel, a frame
    /// rate that does not exist.
    @Test("Only rates that exist")
    func standardRate() {
        #expect(FrameRateRegistration.standardRate(forItem: 25.0) == 25)
        #expect(FrameRateRegistration.standardRate(forItem: 24.98) == 25)
        #expect(FrameRateRegistration.standardRate(forItem: 59.94) == 59.94)
        // 58.82 is more than one hertz away from every standard.
        #expect(FrameRateRegistration.standardRate(forItem: 58.82) == nil)
        #expect(FrameRateRegistration.standardRate(forItem: 0) == nil)
    }

    /// 23.976 and 24.0 are the same output for the TV.
    @Test("Same mode means same output")
    func sameMode() {
        #expect(FrameRateRegistration.sameMode(23.976, 24))
        #expect(FrameRateRegistration.sameMode(29.97, 30))
        #expect(FrameRateRegistration.sameMode(59.94, 60))
        #expect(!FrameRateRegistration.sameMode(24, 25))
        #expect(!FrameRateRegistration.sameMode(50, 60))
    }

    // MARK: - Die drei Regeln

    @Test("The first registration always goes through")
    func firstPassesThrough() {
        var login = FrameRateRegistration()
        let step1 = login.accepts(25, from: .estimated)
        #expect(step1)
        #expect(login.rate == 25)
    }

    /// Rule 1: The same mode costs a black picture and changes nothing.
    @Test("The same mode is not registered twice")
    func sameModeStaysSilent() {
        var login = FrameRateRegistration()
        _ = login.accepts(24, from: .measured)

        let step2 = login.accepts(24, from: .measured)
        #expect(!step2)
        let step3 = login.accepts(23.976, from: .measured)
        #expect(!step3)
    }

    /// **The measured case.** The estimate oscillates between 25 and 24; after the one
    /// permitted follow-up correction it is over.
    @Test("Oscillation ends after one follow-up correction")
    func oscillationEnds() {
        var login = FrameRateRegistration()
        var registrations = 0

        // That is how it looked in the log: the same three values, always alternating.
        for value: Float in [25, 24, 23.976, 25, 24, 23.976, 25, 24, 25, 24]
        where
            login.accepts(value, from: .estimated)
        {
            registrations += 1
        }

        // Once 25, once 24 — and after that nothing more.
        #expect(registrations == 2)
        #expect(login.rate == 24)
    }

    /// Rule 2: A counted number overrules the estimate even when the lock for sources of
    /// equal rank has long been closed.
    @Test("The measurement overrides the estimate, even after the lock")
    func measurementOverridesEstimate() {
        var login = FrameRateRegistration()
        _ = login.accepts(25, from: .estimated)
        _ = login.accepts(24, from: .estimated)
        let step4 = login.accepts(50, from: .estimated)
        #expect(!step4)

        let step5 = login.accepts(50, from: .measured)
        #expect(step5)
        #expect(login.rate == 50)
    }

    /// And never the other way round: The player's estimate during startup is "half the
    /// truth" — it must not overwrite the counted number.
    @Test("The estimate never overrides a measurement")
    func estimateOverridesNothing() {
        var login = FrameRateRegistration()
        _ = login.accepts(50, from: .measured)

        let step6 = login.accepts(24, from: .estimated)
        #expect(!step6)
        #expect(login.rate == 50)
    }

    /// The head of the container stands between the two: better than an estimate during
    /// startup, weaker than counted distances.
    @Test("The container header ranks between estimate and measurement")
    func headInBetween() {
        var withHead = FrameRateRegistration()
        _ = withHead.accepts(30, from: .header)
        let step7 = withHead.accepts(25, from: .estimated)
        #expect(!step7)
        let step8 = withHead.accepts(25, from: .measured)
        #expect(step8)
    }

    // MARK: - Der Hinweis auf die Systemeinstellung (U2)

    /// **The registration that has no effect.** On the device "System adjustment OFF"
    /// appears in 144 of 144 measurements, and above it every time "frame rate
    /// registered". Both are true — together they yield the information nobody asked
    /// for.
    @Test("If the rate divides 60, the switch is irrelevant")
    func dividesSixty() {
        #expect(FrameRateRegistration.dividesSixty(60))
        #expect(FrameRateRegistration.dividesSixty(30))
        #expect(!FrameRateRegistration.dividesSixty(25))
        #expect(!FrameRateRegistration.dividesSixty(50))
        #expect(!FrameRateRegistration.dividesSixty(24))
        // 60/59.94 is 1.001 — one second per 1000 out of step.
        #expect(!FrameRateRegistration.dividesSixty(59.94))
        #expect(!FrameRateRegistration.dividesSixty(0))
    }

    /// The hint comes only if it explains something: Rate does not match **and** the
    /// switch is off.
    @Test("The hint appears only when it explains something")
    func systemHint() {
        #expect(FrameRateRegistration.needsSystemNotice(rate: 25, adjustmentAllowed: false))
        // If the viewer allows the adjustment, the registration takes effect — no hint.
        #expect(!FrameRateRegistration.needsSystemNotice(rate: 25, adjustmentAllowed: true))
        // And at 30 Hz on 60 Hz nobody sees anything, switch or no switch.
        #expect(!FrameRateRegistration.needsSystemNotice(rate: 30, adjustmentAllowed: false))
    }
}
