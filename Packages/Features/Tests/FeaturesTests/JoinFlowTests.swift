import Core
import Flows
import Foundation
import Household
import PortalKit
import ProfileKit
import SourceProbe
import Styling
import Testing

@testable import Features

/// The app side of AP47 — **request, approval and self-sign-in, without a server.**
///
/// **Through the whole integration and not past the reader**, as in `JoinTests`: Every
/// response goes through ``PortalKit/PortalBridge`` with a stub as the session. What is
/// checked is not the response but **the store afterwards** — an "approved" after which the
/// credential or token is not where the app looks for it would look like success on
/// screen. Credentials and tokens are made up and start with `PRUEF-`.
@Suite("Joining in the app")
@MainActor
struct JoinFlowTests {

    // ── Werkzeug ─────────────────────────────────────────────────────────────

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

    static func approved(tag: String?) -> Data {
        let field = tag.map { ##","person_mark":"\##($0)""## } ?? ""
        return Data(
            ##"{"state":"approved","device_token":"PRUEF-merkmal-join"\##(field),"person":\##(childPerson)}"##
                .utf8)
    }

    static let enrollOK = Data(
        ##"{"device_token":"PRUEF-merkmal-enroll","person":\##(childPerson)}"##.utf8)
    static let enrollUnknown = Data(
        ##"{"error":{"code":"enroll.unknown_mark","values":{}}}"##.utf8)

    func requester(_ line: FakeConsole.Wire) -> JoinRequester {
        JoinRequester(
            basis: line.basis, session: FakeConsole.session, keychain: keychain,
            ledgerStore: ledgers, deviceName: "Apple TV Prüfstand", kind: .tv,
            lookUp: { _ in nil }, colorValue: ProfileBrand.value)
    }

    func isMarkedItself(_ line: FakeConsole.Wire) -> SelfSignIn {
        SelfSignIn(
            basis: line.basis, session: FakeConsole.session, keychain: keychain,
            ledgerStore: ledgers, deviceName: "Apple TV Prüfstand", kind: .tv)
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

    // ── Anfragen ─────────────────────────────────────────────────────────────

    @Test("The request carries the profile's name and colour and remembers who asked")
    func requestJoin() async throws {
        let line = FakeConsole.setUp([
            "/join": (
                202,
                Data(##"{"request":"khfsxz4y4fhrybtx6tutx2","state":"pending","expires_in_s":604800}"##.utf8)
            )
        ])
        let state = await requester(line).location(forItem: childProfile)
        #expect(state == .waiting(remainingSeconds: 604_800))

        let sent = try #require(line.requestJoin.first)
        let mainContent = try Self.bodyContent(sent)
        #expect(mainContent["name"] as? String == "Selin")
        #expect(mainContent["color"] as? String == "#9871C4")
        #expect(mainContent["want"] as? [String] == ["portals"])
        #expect(mainContent["kind"] as? String == "tv")

        let pending = try #require(JoinNote(keychain).openRequest)
        #expect(pending.request == "khfsxz4y4fhrybtx6tutx2")
        #expect(pending.profile == childProfile.identifier)
    }

    /// **The server throttles to three per hour** — opening the screen twice does not ask
    /// twice.
    @Test("An open request is not made again")
    func noSecondRequest() async {
        JoinNote(keychain).rememberRequest("abc", forItem: childProfile.identifier)
        let line = FakeConsole.setUp([
            "/join/abc": (200, Data(##"{"state":"pending","expires_in_s":100}"##.utf8))
        ])
        let state = await requester(line).location(forItem: childProfile)
        #expect(state == .waiting(remainingSeconds: 100))
        #expect(line.requestJoin.map(\.route) == ["/join/abc"])
    }

    // ── The outputs ───────────────────────────────────────────────────────────

    /// **The guard this is about:** approved means the credential is in the Keychain, the
    /// token is in the slot of the **requesting** profile, and the portal access carries the
    /// server person — even if a different profile is active by now.
    @Test("Approved: trait in the Keychain, mark and server person in the asking profile")
    func approvedStores() async throws {
        JoinNote(keychain).rememberRequest("abc", forItem: childProfile.identifier)
        DeviceTrait.saveProfile("irgendwer", to: keychain)
        var other = ledger
        other.switchTo(zu: max.identifier)
        other.write(in: ledgers)

        let line = FakeConsole.setUp([
            "/join/abc": (200, Self.approved(tag: "PRUEF-marke-selin"))
        ])
        let state = await requester(line).queryPending()

        #expect(state == .approved(name: "Selin", withTag: true))
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-join")
        #expect(DeviceTrait.profile(from: keychain) == nil, "the device now belongs to Selin")
        #expect(
            PortalMarkerSlot(keychain).tag(forItem: childProfile.identifier)?.value == "PRUEF-marke-selin")
        #expect(PortalMarkerSlot(keychain).tag(forItem: max.identifier) == nil)
        #expect(profile(childProfile.identifier)?.portalPerson == "selin")
        #expect(profile(max.identifier)?.wantsPortals == false)
        #expect(JoinNote(keychain).openRequest == nil)
        let tag = try #require(PersonMarker(value: "PRUEF-marke-selin"))
        #expect(JoinNote(keychain).used == tag.digest)
    }

    /// **A child gets no token** — and the app does not expect one either.
    @Test("Approved as a child: trait yes, mark no, and the sentence says so")
    func approvedChild() async {
        JoinNote(keychain).rememberRequest("abc", forItem: childProfile.identifier)
        let line = FakeConsole.setUp(["/join/abc": (200, Self.approved(tag: nil))])
        let state = await requester(line).queryPending()
        #expect(state == .approved(name: "Selin", withTag: false))
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-join")
        #expect(PortalMarkerSlot(keychain).tag(forItem: childProfile.identifier) == nil)
        #expect(JoinNote(keychain).used == nil)
    }

    @Test(
        "Rejected and expired forget the request, throttled does not",
        arguments: [
            (
                404, ##"{"error":{"code":"\##("join" + ".unknown")","values":{}}}"##, RequestState.expired,
                false
            ),
            (200, ##"{"state":"declined"}"##, RequestState.rejected, false),
            (
                429, ##"{"error":{"code":"join.too_often","values":{"seconds":"120"}}}"##,
                RequestState.throttled(seconds: 120), true
            ),
            (
                200, ##"{"state":"pending","expires_in_s":5}"##, RequestState.waiting(remainingSeconds: 5),
                true
            ),
        ])
    func outcomes(status: Int, raw: String, expected: RequestState, remains: Bool) async {
        JoinNote(keychain).rememberRequest("abc", forItem: childProfile.identifier)
        let line = FakeConsole.setUp(["/join/abc": (status, Data(raw.utf8))])
        #expect(await requester(line).queryPending() == expected)
        #expect((JoinNote(keychain).openRequest != nil) == remains)
        #expect(DeviceTrait.load(from: keychain) == nil)
    }

    /// A network error says nothing about the request — it stays remembered.
    @Test("A network error does not forget the request")
    func networkError() async {
        JoinNote(keychain).rememberRequest("abc", forItem: childProfile.identifier)
        let line = FakeConsole.setUp([:])
        guard case .failed = await requester(line).queryPending() else {
            Issue.record("expected failed")
            return
        }
        #expect(JoinNote(keychain).openRequest != nil)
    }

    // ── Sign-in by another route (check 2026-09-27, Portale B1) ─────────────
    //
    // Counter-check: Without the `mayReplace` latch in `queryPending()`,
    // ``lateApprovalDiscarded()`` goes red; without the signed-in branch in `afterState`,
    // ``signInEndsWaiting()`` goes red.

    /// **The finding:** The shared TV was paired by code while a request was running. A late
    /// pickup of the approval replaced its credential and made it "its own".
    @Test("A late approval does not overwrite a trait set in the meantime")
    func lateApprovalDiscarded() async {
        JoinNote(keychain).rememberRequest("abc", forItem: childProfile.identifier)
        DeviceTrait.save("PRUEF-merkmal-wohnzimmer", to: keychain)
        DeviceTrait.saveProfile("papa", to: keychain)
        let line = FakeConsole.setUp([
            "/join/abc": (200, Self.approved(tag: "PRUEF-marke-selin"))
        ])
        #expect(await requester(line).queryPending() == .none)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-wohnzimmer")
        #expect(DeviceTrait.profile(from: keychain) == "papa")
        #expect(!DeviceTrait.own(in: keychain))
        #expect(PortalMarkerSlot(keychain).tag(forItem: childProfile.identifier) == nil)
        #expect(profile(childProfile.identifier)?.portalPerson == nil)
        #expect(JoinNote(keychain).openRequest == nil)
    }

    /// **A rejected credential may be replaced:** The device was removed in the console, then
    /// asked for admission — the approval must then take effect.
    @Test("An approval replaces the trait that was already there when asking")
    func approvalAfterRejection() async {
        DeviceTrait.save("PRUEF-merkmal-abgewiesen", to: keychain)
        let line = FakeConsole.setUp([
            "/join": (202, Data(##"{"request":"abc","state":"pending","expires_in_s":600}"##.utf8)),
            "/join/abc": (200, Self.approved(tag: "PRUEF-marke-selin")),
        ])
        _ = await requester(line).location(forItem: childProfile)
        #expect(JoinNote(keychain).openRequest?.request == "abc")
        #expect(await requester(line).queryPending() == .approved(name: "Selin", withTag: true))
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-join")
    }

    /// **After a sign-in no loop asks any more** — on TV and phone, through
    /// ``Flows/JoinRequester/afterState(_:previous:)``.
    @Test("Signed in ends the waiting, an Approved stays")
    func signInEndsWaiting() async throws {
        let line = FakeConsole.setUp([:])
        let me = try Self.person(permissions: "{}")
        let waiting = RequestState.waiting(remainingSeconds: 30)
        let unrestricted = RequestState.approved(name: "Selin", withTag: true)
        for state: SignInState in [.signedIn(me, isBorrowed: false), .profileRequired([me])] {
            #expect(await requester(line).afterState(state, previous: waiting) == .none)
            #expect(
                await requester(line).afterState(state, previous: .throttled(seconds: 60)) == .none)
            #expect(await requester(line).afterState(state, previous: unrestricted) == unrestricted)
        }
        #expect(await requester(line).afterState(.unreachable, previous: waiting) == waiting)
        #expect(await requester(line).afterState(.notSignedIn([]), previous: waiting) == waiting)
        #expect(await requester(line).afterState(.notSignedIn([]), previous: unrestricted) == .none)
        #expect(line.requestJoin.isEmpty)
    }

    /// Not signed in and the screen knows nothing: The remembered request is queried once.
    @Test("Not signed in picks up a remembered request")
    func notSignedInAsksAgain() async {
        JoinNote(keychain).rememberRequest("abc", forItem: childProfile.identifier)
        let line = FakeConsole.setUp([
            "/join/abc": (200, Data(##"{"state":"pending","expires_in_s":5}"##.utf8))
        ])
        #expect(
            await requester(line).afterState(.notSignedIn([]), previous: .none)
                == .waiting(remainingSeconds: 5))
    }

    /// **Both settings screens go through the same rule** — neither queries the note itself
    /// any more (check 2026-09-27, Portale B1).
    @Test(
        "TV and phone derive the request state through afterState",
        arguments: [
            ("PortalSettings.swift", CodeLocation.features),
            ("PortalSettingsView.swift", CodeLocation.featuresPhone),
        ])
    func bothByState(file: String, location: CodeLocation) throws {
        let source = SourceText.strippingCommentLines(try SourceText.read(file, in: location))
        #expect(source.contains(".afterState("), "\(file) does not call afterState")
        #expect(!source.contains("openRequest"), "\(file) reads the note itself")
    }

    @Test("The waiting state keeps polling, the exits do not")
    func waitingKeepsAsking() {
        #expect(RequestState.waiting(remainingSeconds: 1).waiting)
        #expect(RequestState.throttled(seconds: nil).waiting)
        for end: RequestState in [
            .none, .rejected, .expired, .approved(name: "x", withTag: true),
            .failed("x"),
        ] {
            #expect(!end.waiting)
        }
    }

    // ── Self-sign-in ──────────────────────────────────────────────────────────
    //
    // The checks of the self-sign-in itself have been in the `Household` package since AP58 R2
    // (`SelfSignInTests`); what stays here are the ones that connect it to the TV.

    func makeToken(_ value: String, forItem profile: Profile) -> PersonMarker {
        let tag = PersonMarker(value: value)!
        PortalMarkerSlot(keychain).create(tag, forItem: profile.identifier)
        return tag
    }

    // ── Findings of the counter-check ─────────────────────────────────────────

    /// **B2:** Self-sign-in → profile switch → sign-in state. On a device that belongs to one
    /// person, the switch writes no loan header, and the state says "not borrowed" — otherwise
    /// the approval page and sign-out disappear.
    @Test("A device owned by a person does not stay borrowed after the profile switch")
    func ownDeviceNotBorrowed() async throws {
        _ = makeToken("PRUEF-marke-selin", forItem: childProfile)
        let wellKnown =
            ##"{"name":"W","version":"0.1.0","api":[1,2],"languages":[],"auth":"pin","setup_required":false,"capabilities":["household","portals","join"]}"##
        let me =
            ##"{"id":"selin","name":"Selin","role":"adult","color":"#9871C4","adult":true,"rights":{"pair_devices":true,"watch":true}}"##
        let line = FakeConsole.setUp([
            "/device/enroll": (200, Self.enrollOK),
            "/.well-known/cinelounge": (200, Data(wellKnown.utf8)),
            "/household/me": (200, Data(me.utf8)),
        ])
        // The self-sign-in runs in the profile that carries the token — the credential has been
        // there since 2026-09-28 (``Core/DeviceTrait``).
        let childSlot = ProfileStore(keychain, forItem: childProfile.identifier.rawValue)
        let signedIn = await ProfilePointer.als(childProfile.identifier.rawValue) {
            await isMarkedItself(line).attempts(.open)
        }
        #expect(signedIn == .signedIn)
        #expect(DeviceTrait.own(in: childSlot))

        let sessionKeychain = SecureStore(service: "probe.\(UUID().uuidString)")
        ProfilePointer.als(nil) {
            var ledger = self.ledger
            _ = ProfileSwitch.switchTo(
                zu: max.identifier, in: &ledger, keychain: sessionKeychain,
                deviceStore: keychain, ledgerStore: ledgers)
            _ = ProfileSwitch.switchTo(
                zu: childProfile.identifier, in: &ledger, keychain: sessionKeychain,
                deviceStore: keychain, ledgerStore: ledgers)
        }
        #expect(DeviceTrait.profile(from: childSlot) == nil)

        let state = await Household.state(
            basis: line.basis, trait: DeviceTrait.load(from: childSlot),
            profile: DeviceTrait.profile(from: childSlot), session: FakeConsole.session)
        guard case .signedIn(_, let isBorrowed) = state else {
            Issue.record("expected signed in, was \(state)")
            return
        }
        #expect(!isBorrowed)
        #expect(ApprovalRule.isVisible(state))
    }

    /// **B2, counterpart:** A shared device (without a marker) writes the header as before.
    @Test("A shared device keeps getting the loan head")
    func sharedDeviceKeepsHeader() {
        var ledger = self.ledger
        ledger.update(max.identifier) { $0.create(.portals(person: "max")) }
        ledger.write(in: ledgers)
        let sessionKeychain = SecureStore(service: "probe.\(UUID().uuidString)")
        ProfilePointer.als(nil) {
            var ledger = self.ledger
            _ = ProfileSwitch.switchTo(
                zu: max.identifier, in: &ledger, keychain: sessionKeychain,
                deviceStore: keychain, ledgerStore: ledgers)
        }
        #expect(
            DeviceTrait.profile(from: ProfileStore(keychain, forItem: max.identifier.rawValue)) == "max"
        )
    }

    /// **B4:** A child profile does not request, and an approval stores no token for it.
    @Test("A child profile does not ask and gets no mark")
    func childDoesNotAsk() async {
        var kind = childProfile
        kind.kind = .kind
        var ledger = self.ledger
        ledger.create(kind)
        ledger.write(in: ledgers)
        let line = FakeConsole.setUp([
            "/join/abc": (200, Self.approved(tag: "PRUEF-marke-kind"))
        ])
        #expect(await requester(line).location(forItem: kind) == .notForChildren)
        #expect(line.requestJoin.isEmpty)

        // If it does have a request after all (made before the switch, say), the token stays out.
        JoinNote(keychain).rememberRequest("abc", forItem: kind.identifier)
        #expect(await requester(line).queryPending() == .approved(name: "Selin", withTag: false))
        #expect(PortalMarkerSlot(keychain).tag(forItem: kind.identifier) == nil)
    }

    /// **B6:** An approval for a profile that has since been removed stores no token.
    @Test("An approval for a removed profile stores no mark under a dead identifier")
    func deadProfile() async {
        let dead = Profile.Identifier(rawValue: UUID().uuidString)
        JoinNote(keychain).rememberRequest("abc", forItem: dead)
        let line = FakeConsole.setUp([
            "/join/abc": (200, Self.approved(tag: "PRUEF-marke-selin"))
        ])
        #expect(await requester(line).queryPending() == .approved(name: "Selin", withTag: false))
        #expect(PortalMarkerSlot(keychain).tag(forItem: dead) == nil)
        #expect(DeviceTrait.load(from: keychain) == "PRUEF-merkmal-join")
    }

    /// **B8:** The throttle lets the loop sleep for one minute at most.
    @Test("The interval is 15 seconds, throttled 60 at most")
    func spacing() {
        #expect(RequestState.waiting(remainingSeconds: 10).spacing == 15)
        #expect(RequestState.throttled(seconds: nil).spacing == 15)
        #expect(RequestState.throttled(seconds: 30).spacing == 30)
        #expect(RequestState.throttled(seconds: 3600).spacing == 60)
    }

    /// **B9:** A withdrawn request does not come back through a running query.
    @Test("A follow-up request does not write back a cleared state")
    func cancel() {
        #expect(RequestState.afterInquiry(current: .none, result: .waiting(remainingSeconds: 5)) == nil)
        #expect(RequestState.afterInquiry(current: .none, result: .rejected) == nil)
        #expect(
            RequestState.afterInquiry(current: .none, result: .approved(name: "S", withTag: true))
                == .approved(name: "S", withTag: true))
        #expect(
            RequestState.afterInquiry(current: .waiting(remainingSeconds: 5), result: .rejected)
                == .rejected)
        #expect(
            RequestState.afterInquiry(current: .waiting(remainingSeconds: 5), result: .failed("x"))
                == nil)
    }

    /// **B1:** The app wires the Keychain through the one route that sets both slots —
    /// otherwise the token never ran in the app while all checks were green.
    @Test("Cloud startup attaches the Keychain through attachKeychain")
    func wiring() throws {
        let source = try SourceText.read("CloudStartup.swift", in: .tvApp)
        #expect(source.contains("let keychain = SecureStore()"))
        #expect(source.contains("attachKeychain(keychain)"))
        // **And the same Keychain as the migration keychain** (counter-check strand C, finding
        // 5): Without it, PIN and age limit would stay under the dead identifier on the first
        // iCloud contact — the checks in the package set it by hand and would not see it.
        #expect(source.contains("moveBundle: keychain"))
        #expect(source.contains("built.pinEscape = "), "Finding 6: the request is reported nowhere")
        #expect(!source.contains(".preferenceStore ="), "set individually, the other slot gets forgotten")
        #expect(!source.contains(".brandStore ="))
    }

    // ── The admin's side ──────────────────────────────────────────────────────

    static func person(permissions: String) throws -> HouseholdPerson {
        try JSONDecoder().decode(
            HouseholdPerson.self,
            from: Data(
                ##"{"id":"max","name":"Max","role":"admin","color":"#629B46","rights":\##(permissions)}"##
                    .utf8))
    }

    /// **Approval page only with the admin right** — on the right and never on the role, and
    /// never with a borrowed profile.
    @Test("The approval page appears only with pair_devices and without a loan")
    func isVisible() throws {
        let admin = try Self.person(permissions: ##"{"pair_devices":true}"##)
        // Role "admin", but without the right: not visible.
        let labelOnly = try Self.person(permissions: ##"{"watch":true}"##)
        #expect(ApprovalRule.isVisible(.signedIn(admin, isBorrowed: false)))
        #expect(!ApprovalRule.isVisible(.signedIn(admin, isBorrowed: true)))
        #expect(!ApprovalRule.isVisible(.signedIn(labelOnly, isBorrowed: false)))
        #expect(!ApprovalRule.isVisible(.notSignedIn([])))
        #expect(!ApprovalRule.isVisible(nil))
    }

    /// **An older server: the old two, and the console turns adult into `admin`.**
    @Test("Older server: child and adult, console only with adult and its own PIN")
    func legacyRole() {
        let child = RoleOption.legacy[0]
        let adult = RoleOption.legacy[1]
        #expect(RoleOption.offers(nil) == RoleOption.legacy)
        #expect(ApprovalRule.role(nil, console: false, ownPin: "1234") == nil)
        #expect(ApprovalRule.role(child, console: false, ownPin: "") == .kind)
        #expect(ApprovalRule.role(adult, console: false, ownPin: "") == .adult)
        #expect(ApprovalRule.role(adult, console: true, ownPin: " ") == nil)
        #expect(ApprovalRule.role(adult, console: true, ownPin: "4321") == .admin(ownPin: "4321"))
        #expect(!ApprovalRule.offersConsole(child))
        #expect(ApprovalRule.role(child, console: true, ownPin: "4321") == nil)
        #expect(!ApprovalRule.ready(adult, console: false, pin: "", ownPin: ""))
        #expect(!ApprovalRule.ready(nil, console: false, pin: "1234", ownPin: ""))
        #expect(ApprovalRule.ready(adult, console: false, pin: "1234", ownPin: ""))
    }

    /// **Roles as data (AP85 #73):** by id, the console apart — never `admin`, which made an
    /// administrator in the role with the 18+ lock.
    @Test("Server roles: by id, console on any role, never the old admin word")
    func serverRole() {
        let offers = RoleOption.offers([
            JoinableRole(id: "adult", name: "Erwachsen", color: "#6aa8ff", adult: false, ownDevices: true),
            JoinableRole(id: "admin-role", name: "Admin", color: "#E2564A", adult: true, ownDevices: true),
            JoinableRole(id: "child", name: "Kind", color: "#6fcf8e", adult: false, ownDevices: false),
        ])
        #expect(offers.map(\.id) == ["adult", "admin-role", "child"])
        #expect(offers.allSatisfy { ApprovalRule.offersConsole($0) })
        #expect(
            ApprovalRule.role(offers[0], console: false, ownPin: "") == .chosen(id: "adult", consolePin: nil))
        #expect(
            ApprovalRule.role(offers[1], console: true, ownPin: "4321")
                == .chosen(id: "admin-role", consolePin: "4321"))
        #expect(ApprovalRule.role(offers[1], console: true, ownPin: "") == nil)
        #expect(offers[1].explanation == "settings.portals.joinRoleHintAdultOwn")
        #expect(offers[2].explanation == "settings.portals.joinRoleHintPaired")
    }

    @Test("Approving and rejecting remove the request from the list")
    func admin() async throws {
        let list =
            ##"{"requests":[{"id":"abc","name":"Selin","color":"#9871C4","want":["portals"],"device":"Selins iPhone","kind":"web","from":"192.0.2.42","asked":1758700000.0,"expires_in_s":100},{"id":"def","name":"Emre","color":"#629B46","want":["portals"],"device":"iPad","kind":"web","from":"192.0.2.43","asked":1758700001.0,"expires_in_s":100}]}"##
        let line = FakeConsole.setUp([
            "/household/joins": (200, Data(list.utf8)),
            "/household/joins/abc/approve": (
                200,
                Data(##"{"person":\##(Self.childPerson),"granted":["portals"],"portals":["ahorn"]}"##.utf8)
            ),
            "/household/joins/def/decline": (200, Data(##"{"declined":true}"##.utf8)),
        ])
        let model = JoinApprovalModel(
            join: Join(
                binding: PortalBridge(
                    basis: line.basis, dialect: .cinelounge, trait: "PRUEF-verwalter",
                    session: FakeConsole.session)),
            lookUp: { _ in nil })
        await model.load()
        #expect(model.requestJoin.map(\.name) == ["Selin", "Emre"])

        let childProfile = try #require(model.requestJoin.first)
        #expect(await model.approve(childProfile, als: .adult, pin: "1234", newName: nil))
        let childRequest = try #require(model.requestJoin.first)
        #expect(await model.reject(childRequest))
        #expect(model.requestJoin.isEmpty)

        let approval = try #require(line.requestJoin.first { $0.route.hasSuffix("/approve") })
        let mainContent = try Self.bodyContent(approval)
        #expect(mainContent["role"] as? String == "adult")
        #expect(mainContent["pin"] as? String == "1234")
    }
}

// ── The stub ──────────────────────────────────────────────────────────────

/// A session that, instead of going to the network, picks one response per **route** — one
/// dedicated calculator per check, so that checks running in parallel do not interfere with
/// each other's line. A route without a response yields a network error: That makes "the
/// server stays silent" testable.
final class FakeConsole: URLProtocol, @unchecked Sendable {

    struct Request: Sendable {
        let method: String
        let route: String
        let bodyContent: Data?
    }

    struct Wire: Sendable {
        let basis: URL
        var requestJoin: [Request] { FakeConsole.recorded(forItem: basis.host ?? "") }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: [String: (Int, Data)]] = [:]
    nonisolated(unsafe) private static var transcript: [String: [Request]] = [:]

    static let session: URLSession = {
        let setup = URLSessionConfiguration.ephemeral
        setup.protocolClasses = [FakeConsole.self]
        return URLSession(configuration: setup)
    }()

    static func setUp(_ routes: [String: (Int, Data)]) -> Wire {
        let calculator = "pruef-\(UUID().uuidString.lowercased()).invalid"
        lock.withLock { answers[calculator] = routes }
        return Wire(basis: URL(string: "http://\(calculator):8100")!)
    }

    static func recorded(forItem calculator: String) -> [Request] {
        lock.withLock { transcript[calculator] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let calculator = request.url?.host ?? ""
        let route = request.url?.path ?? ""
        var bodyContent = request.httpBody
        if bodyContent == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                collected.append(buffer, count: n)
            }
            stream.close()
            bodyContent = collected
        }
        let reply: (Int, Data)? = Self.lock.withLock {
            Self.transcript[calculator, default: []].append(
                Request(method: request.httpMethod ?? "GET", route: route, bodyContent: bodyContent))
            return Self.answers[calculator]?[route]
        }
        guard let (status, data) = reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let header = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: header, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
