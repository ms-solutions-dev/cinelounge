import Core
import Foundation
import JellyfinKit
import Observation
import ProfileKit

/// A5 — **signing in Jellyfin inside the setup, on ``LoginFlow`` and without a second sign-in.**
///
/// The sheet adds only the path around the flow (AP88 §2.8): the address comes from the
/// profile, the server search and the method choice fall away, and Quick Connect starts as soon
/// as the server answers. Everything else — address variants, certificate question, code,
/// password — is the flow's, unchanged.
///
/// **Where a sign-in goes:** ``LoginFlow``'s `persist` is ``SetupJourney/signedIn(_:)``. The
/// journey holds the credential until the machine has compared the user (§2.8 point 4); the
/// sheet never stores anything itself.
///
/// **Which mode applies is the machine's** (``JellyfinMode``) and read from the journey on every
/// access — "Choose another server" and "Again" are inputs to the machine, not a second state
/// here.
@Observable
public final class SetupJellyfinSheet {

    /// What A5 shows.
    nonisolated public enum Step: Sendable, Equatable {
        /// The address is being checked or a code is being requested.
        case connecting
        /// **The profile's server does not answer** (§2.8 point 3) — moved, or another network.
        /// The access in the profile stays; "Choose another server" decides whether it is a move.
        case unreachable(errorKey: String?)
        /// `.fresh`: found servers and the address field.
        case chooseServer
        case code(QuickConnect.Session)
        /// The server offers no code, or the code failed — the password stays.
        case noCode(errorKey: String?)
        case password
        /// Quick Connect signed in someone else (§2.8 point 4).
        case otherUser(signedIn: String, expected: String)
    }

    public let login: LoginFlow

    @ObservationIgnored private let journey: SetupJourney
    @ObservationIgnored private let isChildAccount: (String) -> Bool

    /// - Parameters:
    ///   - memory: where the last checked address lives (``LoginFlow/addressKey``).
    ///   - isChildAccount: whether an access ID (`server|user`) carries a child-account marker
    ///     (``ParentalControls/ChildAccountList/isChild(_:)``).
    ///   - searchMode: how ``LoginFlow`` searches — the TV broadcasts first, the phone runs both at
    ///     once (``LoginFlow/SearchMode/bothAtOnce``, AP58 R7).
    public init(
        journey: SetupJourney, services: LoginServices = .real(), deviceID: String,
        deviceName: String, trust: CertificateTrustStore = CertificateTrustStore(),
        memory: (any KeyValueStore)? = nil, isChildAccount: @escaping (String) -> Bool = { _ in false },
        searchMode: LoginFlow.SearchMode = .broadcastFirst
    ) {
        self.journey = journey
        self.isChildAccount = isChildAccount
        login = LoginFlow(
            services: services, searchMode: searchMode, deviceID: deviceID,
            deviceName: deviceName, trust: trust, memory: memory,
            persist: { [weak journey] in journey?.signedIn($0) })
    }

    /// The machine's mode — `nil` once the sheet is closed.
    public var mode: JellyfinMode? {
        if case .jellyfin(_, let mode) = journey.state { return mode }
        return nil
    }

    /// The profile the sheet signs in — for "Lea · Jellyfin".
    public var profile: SetupProfile? {
        guard case .jellyfin(let identifier, _) = journey.state else { return nil }
        return journey.machine.setupProfile(identifier)
    }

    /// **Child-account markers keep working** (N4, §2.8 point 5) — A5 says so, so that nobody
    /// looks for a fault when an adult profile sees the child's lock.
    public var marksChildAccount: Bool {
        guard let access = profileAccess, let identifier = access.legacyAccountID else { return false }
        return isChildAccount(identifier)
    }

    /// What the server calls itself, or its host.
    public var serverName: String {
        if let reply = login.serverReply { return reply.serverName }
        if case .jellyfin(let server, _, _) = profileAccess { return server.host() ?? server.absoluteString }
        return login.server?.host() ?? ""
    }

