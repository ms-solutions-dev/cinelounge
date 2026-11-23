import Foundation

/// The third way into the household — **request, have it approved, take it along**
/// (AP47).
///
/// **The finding this type answers (2026-09-24):** up to version 2 of the contract a
/// person came into existence only when an administrator created them in the console,
/// and a new device needed a pairing code from the browser every time. Now the person
/// makes a request, the administrator approves it and assigns the role — once.
/// Afterwards their profile carries a **person token**, with which every further
/// device of their own signs in by itself.
///
/// **A type of its own next to ``Household`` and not an extension of it.** `Household`
/// is shared with the iPhone app and keeps its connection private; opening it up would
/// mean changing a shared contract in order to put a new one next to it.
///
/// **Offer it only where the server can do it** — ``ServerVersion/canJoin``. An
/// older server knows none of these paths, and the app stays with the pairing code
/// there.
///
/// **Device token, person token and request token are secrets.** None of the types
/// here names them in `description`, `debugDescription` or a mirror; whoever needs one
/// reads the field explicitly. A log line `"\(approval)"` thus reveals nothing, and
/// somebody will write exactly that line some day.
public struct Join: Sendable {

    private let binding: PortalBridge

    /// - Parameter anbindung: For the requesting person's paths a connection **without** a
    ///   token suffices — it is the question one asks before having one. The
    ///   administrator's paths require theirs.
    public init(binding: PortalBridge) {
        self.binding = binding
    }

    // ── The requesting person's side ──────────────────────────────────────────

    /// Ask for admission — `POST /join`.
    ///
    /// **No role, no PIN, no origin in the body.** What someone *wants*, they say; what
    /// they *are*, the administrator says. If the role were here, a stranger could demand
    /// `admin`. The origin is the address of the request and cannot be given by the app
    /// without also being able to be given falsely.
    ///
    /// - Parameters:
    ///   - name: The display name from the profile. The server truncates to 60 characters.
    ///   - farbe: The profile colour as `#RRGGBB` — **here and not only at approval**,
    ///     because the person has already chosen it; choosing twice would mean two truths
    ///     about the same colour.
    ///   - geraet: What the requesting device should be called in the device list.
    ///   - art: `tv` or `web`, as with ``Household/redeem(password:name:kind:)``.
    ///   - wuensche: **No default.** Today there is only ``JoinWish/portals``; a
    ///     call that wishes for nothing gets `422 join.no_want`.
    ///
    /// Refusals come as ``PortalBridge/TestError/cancelled(status:code:values:)``:
    /// `join.bad_name`, `join.bad_color`, `join.no_want`, `setup.required` (empty
    /// household — then it stays with the console), `join.too_many` (`max`) and
    /// `join.too_often` (`seconds`, 429).
    public func requestJoin(
        name: String, color: String, device: String, kind: DeviceKind, wishes: [JoinWish]
    ) async throws -> JoinRequest {
        let reply: RequestResponse = try await binding.notify(
            "join",
            mainContent: RequestBody(
                name: name, color: color, device: device, kind: kind.rawValue,
                want: wishes.map(\.rawValue)))
        // **Only `pending` is an accepted request.** Any other state in a `202` would be a
        // contract this app does not know — reading it as "waiting" would mean opening a
        // waiting screen for something that never comes.
        guard reply.state == "pending", !reply.request.isEmpty else {
            throw PortalBridge.TestError.unreadable
        }
        return JoinRequest(identifier: reply.request, remainingSeconds: reply.remainingSeconds)
    }

