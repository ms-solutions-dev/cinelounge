import Core
import Foundation
import Testing

@testable import ProfileKit

/// **The profile follows the account — via the same switch as on the TV** (AP58 R2, P1).
///
/// Until R2 the phone had a rebuild of its own (`Profilfolge`): guards twice, no
/// portal header, no emptied session. What is checked here is the shared version
/// ``ProfileSwitch/episode(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``.
///
/// Counter-check: Without ``ProfileSwitch/lock(_:pinStore:pin:)`` in the core
/// ``latchBeforeAll()`` turns red — and with it `ProfilePinPhoneTests` on the
/// phone and `ProfileSwitchTests` here.
@Suite("The profile follows the account")
struct AccountSwitchFollowUpTests {

    static let server = URL(string: "https://jellyfin.beispiel")!

    struct Situation {
        let ledger = InMemoryStore()
        let pins = InMemoryStore()
        let device = InMemoryStore()
        let session = SecureStore(service: "probe.\(UUID().uuidString)")
        let papa: Profile
        let kind: Profile
    }

    /// Parent active, the child with their own account and portal person.
    func state() -> Situation {
        let papa = Profile(
            identifier: .init(rawValue: "k-papa"), name: "Papa",
            credentials: [
                .jellyfin(server: Self.server, userID: "u-papa", username: "Papa"),
                .portals(person: "person-papa"),
            ])
        let kind = Profile(
            identifier: .init(rawValue: "k-kind"), name: "Kind", kind: .kind,
            credentials: [
                .jellyfin(server: Self.server, userID: "u-kind", username: "Kind"),
                .portals(person: "person-kind"),
            ])
        let state = Situation(papa: papa, kind: kind)
        var ledger = ProfileBook()
        ledger.create(papa)
        ledger.create(kind)
        ledger.switchTo(zu: papa.identifier)
        ledger.write(in: state.ledger)
        for user in ["u-papa", "u-kind"] {
            try? state.session.memorize(
                ServerCredentials(
                    serverURL: Self.server, userID: user, username: user,
                    accessToken: "marke-\(user)"))
        }
        try? state.session.switchTo(server: Self.server, user: "u-papa")
        DeviceTrait.saveProfile(
            "person-papa", to: ProfileStore(state.device, forItem: papa.identifier.rawValue))
        return state
    }

    func episode(_ state: Situation, _ user: String, pin: String? = nil) -> ProfileSwitch.SwitchOutcome {
        ProfileSwitch.episode(
            account: "\(Self.server.absoluteString)|\(user)", ledgerStore: state.ledger,
            keychain: state.session, pinStore: state.pins, deviceStore: state.device,
            pin: pin)
    }

    @Test("The latch comes before book, session, header and pointer")
    func latchBeforeAll() throws {
        let l = state()
        ProfilePIN(store: l.pins, forItem: l.kind.identifier).set("4711", now: Date())
        ProfilePointer.als(l.papa.identifier.rawValue) {
            #expect(episode(l, "u-kind") == .pinRequired)
            #expect(episode(l, "u-kind", pin: "0000") == .wrongPin)
            #expect(ProfileBook.read(from: l.ledger).active == l.papa.identifier)
            #expect((try? l.session.loadCredentials())?.userID == "u-papa")
            #expect(DeviceTrait.profile(from: l.device) == "person-papa")
            #expect(ProfilePointer.active == l.papa.identifier.rawValue)

            #expect(episode(l, "u-kind", pin: "4711").result?.profile == l.kind)
            #expect(ProfileBook.read(from: l.ledger).active == l.kind.identifier)
            #expect((try? l.session.loadCredentials())?.userID == "u-kind")
            #expect(ProfilePointer.active == l.kind.identifier.rawValue)
        }
    }

    /// **The finding P1:** On the phone the portal header was never written. Now the
    /// TV's rule applies — the header follows the profile, unless the device belongs to a
    /// person.
    @Test("A shared device afterwards carries the new profile's header, a personal one none")
    func headAfterOwn() {
        let shared = state()
        ProfilePointer.als(shared.papa.identifier.rawValue) {
            #expect(episode(shared, "u-kind").result?.portalPerson == "person-kind")
        }
        // Header and marker have lived in the profile's slot since 2026-09-28.
        #expect(
            DeviceTrait.profile(from: ProfileStore(shared.device, forItem: shared.kind.identifier.rawValue))
                == "person-kind")

        let own = state()
        let childCompartment = ProfileStore(own.device, forItem: own.kind.identifier.rawValue)
        DeviceTrait.saveOwn(true, to: childCompartment)
        ProfilePointer.als(own.papa.identifier.rawValue) {
            #expect(episode(own, "u-kind").result != nil)
        }
        #expect(DeviceTrait.profile(from: childCompartment) == nil)
    }

    @Test("Without a profile for the account nothing switches; the active one stays unchanged")
    func unknownAndUnchanged() {
        let l = state()
        ProfilePointer.als(l.papa.identifier.rawValue) {
            #expect(episode(l, "u-fremd") == .unknown)
            #expect(episode(l, "u-papa") == .unchanged)
            #expect(ProfileBook.read(from: l.ledger).active == l.papa.identifier)
        }
    }

    /// **An active profile with a PIN does not ask again** — it was asked when it
    /// became active. But only if book **and** pointer say so.
    @Test("Already active means book and pointer")
    func alreadyActiveOnlyWithPointer() {
        let l = state()
        ProfilePIN(store: l.pins, forItem: l.papa.identifier).set("1234", now: Date())
        ProfilePointer.als(l.papa.identifier.rawValue) {
            #expect(episode(l, "u-papa") == .unchanged)
        }
        ProfilePointer.als(nil) {
            #expect(episode(l, "u-papa") == .pinRequired, "the pointer points elsewhere")
        }
    }

    @Test("Nobody active: the account's profile, through the same latch")
    func restore() {
        let l = state()
        var ledger = ProfileBook.read(from: l.ledger)
        ledger.clearActive()
        ledger.write(in: l.ledger)
        ProfilePIN(store: l.pins, forItem: l.kind.identifier).set("4711", now: Date())
        let account = "\(Self.server.absoluteString)|u-kind"
        ProfilePointer.als(nil) {
            #expect(ProfileSwitch.restorable(account: account, ledgerStore: l.ledger) == l.kind)
            #expect(
                ProfileSwitch.lock(account: account, ledgerStore: l.ledger, pinStore: l.pins)
                    == l.kind)
            #expect(episode(l, "u-kind") == .pinRequired)
        }
    }
}