    public var step: Step {
        guard let mode else { return .connecting }
        if case .otherUser(let signedIn, let expected, _) = mode {
            return .otherUser(signedIn: signedIn, expected: expected)
        }
        switch login.phase {
        case .server:
            if case .fresh = mode { return .chooseServer }
            return login.error == nil ? .connecting : .unreachable(errorKey: login.error)
        case .connect, .done:
            return .connecting
        case .loginRoute:
            return login.isRunning ? .connecting : .noCode(errorKey: login.error)
        case .password:
            return login.isRunning ? .connecting : .password
        case .code(let session):
            return .code(session)
        }
    }

    // MARK: - Actions

    /// Opens the sheet: with the profile's address straight to the code, or the server search.
    public func begin() async {
        switch mode {
        case .confirm(let access): await confirm(access)
        case .fresh: await login.searchServers()
        case .otherUser, nil: break
        }
    }

    /// A found server (``Step/chooseServer``).
    public func select(_ found: ServerDiscovery.Found) async {
        await login.select(found)
        await startCodeIfOffered()
    }

    /// The typed address (``Step/chooseServer``).
    public func connect() async {
        await login.checkAddress()
        await startCodeIfOffered()
    }

    /// The fingerprint was confirmed — check again and go on to the code.
    public func trustCertificate() async {
        await login.trustCertificate()
        await startCodeIfOffered()
    }

    public func rejectCertificate() {
        login.rejectCertificate()
    }

    /// The profile's server again after it did not answer.
    public func retry() async {
        guard case .confirm(let access) = mode else { return }
        await confirm(access)
    }

    /// A new code after one expired or failed.
    public func newCode() async {
        await login.startCode()
    }

    /// "Sign in with a password" — **the user from the profile is filled in**, the password is
    /// typed.
    public func choosePassword() {
        login.cancelCode()
        login.choosePassword()
        if case .jellyfin(_, _, let username) = profileAccess { login.user = username }
    }

    public func signIn() async {
        await login.notify()
    }

    /// "Choose another server" — the server choice, **without touching the profile's access.**
    public func chooseOtherServer() async {
        login.restart()
        login.address = ""
        journey.send(.chooseOtherServer)
        await login.searchServers()
    }

    /// "Take over as tom".
    public func acceptOtherUser() {
        journey.send(.acceptOtherUser)
    }

    /// "Again" — back to the profile's user, with a fresh code.
    public func again() async {
        journey.send(.back)
        await begin()
    }

    /// The Menu button — **within the sheet first, then back to A4.**
    ///
    /// From the password to the code (or to "no code"); from the code of a server chosen by
    /// hand to the server choice; everything else closes the sheet. A confirmation has no server
    /// choice behind it: its way back is A4 (§3, `LoginFlow`).
    public func back() async {
        switch step {
        case .otherUser:
            await again()
        case .password:
            login.back()
            if login.canUseCode { await login.startCode() }
        case .code, .noCode:
            if case .fresh = mode {
                login.restart()
            } else {
                close()
            }
        case .connecting, .unreachable, .chooseServer:
            close()
        }
    }

    /// Cancels a running code — **when the sheet disappears**, however it went.
    public func stop() {
        login.cancelCode()
    }

    // MARK: - Inside

    private var profileAccess: Access? {
        switch mode {
        case .confirm(let access), .otherUser(_, _, let access): access
        case .fresh, nil: nil
        }
    }

    private func confirm(_ access: Access) async {
        guard case .jellyfin(let server, _, _) = access else { return }
        login.restart()
        login.address = server.absoluteString
        await login.checkAddress()
        await startCodeIfOffered()
    }

    /// **Quick Connect is the normal case** (§2.8 point 2) — the method choice falls away.
    private func startCodeIfOffered() async {
        guard login.phase == .loginRoute, login.canUseCode else { return }
        await login.startCode()
    }

    private func close() {
        login.cancelCode()
        journey.send(.back)
    }
}