    /// Ask how the request is doing — `GET /join/{request}`.
    ///
    /// **Every 15 seconds while the waiting screen is open, never in the background.** A
    /// waiting screen that nobody looks at does not need to know anything.
    ///
    /// **Three refusals are states here and not errors:** `404 join.unknown` means
    /// "unknown or expired" and becomes ``JoinStatus/expired``; `429
    /// join.too_often` becomes ``JoinStatus/throttled(seconds:)``. The waiting
    /// screen has to show both anyway, and an error for them would mean that every UI
    /// writes the same translation again. Everything else is thrown.
    ///
    /// **An approval without a device token is none.** It throws
    /// ``PortalBridge/TestError/unreadable`` — an "approved" after which the app still cannot
    /// get in would be worse than a visible refusal.
    public func pollStatus(request: String) async throws -> JoinStatus {
        let identifier = try Self.identifier(request)
        let reply: PollResponse
        do {
            reply = try await binding.fetch("join/\(identifier)")
        } catch let error as PortalBridge.TestError {
            switch error.code {
            case "join.unknown":
                return .expired
            case "join.too_often":
                guard case .cancelled(_, _, let values) = error else { throw error }
                return .throttled(seconds: values["seconds"].flatMap { Int($0) })
            default:
                throw error
            }
        }
        return try reply.joinStatus()
    }

    /// Sign in a further **own** device with the person token — `POST /device/enroll`.
    ///
    /// **The device then belongs to the person**, not to the household. A shared
    /// living-room TV is therefore not signed in this way: it belongs to nobody, and an
    /// approved person is in its profile picker anyway.
    ///
    /// Answers in the same form as `/login` and `/redeem`, i.e. as ``SignIn``.
    /// Refusals: `401 enroll.unknown_mark` (unknown **or** revoked — no difference, no
    /// oracle), `429 enroll.too_often` (`seconds`) and `409 enroll.too_many_devices`
    /// (`max`, today ten devices per token).
    ///
    /// **A sign-in without a token or without a person throws**
    /// ``PortalBridge/TestError/unreadable``: this path always signs in a device of *a person*,
    /// and a response without them would be a contract that does not exist.
    public func signIn(tag: String, name: String, kind: DeviceKind) async throws -> SignIn {
        let login: SignIn = try await binding.notify(
            "device/enroll", mainContent: TokenBody(mark: tag, name: name, kind: kind.rawValue))
        guard !login.trait.isEmpty, login.person != nil else {
            throw PortalBridge.TestError.unreadable
        }
        return login
    }

    // ── The person's own token ─────────────────────────────────────────────────

    /// Fetch the person token — `POST /household/people/{person}/mark`.
    ///
    /// **The way a new token gets into the app after a revocation** (AP47, 2026-09-25).
    /// The server returns the existing token or creates one if there is none yet; asking
    /// twice renews nothing. Requires a token of the person themselves (or `pair_devices`)
    /// and **never** a borrowed profile — otherwise `403 auth.borrowed_profile` or
    /// `auth.forbidden`.
    ///
    /// - Returns: the token as wording, never empty.
    public func ownToken(person: String) async throws -> String {
        let reply: TokenResponse = try await binding.notify(
            "household/people/\(try Self.identifier(person))/mark", mainContent: EmptyBody())
        return try reply.verifiedToken()
    }

    /// Revoke the person token — `DELETE /household/people/{person}/mark`.
    ///
    /// **Every device that came through the old token drops** (decision 8.4), and the
    /// response immediately carries the new one. Whoever does not store it locks the
    /// person out themselves.
    public func renewToken(person: String) async throws -> TokenRenewal {
        let reply: TokenResponse = try await binding.remove(
            "household/people/\(try Self.identifier(person))/mark")
        return TokenRenewal(
            tag: try reply.verifiedToken(),
            removedDevices: reply.removedDevices ?? 0)
    }

    // ── The administrator's side ───────────────────────────────────────────────

    /// The open requests — `GET /household/joins`.
    ///
    /// Requires the right `pair_devices` and **never** a borrowed profile; the server
    /// checks both and otherwise answers `403`. The app should still show the page only
    /// where ``SignInState/isAllowed(_:)`` says yes with ``AccessRights/pairDevices``.
    public func openRequests() async throws -> [OpenRequest] {
        try await openRequestsWithRoles().requests
    }

