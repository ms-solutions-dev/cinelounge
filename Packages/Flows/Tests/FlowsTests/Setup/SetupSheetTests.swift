import Core
import Foundation
@_spi(Check) import JellyfinKit
import PortalKit
import ProfileKit
import Testing

@_spi(Check) @testable import Flows

/// The sheets of wave 4 at the machine — **A5's four special cases and A6's request**
/// (AP88 §2.8, §6.1).
///
/// Counter-checks: without the `.confirm` branch in `tokenChecked` ``tokenWhileSheetOpen()``
/// stays in A5; without clearing in `requestState` ``withdrawnRequestLeavesNoWaiting()`` keeps
/// "waiting" in A7.
@Suite("Setup — the sheets at the machine")
struct SetupSheetMachineTests {

    typealias Run = SetupMachineTests.Run

    static let lea = SetupMachineTests.lea
    static let leaAccess = SetupMachineTests.leaAccess

    /// Lea in A5 with her profile's access.
    func leaInConfirm() -> Run {
        var run = Run(.resume(Self.lea), notice: true)
        run.send(.openSource(.jellyfin))
        return run
    }

    @Test(
        "\"Choose another server\" turns the confirmation into the server choice, the profile keeps its access"
    )
    func otherServer() {
        var run = leaInConfirm()
        #expect(run.state == .jellyfin(Self.lea.id, .confirm(Self.leaAccess)))
        #expect(run.send(.chooseOtherServer).isEmpty)
        #expect(run.state == .jellyfin(Self.lea.id, .fresh))
        #expect(run.machine.setupProfile(Self.lea.id)?.profile.jellyfin == Self.leaAccess)

        run.send(.back)
        #expect(
            run.page?.row(.jellyfin) == .fromProfile(Self.leaAccess),
            "back: the row still offers the confirmation")
    }

    @Test("\"Choose another server\" also leaves the other-user question, and does nothing elsewhere")
    func otherServerFromQuestion() {
        var run = leaInConfirm()
        run.send(.jellyfinSignedIn(userID: "tom-id", username: "tom"))
        run.send(.chooseOtherServer)
        #expect(run.state == .jellyfin(Self.lea.id, .fresh))

        var sources = Run(.resume(Self.lea), notice: true)
        let before = sources.state
        sources.send(.chooseOtherServer)
        #expect(sources.state == before)
    }

    @Test("A valid Keychain token closes an open A5 — nobody needs the code any more")
    func tokenWhileSheetOpen() {
        var run = leaInConfirm()
        #expect(
            run.send(.tokenChecked(Self.lea.id, valid: true)).isEmpty,
            "the shell stored it, the machine only records")
        #expect(run.page?.row(.jellyfin) == .done(detail: "lea"))
    }

    @Test("An invalid token leaves A5 open")
    func deadTokenWhileSheetOpen() {
        var run = leaInConfirm()
        run.send(.tokenChecked(Self.lea.id, valid: false))
        #expect(run.state == .jellyfin(Self.lea.id, .confirm(Self.leaAccess)))
    }

    /// Anna (no person token) in A6 with a found CL-Server.
    func annaAsking() -> Run {
        var run = Run(.resume(SetupMachineTests.anna), notice: true)
        run.send(.searchFound(jellyfin: [], clServer: SetupMachineTests.clServer))
        run.send(.openSource(.portals))
        return run
    }

    @Test("A6 knows the CL-Server's address from the search")
    func clServerAddress() {
        let run = annaAsking()
        #expect(run.machine.clServerAddress == SetupMachineTests.clServer)
        #expect(run.state == .clServer(SetupMachineTests.anna.id, .request(.none)))
    }

    @Test(
        "A withdrawn, rejected or expired request leaves no \"waiting\" for A7",
        arguments: [
            RequestState.none, .rejected, .expired,
        ])
    func withdrawnRequestLeavesNoWaiting(_ end: RequestState) {
        var run = annaAsking()
        #expect(run.send(.sendJoinRequest) == [.requestJoin(SetupMachineTests.anna.id)])
        run.send(.requestState(.waiting(remainingSeconds: 600)))
        run.send(.requestState(end))
        #expect(run.state == .clServer(SetupMachineTests.anna.id, .request(end)))
        run.send(.back)
        #expect(run.page?.row(.portals) == .found(detail: "cl.example"))
        #expect(run.page?.canFinish == false)
    }

    @Test("A network error while waiting keeps the request")
    func failedPollKeepsWaiting() {
        var run = annaAsking()
        run.send(
            .sendJoinRequest, .requestState(.waiting(remainingSeconds: 600)), .requestState(.failed("x")))
        run.send(.back)
        #expect(run.page?.row(.portals) == .waiting)
    }

    @Test("\"Continue\" while waiting: back to A4 with the row waiting, and \"Done\" counts it")
    func continueWhileWaiting() {
        var run = annaAsking()
        run.send(.sendJoinRequest, .requestState(.waiting(remainingSeconds: 600)))
        run.send(.sourceFinished(.portals, .waiting))
        #expect(run.page?.row(.portals) == .waiting)
        #expect(run.page?.canFinish == true)
    }

    @Test("Approved: the row is done with the person's name")
    func approved() {
        var run = annaAsking()
        run.send(.sendJoinRequest, .requestState(.approved(name: "Anna", withTag: true)))
        run.send(.sourceFinished(.portals, .done(detail: "Anna")))
        #expect(run.page?.row(.portals) == .done(detail: "Anna"))
    }

    @Test("A child's pairing ends as done, never as a request")
    func childPaired() {
        var run = Run(.resume(SetupMachineTests.mia), pin: true, notice: true)
        run.send(.openSource(.portals))
        #expect(run.state == .clServer(SetupMachineTests.mia.id, .childPairing))
        #expect(run.send(.sendJoinRequest).isEmpty)
        run.send(.sourceFinished(.portals, .done(detail: "Mia")))
        #expect(run.page?.row(.portals) == .done(detail: "Mia"))
    }
}

