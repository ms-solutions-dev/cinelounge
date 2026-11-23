import Core
import Features
import Flows
import Foundation
import JellyfinKit
import PlaylistKit
import PortalKit
import ProfileKit
import SecondScreen

/// Where the first setup meets this program — **the gate read from the real stores and the
/// services built from the real holders** (AP88 §1.1, §1.5).
///
/// The core in `Flows` (``Flows/SetupMachine``, ``Flows/SetupJourney``) knows no store and no
/// Keychain; ``Flows/SetupWorld`` turns them into its values, and this type passes in the stores
/// of this TV.
@MainActor
enum SetupShell {

    /// Whether the cold start waits for the setup — **decided once in the app's `init`**, before
    /// ``CloudStartup/start()`` runs, so that the cloud hands its reading to the setup instead of
    /// adopting every profile into a book without an active one.
    private(set) static var waitsForCloud = false
    private static var atLaunch: SetupMachine.Start?

    /// Where the local-network notice remembers that it ran — **once per installation** (§2.5),
    /// in this device's file store and never in iCloud: the system question belongs to the device.
    static let noticeKey = "networkNoticeSeen"

    static var noticeSeen: Bool {
        (try? FileStore().value(for: noticeKey)) == "1"
    }

    /// The journey that runs — **held here and not only in `RootView`'s state**: a color scheme
    /// from a handoff rebuilds the whole interface (`ThemeStore.rebuildID`), and with it every
    /// `@State`. Without this the setup would begin again behind the profile that just arrived.
    private(set) static var running: SetupJourney?

    /// Reads the gate for the cold start — **and starts the network watch at once** when the setup
    /// waits (§2.4): `MainView` starts it only after the setup, and until its first answer the
    /// watch says "connected", so A4 would show "Not reachable" where "No network" is true.
    static func prepare() {
        atLaunch = start()
        if case .fresh = atLaunch { waitsForCloud = true }
        if atLaunch != nil { NetworkWatch.shared.start() }
    }

    /// The start of the cold start, handed out once — a later setup in the same run reads the
    /// gate again (``start()``).
    static func takeLaunchStart() -> SetupMachine.Start? {
        defer { atLaunch = nil }
        return atLaunch
    }

    /// ``Flows/SetupGate`` over this device: the book, the accounts with a token in the Keychain,
    /// the list store and the CL-Server device traits.
    static func start() -> SetupMachine.Start? {
        let keychain = SecureStore()
        let book = ProfileBook.read(from: FileStore())
        let lists = Set(PlaylistStore.onDevice().playlists.map(\.id))
        let usable = SetupWorld.usable(
            book: book, accounts: keychain.allAccounts(), channelLists: lists, keychain: keychain)
        return SetupWorld.start(book: book, usable: usable, describe: describe)
    }

    static func describe(_ profile: Profile) -> SetupProfile {
        SetupWorld.describe(profile, keychain: SecureStore())
    }

    /// Builds the journey for this start and starts it — the intro's end is wired to the
    /// machine (`introEnded`), the code on A2 to the desk.
    ///
    /// - Parameters:
    ///   - onSignedIn: ``SessionStore/signIn(_:)`` — after Quick Connect, and after a token from
    ///     the Keychain still counted (§2.1).
    ///   - onSwitched: the session after a profile became active, as after every switch.
    ///   - onTheme: `ThemeStore.choose` — the color scheme a handoff through the code on A2
    ///     brought, as ``Features/HandoffReceiveView`` applies it.
    static func begin(
        _ start: SetupMachine.Start,
        onSignedIn: @escaping (ServerCredentials) -> Void,
        onSwitched: @escaping (ServerCredentials?) -> Void,
        onTheme: @escaping (Theme) -> Void
    ) -> SetupJourney {
        let desk = SetupCodeDesk()
        let machine = SetupMachine(
            steps: .tv, start: start, isPinSet: AccountCreation.isPinSet(),
            noticeSeen: noticeSeen,
            online: NetworkWatch.shared.connected)
        signedIn = onSignedIn
        switched = onSwitched
        let journey = SetupJourney(machine, services: services(desk: desk))
        desk.mode = { [weak journey] in
            guard case .welcome(let offer) = journey?.state else { return nil }
            return offer.pullMode
        }
        desk.onArrival = { [weak journey] arrival in
            guard let input = arrival.input(describe: describe) else { return }
            journey?.send(input)
        }
        desk.onTheme = onTheme
        running = journey
        journey.start()
        DrawReadiness.shared.afterIntro { [weak journey] in journey?.send(.introEnded) }
        return journey
    }

    /// A source added later from the settings — **the same sheets as the first setup** (A5, the
    /// IPTV sheet, A6) for the active profile, on a journey that ends with its sheet
    /// (``Flows/SetupMachine/Start/retrofit(_:_:)``).
    ///
    /// - Returns: `nil` without an active profile; then the gate leads into the first setup anyway.
    static func retrofit(
        _ kind: Access.Kind,
        onSignedIn: @escaping (ServerCredentials) -> Void,
        onSwitched: @escaping (ServerCredentials?) -> Void
    ) -> SetupJourney? {
        guard let active = ProfileBook.read(from: FileStore()).activeProfile else {
            Diagnostics.step("Retrofit \(kind.rawValue): no active profile", since: nil, area: "Anmeldung")
            return nil
        }
        let machine = SetupMachine(
            steps: .tv, start: .retrofit(describe(active), kind), isPinSet: AccountCreation.isPinSet(),
            noticeSeen: noticeSeen, online: NetworkWatch.shared.connected)
        signedIn = onSignedIn
        switched = onSwitched
        let journey = SetupJourney(machine, services: services(desk: SetupCodeDesk()))
        retrofitting = journey
        journey.start()
        return journey
    }