    /// The open requests **and the roles one can approve them as** — the same call.
    ///
    /// **`roles` is `nil` on a server from before 2026-11-09.** It knows only the three old
    /// words; the app then offers child and adult with the console switch
    /// (``JoinRole/admin(ownPin:)``). An empty list is not the same: that server has
    /// roles, and none to choose.
    public func openRequestsWithRoles() async throws -> (
        requests: [OpenRequest], roles: [JoinableRole]?
    ) {
        let list: RequestList = try await binding.fetch("household/joins")
        return (list.requests, list.roles)
    }

    /// Approve a request — `POST /household/joins/{request}/approve`.
    ///
    /// - Parameters:
    ///   - anfrage: ``OpenRequest/identifier``.
    ///   - rolle: **Required, no default.** The role is the actual decision of this path;
    ///     a call that forgets it should not compile and not guess.
    ///     ``JoinRole/admin(ownPin:)`` carries the new person's PIN along,
    ///     because the server demands it exactly there and nowhere else.
    ///   - pin: The PIN **of the approver** — with the five attempts and the minute's
    ///     pause of `/login`. Face ID in the app does not replace it: the server checks
    ///     the role, never the app.
    ///   - neuerName: `nil` keeps the requested name. Set for
    ///     `409 household.person_exists` — the administrator renames instead of
    ///     throwing the request away. **Also without a default**, so that a call visibly
    ///     says whether it renames.
    ///
    /// Refusals: `auth.bad_credentials` (401), `auth.locked_out` (429),
    /// `household.unknown_role`, `join.admin_needs_pin`, `join.pin_only_for_admin`,
    /// `auth.pin_format` (all 422), `household.person_exists` (409), `join.unknown`
    /// (404 — unknown, expired or already decided).
    public func approve(
        _ request: String, als role: JoinRole, pin: String, newName: String?
    ) async throws -> Intake {
        let identifier = try Self.identifier(request)
        return try await binding.notify(
            "household/joins/\(identifier)/approve",
            mainContent: ApprovalBody(
                role: role.serverWord, pin: pin, name: newName, personPin: role.ownPin,
                console: role.console))
    }

    /// Decline a request — `POST /household/joins/{request}/decline`.
    ///
    /// **No reason.** A reason field would become a message channel from an unsigned-in
    /// stranger into the household — and in the other direction.
    public func reject(_ request: String) async throws {
        let identifier = try Self.identifier(request)
        let reply: RejectionResponse = try await binding.notify(
            "household/joins/\(identifier)/decline", mainContent: EmptyBody())
        // A `200` without `declined: true` is not a confirmation — the UI would otherwise
        // remove the request from the list, and it would be back on the next load.
        guard reply.declined else { throw PortalBridge.TestError.unreadable }
    }

    // ── Wegteile ─────────────────────────────────────────────────────────────

