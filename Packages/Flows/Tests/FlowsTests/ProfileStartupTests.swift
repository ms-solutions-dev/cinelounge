import Core
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit
import Testing

@testable import Flows

/// **The startup of the profiles — one sequence, two sets of switches** (AP58 R2, finding P5).
///
/// Until R2 the sequence lived on the TV in the app target (untested) and on the phone in
/// `SetupState`, with three silent differences. Now they are values in
/// ``ProfileStartup/Steps``; what is checked is that every value takes effect and the sequence is right.
///
/// Counter-check: if `LegacyData.cleanUp` comes before `ProfileStates.adopt`,
/// ``tvTakesOverThenCleansUp()`` turns red (no evidence, nothing cleared); without the guard in
/// ``ProfileKit/ProfileSwitch`` ``startChoiceNeverViaPin()``.
@MainActor
@Suite("The startup of the profiles")
struct ProfileStartupTests {

    static let server = URL(string: "https://media.example:8096")!

    @MainActor
    struct Device {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let ledger = InMemoryStore()
        let standard = UserDefaults(suiteName: "probe.\(UUID().uuidString)")!

        func fetch(_ steps: ProfileStartup.Steps, listen: [String] = ["iptv"]) {
            ProfileStartup.fetch(
                steps,
                device: .init(
                    channelLists: listen, wantsPortals: false, fallbackName: "Home", version: "1.0"),
                keychain: secureStore, ledgerStore: ledger, startStore: standard,
                legacyStore: standard)
        }

        func value(_ key: String) -> String? { try? secureStore.value(for: key) }
    }

    /// A device with one signed-in account and a movie in progress in the legacy data.
    func withLegacyData() throws -> Device {
        let g = Device()
        let credential = ServerCredentials(
            serverURL: Self.server, userID: "alex", username: "Alex", accessToken: "token")
        try g.secureStore.memorize(credential)
        try g.secureStore.saveCredentials(credential)
        try g.secureStore.set(
            #"{"film":{"position":4350,"duration":7200,"watched":false,"favorite":false}}"#,
            for: "vod.memory.v1")
        StateTransfer.fromDevice(listen: ["iptv"], from: g.secureStore, in: g.ledger)
        return g
    }

    @Test("TV: first the state into the profile, then the clean cut")
    func tvTakesOverThenCleansUp() throws {
        let g = try withLegacyData()
        ProfilePointer.als(nil) { g.fetch(.tv) }
        let alex = try #require(ProfileBook.read(from: g.ledger).profile.first)
        #expect(
            StillLedger.read(from: g.ledger, forItem: alex.identifier.rawValue).state.titlePositions["film"]?
                .location == 4350)
        #expect(g.value("vod.memory.v1") == nil, "cleared because the proof is in the profile")
    }

    /// **No states on the phone** — and with that no clearing of what has no evidence in the
    /// profile. The difference is a value, and it takes effect.
    @Test("Phone: without states the legacy data stays until it is proven")
    func phoneWithoutStates() throws {
        let g = try withLegacyData()
        ProfilePointer.als(nil) { g.fetch(.phone) }
        let alex = try #require(ProfileBook.read(from: g.ledger).profile.first)
        #expect(
            StillLedger.read(from: g.ledger, forItem: alex.identifier.rawValue).state.titlePositions.isEmpty)
        #expect(g.value("vod.memory.v1") != nil)
    }

    /// **The device lock becomes the start profile** (AP59 N4) — and without a child profile one is
    /// created, with the accesses of the active profile.
    @Test("Move: device lock starts in the child profile, profile PINs drop", arguments: [true, false])
    func parentalControlsMigration(tv: Bool) throws {
        let g = Device()
        var ledger = ProfileBook()
        let parent = Profile(identifier: .init(rawValue: "k-parent"), name: "Parent")
        ledger.create(parent)
        ledger.switchTo(zu: parent.identifier)
        ledger.write(in: g.ledger)
        ProfilePIN(store: g.secureStore, forItem: parent.identifier).set("1234", now: Date())
        g.standard.set(true, forKey: ChildMode.key)

        ProfilePointer.als(nil) { g.fetch(tv ? .tv : .phone) }

        let after = ProfileBook.read(from: g.ledger)
        let kind = try #require(after.profile.first { $0.kind == .kind })
        #expect(after.active == kind.identifier, "the device starts in the child profile")
        #expect(!g.standard.bool(forKey: ChildMode.key), "the device lock is off")
        #expect(
            !ProfilePIN(store: g.secureStore, forItem: parent.identifier).isSet, "the profile PIN is gone")
        #expect(g.standard.bool(forKey: ParentalControlsMigration.done))
    }

    @Test("Move: an existing child profile is taken, no second one is created")
    func parentalControlsMigrationPresent() throws {
        let g = Device()
        var ledger = ProfileBook()
        let parent = Profile(identifier: .init(rawValue: "k-parent"), name: "Parent")
        let kind = Profile(identifier: .init(rawValue: "k-kind"), name: "Child", kind: .kind)
        ledger.create(parent)
        ledger.create(kind)
        ledger.switchTo(zu: parent.identifier)
        ledger.write(in: g.ledger)
        g.standard.set(true, forKey: ChildMode.key)

        ProfilePointer.als(nil) { g.fetch(.tv) }

        let after = ProfileBook.read(from: g.ledger)
        #expect(after.profile.filter { $0.kind == .kind }.count == 1)
        #expect(after.active == kind.identifier)
    }

    /// **"Start automatically as …" never goes through a PIN on either device.**
    @Test("The start choice switches only to an open profile", arguments: [true, false])
    func startChoiceNeverViaPin(tv: Bool) throws {
        let g = Device()
        var ledger = ProfileBook()
        let parent = Profile(identifier: .init(rawValue: "k-parent"), name: "Parent")
        let kind = Profile(identifier: .init(rawValue: "k-kind"), name: "Child")
        ledger.create(kind)
        ledger.create(parent)
        ledger.switchTo(zu: kind.identifier)
        ledger.write(in: g.ledger)
        ProfilePIN(store: g.secureStore, forItem: parent.identifier).set("1234", now: Date())
        StartChoice(store: g.standard).set(parent.identifier)
        // The migration (AP59 N4) deleted the PIN on the first start — here it is about the rule
        // that continues to apply for a PIN from the cloud.
        g.standard.set(true, forKey: ParentalControlsMigration.done)

        ProfilePointer.als(nil) { g.fetch(tv ? .tv : .phone) }
        #expect(ProfileBook.read(from: g.ledger).active == kind.identifier, "the PIN holds")

        ProfilePIN(store: g.secureStore, forItem: parent.identifier).forget()
        ProfilePointer.als(nil) {
            g.fetch(tv ? .tv : .phone)
            #expect(ProfilePointer.active == parent.identifier.rawValue, "the pointer follows")
        }
        #expect(ProfileBook.read(from: g.ledger).active == parent.identifier)
    }

    /// **An old sign-in on the phone belongs to its person, on the TV it does not.**
    @Test("Only the phone adds the own-flag afterwards")
    func ownOnlyOnPhone() {
        for (steps, own) in [(ProfileStartup.Steps.phone, true), (.tv, false)] {
            let g = Device()
            DeviceTrait.save("PRUEF-merkmal", to: g.secureStore)
            ProfilePointer.als(nil) { g.fetch(steps) }
            #expect(DeviceTrait.own(in: g.secureStore) == own)
        }
    }
}
