import Core
import Diagnose
import Foundation
import JellyfinKit
import Observation

/// Signing in at a media server — **find the server, check the address, sign in with code or
/// password** (AP58 R7, finding E1).
///
/// **The finding:** On the TV this flow lived in the app target (`LoginModel`) and had
/// not a single test; on the phone it lived a second time in the `SetupModel`, with
/// different error keys, without address memory and with a code that only learned at the
/// press whether the server offers it. The search in the home network ran differently at both
/// places, and the reachability check (AP18) was missing on the phone until wave 1.
///
/// **What stays per device is the path around it:** path choice, network explanation, channel list,
/// portals and handoff belong to the platform models. They read ``phase`` and map it
/// onto their own steps. **Where an account is put** is told by the callback
/// `persist` — on the TV the session in the Keychain, on the phone the
/// `SetupState`, which additionally writes it into the account list.
///
/// **The deliberately differing spots appear as values and not as a second version:**
/// ``SearchMode`` (the TV calls out first and probes only if the broadcast comes back empty, the
/// phone does both at once) and the address memory (only the TV, where
/// typing is the most expensive process).
@Observable
public final class LoginFlow {

    /// Where the sign-in stands.
    nonisolated public enum Phase: Sendable, Equatable {
        /// Enter an address or choose a find.
        case server
        /// The address is being checked.
        case connect
        /// The server answers — code or password?
        case loginRoute
        case password
        /// The code is shown and waits for confirmation on the other device.
        case code(QuickConnect.Session)
        case done(ServerCredentials)
    }

    /// How the home network is searched.
    nonisolated public enum SearchMode: Sendable, Equatable {
        /// **First the broadcast, probing only if it stays empty** — the TV.
        ///
        /// The broadcast costs one packet and returns the address the server itself considers
        /// the right one; probing costs up to 254 requests. The list appears only
        /// at the end, including reachability: A list that keeps growing under the focus
        /// moves away from the viewer.
        case broadcastFirst
        /// **Both side by side, the finds grow along** — the phone.
        ///
        /// Together both take as long as the longer one; whoever only calls out never finds a
        /// server in a container (it does not publish `7359/udp`), whoever only probes
        /// loses everyone beyond their own `/24`.
        case bothAtOnce
    }

    /// How long a code is valid. The server discards unconfirmed codes after five minutes.
    public static let codeLifetime = 300

    /// Where the last checked address lives — structure, hence file store (README,
    /// "Where a setting belongs"). Until R7 it lived on the TV in `UserDefaults`.
    public static let addressKey = "server.lastAddress"

    /// Brings the address remembered on the TV in `UserDefaults` until R7 **once** into the
    /// file store and cleans up there (decision 2: clean cut). An address already
    /// standing there wins — it is the younger one.
    public static func adoptLegacyAddress(from legacy: UserDefaults, in fresh: any KeyValueStore) {
        guard let address = legacy.string(forKey: addressKey) else { return }
        if (try? fresh.value(for: addressKey)) == nil {
            try? fresh.set(address, for: addressKey)
        }
        legacy.removeObject(forKey: addressKey)
    }

    public private(set) var phase: Phase = .server
    /// Translation key of the last failure — all from the shared catalog.
    public private(set) var error: String?
    /// Whether a request is currently running that has no step of its own (password sign-in).
    public private(set) var isRunning = false

    public var address: String
    public var user = ""
    public var password = ""

    /// The resolved address of the server — not the one entered.
    public private(set) var server: URL?
    public private(set) var serverReply: JellyfinConnection.ServerInfo?
    /// Whether the server offers sign-in by code — **asked beforehand**, so that no button
    /// stands there that only learns at the press that it does not exist.
    public private(set) var canUseCode = false

    /// The open certificate question — `nil` if none is pending.
    ///
    /// A rejected certificate arrives as an ordinary connection error; what
    /// distinguishes it lies only in the mailbox (``Grundstock/CertificatePrompt``). Until R7
    /// the TV looked in there via an `onChange` of the error message, the
    /// phone here in the flow.
    public private(set) var certificatePrompt: CertificatePrompt.Pending?

    /// Verbleibende Sekunden des laufenden Codes.
    public private(set) var remainingSeconds = codeLifetime

    // MARK: Search

    /// The finds of the search in the order of the search.
    public private(set) var discoveries: [ServerDiscovery.Found] = []
    /// Which finds this device does **not** reach — by ID (AP18).
    public private(set) var unreachable: Set<String> = []
    public private(set) var isSearching = false

