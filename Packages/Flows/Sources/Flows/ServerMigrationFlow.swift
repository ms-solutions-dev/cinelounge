import Core
import Diagnose
import Foundation
import JellyfinKit
import Observation
import ProfileKit

/// Rewrites the address of a server that has moved — **after checking whether
/// the same server answers there** (AP58 R7, finding E2).
///
/// **The finding:** Two models of the same name, `UmzugModell` on the TV and on the
/// phone, with the same rule (``Core/ServerMove``, since AP41), two state shapes
/// and two address readers — on the phone, until wave 1, `URL(string:)` read the input
/// `jellyfin.example:8096` as a scheme without a host. Now one flow.
///
/// **A move is not a login.** The access token still applies; it belongs to the server
/// and not to its address. The decision is made on the server ID
/// (``JellyfinKit/JellyfinConnection/ServerInfo/id``), never on the name — "Jellyfin" is the
/// shipping name. **Where there is no ID, it does not guess but asks**
/// (``confirmWithoutID()``).
///
/// **Which server moves is stated by the platform:** The TV passes in the account of the
/// selected profile, the phone the signed-in session
/// (``init(sessionFrom:verify:)``). Everything under the old address moves along.
@Observable
public final class ServerMigrationFlow {

    /// Where the comparison leads.
    nonisolated public enum Finding: Sendable, Equatable {
        /// Nothing checked yet.
        case pending
        case isRunning
        /// The same server — the move is one.
        case sameOne(name: String)
        /// A **different** server. Not a move but a second one — not an error: It could
        /// just as well be a mistyped address.
        case other(name: String)
        /// The previous access carries no ID; nothing can be compared.
        case withoutIdentifier(name: String)
        /// No Jellyfin answers at the address. Key in the catalog.
        case error(String)
        /// Moved. This many accesses moved along.
        case relocated(count: Int)
    }

    public private(set) var finding: Finding = .pending
    public var address = ""

    /// The address at which the server has been so far.
    public let previous: URL?
    private let knownID: String?
    private let keychain: SecureStore
    /// Wo ``ProfileKit/ProfileBook`` liegt — siehe ``adopt()``.
    private let ledgerStore: any KeyValueStore
    private let query: @Sendable (URL) async throws -> (url: URL, info: JellyfinConnection.ServerInfo)

    /// The address that the comparison has confirmed. Only it may be adopted.
    private var verified: URL?

    /// Whether a move **without a verifiable ID** was explicitly agreed to.
    public private(set) var confirmedWithoutID = false

    /// - Parameters:
    ///   - bisher: the address at which the server has been so far — `nil` means: no account.
    ///   - serverkennung: the ID that came along on login (``Core/ServerCredentials/serverID``).
    ///   - buchablage: where ``ProfileKit/ProfileBook`` lives — its profiles move along (E3).
    ///     `nil` means the device's file store.
    ///   - pruefe: how an address is queried — the checks pass in an answer.
    public init(
        from previous: URL?,
        serverID: String?,
        keychain: SecureStore = SecureStore(),
        ledgerStore: (any KeyValueStore)? = nil,
        verify: @escaping @Sendable (URL) async throws -> (url: URL, info: JellyfinConnection.ServerInfo) =
            { try await JellyfinConnection().probeAny($0) }
    ) {
        self.previous = previous
        self.knownID = serverID
        self.keychain = keychain
        self.ledgerStore = ledgerStore ?? FileStore()
        self.query = verify
    }

    /// The server ID **of the account that is moving** — not that of the running session
    /// (check Setup, E5, 2026-09-27).
    ///
    /// On the TV the server of a **selected** profile moves. Until then it was compared
    /// with the ID of the active session: If that hung on a different server,
    /// the right new address was "a different server" and the move impossible — and the
    /// address of the active server, typed by mistake, was "the same". The search is done in
    /// the account list by address and user; the session only if it is exactly this
    /// account (a device from the time before the list).
    public static func serverID(
        server: URL, user: String, in keychain: SecureStore
    ) -> String? {
        if let account = keychain.allAccounts().first(where: {
            $0.serverURL == server && $0.userID == user
        }) {
            return account.serverID
        }
        guard let session = try? keychain.loadCredentials(),
            session.serverURL == server, session.userID == user
        else { return nil }
        return session.serverID
    }

    /// The move of the **signed-in session** — the phone's path.
    public convenience init(
        sessionFrom keychain: SecureStore = SecureStore(),
        verify: @escaping @Sendable (URL) async throws -> (url: URL, info: JellyfinConnection.ServerInfo) =
            { try await JellyfinConnection().probeAny($0) }
    ) {
        let session = try? keychain.loadCredentials()
        self.init(
            from: session?.serverURL, serverID: session?.serverID,
            keychain: keychain, verify: verify)
    }

