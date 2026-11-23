import Core
import Diagnose
import Foundation
import Household
import Observation
import PortalKit
import ProfileKit

// MARK: - The requesting person's side

/// How the own request stands — **what the waiting screen shows.**
///
/// **Every outcome has its own case and thus its own sentence.** "Rejected" and "expired"
/// both end with "ask again", but say different things: One is a decision, the other
/// that nobody decided. Telling nothing happening apart from "no" is the whole point of an approval.
public nonisolated enum RequestState: Equatable, Sendable {
    /// No open request.
    case none
    /// Submitted, not yet decided.
    case waiting(remainingSeconds: Int)
    /// Approved — **the device is thereby already signed in.** `withTag` is `false` for
    /// a child: It gets no person token, and the UI then also promises
    /// no further devices.
    case approved(name: String, withTag: Bool)
    case rejected
    case expired
    /// Too many attempts from this address. The request stays remembered.
    case throttled(seconds: Int?)
    /// A refusal or a network error, already as a sentence.
    case failed(String)
    /// A child profile does not ask (cross-check of 2026-09-24): The server would give it
    /// no token, and a child's role is set by the administrator, not by a request.
    case notForChildren

    /// Whether polling continues here.
    public var waiting: Bool {
        switch self {
        case .waiting, .throttled: true
        default: false
        }
    }

    /// The longest interval between two polls, in seconds.
    public static let maxInterval = 60

    /// How long until the next poll.
    ///
    /// **15 seconds, with `throttled` as long as the server says — but at most one
    /// minute** (cross-check of 2026-09-24). A throttle of 3600 seconds let the
    /// loop sleep for an hour; whoever approved in that time saw nothing on the TV.
    /// One poll per minute does not noticeably lengthen a throttle.
    public var spacing: Int {
        guard case .throttled(let seconds) = self, let seconds else { return 15 }
        return min(Self.maxInterval, max(15, seconds))
    }

    /// What is adopted from a poll — `nil` means discard.
    ///
    /// **A poll that ran while someone withdrew the request does not write the
    /// emptied state back** (cross-check of 2026-09-24). Except for
    /// "approved": Then the device is already signed in, and to conceal that would mean
    /// showing a state that is not true. A network error does not end the waiting.
    public static func afterInquiry(current: RequestState, result: RequestState) -> RequestState? {
        if case .approved = result { return result }
        guard current.waiting else { return nil }
        if case .failed = result { return nil }
        return result
    }
}

/// Asking for admission and waiting for approval — **"Switch on portals" without a
/// server person** (AP47, first app line).
///
/// **A value with session and stores passed in, and no view.** The outcomes
/// are the actual work: An "approved" after which the trait or token do not
/// lie where the app looks for them looks like success on screen and is none. That
/// has to be verifiable without a server and without a TV.
public struct JoinRequester {

    let basis: URL
    let session: URLSession
    /// Where device trait, request token and person token live — in the program the
    /// Keychain.
    let keychain: any KeyValueStore
    /// Where the ``ProfileKit/ProfileBook`` lives.
    let ledgerStore: any KeyValueStore
    let deviceName: String
    let kind: DeviceKind
    /// The sentence for a key from the catalogs — `LanguageFallback.message` of the
    /// design layer, passed in because `Flows` knows no design layer.
    let lookUp: @Sendable (String) -> String?
    /// The numeric value of a profile color — `ProfileBrand.value` of the design layer.
    let colorValue: @Sendable (String) -> UInt32?

    /// **Shared since decision 27 (B7)** — until 2026-09-26 the flow lived in the
    /// TV package, and the phone could not ask for admission.
    public init(
        basis: URL, session: URLSession = .shared, keychain: any KeyValueStore,
        ledgerStore: any KeyValueStore, deviceName: String, kind: DeviceKind,
        lookUp: @escaping @Sendable (String) -> String?,
        colorValue: @escaping @Sendable (String) -> UInt32?
    ) {
        self.basis = basis
        self.session = session
        self.keychain = keychain
        self.ledgerStore = ledgerStore
        self.deviceName = deviceName
        self.kind = kind
        self.lookUp = lookUp
        self.colorValue = colorValue
    }

    private var join: Join {
        Join(binding: PortalBridge(basis: basis, dialect: .cinelounge, session: session))
    }

    private var note: JoinNote { JoinNote(keychain) }