    /// The finds with their reachability note. An unreachable one stays selectable: It
    /// is there, only the path to it is wrong.
    public var verifiedDiscoveries: [ServerDiscovery.Reachability] {
        discoveries.map { .init(found: $0, reachable: !unreachable.contains($0.id)) }
    }

    /// The address for the QR code: the server's web interface, where confirmation happens.
    public var codeWebAddress: String {
        guard let server else { return "" }
        return server.appending(path: "web/index.html").absoluteString + "#/quickconnect"
    }

    private let services: LoginServices
    private let searchMode: SearchMode
    private let deviceID: String
    private let deviceName: String
    private let trust: CertificateTrustStore
    private let memory: (any KeyValueStore)?
    private let persist: @MainActor (ServerCredentials) -> Void

    private var searchRun: Task<Void, Never>?
    private var codeRun: Task<Void, Never>?
    private var clock: Task<Void, Never>?

    /// - Parameters:
    ///   - gedaechtnis: Where the last checked address lives; `nil` remembers nothing.
    ///   - ablegen: what happens with a new account before ``phase`` jumps to ``Phase/done(_:)``.
    public init(
        services: LoginServices = .real(),
        searchMode: SearchMode,
        deviceID: String,
        deviceName: String,
        trust: CertificateTrustStore = CertificateTrustStore(),
        memory: (any KeyValueStore)? = nil,
        persist: @escaping @MainActor (ServerCredentials) -> Void
    ) {
        self.services = services
        self.searchMode = searchMode
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.trust = trust
        self.memory = memory
        self.persist = persist
        self.address = memory.flatMap { try? $0.value(for: Self.addressKey) } ?? ""
    }

    // MARK: - Search on the home network

    /// Searches for media servers in the home network and re-checks every find (AP18).
    ///
    /// **With ``SearchMode/bothAtOnce`` the broadcast wins on equal ID** — its
    /// address is the one the server itself considers the right one.
    public func searchServers() async {
        isSearching = true
        discoveries = []
        unreachable = []
        error = nil
        defer { isSearching = false }

        let found: [ServerDiscovery.Found]
        switch searchMode {
        case .broadcastFirst:
            // Here too via ``NetworkScan/create(combined:and:)`` — the broadcast alone
            // returns the same server once per broadcast address (T2, 2026-09-27).
            let called = NetworkScan.create(combined: await services.broadcast(), and: [])
            found = called.isEmpty ? await runProbe(growing: false) : called
        case .bothAtOnce:
            async let called = services.broadcast()
            let probed = await runProbe(growing: true)
            found = NetworkScan.create(combined: await called, and: probed)
        }
        guard !Task.isCancelled else { return }

        let verified = await ServerDiscovery.verify(
            NetworkScan.create(combined: found, and: []), using: services.reached)
        discoveries = verified.map(\.found)
        // Every find with shortened ID and address — so that a duplicate in the image
        // can be checked against the log and does not have to be guessed.
        Diagnose.step(
            .login,
            "Discoveries: "
                + discoveries.map { "\($0.id.prefix(6))@\($0.address.host() ?? "?")" }.joined(separator: ", ")
        )
        unreachable = Set(verified.filter { !$0.reachable }.map(\.id))
        Diagnose.step(
            .login, "Search finished: \(discoveries.count) servers, \(unreachable.count) unreachable")
    }

    /// Starts the search as a task of its own — so that a chosen find can cancel it.
    public func startSearch() {
        searchRun?.cancel()
        searchRun = Task { await searchServers() }
    }

    /// Probes the own network.
    ///
    /// **A lock and not an actor** collects the finds: The callback is synchronous and comes
    /// from a group of up to 64 requests; a `Task { }` inside it would leave finds
    /// open after the end, and the list would be complete one time and not the next.
    /// - Parameter mitwachsend: whether every find appears in ``discoveries`` immediately.
    private func runProbe(growing: Bool) async -> [ServerDiscovery.Found] {
        let collector = DiscoveryCollector()
        let displayed: (@Sendable (ServerDiscovery.Found) -> Void)? =
            growing
            ? { @Sendable [weak self] fund in _ = Task { @MainActor in self?.takeDiscovery(fund) } } : nil
        await services.probe { fund in
            collector.take(fund)
            displayed?(fund)
        }
        return collector.discoveries
    }