    /// A request token that qualifies as **one** path segment — or an error.
    ///
    /// **The token is written into the path**, and a `/` or `..` in it would lead the
    /// request to a different path of the server than the one meant. The server issues 22
    /// lowercase letters and digits; what is permitted is what `token_urlsafe` could ever
    /// produce, and nothing else.
    static func identifier(_ raw: String) throws -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAllowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !clean.isEmpty, clean.count <= 128,
            clean.unicodeScalars.allSatisfy(isAllowed.contains)
        else { throw PortalBridge.TestError.unreadable }
        return clean
    }

    // ── Bodies that go out ────────────────────────────────────────────────────

    /// **English keys on purpose**, as in ``Household``: the writer translates German words
    /// into the server's and leaves these alone.
    private struct RequestBody: Encodable, Sendable {
        let name: String
        let color: String
        let device: String
        let kind: String
        let want: [String]
    }

    private struct TokenBody: Encodable, Sendable {
        let mark: String
        let name: String
        let kind: String
    }

    /// `name` and `person_pin` drop out when they are `nil` — the synthesised `encode`
    /// uses `encodeIfPresent`. **That is intentional here and no accident:** a
    /// `person_pin` sent along with a role other than `admin` is rejected by the server
    /// with `422 join.pin_only_for_admin`.
    private struct ApprovalBody: Encodable, Sendable {
        let role: String
        let pin: String
        let name: String?
        let personPin: String?
        /// Only for a role from the server's list (``JoinRole/chosen(id:consolePin:)``); the
        /// three old words leave it out, and an older server never sees it.
        let console: Bool?

        enum CodingKeys: String, CodingKey {
            case role, pin, name, console
            case personPin = "person_pin"
        }
    }

    private struct EmptyBody: Encodable, Sendable {}

    // ── Responses that come in ────────────────────────────────────────────────
    //
    // **The keys are in the inner language.** The reader translates `state` to `state`
    // and `kind` to `kind` before `CodingKeys` applies (``PortalDialect``); a `case state`
    // would never find anything here, and the error would look like an empty response.

    private struct RequestResponse: Decodable {
        let request: String
        let state: String
        let remainingSeconds: Int

        enum CodingKeys: String, CodingKey {
            case request, state = "stand"
            case remainingSeconds = "expires_in_s"
        }
    }

    private struct PollResponse: Decodable {
        let state: String
        let remainingSeconds: Int?
        let trait: String?
        let tag: String?
        let person: HouseholdPerson?

        enum CodingKeys: String, CodingKey {
            case state = "stand"
            case remainingSeconds = "expires_in_s"
            case trait = "device_token"
            case tag = "person_mark"
            case person
        }

        /// **Each state only with what constitutes it** — otherwise the response is unreadable
        /// and not a state with gaps.
        func joinStatus() throws -> JoinStatus {
            switch state {
            case "pending":
                guard let remainingSeconds else { throw PortalBridge.TestError.unreadable }
                return .waiting(remainingSeconds: remainingSeconds)
            case "declined":
                return .rejected
            case "approved":
                guard let trait, !trait.isEmpty, let person else {
                    throw PortalBridge.TestError.unreadable
                }
                // An empty token is no token: `nil` as with the child, instead of a string with which
                // `/device/enroll` can only fail.
                let tag = self.tag.flatMap { $0.isEmpty ? nil : $0 }
                return .approved(
                    JoinApproval(trait: trait, personToken: tag, person: person))
            default:
                throw PortalBridge.TestError.unreadable
            }
        }
    }

    private struct RequestList: Decodable {
        let requests: [OpenRequest]
        let roles: [JoinableRole]?
    }

    private struct RejectionResponse: Decodable {
        let declined: Bool
    }

    private struct TokenResponse: Decodable {
        let mark: String?
        let removedDevices: Int?

        enum CodingKeys: String, CodingKey {
            case mark
            case removedDevices = "devices_removed"
        }

        /// A response without a token is none — storing an empty one would mean overwriting
        /// the valid one in the profile.
        func verifiedToken() throws -> String {
            let clean = (mark ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw PortalBridge.TestError.unreadable }
            return clean
        }
    }
}

/// What a revocation of the person token leaves behind.
///
/// **Without `description`**, for the same reason as ``JoinApproval``: the token
/// is a secret and should appear in no log line.
public struct TokenRenewal: Sendable, Equatable {
    /// The new token — belongs in the profile immediately.
    public let tag: String
    /// How many devices dropped with the old one.
    public let removedDevices: Int
}

extension TokenRenewal: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var description: String { "TokenRenewal(•••, \(removedDevices))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

// ── What goes out ─────────────────────────────────────────────────────────────

/// What a request wishes for.
///
/// **A list and not a field**, as in the contract: today there is exactly one wish,
/// and a second ("Live shared") should not cost a second path. Unknown wishes are
/// silently dropped by the server.
public enum JoinWish: String, Sendable, CaseIterable {
    /// See the portals — every one that is on in the household and that the role may see.
    case portals = "portals"
}

/// Which role the administrator assigns at approval.
///
/// **The new person's PIN hangs on the role and not next to it.** The server requires
/// it for `admin` (`join.admin_needs_pin`) and rejects it for every other role
/// (`join.pin_only_for_admin`). As a field of its own next to the role, both refusals
/// would be a call one can write; this way neither can be written.
///
/// **No child with a token:** for ``kind`` the server issues no person token — the
/// administrator pairs that child's device.
public enum JoinRole: Sendable, Equatable {
    /// The three old words — **only for a server without a role list** (before 2026-11-09).
    case kind
    case adult
    /// - Parameter ownPin: 4–8 digits; the server checks the format
    ///   (`auth.pin_format`), so that there is only one place that defines it.
    case admin(ownPin: String)
    /// A role from the server's list (``Join/openRequestsWithRoles()``), with the console
    /// on top when `consolePin` is set (AP85 #73, 2026-11-09).
    ///
    /// **Role and console apart.** The old `admin` meant "the role `adult` plus console" —
    /// and since `adult` may be the role with the 18+ lock, an administrator approved that way
    /// ran the console without 18+.
    case chosen(id: String, consolePin: String?)

