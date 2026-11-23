import Core
import Diagnose
@_spi(Check) import Flows
import Foundation
@_spi(Check) import JellyfinKit
import Observation
import PlaylistKit

/// One source added by hand — **a Jellyfin account or an IPTV list, from the settings and from
/// the first setup's IPTV row.**
///
/// **Until AP88 wave 6 this was the phone's whole first setup** (`SetupModel` with the path
/// choice). The first setup now runs on the shared ``Flows/SetupJourney`` (``SetupModel``); what
/// stays here are the forms behind "Add account" and "New channel list", which begin at their
/// path and never at a choice between paths.
///
/// **The sign-in to the media server has been in the shared ``Flows/LoginFlow`` since AP58 R7**
/// (finding E1) — the same flow as on the TV, with ``Flows/LoginFlow/SearchMode/bothAtOnce``.
/// What stays here: the network explanation and the channel list; on the server path
/// ``step`` drops out of the sign-in phase.
@MainActor
@Observable
public final class SourceFormModel {

    /// Which form this is.
    public enum Entry: Sendable, Equatable {
        case jellyfin
        case channelList
    }

    /// Wo man gerade steht.
    public enum Step: Sendable, Equatable {
        /// The explanation **before** the system prompt — it exists only on the server path.
        case networkPermission
        case server
        case connect
        case loginRoute
        case password
        case code
        case channelList
        case done
    }

    /// Whether the app can **search** for servers on the home network.
    ///
    /// **Since 2026-09-10 yes, and with that the screen before it is back.**
    /// ``NetworkLawView`` announces two things — a reach into the local network and the
    /// system prompt that iOS then raises —, and both really exist now.
    /// Until then this said `false`, and that was the right decision: an
    /// announcement that does not arrive is worse than a button without effect. It
    /// lets the viewer believe they did something wrong, and the explanation "the
    /// question comes exactly once" turns that into a worry they cannot shake.
    public static let searchBuilt = true

    /// Where you stand outside the sign-in — on the server path ``Preflight/jellyfin``.
    private enum Preflight: Equatable {
        case networkPermission, jellyfin, channelList, done
    }

    private var leadTime: Preflight = .channelList
    /// Where the form begins — **"back" there leads out of the form**, not to a choice of paths.
    private var start: Preflight = .channelList

    /// The shared sign-in to the media server.
    public let login: LoginFlow

    /// Where you stand right now — on the server path, from the sign-in phase.
    public var step: Step {
        switch leadTime {
        case .networkPermission: .networkPermission
        case .channelList: .channelList
        case .done: .done
        case .jellyfin:
            switch login.phase {
            case .server: .server
            case .connect: .connect
            case .loginRoute: .loginRoute
            case .password: .password
            case .code: .code
            case .done: .done
            }
        }
    }

    /// Whether something is running right now — on the server path, the sign-in.
    public var isRunning: Bool { login.isRunning || login.phase == .connect }

    private var ownError: String?

    /// What went wrong — as a key. On the server path, that of the sign-in.
    public var error: String? { leadTime == .jellyfin ? login.error : ownError }

    public var address: String {
        get { login.address }
        set { login.address = newValue }
    }

    public var user: String {
        get { login.user }
        set { login.user = newValue }
    }
    public var password: String {
        get { login.password }
        set { login.password = newValue }
    }
    public var foundServer: URL? { login.server }
    public var serverName: String? { login.serverReply?.serverName }
    public var code: QuickConnect.Session? {
        if case .code(let session) = login.phase { return session }
        return nil
    }

    /// The open certificate question — `nil` if none is pending. Raised by the shared
    /// flow; a `.home` name with a self-issued certificate is the normal case
    /// on the home network.
    public var certificatePrompt: CertificatePrompt.Pending? { login.certificatePrompt }

    /// The credential that **this** run created. `nil` as long as there is none.
    ///
    /// **For the "Add account" path.** The setup stores the credential itself; whoever
    /// has anything else in mind afterwards — turning it into a child account, re-reading the
    /// list — would otherwise have to fetch it back from the Keychain and guess
    /// which of several is the new one.
    public var createdCredentials: ServerCredentials? {
        if case .done(let credential) = login.phase { return credential }
        return nil
    }

    private let state: SetupState
    private let accessInfo: AccessInfo

    /// How a provider credential is asked about its extensions: `true` means "supports
    /// HLS", `false` "raw stream only", `nil` "did not answer".
    ///
    /// **Injected so that the checks do not touch the network.** The default asks
    /// the provider (``askProvider``); a check supplies the answer.
    public typealias AccessInfo = @Sendable (Playlist, XtreamEndpoint) async -> Bool?