    /// Files a find — **once per server.** The same server reported on 2026-09-10
    /// under two different addresses with the same ID.
    func takeDiscovery(_ fund: ServerDiscovery.Found) {
        guard
            !discoveries.contains(where: {
                $0.id == fund.id
                    || ($0.address.host() == fund.address.host() && $0.address.port == fund.address.port)
            })
        else { return }
        discoveries.append(fund)
    }

    // MARK: - Address

    /// A find was chosen: The address moves into the field and is checked — via the
    /// field and not around it, so that variants and certificate question apply.
    public func select(_ fund: ServerDiscovery.Found) async {
        searchRun?.cancel()
        address = fund.address.absoluteString
        await checkAddress()
    }

    /// Checks whether a Jellyfin really answers at the entered address.
    ///
    /// **`probeAny` and not `probe`:** Anyone who types a short host name means one of several
    /// spellings. **And right afterwards the question about the code** — at the resolved
    /// address, otherwise the wrong target is queried.
    public func checkAddress() async {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let target = JellyfinConnection.normalizeAddress(address) else {
            error = JellyfinConnection.Failure.invalidAddress.messageKey
            phase = .server
            return
        }
        error = nil
        phase = .connect
        do {
            let (resolved, info) = try await services.verify(target)
            server = resolved
            serverReply = info
            address = resolved.absoluteString
            try? memory?.set(resolved.absoluteString, for: Self.addressKey)
            canUseCode = await services.canUseCode(resolved)
            Diagnose.step(.login, "Server recognized: \(info.serverName)")
            phase = .loginRoute
        } catch let failure as JellyfinConnection.Failure {
            Diagnose.hint(.login, "Server not reached: \(failure.messageKey)")
            takeCertificatePrompt(fallback: failure.messageKey)
        } catch {
            Diagnose.hint(.login, "Server not reached", error)
            takeCertificatePrompt(fallback: JellyfinConnection.Failure.unreachable.messageKey)
        }
    }

    /// **First look into the mailbox, then report.** Whoever shows the message without looking
    /// there sends the viewer off to check an address that is right.
    func takeCertificatePrompt(fallback key: String) {
        if let pending = CertificatePrompt.shared.current {
            Diagnose.step(.login, "Certificate of \(pending.host) needs confirmation")
            certificatePrompt = pending
            error = nil
        } else {
            error = key
        }
        phase = .server
    }

    /// Confirms the shown fingerprint — **and tries again right away.**
    public func trustCertificate() async {
        guard confirmCertificate() else { return }
        await checkAddress()
    }

    /// Only the confirmation, **without waiting** — for a prompt that closes
    /// itself at the press: When closing, it asks whether another question is still open, and
    /// must then find none, otherwise it would read the confirmation as a rejection.
    /// - Returns: whether a question was open.
    @discardableResult
    public func confirmCertificate() -> Bool {
        guard let pending = certificatePrompt else { return false }
        try? trust.trust(pending.fingerprint, for: pending.host)
        CertificatePrompt.shared.answer(pending)
        certificatePrompt = nil
        return true
    }

    /// Rejected — **and the mailbox is emptied**, otherwise a question left lying around
    /// would pop up again at the next, entirely different failure.
    public func rejectCertificate() {
        if let pending = certificatePrompt { CertificatePrompt.shared.answer(pending) }
        certificatePrompt = nil
        error = "cert.rejected"
        phase = .server
    }

    // MARK: - Password

    /// Switches to password entry — with empty fields.
    public func choosePassword() {
        user = ""
        password = ""
        error = nil
        phase = .password
    }

    /// Signs in with name and password. **The password is not kept afterwards** — what
    /// comes back is an access token. On a failure the reason goes into the ledger,
    /// the password does not.
    public func notify() async {
        guard let server, !user.isEmpty else { return }
        isRunning = true
        error = nil
        defer { isRunning = false }
        do {
            let credential = try await services.notify(
                server, user, password, deviceID, deviceName)
            complete(using: credential)
        } catch let failure as JellyfinConnection.Failure {
            Diagnose.hint(.login, "Sign-in rejected: \(failure.messageKey)")
            error = failure.messageKey
        } catch let thrownError {
            Diagnose.hint(.login, "Sign-in failed", thrownError)
            error = JellyfinConnection.Failure.unreachable.messageKey
        }
    }

    // MARK: - Code