    /// The address at which the server was previously reachable — for the notice.
    public var previousAddress: String? { previous?.absoluteString }

    /// The typed address as a URL — **via the same rule as login**
    /// (``JellyfinKit/JellyfinConnection/normalizeAddress(_:)``): It adds `http://` and
    /// requires a host.
    public nonisolated static func target(from input: String) -> URL? {
        JellyfinConnection.normalizeAddress(input)
    }

    /// What the comparison of two IDs means — the rule from ``Core/ServerMove``,
    /// translated into the ``Finding``.
    public nonisolated static func finding(reported: String, previous: String?, name: String) -> Finding {
        switch ServerMove.compare(reported: reported, previous: previous, name: name) {
        case .sameOne: .sameOne(name: name)
        case .withoutIdentifier: .withoutIdentifier(name: name)
        case .other: .other(name: name)
        }
    }

    private static func asRuleFinding(_ own: Finding) -> ServerMove.Finding? {
        switch own {
        case .sameOne(let name): .sameOne(name: name)
        case .withoutIdentifier(let name): .withoutIdentifier(name: name)
        case .other(let name): .other(name: name)
        case .pending, .isRunning, .error, .relocated: nil
        }
    }

    /// Whether an explicit consent has to be asked for here.
    public var asksForConsent: Bool {
        if case .withoutIdentifier = finding { return !confirmedWithoutID }
        return false
    }

    /// Agreed, although it could not be checked.
    public func confirmWithoutID() {
        confirmedWithoutID = true
    }

    /// Whether "Adopt address" may do anything — **only after a comparison that allows it.**
    public var isAdoptable: Bool {
        guard verified != nil, let rule = Self.asRuleFinding(finding) else { return false }
        return ServerMove.mayMove(rule, confirmed: confirmedWithoutID)
    }

    /// Queries the new address and compares the IDs.
    ///
    /// **The address is remembered even without an ID**, because otherwise there would be nothing to
    /// adopt if consent is given right away. Whether adopting is **allowed** is decided by
    /// ``isAdoptable``.
    public func verify() async {
        guard previous != nil else {
            finding = .error("accounts.move.noAccount")
            return
        }
        guard let target = Self.target(from: address) else {
            finding = .error(JellyfinConnection.Failure.invalidAddress.messageKey)
            return
        }
        finding = .isRunning
        verified = nil
        confirmedWithoutID = false
        do {
            let (found, info) = try await query(target)
            let result = Self.finding(
                reported: info.id, previous: knownID, name: info.serverName)
            switch result {
            case .sameOne, .withoutIdentifier: verified = found
            default: verified = nil
            }
            finding = result
            Diagnose.step(.login, "Server move checked: \(result)")
        } catch let failure as JellyfinConnection.Failure {
            finding = .error(failure.messageKey)
        } catch {
            Diagnose.hint(.login, "Server move check failed", error)
            finding = .error(JellyfinConnection.Failure.unreachable.messageKey)
        }
    }

    /// Rewrites the address — in the list, in the session **and in every profile.**
    ///
    /// **Everything under the old address moves along:** Two people on the same server
    /// do not have two moves.
    ///
    /// **The profiles belong to it** (check Setup, E3, 2026-09-27). Until then
    /// the move rewrote only the account list and the session; the profiles kept the
    /// old address, and the next profile switch found no account under it — the
    /// session was cleared, the media library was gone.
    ///
    /// **Zero is not a move** (E4): If there was nothing at all under the old address, the
    /// flow says so instead of reporting "moved" and closing the sheet.
    ///
    /// **All or nothing** (ultra e5, round A.1, 2026-09-27). Until then the
    /// flow wrote the profiles **before** it knew whether an access had moved along: With
    /// "nothing moved" the profiles already pointed to the new address, under which there was
    /// no account. The profiles therefore follow only once at least one access
    /// has moved.
    public func adopt() {
        guard let previous, let fresh = verified, isAdoptable else { return }
        do {
            let count = try keychain.relocate(from: previous, after: fresh)
            guard count > 0 else {
                finding = .error("accounts.move.nothingMoved")
                Diagnose.hint(.login, "Server move: nothing at the old address, profiles unchanged")
                return
            }
            var ledger = ProfileBook.read(from: ledgerStore)
            let profile = ledger.moveServer(from: previous, after: fresh)
            if profile > 0 { ledger.write(in: ledgerStore) }
            finding = .relocated(count: count)
            Diagnose.step(.login, "Server move applied, \(count) credentials, \(profile) profiles")
        } catch {
            Diagnose.error(.login, "Server move could not be written", error)
            finding = .error(JellyfinConnection.Failure.unreachable.messageKey)
        }
    }

    /// Back to the input, **without throwing away the typed text** — on tvOS
    /// typing is the platform's most expensive operation.
    public func backToInput() {
        finding = .pending
        verified = nil
        confirmedWithoutID = false
    }
}