    /// What the server calls the role.
    var serverWord: String {
        switch self {
        case .kind: "child"
        case .adult: "adult"
        case .admin: "admin"
        case .chosen(let id, _): id
        }
    }

    var ownPin: String? {
        switch self {
        case .admin(let pin): pin
        case .chosen(_, let pin): pin
        case .kind, .adult: nil
        }
    }

    /// `console` in the body — `nil` for the old words, so an older server never sees it.
    var console: Bool? {
        if case .chosen(_, let pin) = self { return pin != nil }
        return nil
    }
}

/// A role the administrator can approve a request as — from `GET /household/joins`.
///
/// **Only what the choice needs.** No portal list, no member count: the approver holds
/// `pair_devices`, not `change_access`, and sees the role, not its make-up.
public struct JoinableRole: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// The role's colour as `#RRGGBB`.
    public let color: String
    /// Whether the role sees 18+ (`view_adult`).
    public let adult: Bool
    /// Whether people in it sign in further devices themselves (`own_devices`) — otherwise
    /// the administrator pairs them.
    public let ownDevices: Bool

    public init(id: String, name: String, color: String, adult: Bool, ownDevices: Bool) {
        self.id = id
        self.name = name
        self.color = color
        self.adult = adult
        self.ownDevices = ownDevices
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, adult
        case ownDevices = "own_devices"
    }
}

// ── What comes in ─────────────────────────────────────────────────────────────

/// An accepted request — **accepted, not done** (`202`).
public struct JoinRequest: Sendable, Equatable {
    /// The request token: **the only credential** with which the app asks later. A
    /// secret — whoever has it fetches the device token after approval.
    public let identifier: String
    /// How long the request is still valid, in seconds. Seven days today.
    public let remainingSeconds: Int
}

/// How a request stands.
public enum JoinStatus: Sendable, Equatable {
    /// Not decided yet.
    case waiting(remainingSeconds: Int)
    /// Approved — and the device is thereby already signed in.
    case approved(JoinApproval)
    /// Declined. **Without a reason**, on purpose (see ``Join/reject(_:)``).
    case rejected
    /// Unknown or expired — **the same for the app**, as with the pairing code: the answer
    /// is "start over" both times. An approval that has lain longer than ten minutes after
    /// the first pickup also ends here.
    case expired
    /// Too many wrong attempts from this address. `seconds` is the wait time the server
    /// names; `nil` if it names none.
    case throttled(seconds: Int?)
}

/// What an approval brings the requesting device.
///
/// **The device is thereby already signed in** — a second step through
/// `/device/enroll` would only be one more that can fail. ``trait`` belongs in the
/// Keychain like any other device token, ``personToken`` in the profile.
public struct JoinApproval: Sendable, Equatable {
    /// The device token for `X-CL-Device`. **Never empty** — an approval without a token is
    /// read as unreadable by ``Join/pollStatus(request:)``.
    public let trait: String
    /// The person token for the profile — **`nil` for a child**: it carries none, its
    /// device is paired by the administrator.
    public let personToken: String?
    public let person: HouseholdPerson
}