    /// Submitting the request — name and color **from the profile**, as the concept wants:
    /// The person has already chosen both there, and a second choice would be two
    /// truths about the same color.
    ///
    /// **An open request is not submitted again.** The server throttles at
    /// three per hour, and whoever opens the screen twice does not ask twice.
    public func location(forItem profile: Profile) async -> RequestState {
        guard profile.kind != .kind else { return .notForChildren }
        if note.openRequest != nil { return await queryPending() }
        do {
            let request = try await join.requestJoin(
                name: profile.name, color: Self.colorWord(profile.color, colorValue: colorValue),
                device: deviceName,
                kind: kind, wishes: [.portals])
            note.rememberRequest(
                request.identifier, forItem: profile.identifier,
                trait: DeviceTrait.load(from: keychain))
            return .waiting(remainingSeconds: request.remainingSeconds)
        } catch {
            Diagnose.error(.login, "Join request not sent", error)
            return .failed(Self.message(error, lookUp: lookUp))
        }
    }

    /// Poll once — **the cadence for it belongs to the view**, because only it knows whether
    /// someone is looking.
    ///
    /// **An approval that would replace a meanwhile different trait is discarded**
    /// and logged (``ProfileKit/JoinNote/mayReplace(_:)``, check 2026-09-27,
    /// B1). The result is then ``RequestState/none``.
    public func queryPending() async -> RequestState {
        guard let pending = note.openRequest else { return .none }
        let state: JoinStatus
        do {
            state = try await join.pollStatus(request: pending.request)
        } catch {
            Diagnose.hint(.login, "Follow-up on the join request got no answer", error)
            // **The request stays remembered.** A network error says nothing about it.
            return .failed(Self.message(error, lookUp: lookUp))
        }
        switch state {
        case .waiting(let rest):
            return .waiting(remainingSeconds: rest)
        case .throttled(let seconds):
            return .throttled(seconds: seconds)
        case .rejected:
            note.forgetRequest()
            return .rejected
        case .expired:
            note.forgetRequest()
            return .expired
        case .approved(let approval):
            guard note.mayReplace(DeviceTrait.load(from: keychain)) else {
                note.forgetRequest()
                Diagnose.hint(
                    .login,
                    "Join approval discarded: the device has since signed in differently")
                return .none
            }
            let withTag = adopt(approval, forItem: pending.profile)
            note.forgetRequest()
            return .approved(name: approval.person.name, withTag: withTag)
        }
    }

    /// Withdraw the request — **only here**; at the server it expires after its deadline.
    public func forget() { note.forgetRequest() }

    /// Where the request stands, **after the sign-in state has been newly determined** — the same
    /// rule on TV and phone (check 2026-09-27, B1).
    ///
    /// - **Not signed in:** A remembered request is polled once if the
    ///   screen does not yet know about it — so it comes back after a restart. An
    ///   "approved" from earlier no longer applies after a sign-out.
    /// - **Signed in** (also with profile choice): **The waiting ends.** The sign-in came by
    ///   another path, and ``Household/DeviceSignIn/create(_:own:in:)`` has already
    ///   cleared the note; a loop that kept polling would stand in the background without "waiting" and without
    ///   a Cancel button. An "approved" stays, so that the sentence
    ///   for it can be seen.
    /// - Otherwise (address silent, old bridge …) everything stays as it is.
    public func afterState(_ state: SignInState?, previous: RequestState) async -> RequestState {
        switch state {
        case .notSignedIn:
            var now = previous
            if case .approved = previous { now = .none }
            guard now == .none, note.openRequest != nil else { return now }
            return await queryPending()
        case .signedIn, .profileRequired:
            return previous.waiting ? .none : previous
        default:
            return previous
        }
    }

