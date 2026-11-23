import Foundation
import SourceProbe
import Testing

@testable import PortalKit

/// The join (AP47) — **against the response shapes of the rolled-out server.**
///
/// **Where the recordings come from (2026-09-24):** `well-known-fassung2.json` is real, a read-only
/// `GET /.well-known/cinelounge` against the home server. All the others are derived from the server
/// code (`cinelounge/web/auth.py`, `cinelounge/web/admin.py`, `cinelounge/household/joins.py`) and from
/// its check run `tests/test_beitritt.py` — **not** recorded. Recording would mean making a request
/// against the real household, and it would then sit in the owner's approval list. Attributes and
/// tokens in them are invented and begin with `PRUEF-`.
///
/// **Through the whole connection and not past the reader.** Every response goes through
/// ``PortalBridge`` with a dummy as the session — because the traps lie exactly there: the reader
/// translates `state` to `state`, `kind` to `kind` and `portals` to `portals`, and a `404` or `429`
/// becomes a refusal before a model sees it.
@Suite("Joining")
struct JoinTests {

    // ── Werkzeug ─────────────────────────────────────────────────────────────

    private func recording(_ name: String) throws -> Data {
        let folder = try #require(Bundle.module.url(forResource: "Mitschnitte", withExtension: nil))
        return try Data(contentsOf: folder.appendingPathComponent("\(name).json"))
    }

    /// A join whose server answers with `status` and `data`.
    private func join(
        _ data: Data, status: Int, trait: String? = nil
    ) -> (Join, Stub.Wire) {
        let line = Stub.setUp(status: status, data: data)
        let bridge = PortalBridge(
            basis: line.basis, dialect: .cinelounge, trait: trait, session: Stub.session)
        return (Join(binding: bridge), line)
    }

    private func join(
        recording name: String, status: Int, trait: String? = nil
    ) throws -> (Join, Stub.Wire) {
        join(try recording(name), status: status, trait: trait)
    }