    /// The path through the six-digit code — **with a clock, and cancelable.**
    ///
    /// `waitForApproval` polls for five minutes. Without the handle on the task it kept
    /// running if the viewer went back, and later pushed the screen to "Done" without
    /// their doing anything (finding on the phone; on the TV only "Cancel" canceled,
    /// "Back" did not).
    public func startCode() async {
        guard let server else { return }
        guard canUseCode else {
            error = QuickConnect.Failure.notEnabled.messageKey
            phase = .loginRoute
            return
        }
        codeRun?.cancel()
        let run = Task { @MainActor in await self.runCode(server) }
        codeRun = run
        await run.value
    }

    /// **Canceled means canceled** — also between the last poll and filing;
    /// a canceled run files no account and pushes no screen onward.
    private func runCode(_ server: URL) async {
        error = nil
        isRunning = true
        do {
            let session = try await services.beginCode(server, deviceID, deviceName)
            isRunning = false
            guard !Task.isCancelled else { return }
            phase = .code(session)
            startClock()
            let credential = try await services.waitForCode(
                server, session, deviceID, deviceName, .seconds(Self.codeLifetime))
            guard !Task.isCancelled else { return }
            stopClock()
            complete(using: credential)
        } catch let thrownError {
            isRunning = false
            guard !Task.isCancelled, !(thrownError is CancellationError) else { return }
            stopClock()
            Diagnose.hint(.login, "Code sign-in failed", thrownError)
            error =
                (thrownError as? QuickConnect.Failure)?.messageKey
                ?? JellyfinConnection.Failure.unreachable.messageKey
            phase = .loginRoute
        }
    }

    /// Cancels the running code and goes back to the choice of the sign-in path.
    public func cancelCode() {
        abortCode()
        if case .code = phase { phase = .loginRoute }
    }

    private func abortCode() {
        codeRun?.cancel()
        codeRun = nil
        stopClock()
    }

    private func startClock() {
        remainingSeconds = Self.codeLifetime
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.remainingSeconds > 0 else { return }
                self.remainingSeconds -= 1
            }
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
    }

    // MARK: - End and way back

    private func complete(using credential: ServerCredentials) {
        password = ""
        persist(credential)
        phase = .done(credential)
    }

    /// An account that was created **elsewhere** (the handoff from the phone) — continue as
    /// after a sign-in, without filing it again.
    public func adopt(_ credential: ServerCredentials) {
        abortCode()
        phase = .done(credential)
    }

    /// One step back **within** the sign-in.
    ///
    /// From password and from code back to the choice of the sign-in path, from there to the address —
    /// whoever goes back on the password screen wants to change the path and not
    /// the server. A running code is canceled in the process.
    /// - Returns: `false` if the sign-in begins here — then the way back belongs to the
    ///   platform model (path choice or network explanation).
    @discardableResult
    public func back() -> Bool {
        error = nil
        abortCode()
        switch phase {
        case .loginRoute:
            phase = .server
            return true
        case .password, .code:
            phase = .loginRoute
            return true
        case .server, .connect, .done:
            return false
        }
    }

    /// Resets everything to the start without clearing the address field.
    public func restart() {
        abortCode()
        searchRun?.cancel()
        error = nil
        phase = .server
    }

    /// Sets the phase — **only for checks** that want to enter in the middle of a path
    /// without signing in a server.
    @_spi(Check) public func setPhaseForTesting(_ incoming: Phase) {
        phase = incoming
    }

    /// Files a find like the search — **only for checks.**
    @_spi(Check) public func takeDiscoveryForTesting(_ fund: ServerDiscovery.Found) {
        takeDiscovery(fund)
    }

    /// Like ``takeCertificatePrompt(fallback:)`` — **only for checks.**
    @_spi(Check) public func takeCertificatePromptForTesting(fallback key: String) {
        takeCertificatePrompt(fallback: key)
    }
}

/// Collects the finds of the probing — **a lock and not an actor**, see
/// ``LoginFlow``.
nonisolated private final class DiscoveryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [ServerDiscovery.Found] = []

    var discoveries: [ServerDiscovery.Found] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func take(_ fund: ServerDiscovery.Found) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(fund)
    }
}