/// The token that outlived the app (§2.1, §5.3).
@Suite("Setup — the Keychain hit")
struct SetupKeychainHitTests {

    static let server = SetupMachineTests.server
    static let lea = ServerCredentials(
        serverURL: server, userID: "lea-id", username: "lea", accessToken: "t1")
    static let otherServerLea = ServerCredentials(
        serverURL: URL(string: "https://elsewhere.example:8096")!, userID: "lea-id", username: "lea",
        accessToken: "t2")

    @Test("Only the same server and the same user count")
    func sameServerAndUser() {
        #expect(
            SetupKeychainHit.credential(for: SetupMachineTests.leaAccess, in: [Self.otherServerLea]) == nil)
        #expect(
            SetupKeychainHit.credential(
                for: SetupMachineTests.leaAccess, in: [Self.otherServerLea, Self.lea])
                == Self.lea)
        #expect(SetupKeychainHit.credential(for: .channelList(identifier: "x"), in: [Self.lea]) == nil)
    }

    @Test("A token the server refuses is no hit, and without a token nothing is asked")
    func refusedToken() async {
        var asked = 0
        let refused = await SetupKeychainHit.check(SetupMachineTests.leaAccess, in: [Self.lea]) { _ in
            asked += 1
            return false
        }
        #expect(refused == nil)
        let valid = await SetupKeychainHit.check(SetupMachineTests.leaAccess, in: [Self.lea]) { _ in true }
        #expect(valid == Self.lea)
        let none = await SetupKeychainHit.check(SetupMachineTests.leaAccess, in: []) { _ in
            asked += 1
            return true
        }
        #expect(none == nil)
        #expect(asked == 1)
    }

    @Test("A hit signs in only while its profile is the active one")
    func onlyForTheActiveProfile() {
        var lea = Profile(name: "Lea")
        lea.create(SetupMachineTests.leaAccess)
        let tom = Profile(name: "Tom")
        #expect(SetupKeychainHit.signsIn(SetupMachineTests.leaAccess, active: lea))
        #expect(
            !SetupKeychainHit.signsIn(SetupMachineTests.leaAccess, active: tom),
            "someone else was chosen meanwhile")
        #expect(!SetupKeychainHit.signsIn(SetupMachineTests.leaAccess, active: nil))
    }
}