    /// - Parameters:
    ///   - entry: the form — the account sign-in or a channel list.
    ///   - services: the sign-in's network — the checks pass in their own.
    public init(
        entry: Entry = .jellyfin,
        state: SetupState = SetupState(),
        services: LoginServices = .real(),
        trust: CertificateTrustStore = CertificateTrustStore(),
        deviceID: String,
        deviceName: String = "iPhone",
        accessInfo: @escaping AccessInfo = SourceFormModel.askProvider
    ) {
        self.state = state
        self.accessInfo = accessInfo
        login = LoginFlow(
            services: services, searchMode: .bothAtOnce, deviceID: deviceID,
            deviceName: deviceName, trust: trust,
            persist: { state.create(jellyfin: $0) })
        switch entry {
        case .jellyfin: chooseJellyfin()
        case .channelList: chooseChannelList()
        }
        start = leadTime
    }

    /// Whether the form stands at its first step — **there is no way back inside it**, the
    /// navigation that opened it leads out.
    public var isAtStart: Bool { leadTime == start }

    /// The default: **one** request to `player_api.php`, the same information that
    /// `ProviderChannelSource` fetches later at the first channel — only earlier.
    public static let askProvider: AccessInfo = { list, credential in
        let reply = try? await XtreamClient(playlist: list, credentials: credential).verify()
        Diagnose.step(
            .network,
            "Access: allowed extensions "
                + (reply?.allowedOutputFormats?.joined(separator: ", ") ?? "not stated"))
        return reply?.allowsHLS
    }

    // MARK: - The path

    /// **The explanation comes before the prompt — but only if there is a prompt.** Whoever
    /// asks without explanation gets a no, and on iOS that cannot be taken back
    /// without going to the system settings. As long as the search is not built, nobody
    /// asks: see ``searchBuilt``.
    public func chooseJellyfin() {
        ownError = nil
        login.restart()
        leadTime = Self.searchBuilt ? .networkPermission : .jellyfin
    }

    public func chooseChannelList() {
        ownError = nil
        leadTime = .channelList
    }

    /// Onward from the explanation — **both answers lead on.**
    ///
    /// Whoever allows the search gets a list of finds; whoever declines it, a field. The second
    /// path is not an emergency exit: typing the address by hand is the
    /// cheapest operation on the phone — on the TV it was the most expensive.
    ///
    /// - Parameter mitSuche: Whether to search. **The decision is made only here**, and
    ///   that is why it is passed as a value and not as a guess in the screen behind: whoever
    ///   chose "by hand" should not see the system prompt after all.
    public func continueToServer(withSearch: Bool = false) {
        leadTime = .jellyfin
        guard withSearch else { return }
        login.startSearch()
    }

    /// One step back — **and not to the start.**
    ///
    /// **Until 2026-09-06 the way back always led to the path choice.** But it is mostly taken
    /// to change the **sign-in path** — and then you stood three screens
    /// further forward and had to have the server searched again. Within the sign-in,
    /// ``Flows/LoginFlow/back()`` decides (including cancelling a running code); the first step
    /// of the form is its end, since AP88 wave 6 there is no path choice before it.
    public func back() {
        ownError = nil
        switch leadTime {
        case .done, .networkPermission, .channelList:
            break
        case .jellyfin:
            guard !login.back() else { return }
            if case .done = login.phase { return }
            guard Self.searchBuilt else { return }
            login.restart()
            leadTime = .networkPermission
        }
    }

    /// Sets the step — **for checks only.**
    ///
    /// **It lives here and not as an `internal var step`.** The state stays
    /// unwritable from outside; what a check needs is the entry into the middle of a
    /// path, without signing in a server for it.
    func setStepForCheck(_ new: Step) {
        switch new {
        case .networkPermission: leadTime = .networkPermission
        case .channelList: leadTime = .channelList
        case .done: leadTime = .done
        case .server, .connect, .loginRoute, .password, .code:
            leadTime = .jellyfin
            login.setPhaseForTesting(Self.phase(zu: new))
        }
    }

    private static func phase(zu step: Step) -> LoginFlow.Phase {
        switch step {
        case .connect: .connect
        case .loginRoute: .loginRoute
        case .password: .password
        case .code:
            .code(QuickConnect.Session.forCheck)
        default: .server
        }
    }

    // MARK: - The search on the home network

    /// What has been found so far — **grows while the search runs.**
    public var found: [ServerDiscovery.Found] { login.discoveries }
    /// Which finds this device does **not** reach — by identifier (AP18). The entry
    /// stays selectable and carries a note.
    public var unreachable: Set<String> { login.unreachable }
    /// Whether a search is running right now.
    public var isSearching: Bool { login.isSearching }

    /// Searches for media servers on the home network — broadcast and probing side by side, then the
    /// reachability check (``Flows/LoginFlow/searchServers()``).
    public func searchServers() async { await login.searchServers() }

