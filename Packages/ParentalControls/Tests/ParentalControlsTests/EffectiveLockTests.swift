import Core
import Testing

@testable import ParentalControls

/// **"Block what is not understood" from profile and device** — thread G, 2026-09-25.
///
/// The finding: ``UnrecognizedLock/read(from:forItem:)`` also read a **profile** without
/// an entry as "yes". With "either one blocks", the device switch "off" then
/// never took effect once a profile was active.
@Suite("The effective lock for unrecognized ratings")
struct EffectiveLockTests {

    /// **The case in question:** The device explicitly says no, the profile says nothing.
    @Test("Device off and profile without an entry does not lock")
    func deviceFromProfileWithout() {
        let bucket = InMemoryStore()
        UnrecognizedLock.write(false, in: bucket, forItem: nil)

        #expect(UnrecognizedLock.own(from: bucket, forItem: "kind") == nil)
        #expect(UnrecognizedLock.applicable(from: bucket, forItem: "kind") == false)
    }

    @Test("An explicit yes on the profile locks, even if the device says no")
    func profileYes() {
        let bucket = InMemoryStore()
        UnrecognizedLock.write(false, in: bucket, forItem: nil)
        UnrecognizedLock.write(true, in: bucket, forItem: "kind")

        #expect(UnrecognizedLock.applicable(from: bucket, forItem: "kind"))
    }

    /// **The device keeps its cautious default.** A device at which nobody
    /// ever asked is undecided — and there yes applies.
    @Test("A device without an entry locks")
    func deviceWithout() {
        let bucket = InMemoryStore()

        #expect(UnrecognizedLock.applicable(from: bucket, forItem: "kind"))
        #expect(UnrecognizedLock.applicable(from: bucket, forItem: nil))
    }

    /// **A no on the profile does not open a device that says yes** — the cautious answer
    /// wins.
    @Test("A no on the profile does not loosen the device")
    func profileNoDeviceYes() {
        #expect(UnrecognizedLock.forItem(profile: false, device: true))
        #expect(UnrecognizedLock.forItem(profile: false, device: false) == false)
        #expect(UnrecognizedLock.forItem(profile: nil, device: false) == false)
        #expect(UnrecognizedLock.forItem(profile: true, device: false))
    }
}