/// A code the check hands out when it wants to — **the wait for approval without a clock.**
nonisolated final class CodeGate: Sendable {
    let stream: AsyncStream<ServerCredentials>
    let continuation: AsyncStream<ServerCredentials>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func approve(_ credential: ServerCredentials) {
        continuation.yield(credential)
    }

    func wait() async throws -> ServerCredentials {
        for await credential in stream { return credential }
        throw CancellationError()
    }
}

/// A5 on ``LoginFlow`` — **address from the profile, Quick Connect at once, the user question**
/// (AP88 §2.8, G6 at the sheet).
///
/// Counter-checks: if `begin()` stops after `checkAddress` ``codeAtOnce()`` sees the method
/// choice; if `persist` stores directly instead of through the journey, ``otherUserAsks()``
/// finds tom stored.
@MainActor
@Suite("Setup — A5 Jellyfin")
struct SetupJellyfinSheetTests {

    nonisolated static let info = JellyfinConnection.ServerInfo(
        serverName: "Wohnzimmer", version: "10.11.0", id: "s1")
    nonisolated static let leaCredential = ServerCredentials(
        serverURL: SetupMachineTests.server, userID: "lea-id", username: "lea", accessToken: "t")
    nonisolated static let tomCredential = ServerCredentials(
        serverURL: SetupMachineTests.server, userID: "tom-id", username: "tom", accessToken: "token")

    final class Stored {
        var credentials: [ServerCredentials] = []
    }

    struct Rig {
        let journey: SetupJourney
        let sheet: SetupJellyfinSheet
        let stored: Stored
        let gate: CodeGate
    }

    func rig(
        reachable: Bool = true, offersCode: Bool = true, childAccounts: Set<String> = []
    ) async -> Rig {
        let stored = Stored()
        var services = SetupServices.mock()
        services.storeJellyfin = { stored.credentials.append($0) }
        let journey = SetupJourney(
            SetupMachine(
                steps: .tv, start: .resume(SetupMachineTests.lea), isPinSet: false, noticeSeen: true),
            services: services)
        journey.start()
        await journey.settle()
        journey.send(.openSource(.jellyfin))

        let gate = CodeGate()
        var login = LoginServices.mock(server: reachable ? Self.info : nil, canUseCode: offersCode)
        login.beginCode = { _, _, _ in .forCheck }
        login.waitForCode = { _, _, _, _, _ in try await gate.wait() }
        let sheet = SetupJellyfinSheet(
            journey: journey, services: login, deviceID: "probe", deviceName: "Apple TV",
            isChildAccount: { childAccounts.contains($0) })
        return Rig(journey: journey, sheet: sheet, stored: stored, gate: gate)
    }

    /// Starts the sheet and waits until it shows the code.
    func open(_ rig: Rig) async -> Task<Void, Never> {
        let running = Task { await rig.sheet.begin() }
        for _ in 0..<200 where rig.sheet.step != .code(.forCheck) { await Task.yield() }
        return running
    }