    /// Stores a find like the search does — **for checks only.**
    func takeDiscoveryForTesting(_ fund: ServerDiscovery.Found) {
        login.takeDiscoveryForTesting(fund)
    }

    /// A find was chosen: the address moves into the field and is checked.
    public func select(_ fund: ServerDiscovery.Found) async { await login.select(fund) }

    // MARK: - Media server

    /// Checks the entered address — ``Flows/LoginFlow/checkAddress()``.
    public func checkAddress() async { await login.checkAddress() }

    /// How the shared flow takes a certificate question — **for checks only.**
    func takeCertificatePrompt(fallback key: String) {
        leadTime = .jellyfin
        login.takeCertificatePromptForTesting(fallback: key)
    }

    public func trustCertificate() async { await login.trustCertificate() }

    public func rejectCertificate() { login.rejectCertificate() }

    public func choosePassword() { login.choosePassword() }

    /// Signs in with name and password.
    public func notify() async { await login.notify() }

    /// The path via the six-digit code on the TV.
    ///
    /// **On the phone the second path, on the TV the first.** There typing is the
    /// most expensive operation there is; here it is cheap. The code stays anyway, because
    /// it can do something the password cannot: it does not ask for one.
    public func startCode() async { await login.startCode() }

    // MARK: - Channel list

    /// Stores a provider credential — and asks it **once** what it offers.
    ///
    /// **The account allows one connection**, and a connection burst leads to an
    /// IP throttle that also blocks the API and lasts minutes (measured on 2026-08-15).
    /// That is why this said "without checking it" until 2026-09-07. What has changed since: the
    /// information `allowed_output_formats` decides **which engine** plays the channels of this
    /// credential (AP2) — a credential that only offers `ts` runs through its own
    /// repackager, without time offset and without seeking trouble. The viewer should read that **when entering it**
    /// and not guess it at the first channel. A request to `player_api.php` is
    /// not a stream connection: it does not count against the one allowed connection, and
    /// it is made exactly once — whoever mistypes does not get a second one.
    ///
    /// **The identifier is computed and not rolled** (setup check, E14,
    /// 2026-09-27): ``Core/ListKey`` from machine and user, as everywhere else
    /// (AP42). A random identifier went out with every handoff until the next start,
    /// and a TV with the same account then kept the list twice.
    public func addChannelList(name: String, address: URL, user: String, password: String) {
        let list = Playlist(name: name, kind: .xtream(server: address, username: user))
        state.create(channelList: list, password: password)
        storedAddress = address
        leadTime = .done
        askSuffixes(list, address: address, user: user, password: password)
    }

    /// What the credential said about its extensions — `nil` as long as it has said nothing
    /// special. Shown on the finish screen.
    public private(set) var accessHint: String?

    /// The running reach for the extensions — for checks that want to wait for the answer
    /// instead of a clock.
    public private(set) var lookupTask: Task<Void, Never>?

    /// Asks the credential for its extensions and writes the hint if it only offers raw
    /// streams. **Without an answer no hint:** a panel that does not answer is
    /// no finding about the extensions — the same direction as in `AccountInfo.allowsHLS`.
    private func askSuffixes(_ list: Playlist, address: URL, user: String, password: String) {
        let credential = XtreamEndpoint(server: address, username: user, password: password)
        let info = accessInfo
        lookupTask = Task { [weak self] in
            guard let isAllowed = await info(list, credential), !isAllowed else { return }
            self?.accessHint = AppLanguageSetting.text("setup.playlist.rawOnly")
        }
    }

    public func createList(name: String, address: URL) {
        state.create(
            channelList: Playlist(name: name, kind: .m3u(address)),
            password: nil)
        storedAddress = address
        leadTime = .done
    }

    /// The address of the list this form stored — **for the row of the first setup**, which says
    /// the provider's host after ✓, as on the TV.
    public private(set) var storedAddress: URL?

    // MARK: - Completion

    /// **And creates the profile that owns what was just set up** (AP41).
    ///
    /// **Here and not only at the next start.** ``SetupState/createProfiles(fallbackName:)``
    /// also runs in the ``Startup``; without this call the phone would stand there after the
    /// setup without a profile until the next start — it would run (the shell then falls
    /// back to the device state), but the profile switcher would be empty, and whoever just entered
    /// two accounts would look for them there.
    public func complete() {
        state.markDone()
        state.createProfiles(fallbackName: AppLanguageSetting.text("profile.default.name"))
    }

    /// What stands there at the end — for ``DoneView``.
    public var summary: [String] {
        var rows: [String] = []
        if let server = state.jellyfin {
            rows.append(serverName ?? server.serverURL.host() ?? "")
        }
        for list in state.channelLists { rows.append(list.name) }
        if state.portalsWanted {
            rows.append(AppLanguageSetting.text("tab.portals"))
        }
        return rows
    }
}