    /// What an approval leaves behind, and **where**.
    ///
    /// - The trait into the Keychain, as after `/redeem` (``Core/DeviceTrait``);
    ///   a remembered loan profile is dropped, because the device now belongs to a person.
    /// - The portals access with the server person into the **asking** profile, not into the
    ///   currently active one.
    /// - The person token into this profile's slot (``ProfileKit/PortalMarkerSlot``) — from
    ///   there it migrates along via the zone. **For a child there is none**, and then
    ///   none is expected either — not even if the profile has meanwhile become one.
    /// - The device counts as **own** (``Core/DeviceTrait/ownKey``): A later
    ///   profile switch then writes no loan header that would turn the sign-in into a loan.
    ///
    /// **If the asking profile no longer exists**, only the trait stays — the device is
    /// admitted. Access and token are dropped: A token under a dead ID
    /// would lie in the Keychain as a secret without an owner.
    ///
    /// - Returns: whether a token was filed.
    @discardableResult
    public func adopt(_ approval: JoinApproval, forItem identifier: Profile.Identifier) -> Bool {
        DeviceSignIn.create(approval.trait, own: true, in: keychain)

        var ledger = ProfileBook.read(from: ledgerStore)
        guard let requester = ledger.profile.first(where: { $0.identifier == identifier }) else {
            return false
        }
        ledger.update(identifier) { $0.create(.portals(person: approval.person.id)) }
        ledger.write(in: ledgerStore)

        var withTag = false
        if requester.kind != .kind, let value = approval.personToken,
            let tag = PersonMarker(value: value)
        {
            PortalMarkerSlot(keychain).create(tag, forItem: identifier)
            // This device came in through the approval with exactly this token: If it falls
            // victim to a revocation, this device falls too, and the self-sign-in
            // recognizes the new token by its being a different one.
            note.rememberUsed(tag)
            withTag = true
        }
        // **Now and not at the next foreground:** The person's second device is waiting
        // for exactly this token.
        SyncCall.call(.byHand)
        return withTag
    }

    /// The color marker as `#RRGGBB`, as the server demands it.
    public nonisolated static func colorWord(
        _ tag: Profile.ColorTag, colorValue: (String) -> UInt32?
    ) -> String {
        String(format: "#%06X", colorValue(tag.rawValue) ?? 0xD3_A8_50)
    }

    /// An error as a sentence — **never with trait or token in it.** The sentences come from
    /// the catalog via the server code; a network error names the address, never the body.
    public static func message(_ error: any Error, lookUp: (String) -> String?) -> String {
        if let rejection = error as? PortalBridge.TestError {
            return rejection.message(lookUp: lookUp)
        }
        return error.localizedDescription
    }
}

// MARK: - The administrator's side

/// A role on offer when approving — **from the server's list, or the old two.**
///
/// Since the console rebuild (2026-11-09) roles are data: the server sends them with the
/// request list (``PortalKit/Join/openRequestsWithRoles()``), and the administrator chooses
/// among the household's real roles. A server from before knows only `child`, `adult` and
/// `admin`; then the app offers child and adult, and the console switch turns adult into
/// the old `admin` (``PortalKit/JoinRole/admin(ownPin:)``).
public nonisolated struct RoleOption: Identifiable, Hashable, Sendable {
    /// The server's role id — or `child`/`adult` for an older server.
    public let id: String
    /// The role's name from the server; `nil` for the old two, which use ``titleKey``.
    public let name: String?
    /// The language key of the old two.
    public let titleKey: String
    /// `#RRGGBB`, `nil` for the old two.
    public let color: String?
    public let adult: Bool
    public let ownDevices: Bool
    /// From the server's list — then the role goes out by id with `console` apart.
    public let fromServer: Bool

    /// What the card says about the role — **from its rights, not its name**: a role called
    /// "Teens" says nothing, "no 18+, pairs its own devices" does.
    public var explanation: String {
        switch (adult, ownDevices) {
        case (true, true): "settings.portals.joinRoleHintAdultOwn"
        case (true, false): "settings.portals.joinRoleHintAdultPaired"
        case (false, true): "settings.portals.joinRoleHintOwn"
        case (false, false): "settings.portals.joinRoleHintPaired"
        }
    }

    /// The offer: the server's roles in its order, or child and adult.
    public static func offers(_ roles: [JoinableRole]?) -> [RoleOption] {
        guard let roles else { return legacy }
        return roles.map {
            RoleOption(
                id: $0.id, name: $0.name, titleKey: "", color: $0.color, adult: $0.adult,
                ownDevices: $0.ownDevices, fromServer: true)
        }
    }

    /// The two an older server knows — `admin` is adult plus the console switch.
    public static let legacy: [RoleOption] = [
        RoleOption(
            id: "child", name: nil, titleKey: "settings.portals.joinRoleChild", color: nil,
            adult: false, ownDevices: false, fromServer: false),
        RoleOption(
            id: "adult", name: nil, titleKey: "settings.portals.joinRoleAdult", color: nil,
            adult: true, ownDevices: true, fromServer: false),
    ]
}

