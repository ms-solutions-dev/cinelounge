import Core
import Foundation
import PortalKit
import ProfileKit
import Testing

@testable import Household

/// **Self-enrollment with the person token and the sign-out that blocks it** — moved here from the
/// TV's join checks (AP58 R2), because since 2026-09-26 both live in the `Household` package
/// for TV and phone.
///
/// Through the whole integration: Every answer goes through ``PortalKit/PortalBridge`` with
/// the ``FakeConsole`` as session. What is checked is **the store afterwards**. Credentials and tokens are
/// made up and begin with `PRUEF-`.
@Suite("Self sign-in and sign-out")
@MainActor
struct SelfSignInTests {

    let keychain = InMemoryStore()
    let ledgers = InMemoryStore()
    let childProfile = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Selin", color: .lilac,
        credentials: [.portals(person: nil)])
    let max = Profile(
        identifier: Profile.Identifier(rawValue: UUID().uuidString), name: "Max", color: .moss)

    init() {
        var ledger = ProfileBook()
        ledger.create(childProfile)
        ledger.create(max)
        ledger.write(in: ledgers)
    }

    static let childPerson =
        ##"{"id":"selin","name":"Selin","role":"adult","color":"#9871C4","adult":true}"##
    static let enrollOK = Data(
        ##"{"device_token":"PRUEF-merkmal-enroll","person":\##(childPerson)}"##.utf8)
    static let enrollUnknown = Data(
        ##"{"error":{"code":"enroll.unknown_mark","values":{}}}"##.utf8)

    func isMarkedItself(_ line: FakeConsole.Wire, kind: DeviceKind = .tv) -> SelfSignIn {
        SelfSignIn(
            basis: line.basis, session: FakeConsole.session, keychain: keychain,
            ledgerStore: ledgers, deviceName: "Test rig", kind: kind)
    }

    static func bodyContent(_ request: FakeConsole.Request) throws -> [String: Any] {
        let data = try #require(request.bodyContent)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    var ledger: ProfileBook { ProfileBook.read(from: ledgers) }

    func profile(_ identifier: Profile.Identifier) -> Profile? {
        ledger.profile.first { $0.identifier == identifier }
    }

    func makeToken(_ value: String, forItem profile: Profile) -> PersonMarker {
        let tag = PersonMarker(value: value)!
        PortalMarkerSlot(keychain).create(tag, forItem: profile.identifier)
        return tag
    }

    @Test("The decision as a board")
    func board() {
        // After a sign-out exactly this token is blocked, another one is not.
        #expect(
            !SelfSignIn.expectedValue(
                .open, hasTrait: false, tag: "m", used: nil, failed: nil, signedOut: "m"))
        #expect(
            SelfSignIn.expectedValue(
                .open, hasTrait: false, tag: "neu", used: nil, failed: nil, signedOut: "m"))
        // Opening: only without a credential.
        #expect(
            SelfSignIn.expectedValue(
                .open, hasTrait: false, tag: "m", used: nil, failed: nil, signedOut: nil))
        #expect(
            !SelfSignIn.expectedValue(
                .open, hasTrait: true, tag: "m", used: "x", failed: nil, signedOut: nil))
        // Rejected: without a credential yes; with a credential only for a token other than the one used.
        #expect(
            SelfSignIn.expectedValue(
                .dismissed, hasTrait: false, tag: "m", used: nil, failed: nil, signedOut: nil))
        #expect(
            SelfSignIn.expectedValue(
                .dismissed, hasTrait: true, tag: "neu", used: "alt", failed: nil, signedOut: nil
            ))
        #expect(
            !SelfSignIn.expectedValue(
                .dismissed, hasTrait: true, tag: "alt", used: "alt", failed: nil, signedOut: nil
            ))
        #expect(
            !SelfSignIn.expectedValue(
                .dismissed, hasTrait: true, tag: "m", used: nil, failed: nil, signedOut: nil))
        // A failed token never again.
        #expect(
            !SelfSignIn.expectedValue(
                .open, hasTrait: false, tag: "m", used: nil, failed: "m", signedOut: nil))
        #expect(
            !SelfSignIn.expectedValue(
                .dismissed, hasTrait: true, tag: "m", used: "alt", failed: "m", signedOut: nil)
        )
    }

    @Test("A new device with a token in the profile signs itself in on opening")
    func newDevice() async throws {
        let tag = makeToken("PRUEF-marke-selin", forItem: childProfile)
        let line = FakeConsole.setUp(["/device/enroll": (200, Self.enrollOK)])

        #expect(await isMarkedItself(line).attempts(.open) == .signedIn)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-enroll")
        #expect(JoinNote(keychain).used == tag.digest)
        #expect(profile(childProfile.identifier)?.portalPerson == "selin")
        let mainContent = try Self.bodyContent(try #require(line.requestJoin.first))
        #expect(mainContent["mark"] as? String == "PRUEF-marke-selin")
        #expect(mainContent["kind"] as? String == "tv")

        // Already signed in: no request at the next opening.
        #expect(await isMarkedItself(line).attempts(.open) == .notNeeded)
        #expect(line.requestJoin.count == 1)
    }

    /// **Widerruf → neue Marke → stille Neuanmeldung genau einmal.**
    @Test("After a revocation the device signs in again with the new token exactly once")
    func revoke() async {
        let old = PersonMarker(value: "PRUEF-marke-alt")!
        DeviceTrait.save("PRUEF-merkmal-tot", to: keychain)
        JoinNote(keychain).rememberUsed(old)
        _ = makeToken("PRUEF-marke-neu", forItem: childProfile)
        let line = FakeConsole.setUp(["/device/enroll": (200, Self.enrollOK)])

        // Nothing happens on opening — the credential is there after all.
        #expect(await isMarkedItself(line).attempts(.open) == .notNeeded)
        #expect(line.requestJoin.isEmpty)

        #expect(await isMarkedItself(line).attempts(.dismissed) == .signedIn)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-enroll")
        // A second `auth.required` with the same token is not a new occasion.
        #expect(await isMarkedItself(line).attempts(.dismissed) == .notNeeded)
        #expect(line.requestJoin.count == 1)
    }

    /// As long as the new token has not arrived yet, an attempt achieves nothing.
    @Test("Revoked, but the old token still in the profile: no attempt")
    func revocationWithoutNewToken() async {
        let old = makeToken("PRUEF-marke-alt", forItem: childProfile)
        DeviceTrait.save("PRUEF-merkmal-tot", to: keychain)
        JoinNote(keychain).rememberUsed(old)
        let line = FakeConsole.setUp(["/device/enroll": (200, Self.enrollOK)])
        #expect(await isMarkedItself(line).attempts(.dismissed) == .notNeeded)
        #expect(line.requestJoin.isEmpty)
    }

    /// **Invalid token → no loop.**
    @Test("A rejected token is never tried again")
    func invalidToken() async {
        let tag = makeToken("PRUEF-marke-tot", forItem: childProfile)
        let line = FakeConsole.setUp(["/device/enroll": (401, Self.enrollUnknown)])

        #expect(await isMarkedItself(line).attempts(.open) == .failed)
        #expect(JoinNote(keychain).failed == tag.digest)
        #expect(await isMarkedItself(line).attempts(.open) == .notNeeded)
        #expect(await isMarkedItself(line).attempts(.dismissed) == .notNeeded)
        #expect(line.requestJoin.count == 1)
        #expect(DeviceTrait.load(from: keychain) == nil)
    }

    /// A network error is not a dead token — at the next occasion there is **one** attempt again.
    @Test("A network error does not lock the token")
    func networkErrorDoesNotBlock() async {
        _ = makeToken("PRUEF-marke-selin", forItem: childProfile)
        let line = FakeConsole.setUp([:])
        #expect(await isMarkedItself(line).attempts(.open) == .failed)
        #expect(JoinNote(keychain).failed == nil)
        #expect(await isMarkedItself(line).attempts(.open) == .failed)
        #expect(line.requestJoin.count == 2, "one per occasion")
    }

    @Test("A child profile, a profile without portals and one without a token sign in nothing")
    func notNeeded() async {
        let line = FakeConsole.setUp(["/device/enroll": (200, Self.enrollOK)])
        #expect(await isMarkedItself(line).attempts(.open) == .notNeeded, "without token")

        var ledger = self.ledger
        ledger.update(childProfile.identifier) { $0.kind = .kind }
        ledger.write(in: ledgers)
        _ = makeToken("PRUEF-marke-selin", forItem: childProfile)
        #expect(await isMarkedItself(line).attempts(.open) == .notNeeded, "child")

        ledger.update(childProfile.identifier) { profile in
            profile.kind = .adult
            profile.remove(.portals(person: nil))
        }
        ledger.write(in: ledgers)
        #expect(await isMarkedItself(line).attempts(.open) == .notNeeded, "without portal request")
        #expect(line.requestJoin.isEmpty)
    }

    /// **B3:** Sign out, then open the portals — there must be **no** silent
    /// re-enrollment. Via ``PortalSignOut``, that is, the view's path.
    @Test("After signing out the device does not quietly sign in again")
    func signOutStaysSignedOut() async {
        _ = makeToken("PRUEF-marke-selin", forItem: childProfile)
        let line = FakeConsole.setUp([
            "/device/enroll": (200, Self.enrollOK),
            "/logout": (200, Data("{}".utf8)),
        ])
        #expect(await isMarkedItself(line).attempts(.open) == .signedIn)

        await PortalSignOut.notify(
            from: false, basis: line.basis, session: FakeConsole.session,
            keychain: keychain, ledgerStore: ledgers)
        #expect(DeviceTrait.load(from: keychain) == nil)
        #expect(await isMarkedItself(line).attempts(.open) == .notNeeded)
        #expect(await isMarkedItself(line).attempts(.dismissed) == .notNeeded)
        #expect(line.requestJoin.map(\.route) == ["/device/enroll", "/logout"])

        // A new approval lifts the block.
        let tag = PersonMarker(value: "PRUEF-marke-selin")!
        JoinNote(keychain).rememberUsed(tag)
        #expect(JoinNote(keychain).signedOut == nil)
    }

    /// **B3, second part:** ten devices on the token — do not ask again at every opening.
    @Test("409 too_many_devices locks the token like an unknown one")
    func tooManyDevices() async {
        _ = makeToken("PRUEF-marke-selin", forItem: childProfile)
        let line = FakeConsole.setUp([
            "/device/enroll": (
                409, Data(##"{"error":{"code":"enroll.too_many_devices","values":{"max":"10"}}}"##.utf8)
            )
        ])
        #expect(await isMarkedItself(line).attempts(.open) == .failed)
        #expect(await isMarkedItself(line).attempts(.open) == .notNeeded)
        #expect(line.requestJoin.count == 1)
    }

    /// **The setup names its profile** (AP88 §2.1) — the credential lands in the active
    /// profile's compartment, so a different one signs nothing in. Counter-check: without the
    /// identifier guard in `attempts(_:forItem:)` the second call signs in Selin for Max.
    @Test("The setup occasion signs in only the profile it names, and only once")
    func setupOccasion() async {
        _ = makeToken("PRUEF-marke-selin", forItem: childProfile)
        let line = FakeConsole.setUp(["/device/enroll": (200, Self.enrollOK)])

        #expect(await isMarkedItself(line).attempts(.setup, forItem: max.identifier) == .notNeeded)
        #expect(line.requestJoin.isEmpty)
        #expect(await isMarkedItself(line).attempts(.setup, forItem: childProfile.identifier) == .signedIn)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-enroll")
        #expect(await isMarkedItself(line).attempts(.setup, forItem: childProfile.identifier) == .notNeeded)
        #expect(line.requestJoin.count == 1)
        #expect(
            !SelfSignIn.expectedValue(
                .setup, hasTrait: false, tag: "m", used: nil, failed: "m", signedOut: nil))
    }

    /// **Self-enrollment makes the device its own** — the same store on both devices
    /// (``DeviceSignIn/create(_:own:in:)``), even with a borrowed header in front.
    @Test(
        "After self sign-in: trait, no loaner head, own — on the phone as on the TV",
        arguments: [DeviceKind.tv, .web])
    func ownAfterSelfSignIn(kind: DeviceKind) async throws {
        _ = makeToken("PRUEF-marke-selin", forItem: childProfile)
        DeviceTrait.saveProfile("irgendwer", to: keychain)
        let line = FakeConsole.setUp(["/device/enroll": (200, Self.enrollOK)])
        #expect(await isMarkedItself(line, kind: kind).attempts(.open) == .signedIn)
        #expect(DeviceTrait.own(in: keychain))
        #expect(DeviceTrait.profile(from: keychain) == nil)
        let mainContent = try Self.bodyContent(try #require(line.requestJoin.first))
        #expect(mainContent["kind"] as? String == kind.rawValue)
    }
}
