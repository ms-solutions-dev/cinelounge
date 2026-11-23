import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **Whoever removes the active profile does not land in a protected one** (check
/// 2026-09-25 evening, finding 1).
///
/// Counter-check: with the old succession from ``ProfileKit/ProfileBook/remove(_:)``, a parent profile
/// is afterwards active without a PIN, and another profile stays locked out.
@MainActor
@Suite("Removing the active profile and the profile PIN")
struct ProfileRemovalLatchTests {

    struct Setup {
        let model: ProfileModel
        let store: InMemoryStore
        let keychain: SecureStore
    }

    func setup() -> Setup {
        let store = InMemoryStore()
        let keychain = SecureStore(service: "probe.\(UUID().uuidString)")
        let model = ProfileModel(
            keychain: keychain, store: store, cloud: { nil },
            startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
        return Setup(model: model, store: store, keychain: keychain)
    }

    /// **The case from the check:** a parent profile has a PIN, the child sits in front and removes
    /// their own profile. Nobody gets through without a PIN, so nobody sits in front, and the
    /// next start asks "Who's watching?".
    @Test("Only a protected successor: nobody becomes active, the startup asks")
    func noneWithoutPin() throws {
        let s = setup()
        try ProfilePointer.als(nil) {
            let papa = try #require(
                s.model.create(name: "Papa", color: .turquoise, kind: .adult, avatar: nil))
            let kind = try #require(
                s.model.create(name: "Kind", color: .moss, kind: .adult, avatar: nil))
            defer { ProfilePIN(store: s.keychain, forItem: papa).forget() }
            #expect(
                ProfilePINMaintenance.set(
                    "1234", old: nil, forItem: papa, keychain: s.keychain, cloud: nil,
                    now: Date()) == .isSet)
            #expect(s.model.switchTo(zu: kind).result != nil)

            #expect(s.model.remove(kind) == .removed)

            #expect(s.model.active == nil, "Dad (PIN) must not become active without a PIN")
            #expect(ProfileBook.read(from: s.store).active == nil)
            #expect(ProfilePointer.active == nil, "the store falls back to the device")
            #expect(s.model.launchGate == .whoIsWatching)
            #expect(s.model.switchTo(zu: papa).result == nil, "the latch still holds")
            #expect(s.model.switchTo(zu: papa, pin: "1234").result != nil)
        }
    }

    /// **If an open profile stands behind the protected one, it moves up** — via the same
    /// switch that startup takes.
    @Test("An open profile behind the protected one moves up")
    func openOnesMoveUp() throws {
        let s = setup()
        try ProfilePointer.als(nil) {
            let papa = try #require(
                s.model.create(name: "Papa", color: .turquoise, kind: .adult, avatar: nil))
            let kind = try #require(
                s.model.create(name: "Kind", color: .moss, kind: .adult, avatar: nil))
            let grandmother = try #require(
                s.model.create(name: "Oma", color: .turquoise, kind: .adult, avatar: nil))
            defer { ProfilePIN(store: s.keychain, forItem: papa).forget() }
            #expect(
                ProfilePINMaintenance.set(
                    "1234", old: nil, forItem: papa, keychain: s.keychain, cloud: nil,
                    now: Date()) == .isSet)
            #expect(s.model.switchTo(zu: kind).result != nil)

            #expect(s.model.remove(kind) == .removed)

            #expect(s.model.active == grandmother)
            #expect(ProfileBook.read(from: s.store).active == grandmother)
            #expect(ProfilePointer.active == grandmother.rawValue)
        }
    }
}