/// The calculation behind the Approve button.
public nonisolated enum ApprovalRule {

    /// The role that goes to the server — **or `nil`, and then the button is locked.**
    ///
    /// No choice means no role; a default would be exactly the decision this path demands,
    /// made silently. With the console the new person additionally needs a PIN of their own,
    /// otherwise they never get into it.
    public static func role(_ option: RoleOption?, console: Bool, ownPin: String) -> JoinRole? {
        guard let option else { return nil }
        let pin = ownPin.trimmingCharacters(in: .whitespacesAndNewlines)
        if console, pin.isEmpty { return nil }
        if option.fromServer {
            return .chosen(id: option.id, consolePin: console ? pin : nil)
        }
        switch (option.id, console) {
        case ("adult", true): return .admin(ownPin: pin)
        case ("adult", false): return .adult
        case ("child", false): return .kind
        default: return nil
        }
    }

    /// Whether the console switch is offered for this role. **Always with a server role
    /// list**; an older server hands out the console only together with `adult`.
    public static func offersConsole(_ option: RoleOption?) -> Bool {
        guard let option else { return false }
        return option.fromServer || option.id == "adult"
    }

    /// Whether the button takes effect: a role **and** the approver's PIN.
    public static func ready(
        _ option: RoleOption?, console: Bool, pin: String, ownPin: String
    ) -> Bool {
        role(option, console: console, ownPin: ownPin) != nil
            && !pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the approval page appears at all.
    ///
    /// **On the right and never on the role** — the house rule from ``PortalKit/AccessRights``.
    /// ``PortalKit/SignInState/isAllowed(_:)`` always says no for a borrowed profile; the
    /// server would reject it anyway with `403 auth.borrowed_profile`.
    public static func isVisible(_ state: SignInState?) -> Bool {
        state?.isAllowed { $0.pairDevices } ?? false
    }
}

/// The open requests for the administrator — load, approve, reject.
@Observable
public final class JoinApprovalModel {

    public private(set) var requestJoin: [OpenRequest] = []
    /// What one can approve as — the server's roles, or the old two until it has answered.
    public private(set) var roleOptions: [RoleOption] = RoleOption.legacy
    public private(set) var isLoading = false
    public private(set) var isWorking = false
    /// The last refusal as a sentence.
    public private(set) var rejection: String?
    /// The code of the last refusal — for `household.person_exists`, in response to which the
    /// name field appears.
    public private(set) var rejectionCode: String?

    private let join: Join
    private let lookUp: @Sendable (String) -> String?

    public init(join: Join, lookUp: @escaping @Sendable (String) -> String?) {
        self.join = join
        self.lookUp = lookUp
    }

    /// This program's model — with trait and remembered profile of the device.
    public static func onDevice(
        lookUp: @escaping @Sendable (String) -> String?
    ) -> JoinApprovalModel? {
        let keychain = SecureStore()
        guard let bridgeAddress = BridgeAddress.effective(from: keychain),
            let trait = DeviceTrait.load(from: keychain)
        else { return nil }
        return JoinApprovalModel(
            join: Join(
                binding: PortalBridge(
                    basis: bridgeAddress, dialect: .cinelounge, trait: trait,
                    profile: DeviceTrait.profile(from: keychain))),
            lookUp: lookUp)
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await join.openRequestsWithRoles()
            requestJoin = loaded.requests
            roleOptions = RoleOption.offers(loaded.roles)
            rejection = nil
            rejectionCode = nil
        } catch {
            Diagnose.error(.login, "Open join requests not loaded", error)
            memorize(error)
        }
    }

    /// - Returns: whether it was approved. The request then disappears from the list.
    @discardableResult
    public func approve(
        _ request: OpenRequest, als role: JoinRole, pin: String, newName: String?
    ) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await join.approve(
                request.identifier, als: role, pin: pin, newName: newName)
            requestJoin.removeAll { $0.identifier == request.identifier }
            rejection = nil
            rejectionCode = nil
            return true
        } catch {
            Diagnose.error(.login, "Join request not accepted", error)
            memorize(error)
            return false
        }
    }

    @discardableResult
    public func reject(_ request: OpenRequest) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await join.reject(request.identifier)
            requestJoin.removeAll { $0.identifier == request.identifier }
            rejection = nil
            rejectionCode = nil
            return true
        } catch {
            Diagnose.error(.login, "Join request not declined", error)
            memorize(error)
            return false
        }
    }

    private func memorize(_ error: any Error) {
        rejection = JoinRequester.message(error, lookUp: lookUp)
        rejectionCode = (error as? PortalBridge.TestError)?.code
    }
}