    private func bodyContent(_ line: Stub.Wire) throws -> [String: Any] {
        let request = try #require(line.requestJoin.first)
        let data = try #require(request.bodyContent)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // ── The capability ────────────────────────────────────────────────────

    @Test("The rolled-out server reports join and version 2")
    func capability() throws {
        let version = try JSONDecoder().decode(ServerVersion.self, from: recording("well-known-fassung2"))
        #expect(version.canJoin)
        #expect(version.recognized)
        #expect(version.api == [1, 2])
    }

    /// **The brake for an app on an older server:** without `join` no request, even if the version number
    /// fits.
    @Test("Without join in capabilities no joining is offered")
    func withoutCapability() throws {
        let raw = Data(
            ##"{"name":"W","version":"0.1.0","api":[1,2],"languages":[],"auth":"pin","setup_required":false,"capabilities":["household","portals"]}"##
                .utf8)
        let version = try JSONDecoder().decode(ServerVersion.self, from: raw)
        #expect(version.canJoin == false)
        #expect(version.recognized)
    }

    // ── Anfragen ─────────────────────────────────────────────────────────────

    @Test("Requests: 202, request token, seven days — and nothing in the body that the admin decides")
    func requestJoin() async throws {
        let (join, line) = try join(recording: "join-angenommen", status: 202)
        let request = try await join.requestJoin(
            name: "Selin", color: "#4A90D9", device: "Selins iPhone", kind: .web, wishes: [.portals])
        #expect(request.identifier == "khfsxz4y4fhrybtx6tutx2")
        #expect(request.remainingSeconds == 604_800)

        let sent = try #require(line.requestJoin.first)
        #expect(sent.method == "POST")
        #expect(sent.route == "/join")
        let mainContent = try bodyContent(line)
        #expect(Set(mainContent.keys) == ["name", "color", "device", "kind", "want"])
        #expect(mainContent["want"] as? [String] == ["portals"])
        #expect(mainContent["kind"] as? String == "web")
    }

    @Test("A 202 with a state other than pending is not an accepted request")
    func requestNotPending() async throws {
        let (join, _) = join(
            Data(##"{"request":"abc","state":"approved","expires_in_s":1}"##.utf8), status: 202)
        await #expect(throws: PortalBridge.TestError.self) {
            _ = try await join.requestJoin(
                name: "Selin", color: "#4A90D9", device: "x", kind: .web, wishes: [.portals])
        }
    }

    @Test("Rejections on requesting come as code with values")
    func requestThrottled() async throws {
        let (join, _) = try join(recording: "join-gedrosselt", status: 429)
        do {
            _ = try await join.requestJoin(
                name: "Selin", color: "#4A90D9", device: "x", kind: .web, wishes: [.portals])
            Issue.record("a 429 must not pass as a request")
        } catch let error as PortalBridge.TestError {
            #expect(error.code == "join.too_often")
            guard case .cancelled(let status, _, let values) = error else { return }
            #expect(status == 429)
            #expect(values["seconds"] == "3412")
        }
    }

    // ── Nachfragen ───────────────────────────────────────────────────────────

    @Test("Polling: waiting — and state arrives despite the dialect")
    func waiting() async throws {
        let (join, line) = try join(recording: "join-wartet", status: 200)
        let state = try await join.pollStatus(request: "khfsxz4y4fhrybtx6tutx2")
        #expect(state == .waiting(remainingSeconds: 512_000))
        #expect(line.requestJoin.first?.method == "GET")
        #expect(line.requestJoin.first?.route == "/join/khfsxz4y4fhrybtx6tutx2")
    }

    @Test("Polling: approved brings credential, person token and person")
    func approved() async throws {
        let (join, _) = try join(recording: "join-freigegeben", status: 200)
        let state = try await join.pollStatus(request: "khfsxz4y4fhrybtx6tutx2")
        guard case .approved(let approval) = state else {
            Issue.record("expected approved, was \(state)")
            return
        }
        #expect(approval.trait == "PRUEF-merkmal-kein-echtes-4gts3k3EQjmfGD8d7U")
        #expect(approval.personToken == "PRUEF-marke-keine-echte-Zq0XbYl7u2WmRr9s")
        #expect(approval.person.id == "selin")
        #expect(approval.person.role == "adult")
        #expect(approval.person.adult == true)
    }

    /// **A child gets no token** (decision 14) — but its device.
    @Test("Polling: approved as a child — credential yes, token no")
    func approvedChild() async throws {
        let (join, _) = try join(recording: "join-freigegeben-kind", status: 200)
        guard case .approved(let approval) = try await join.pollStatus(request: "abc")
        else {
            Issue.record("expected approved")
            return
        }
        #expect(approval.personToken == nil)
        #expect(!approval.trait.isEmpty)
        #expect(approval.person.adult == false)
    }

    @Test("Polling: declined")
    func rejected() async throws {
        let (join, _) = try join(recording: "join-abgelehnt", status: 200)
        #expect(try await join.pollStatus(request: "abc") == .rejected)
    }

    @Test("Polling: 404 join.unknown is expired and not an error")
    func expired() async throws {
        let (join, _) = try join(recording: "join-unbekannt", status: 404)
        #expect(try await join.pollStatus(request: "abc") == .expired)
    }

    @Test("Polling: 429 is throttled, with the server's wait time")
    func throttled() async throws {
        let (join, _) = try join(recording: "join-gedrosselt", status: 429)
        #expect(try await join.pollStatus(request: "abc") == .throttled(seconds: 3412))
    }

    @Test("Polling: every other rejection is thrown, not swallowed")
    func otherRejection() async throws {
        let (join, _) = join(
            Data(##"{"error":{"code":"auth.required","values":{}}}"##.utf8), status: 401)
        await #expect(throws: PortalBridge.TestError.self) {
            _ = try await join.pollStatus(request: "abc")
        }
    }

    /// **The guard this is about:** an approval after which the app still does not get in must not pass as
    /// a success.
    @Test(
        "Approved without a credential, with an empty credential or without a person is unreadable",
        arguments: [
            ##"{"state":"approved","person_mark":"m","person":{"id":"s","name":"S","role":"adult","color":"#000000"}}"##,
            ##"{"state":"approved","device_token":"","person_mark":"m","person":{"id":"s","name":"S","role":"adult","color":"#000000"}}"##,
            ##"{"state":"approved","device_token":"t","person_mark":"m"}"##,
            ##"{"state":"pending"}"##,
            ##"{"state":"zeitreise"}"##,
        ])
    func approvalWithoutMarker(raw: String) async throws {
        let (join, _) = join(Data(raw.utf8), status: 200)
        await #expect(throws: PortalBridge.TestError.self) {
            _ = try await join.pollStatus(request: "abc")
        }
    }

    /// The request token is in the way — a `/` in it led to a different path.
    @Test(
        "A request token that is not a path segment does not go out at all",
        arguments: ["", "  ", "../household/joins", "abc/approve", "a b", "abc?x=1"])
    func identifierChecked(raw: String) async throws {
        let (join, line) = try join(recording: "join-wartet", status: 200)
        await #expect(throws: PortalBridge.TestError.self) {
            _ = try await join.pollStatus(request: raw)
        }
        #expect(line.requestJoin.isEmpty)
    }

    // ── The administrator's side ──────────────────────────────────────────

    @Test("Open requests: with credential, name, device, time, origin — kind arrives as art")
    func openRequests() async throws {
        let (join, line) = try join(
            recording: "household-joins", status: 200, trait: "PRUEF-verwalter")
        let list = try await join.openRequests()
        let first = try #require(list.first)
        #expect(first.identifier == "khfsxz4y4fhrybtx6tutx2")
        #expect(first.name == "Selin")
        #expect(first.color == "#4A90D9")
        #expect(first.wishes == ["portals"])
        #expect(first.device == "Selins iPhone")
        #expect(first.kind == "web")
        #expect(first.origin == "192.0.2.42")
        #expect(first.asked == Date(timeIntervalSince1970: 1_758_700_000.25))
        #expect(first.remainingSeconds == 512_000)
        #expect(line.requestJoin.first?.route == "/household/joins")
        #expect(line.requestJoin.first?.header["X-CL-Device"] == "PRUEF-verwalter")
    }

    /// **Recorded against the server of 2026-11-09** (`rolecheck/record.py`): the adult role
    /// with the 18+ lock, a role "Admin" with 18+, and the seeded child role.
    @Test("The request list carries the roles to approve as")
    func openRequestsWithRoles() async throws {
        let (join, _) = try join(
            recording: "household-joins-roles", status: 200, trait: "PRUEF-verwalter")
        let (requests, roles) = try await join.openRequestsWithRoles()
        #expect(requests.first?.kind == "phone")
        let byID = Dictionary(uniqueKeysWithValues: try #require(roles).map { ($0.id, $0) })
        #expect(byID["adult"]?.name == "Erwachsen")
        #expect(byID["adult"]?.adult == false)
        #expect(byID["adult"]?.ownDevices == true)
        #expect(byID["child"]?.ownDevices == false)
        // `admin` is reserved — a role called "Admin" gets another id, so names never go out.
        #expect(byID["admin-role"]?.adult == true)
    }

    @Test("An older server sends no role list: nil, not empty")
    func openRequestsWithoutRoles() async throws {
        let (join, _) = try join(
            recording: "household-joins", status: 200, trait: "PRUEF-verwalter")
        #expect(try await join.openRequestsWithRoles().roles == nil)
    }

    @Test("A chosen role goes out by id, the console apart")
    func approveChosenWithConsole() async throws {
        let (join, line) = try join(
            recording: "join-freigabe", status: 200, trait: "PRUEF-verwalter")
        _ = try await join.approve(
            "abc", als: .chosen(id: "admin-role", consolePin: "4321"), pin: "1234", newName: nil)
        let mainContent = try bodyContent(line)
        #expect(mainContent["role"] as? String == "admin-role")
        #expect(mainContent["console"] as? Bool == true)
        #expect(mainContent["person_pin"] as? String == "4321")
    }

    @Test("A chosen role without the console sends console false and no person_pin")
    func approveChosenWithoutConsole() async throws {
        let (join, line) = try join(
            recording: "join-freigabe", status: 200, trait: "PRUEF-verwalter")
        _ = try await join.approve(
            "abc", als: .chosen(id: "adult", consolePin: nil), pin: "1234", newName: nil)
        let mainContent = try bodyContent(line)
        #expect(Set(mainContent.keys) == ["role", "pin", "console"])
        #expect(mainContent["console"] as? Bool == false)
    }

    @Test("Approving as an adult: role and PIN of the approver, no person_pin, no name")
    func approveAdult() async throws {
        let (join, line) = try join(
            recording: "join-freigabe", status: 200, trait: "PRUEF-verwalter")
        let recording = try await join.approve(
            "khfsxz4y4fhrybtx6tutx2", als: .adult, pin: "1234", newName: nil)
        #expect(recording.person.id == "selin")
        #expect(recording.granted == ["portals"])
        // `portals` arrives as `portals` — without the translation the list would be empty.
        #expect(recording.portals == ["ard", "nightshift"])

        #expect(line.requestJoin.first?.route == "/household/joins/khfsxz4y4fhrybtx6tutx2/approve")
        let mainContent = try bodyContent(line)
        #expect(Set(mainContent.keys) == ["role", "pin"])
        #expect(mainContent["role"] as? String == "adult")
        #expect(mainContent["pin"] as? String == "1234")
    }

    @Test("Approving as an admin carries the admin's own PIN, a new name goes along")
    func approveAdmin() async throws {
        let (join, line) = try join(
            recording: "join-freigabe", status: 200, trait: "PRUEF-verwalter")
        _ = try await join.approve(
            "abc", als: .admin(ownPin: "4321"), pin: "1234", newName: "Selin K")
        let mainContent = try bodyContent(line)
        #expect(mainContent["role"] as? String == "admin")
        #expect(mainContent["person_pin"] as? String == "4321")
        #expect(mainContent["name"] as? String == "Selin K")
    }

    @Test("Approving as a child means child and carries no person_pin")
    func approveChild() async throws {
        let (join, line) = try join(
            recording: "join-freigabe", status: 200, trait: "PRUEF-verwalter")
        _ = try await join.approve("abc", als: .kind, pin: "1234", newName: nil)
        let mainContent = try bodyContent(line)
        #expect(mainContent["role"] as? String == "child")
        #expect(mainContent["person_pin"] == nil)
    }

    @Test("A rejection on approval comes as a code")
    func approvalRejected() async throws {
        let (join, _) = try join(recording: "join-verwalter-ohne-pin", status: 422)
        do {
            _ = try await join.approve("abc", als: .adult, pin: "1234", newName: nil)
            Issue.record("a 422 must not pass as an admission")
        } catch let error as PortalBridge.TestError {
            #expect(error.code == "join.admin_needs_pin")
        }
    }

    @Test("Declining: confirmed only with declined true")
    func reject() async throws {
        let (join, line) = try join(recording: "join-ablehnung", status: 200)
        try await join.reject("abc")
        #expect(line.requestJoin.first?.route == "/household/joins/abc/decline")
        #expect(line.requestJoin.first?.method == "POST")

        let (silent, _) = self.join(Data(##"{"declined":false}"##.utf8), status: 200)
        await #expect(throws: PortalBridge.TestError.self) { try await silent.reject("abc") }
    }

    // ── Self-registration with the person token ───────────────────────────

    @Test("Signing in with the token: same shape as /login, the device belongs to the person")
    func signIn() async throws {
        let (join, line) = try join(recording: "device-enroll", status: 200)
        let login = try await join.signIn(
            tag: "PRUEF-marke", name: "Apple TV Selin", kind: .tv)
        #expect(login.trait == "PRUEF-merkmal-kein-echtes-enroll-Hk2")
        #expect(login.person?.id == "selin")
        #expect(line.requestJoin.first?.route == "/device/enroll")
        let mainContent = try bodyContent(line)
        #expect(Set(mainContent.keys) == ["mark", "name", "kind"])
        #expect(mainContent["kind"] as? String == "tv")
    }

    @Test("More than ten devices per token: enroll.too_many_devices with max")
    func tooManyDevices() async throws {
        let (join, _) = try join(recording: "enroll-zu-viele", status: 409)
        do {
            _ = try await join.signIn(tag: "PRUEF-marke", name: "x", kind: .tv)
            Issue.record("a 409 must not pass as a sign-in")
        } catch let error as PortalBridge.TestError {
            #expect(error.code == "enroll.too_many_devices")
            guard case .cancelled(let status, _, let values) = error else { return }
            #expect(status == 409)
            #expect(values["max"] == "10")
        }
    }

    @Test("Unknown or revoked token: enroll.unknown_mark")
    func unknownMarker() async throws {
        let (join, _) = try join(recording: "enroll-unbekannt", status: 401)
        do {
            _ = try await join.signIn(tag: "PRUEF-marke", name: "x", kind: .tv)
            Issue.record("a 401 must not pass as a sign-in")
        } catch let error as PortalBridge.TestError {
            #expect(error.code == "enroll.unknown_mark")
        }
    }

    @Test(
        "A sign-in with the token without a person or with an empty credential is unreadable",
        arguments: [
            ##"{"device_token":"t","person":null}"##,
            ##"{"device_token":"","person":{"id":"s","name":"S","role":"adult","color":"#000000"}}"##,
        ])
    func signInWithoutPerson(raw: String) async throws {
        let (join, _) = join(Data(raw.utf8), status: 200)
        await #expect(throws: PortalBridge.TestError.self) {
            _ = try await join.signIn(tag: "m", name: "x", kind: .tv)
        }
    }

    // ── Geheimnisse ──────────────────────────────────────────────────────────

    /// **Attribute and token never in a log line** — on none of the three ways by which Swift writes a
    /// value out by itself, and not wrapped in a state either.
    @Test("Credential, person token and request token appear in no output")
    func secrets() async throws {
        let (join, _) = try join(recording: "join-freigegeben", status: 200)
        let state = try await join.pollStatus(request: "abc")
        guard case .approved(let approval) = state else {
            Issue.record("expected approved")
            return
        }
        var dumped = ""
        dump(approval, to: &dumped)
        var progressDumped = ""
        dump(state, to: &progressDumped)
        let outputs = [
            "\(approval)", String(reflecting: approval), dumped,
            "\(state)", String(reflecting: state), progressDumped,
        ]
        for output in outputs {
            #expect(!output.contains("PRUEF-merkmal"), "credential in: \(output.prefix(60))")
            #expect(!output.contains("PRUEF-marke"), "token in: \(output.prefix(60))")
        }
        #expect("\(approval)".contains("selin"), "the person may appear, otherwise the line says nothing")

        let request = JoinRequest(identifier: "khfsxz4y4fhrybtx6tutx2", remainingSeconds: 1)
        var requestDumped = ""
        dump(request, to: &requestDumped)
        for output in ["\(request)", String(reflecting: request), requestDumped] {
            #expect(!output.contains("khfsxz4y4fhrybtx6tutx2"))
        }

        let list = try JSONDecoder().decode(
            [OpenRequest].self,
            from: Data(
                ##"[{"id":"khfsxz4y4fhrybtx6tutx2","name":"Selin","color":"#4A90D9","want":[],"device":"d","art":"web","from":"x","asked":1,"expires_in_s":1}]"##
                    .utf8))
        let pending = try #require(list.first)
        var openDumped = ""
        dump(pending, to: &openDumped)
        for output in ["\(pending)", String(reflecting: pending), openDumped] {
            #expect(!output.contains("khfsxz4y4fhrybtx6tutx2"))
        }
    }

    /// **A new administrator's own PIN** belongs in an output as little as attribute or token (counter-check
    /// of 2026-09-24).
    @Test("The admin role's own PIN appears in no output")
    func roleSecret() {
        let role = JoinRole.admin(ownPin: "PRUEF-4321")
        var dumped = ""
        dump(role, to: &dumped)
        for output in ["\(role)", String(reflecting: role), dumped] {
            #expect(!output.contains("PRUEF-4321"), "PIN in: \(output)")
        }
        #expect("\(role)".contains("admin"))
    }

    // ── Sentences ─────────────────────────────────────────────────────────

    /// **Every code that a join path can return has a sentence** in `de`, `en` and `tr` — otherwise the bare
    /// code would appear on the TV. The list stands here as server codes and not as app keys: the key arises
    /// via ``PortalBridge/TestError/sentenceKey``, that is, the same way as in the app.
    ///
    /// **In both programs** (review 2026-09-27, design B1): until then the sentences were only in the TV's
    /// catalog, and on the phone `join.bad_name` appeared.
    @Test(
        "Every join rejection has a sentence in de, en and tr",
        arguments: [CodeLocation.tvCatalog, .phoneCatalog])
    func wordings(catalog: CodeLocation) throws {
        let wordings = try SourceText.catalogEntries(catalog)

        let codes = [
            "join.bad_name", "join.bad_color", "join.no_want", "join.too_many", "join.too_often",
            "join.unknown", "join.admin_needs_pin", "join.pin_only_for_admin",
            "enroll.unknown_mark", "enroll.too_often", "enroll.too_many_devices",
            "mark.not_for_children", "setup.required", "household.person_exists",
            "household.unknown_role", "auth.pin_format", "auth.locked_out", "auth.bad_credentials",
            "auth.forbidden", "auth.borrowed_profile",
        ]
        for code in codes {
            let key = try #require(
                PortalBridge.TestError.cancelled(status: 400, code: code, values: [:]).sentenceKey)
            let entry = wordings[key] as? [String: Any]
            let languages = entry?["localizations"] as? [String: Any] ?? [:]
            for language in ["de", "en", "tr"] {
                let unit = (languages[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                #expect(!value.isEmpty, "\(key) missing in \(language)")
            }
        }
    }
}

// ── The dummy ─────────────────────────────────────────────────────────────

/// A session that reaches into a response instead of the network — **a machine of its own per test**, so
/// that tests running in parallel do not interfere with each other's line.
final class Stub: URLProtocol, @unchecked Sendable {

    struct Request: Sendable {
        let method: String
        let route: String
        let header: [String: String]
        let bodyContent: Data?
    }

    /// What a test sees: its address and what arrived there.
    struct Wire: Sendable {
        let basis: URL
        var requestJoin: [Request] { Stub.recorded(forItem: basis.host ?? "") }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var transcript: [String: [Request]] = [:]

    static let session: URLSession = {
        let setup = URLSessionConfiguration.ephemeral
        setup.protocolClasses = [Stub.self]
        return URLSession(configuration: setup)
    }()

    static func setUp(status: Int, data: Data) -> Wire {
        let calculator = "pruef-\(UUID().uuidString.lowercased()).invalid"
        lock.withLock { answers[calculator] = (status, data) }
        return Wire(basis: URL(string: "http://\(calculator):8100")!)
    }

    static func recorded(forItem calculator: String) -> [Request] {
        lock.withLock { transcript[calculator] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let calculator = request.url?.host ?? ""
        // The body is no longer in `httpBody` here, but in the stream.
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
        let urlRequest = Request(
            method: request.httpMethod ?? "GET", route: request.url?.path ?? "",
            header: request.allHTTPHeaderFields ?? [:], bodyContent: bodyContent)
        let reply: (Int, Data)? = Self.lock.withLock {
            Self.transcript[calculator, default: []].append(urlRequest)
            return Self.answers[calculator]
        }
        let (status, data) = reply ?? (599, Data())
        let header = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: header, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