/// What the sign-in needs from the network — **as values, so that the checks get by without a
/// server.** ``real(connection:quickConnect:)`` is the program's path.
nonisolated public struct LoginServices: Sendable {
    public typealias Hit = ServerDiscovery.Found

    public var broadcast: @Sendable () async -> [Hit]
    /// Probes the own network and reports every find immediately.
    public var probe: @Sendable (_ fund: @escaping @Sendable (Hit) -> Void) async -> Void
    /// Whether this address is reachable (AP18).
    public var reached: @Sendable (URL) async -> Bool
    public var verify: @Sendable (URL) async throws -> (url: URL, info: JellyfinConnection.ServerInfo)
    public var canUseCode: @Sendable (URL) async -> Bool
    public var beginCode:
        @Sendable (_ server: URL, _ device: String, _ name: String) async throws -> QuickConnect.Session
    public var waitForCode:
        @Sendable (
            _ server: URL, _ session: QuickConnect.Session, _ device: String, _ name: String,
            _ deadline: Duration
        ) async throws -> ServerCredentials
    public var notify:
        @Sendable (
            _ server: URL, _ user: String, _ password: String, _ device: String, _ name: String
        ) async throws -> ServerCredentials

    public init(
        broadcast: @escaping @Sendable () async -> [Hit],
        probe: @escaping @Sendable (_ fund: @escaping @Sendable (Hit) -> Void) async -> Void,
        reached: @escaping @Sendable (URL) async -> Bool,
        verify: @escaping @Sendable (URL) async throws -> (url: URL, info: JellyfinConnection.ServerInfo),
        canUseCode: @escaping @Sendable (URL) async -> Bool,
        beginCode: @escaping @Sendable (URL, String, String) async throws -> QuickConnect.Session,
        waitForCode:
            @escaping @Sendable (URL, QuickConnect.Session, String, String, Duration) async throws ->
            ServerCredentials,
        notify: @escaping @Sendable (URL, String, String, String, String) async throws -> ServerCredentials
    ) {
        self.broadcast = broadcast
        self.probe = probe
        self.reached = reached
        self.verify = verify
        self.canUseCode = canUseCode
        self.beginCode = beginCode
        self.waitForCode = waitForCode
        self.notify = notify
    }

    /// The program's path: broadcast, probing the own network, `JellyfinConnection`
    /// and `QuickConnect`.
    public static func real(
        connection: JellyfinConnection = JellyfinConnection(),
        quickConnect: QuickConnect = QuickConnect()
    ) -> LoginServices {
        LoginServices(
            broadcast: { await ServerDiscovery().search() },
            probe: { fund in
                guard let network = NetworkScan.ownNetwork() else {
                    Diagnose.hint(.login, "Search: no usable IPv4 network, broadcast only")
                    return
                }
                let targets = NetworkScan.addresses(own: network.address, mask: network.mask)
                guard !targets.isEmpty else { return }
                Diagnose.step(.login, "Search: \(targets.count) addresses on network \(network.address)")
                await NetworkScan.knock(
                    on: targets, query: { await NetworkScan.queryServer($0) }, fund: fund)
            },
            reached: { (try? await connection.probeAny($0)) != nil },
            verify: { try await connection.probeAny($0) },
            canUseCode: { await quickConnect.isEnabled(server: $0) },
            beginCode: { try await quickConnect.begin(server: $0, deviceID: $1, deviceName: $2) },
            waitForCode: {
                try await quickConnect.waitForApproval(
                    server: $0, session: $1, deviceID: $2, deviceName: $3, timeout: $4)
            },
            notify: {
                try await connection.authenticate(
                    server: $0, username: $1, password: $2, deviceID: $3, deviceName: $4)
            })
    }

    /// A network without a network — **only for checks.** Every call that a check does not
    /// specify fails like a server that does not answer.
    @_spi(Check) public static func mock(
        broadcast: [Hit] = [],
        probed: [Hit] = [],
        reached: @escaping @Sendable (URL) -> Bool = { _ in true },
        server: JellyfinConnection.ServerInfo? = nil,
        canUseCode: Bool = false,
        credential: ServerCredentials? = nil
    ) -> LoginServices {
        LoginServices(
            broadcast: { broadcast },
            probe: { fund in probed.forEach(fund) },
            reached: { reached($0) },
            verify: { address in
                guard let server else { throw JellyfinConnection.Failure.unreachable }
                return (address, server)
            },
            canUseCode: { _ in canUseCode },
            beginCode: { _, _, _ in throw QuickConnect.Failure.notEnabled },
            waitForCode: { _, _, _, _, _ in throw QuickConnect.Failure.expired },
            notify: { _, _, _, _, _ in
                guard let credential else { throw JellyfinConnection.Failure.wrongCredentials }
                return credential
            })
    }
}
