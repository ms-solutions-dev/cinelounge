import Core
import Foundation
import ParentalControls
import Testing

@testable import FeaturesPhone

/// **Age limit and "Lock what is not understood" live where the PIN lives** —
/// AP40, 2026-09-20.
///
/// The finding from 2026-09-19: Both were in `UserDefaults` here and in the Keychain on the TV,
/// under the **same** name. The fix the TV got on 2026-09-11
/// for the age limit (AP22) therefore never arrived here — it was made in the shared
/// building block, which this side did not use.
///
/// **And it is explicitly an exception to "structure → file".** The two apply
/// together with the PIN, and the PIN survives a reinstall. If they lived in a
/// file, afterwards there would be: PIN set, child mode on, no limit — and without a limit
/// the filter lets everything through without reporting it.
@Suite("Parental controls read and write in the shared location")
@MainActor
struct ParentalControlsStoreTests {

    private func store(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: "test.\(name).\(UUID().uuidString)")!
    }

    @Test("What is set here is found by the TV's reader")
    func writesWhereTVReads() {
        let keychain = InMemoryStore()
        let state = ParentalControlsState(store: store("set"), keychain: keychain)

        state.set(limit: .from12)
        state.set(blocksUnrecognized: false)

        // Exactly the readers the TV uses.
        #expect(AgeLimit.read(from: keychain) == .from12)
        #expect(UnrecognizedLock.read(from: keychain) == false)
    }

    @Test("A limit from the old store is carried over")
    func adoptsOldLimit() {
        let old = store("adoption")
        old.set(16, forKey: "childLock.ageLimit")
        old.set(false, forKey: "childLock.blockUnknown")

        let keychain = InMemoryStore()
        ParentalControlsState(store: old, keychain: keychain).adoptFromStore()

        #expect(AgeLimit.read(from: keychain) == .from16)
        #expect(UnrecognizedLock.read(from: keychain) == false)
    }

    /// **The younger value wins, and it sits in the Keychain.**
    ///
    /// That is where what this app wrote or what a handoff brought ends up —
    /// both are younger than the old entry. Overwriting a set limit with an older one
    /// would mean loosening parental controls without anyone seeing it.
    @Test("An existing value is not overwritten by an old one")
    func overwritesNothing() {
        let old = store("precedence")
        old.set(6, forKey: "childLock.ageLimit")

        let keychain = InMemoryStore()
        AgeLimit.write(.from18, in: keychain)

        ParentalControlsState(store: old, keychain: keychain).adoptFromStore()

        #expect(AgeLimit.read(from: keychain) == .from18)
    }

    /// **Without an entry, what is not understood locks** — the undecided answer is the
    /// cautious one for parental controls.
    @Test("Without an entry, unrecognized content is blocked")
    func defaultIsYes() {
        #expect(UnrecognizedLock.read(from: InMemoryStore()))
    }
}

// MARK: - The device identifier (AP40, 20.09.2026)

/// **The media server must not see a new device.**
///
/// The ID was `app.deviceID` on the phone and `device.id` on the TV. Anyone who simply
/// switches over finds nothing, rolls a fresh one — and Jellyfin keeps sessions per device:
/// the old sign-in would stay there as a device that never exists again.
@Suite("The device identifier survives the rename")
struct DeviceIdentifierTests {

    private func store(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: "test.device.\(name).\(UUID().uuidString)")!
    }

    @Test("The old name is adopted instead of being rolled anew")
    func adoptsOldName() {
        let defaults = store("adoption")
        defaults.set("the-old-identifier", forKey: "app.deviceID")

        #expect(DeviceIdentity.adopt(from: "app.deviceID", in: defaults))
        #expect(DeviceIdentity.id(in: defaults) == "the-old-identifier")
    }

    /// **Never overwrite:** An ID that has already been assigned is known to the server,
    /// and the older one next to it would be a second device.
    @Test("An existing identifier is left untouched")
    func overwritesNothing() {
        let defaults = store("precedence")
        defaults.set("the-old", forKey: "app.deviceID")
        let existing = DeviceIdentity.id(in: defaults)

        #expect(DeviceIdentity.adopt(from: "app.deviceID", in: defaults) == false)
        #expect(DeviceIdentity.id(in: defaults) == existing)
    }

    /// A fresh device has nothing to adopt — and still gets an ID
    /// that stays the same across program runs.
    @Test("Without an old entry nothing happens, and the new identifier stays stable")
    func freshDevice() {
        let defaults = store("fresh")

        #expect(DeviceIdentity.adopt(from: "app.deviceID", in: defaults) == false)
        let first = DeviceIdentity.id(in: defaults)
        #expect(DeviceIdentity.id(in: defaults) == first)
    }
}
