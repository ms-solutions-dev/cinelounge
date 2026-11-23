import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// **"Start automatically as …"** — this device's choice (AP45, 2026-09-23).
///
/// **Per device and not per profile, and therefore not in the cloud.** The TV in the
/// living room starts as "Family", the one in the child's room as a child profile. A value that
/// moved along would turn one device's setting into the other's — that is why
/// it lives in `UserDefaults` next to ``ParentalControls/ChildMode`` and not in the
/// profile ledger.
@MainActor
@Suite("This device's start choice")
struct StartChoiceTests {

    func store() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test("Without a choice nothing starts by itself")
    func withoutChoice() {
        let choice = StartChoice(store: store())
        #expect(choice.identifier == nil)
        #expect(choice.applies(in: ProfileBook()) == nil)
    }

    @Test("The choice survives a program run")
    func survived() {
        let store = store()
        var ledger = ProfileBook()
        let childProfile = Profile(name: "Selin")
        ledger.create(childProfile)

        StartChoice(store: store).set(childProfile.identifier)

        let fresh = StartChoice(store: store)
        #expect(fresh.identifier == childProfile.identifier)
        #expect(fresh.applies(in: ledger)?.name == "Selin")
    }

    /// **The case this check exists for.**
    ///
    /// A deleted profile must not determine a start. Without this line the
    /// device would face an identifier on the next power-on that belongs to nobody — and
    /// the UI would have to invent something. The same rule as in
    /// ``ProfileBook/switchTo(zu:)``: An unknown profile does not become active.
    @Test("A deleted profile no longer determines the start")
    func deleted() {
        let store = store()
        var ledger = ProfileBook()
        let childProfile = Profile(name: "Selin")
        ledger.create(childProfile)
        StartChoice(store: store).set(childProfile.identifier)

        ledger.remove(childProfile.identifier)

        let choice = StartChoice(store: store)
        // The identifier is still there — it is forgotten only when someone sets a new one.
        #expect(choice.identifier == childProfile.identifier)
        // But it no longer **applies**.
        #expect(choice.applies(in: ledger) == nil)
    }

    @Test("The choice can be withdrawn")
    func back() {
        let store = store()
        var ledger = ProfileBook()
        let childProfile = Profile(name: "Selin")
        ledger.create(childProfile)

        let choice = StartChoice(store: store)
        choice.set(childProfile.identifier)
        choice.set(nil)

        #expect(choice.identifier == nil)
        #expect(StartChoice(store: store).applies(in: ledger) == nil)
    }
}

/// **The start choice must not bypass a PIN** — AP45, 2026-09-23.
///
/// **The case that makes these checks necessary:** "Always start as a parent" is a
/// convenient setting and would be a hole if it skipped the keypad. Whoever can
/// set it is just anybody at the device — it lives in `UserDefaults` and not behind the
/// lock. A child who sets it to an adult profile and restarts the TV
/// would otherwise get in without a PIN and would have defeated the parental controls in two steps.
@MainActor
@Suite("The start choice at startup")
struct StartupTests {

    static func sharedStore() -> SecureStore { SecureStore(service: "probe.\(UUID().uuidString)") }

    @Test("An open profile is taken over at start")
    func openProfile() {
        ProfilePointer.als(nil) {
            let store = UserDefaults(suiteName: UUID().uuidString)!
            var ledger = ProfileBook()
            let family = Profile(name: "Familie")
            let childProfile = Profile(name: "Selin")
            ledger.create(family)
            ledger.create(childProfile)

            let choice = StartChoice(store: store)
            choice.set(childProfile.identifier)

            let outcome = choice.apply(
                in: &ledger, keychain: Self.sharedStore(),
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore())

            #expect(outcome?.result?.profile.name == "Selin")
            #expect(ledger.activeProfile?.name == "Selin")
        }
    }

    /// **The line that matters.**
    @Test("A profile with a PIN is not taken over at start")
    func protectedProfile() {
        ProfilePointer.als(nil) {
            let sharedStore = Self.sharedStore()
            let store = UserDefaults(suiteName: UUID().uuidString)!
            var ledger = ProfileBook()
            let kind = Profile(name: "Selin")
            let papa = Profile(name: "Max")
            ledger.create(kind)
            ledger.create(papa)
            ProfilePIN(store: sharedStore, forItem: papa.identifier).set("1234", now: Date())

            let choice = StartChoice(store: store)
            choice.set(papa.identifier)

            let outcome = choice.apply(
                in: &ledger, keychain: sharedStore,
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore())

            #expect(outcome == .pinRequired)
            // **And the ledger stays where it was** — the foreign name is not on the
            // screen while the PIN is still pending.
            #expect(ledger.activeProfile?.name == "Selin")
        }
    }

    @Test("Without a choice nothing happens at start")
    func withoutChoice() {
        ProfilePointer.als(nil) {
            var ledger = ProfileBook()
            ledger.create(Profile(name: "Familie"))
            let choice = StartChoice(store: UserDefaults(suiteName: UUID().uuidString)!)

            #expect(
                choice.apply(
                    in: &ledger, keychain: Self.sharedStore(),
                    deviceStore: InMemoryStore(), ledgerStore: InMemoryStore()) == nil)
        }
    }

    @Test("A deleted profile is not looked up at start")
    func deleted() {
        ProfilePointer.als(nil) {
            let store = UserDefaults(suiteName: UUID().uuidString)!
            var ledger = ProfileBook()
            let route = Profile(name: "Weg")
            ledger.create(route)
            ledger.create(Profile(name: "Familie"))
            StartChoice(store: store).set(route.identifier)
            ledger.remove(route.identifier)

            #expect(
                StartChoice(store: store).apply(
                    in: &ledger, keychain: Self.sharedStore(),
                    deviceStore: InMemoryStore(), ledgerStore: InMemoryStore()) == nil)
        }
    }
}