    @Test("The profile's address, then straight to the code — no search, no method choice")
    func codeAtOnce() async {
        let rig = await rig()
        let running = await open(rig)
        #expect(rig.sheet.step == .code(.forCheck))
        #expect(rig.sheet.login.address == SetupMachineTests.server.absoluteString)
        #expect(rig.sheet.login.discoveries.isEmpty)
        #expect(rig.sheet.serverName == "Wohnzimmer")
        #expect(rig.sheet.profile?.profile.name == "Lea")

        rig.gate.approve(Self.leaCredential)
        await running.value
        await rig.journey.settle()
        #expect(rig.stored.credentials == [Self.leaCredential])
        #expect(rig.sheet.mode == nil, "the sheet is closed")
        guard case .sources(let page) = rig.journey.state else {
            Issue.record("expected A4, got \(rig.journey.state)")
            return
        }
        #expect(page.row(.jellyfin) == .done(detail: "lea"))
    }

    @Test("G6 Quick Connect signs in tom: a question and nothing stored; \"Again\" asks for a new code")
    func otherUserAsks() async {
        let rig = await rig()
        let running = await open(rig)
        rig.gate.approve(Self.tomCredential)
        await running.value
        #expect(rig.sheet.step == .otherUser(signedIn: "tom", expected: "lea"))
        #expect(rig.stored.credentials.isEmpty)

        let again = Task { await rig.sheet.again() }
        for _ in 0..<200 where rig.sheet.step != .code(.forCheck) { await Task.yield() }
        #expect(rig.sheet.mode == .confirm(SetupMachineTests.leaAccess))
        #expect(rig.sheet.step == .code(.forCheck))
        rig.gate.approve(Self.tomCredential)
        await again.value

        rig.sheet.acceptOtherUser()
        #expect(rig.stored.credentials == [Self.tomCredential], "taken over only by a press")
    }

    @Test("The profile's server does not answer: a sentence, the access stays, another server is a choice")
    func unreachable() async {
        let rig = await rig(reachable: false)
        await rig.sheet.begin()
        guard case .unreachable(let key) = rig.sheet.step else {
            Issue.record("expected unreachable, got \(rig.sheet.step)")
            return
        }
        #expect(key != nil)
        #expect(rig.sheet.mode == .confirm(SetupMachineTests.leaAccess))

        await rig.sheet.chooseOtherServer()
        #expect(rig.sheet.mode == .fresh)
        #expect(rig.sheet.step == .chooseServer)
        #expect(rig.sheet.login.address.isEmpty)
        #expect(
            rig.journey.machine.setupProfile(SetupMachineTests.lea.id)?.profile.jellyfin
                == SetupMachineTests.leaAccess)
    }

    @Test("Without Quick Connect the password is the way, with the profile's user filled in")
    func noCode() async {
        let rig = await rig(offersCode: false)
        await rig.sheet.begin()
        #expect(rig.sheet.step == .noCode(errorKey: nil))
        rig.sheet.choosePassword()
        #expect(rig.sheet.step == .password)
        #expect(rig.sheet.login.user == "lea")

        await rig.sheet.back()
        #expect(rig.sheet.step == .noCode(errorKey: nil), "from the password back to the choice, not out")
        await rig.sheet.back()
        #expect(rig.sheet.mode == nil)
    }

    @Test("The Menu button on the code closes the sheet and cancels the code")
    func backFromCode() async {
        let rig = await rig()
        let running = await open(rig)
        await rig.sheet.back()
        await running.value
        #expect(rig.sheet.mode == nil)
        guard case .sources(let page) = rig.journey.state else {
            Issue.record("expected A4, got \(rig.journey.state)")
            return
        }
        #expect(page.row(.jellyfin) == .fromProfile(SetupMachineTests.leaAccess))
        rig.gate.approve(Self.leaCredential)
        #expect(rig.stored.credentials.isEmpty, "a cancelled code stores nothing")
    }

    @Test("A child-account marker on the confirmed access is shown")
    func childAccountMarker() async {
        let marked = await rig(childAccounts: [SetupMachineTests.leaAccess.legacyAccountID!])
        #expect(marked.sheet.marksChildAccount)
        let plain = await rig()
        #expect(!plain.sheet.marksChildAccount)
    }
}