    /// The retrofit is over — nothing else to adopt, only the poll stops.
    static func finishRetrofit(_ journey: SetupJourney) {
        journey.stop()
        if retrofitting === journey { retrofitting = nil }
        networkPoll?.cancel()
        networkPoll = nil
    }

    /// The setup is over — **the profiles nobody chose come into the book**, the network poll
    /// stops.
    static func finish(_ journey: SetupJourney) {
        journey.stop()
        if running === journey { running = nil }
        networkPoll?.cancel()
        networkPoll = nil
        waitsForCloud = false
        CloudStartup.adoptRemaining()
    }

    // MARK: - Services

    private static var networkPoll: Task<Void, Never>?
    /// The retrofit that runs — held apart from ``running``, so that a rebuild never takes it for
    /// the first setup.
    private static var retrofitting: SetupJourney?
    /// The journey whose sheets the services serve.
    private static var current: SetupJourney? { running ?? retrofitting }
    /// The shell's callbacks of the running setup — **held here and not captured**, so that the
    /// services stay main-actor closures without carrying the view's closures across.
    private static var signedIn: (ServerCredentials) -> Void = { _ in }
    private static var switched: (ServerCredentials?) -> Void = { _ in }

    /// The services of the TV.
    ///
    /// **The CL-Server calls take the address the search found** (``Flows/SetupMachine/clServerAddress``)
    /// from the running journey — a fresh TV has no stored address yet (§10.1).
    private static func services(desk: SetupCodeDesk) -> SetupServices {
        SetupServices(
            probeCloud: { CloudAnswer(await CloudStartup.reading(), describe: describe) },
            wait: { try? await Task.sleep(for: $0) },
            drawReady: { DrawReadiness.shared.notify() },
            watchNetwork: watchNetwork,
            adoptCloudProfile: { CloudStartup.cloud?.adopt([$0]) },
            activate: { identifier in
                let management = ProfileManagement(cloud: { CloudStartup.cloud })
                guard let result = management.switchTo(zu: identifier).result else { return false }
                switched(ProfilePicker.session(after: result))
                return true
            },
            rememberNotice: { try? FileStore().set("1", for: noticeKey) },
            search: search,
            checkToken: checkToken,
            reloadLists: { Set(PlaylistStore.onDevice().playlists.map(\.id)) },
            enroll: { await ClServerCalls.enroll($0, at: current?.machine.clServerAddress) },
            requestJoin: { await ClServerCalls.requestJoin($0, at: current?.machine.clServerAddress) },
            copyChannelLists: { SetupWorld.copyChannelLists(from: $0, to: $1, in: FileStore()) },
            storeJellyfin: { signedIn($0) },
            applyStartChoice: { StartChoice().set($0) },
            issueCode: { await desk.issue() },
            revokeCode: { desk.revoke($0) },
            codeValidity: .seconds(HandoffKey.validity))
    }

    /// The home-network search **after the notice** (§2.5): Jellyfin through its broadcast, the
    /// way `LoginFlow` searches first, and the CL-Server through Bonjour (`_cinelounge._tcp`), the
    /// way the settings search — both at once, so that A4 waits for the slower one only.
    ///
    /// **A stored CL-Server address stands in when Bonjour finds none** — after "Reset everything"
    /// it may still lie in the Keychain, and the calls of A6 prefer it anyway.
    private static func search() async -> SetupServices.SearchReport {
        async let broadcast = ServerDiscovery().search()
        async let lookup = ServerLookup.find()
        let jellyfin = NetworkScan.create(combined: await broadcast, and: [])
        let clServer = await lookup ?? BridgeAddress.effective(from: SecureStore())
        Diagnostics.network.info(
            "Setup: search found \(jellyfin.count) Jellyfin server(s), \(clServer == nil ? "no" : "a") CL-Server"
        )
        return SetupServices.SearchReport(jellyfin: jellyfin, clServer: clServer)
    }

    /// The token that outlived the app (§2.1) — **signed in only for the profile that is still
    /// active** (``Flows/SetupKeychainHit/signsIn(_:active:)``).
    private static func checkToken(_ access: Access) async -> Bool {
        guard
            let credential = await SetupKeychainHit.check(
                access, in: SecureStore().allAccounts(),
                isValid: SetupKeychainHit.realCheck(deviceID: DeviceIdentity.id())),
            SetupKeychainHit.signsIn(access, active: ProfileBook.read(from: FileStore()).activeProfile)
        else { return false }
        signedIn(credential)
        return true
    }

    /// ``Core/NetworkWatch`` from the setup on and not only from `MainView` (§2.4) — **asked every
    /// two seconds**, because the guard reports changes only into the trace.
    private static func watchNetwork(_ report: @escaping @MainActor (Bool) -> Void) {
        NetworkWatch.shared.start()
        let first = NetworkWatch.shared.connected
        report(first)
        networkPoll?.cancel()
        networkPoll = Task {
            var last = first
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let now = NetworkWatch.shared.connected
                guard now != last else { continue }
                last = now
                report(now)
            }
        }
    }
}