/// An open request, as the administrator sees it.
public struct OpenRequest: Decodable, Sendable, Equatable, Identifiable {
    /// The request token — the same one with which the requesting person asks. Hence a
    /// secret like it.
    public let identifier: String
    public let name: String
    /// The colour the person chose in their profile, as `#RRGGBB`.
    public let color: String
    /// The wishes as server words — **unknown ones stay too**, so that the administrator
    /// sees what was asked for even if this app does not know it.
    public let wishes: [String]
    /// What the requesting device wants to be called — "a user's iPhone".
    public let device: String
    /// `tv` or `web` — as text, because an unknown kind must not empty the list.
    public let kind: String
    /// The address the request came from — **the only thing** by which the administrator
    /// can tell "from my network" from "from outside".
    public let origin: String
    /// Wann gefragt wurde.
    public let asked: Date
    public let remainingSeconds: Int

    public var id: String { identifier }

    /// The keys in the inner language: `kind` arrives as `kind`.
    enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case name
        case color = "color"
        case wishes = "want"
        case device = "device"
        case kind = "art"
        case origin = "from"
        case asked = "asked"
        case remainingSeconds = "expires_in_s"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try values.decode(String.self, forKey: .identifier)
        name = try values.decode(String.self, forKey: .name)
        color = try values.decode(String.self, forKey: .color)
        wishes = try values.decode([String].self, forKey: .wishes)
        device = try values.decode(String.self, forKey: .device)
        kind = try values.decode(String.self, forKey: .kind)
        origin = try values.decode(String.self, forKey: .origin)
        // Seconds since 1970 as a fractional number — the server writes `time.time()`.
        asked = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .asked))
        remainingSeconds = try values.decode(Int.self, forKey: .remainingSeconds)
    }
}

/// What an approval yields for the administrator.
public struct Intake: Decodable, Sendable, Equatable {
    /// The new person — without PIN, unless they are an administrator.
    public let person: HouseholdPerson
    /// Which wishes were granted, as server words.
    public let granted: [String]
    /// Which portals the person now sees: every one that is on in the household and that
    /// their role may see.
    public let portals: [String]

    /// `portals` arrives translated as `portals`.
    enum CodingKeys: String, CodingKey {
        case person
        case granted = "granted"
        case portals = "portale"
    }
}

// ── Secrets stay out of log lines ─────────────────────────────────────────────
//
// **All three ways in which Swift writes a value out by itself** are blocked here:
// `description` (`"\(x)"`, `print`), `debugDescription` (`debugPrint`, enumeration
// cases with payload) and the mirror (`dump`). One of them left open would suffice.

extension JoinApproval: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "JoinApproval(person: \(person.id), credential: •••, personToken: \(personToken == nil ? "none" : "•••"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["person": person.id], displayStyle: .struct)
    }
}

/// **The own PIN of a new administrator is a secret** like token and mark — an
/// enumeration case with payload would otherwise write it into every log line that
/// names the role.
extension JoinRole: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .kind: "JoinRole.kind"
        case .adult: "JoinRole.adult"
        case .admin: "JoinRole.admin(ownPin: •••)"
        case .chosen(let id, let pin): "JoinRole.chosen(id: \(id), consolePin: \(pin == nil ? "nil" : "•••"))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["role": serverWord], displayStyle: .enum)
    }
}

extension JoinRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "JoinRequest(identifier: •••, remainingSeconds: \(remainingSeconds))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["remainingSeconds": remainingSeconds], displayStyle: .struct)
    }
}

extension OpenRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "OpenRequest(identifier: •••, name: \(name), device: \(device))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["name": name, "device": device], displayStyle: .struct)
    }
}

// ── The capability ────────────────────────────────────────────────────────────

extension ServerVersion {

    /// The word under which the server reports joining in `capabilities`.
    public static let joinCapability = "join"

    /// May the app offer a request?
    ///
    /// **Listen to the capability and not to the version number.** The number says "the
    /// contract has changed" and slows down an app from the future; the capability says
    /// "this you may offer" and slows down an app at an older server. Those are two
    /// questions, and one answer for both would answer one of them wrongly.
    ///
    /// **Here and not in ``PortalCapability``:** that one says what a *portal* can do, and
    /// attaches controls to a portal. Joining is a capability of the *server*; as a portal
    /// capability it would be at every portal or at none.
    public var canJoin: Bool { capabilities.contains(Self.joinCapability) }
}
