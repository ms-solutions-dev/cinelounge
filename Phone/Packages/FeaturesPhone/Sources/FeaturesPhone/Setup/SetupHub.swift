import Core
import Diagnose
import Flows
import Foundation
import JellyfinKit
import PlaylistKit
import PortalKit
import ProfileKit

/// Where the first setup meets this phone — **the gate read from the phone's stores and the
/// services built from them** (AP88 §1.1, §1.5, wave 6).
///
/// **The counterpart of the TV's `SetupShell`, with the same core.** ``Flows/SetupMachine`` and
/// ``Flows/SetupJourney`` run unchanged; this type passes in the stores of this phone and the
/// deliberate differences (``Flows/SetupSteps/phone``). What differs from the TV is where the
/// stores are: the channel lists in the Keychain's default service (`CloudStartup.build` in the
/// app explains why), the Jellyfin sign-in through ``SetupState/create(jellyfin:)``.
@MainActor
public enum SetupHub {

    /// The stores the setup reads and writes — **the device's in the program, in-memory ones in
    /// the checks**, so that a check runs the real services against a book it can read back.
    @MainActor
    public struct Stores {
        public var keychain: SecureStore
        public var ledger: any KeyValueStore
        public var lists: PlaylistStore
        public var defaults: UserDefaults
        public var cloud: @MainActor () -> ProfileCloud?

        public init(
            keychain: SecureStore, ledger: any KeyValueStore, lists: PlaylistStore, defaults: UserDefaults,
            cloud: @escaping @MainActor () -> ProfileCloud?
        ) {
            self.keychain = keychain
            self.ledger = ledger
            self.lists = lists
            self.defaults = defaults
            self.cloud = cloud
        }

        /// This phone's stores — the same ones ``SetupState`` opens by default.
        public static var device: Stores {
            Stores(
                keychain: SecureStore(), ledger: FileStore(),
                lists: PlaylistStore(store: SecureStore(), secrets: SecureStore(), ledger: FileStore()),
                defaults: .standard, cloud: { ProfileCloud.attached })
        }

        /// The phone's setup state over these stores — **where a Jellyfin sign-in and a channel
        /// list land** (``SetupState/create(jellyfin:)``, ``SetupState/create(channelList:password:)``).
        var setupState: SetupState {
            SetupState(keychain: keychain, listen: lists, store: defaults, ledgerStore: ledger)
        }

        var management: ProfileManagement {
            ProfileManagement(keychain: keychain, store: ledger, cloud: cloud, startStore: defaults)
        }
    }

    /// Where the local-network notice remembers that it ran — **the same key as on the TV**, once
    /// per installation and never in iCloud: the system question belongs to the device.
    static let noticeKey = "networkNoticeSeen"

    /// Whether the cold start waits for the setup — **decided once in the app's `init`**, before
    /// the cloud starts, so that it hands its reading to the setup instead of adopting every
    /// profile into a book without an active one (finding 1).
    public private(set) static var waitsForCloud = false

    /// The model that runs — **held here and not only in the view's state**: a language change
    /// rebuilds the shell (`.id(language.identifier)`), and with it every `@State`. Without this
    /// the setup would begin again in the middle of A4.
    private(set) static var running: SetupModel?

    /// What the app does with the profiles from iCloud that nobody chose — set by the app's
    /// `CloudStartup`, run when the setup ends (§2.6 point 4).
    public static var adoptRemaining: @MainActor () -> Void = {}

    /// Reads the gate for the cold start.
    public static func prepare(stores: Stores = .device) {
        if case .fresh = start(stores: stores) { waitsForCloud = true }
    }

    // MARK: - The iCloud reading

    private static var launchReading: ProfileCloud.Reading?
    private static var delivered = false
    private static var waiting: [CheckedContinuation<ProfileCloud.Reading, Never>] = []

    /// The cloud's first reading — **from the app's `CloudStartup`**, which does not adopt while
    /// the setup waits.
    public static func deliver(_ reading: ProfileCloud.Reading) {
        delivered = true
        guard !waiting.isEmpty else {
            launchReading = reading
            return
        }
        let now = waiting
        waiting = []
        for continuation in now { continuation.resume(returning: reading) }
    }

    /// The launch reading once, after that a fresh question — a setup that begins later in the
    /// run (after "Reset everything") asks itself.
    static func reading(stores: Stores) async -> ProfileCloud.Reading {
        if let launchReading {
            self.launchReading = nil
            return launchReading
        }
        if waitsForCloud, !delivered, stores.cloud() != nil {
            return await withCheckedContinuation { waiting.append($0) }
        }
        guard let cloud = stores.cloud() else { return .unread }
        return await cloud.findReporting()
    }

    // MARK: - The gate

    /// ``Flows/SetupGate`` over this phone — `nil` when a profile here can play something.
    static func start(stores: Stores) -> SetupMachine.Start? {
        let book = ProfileBook.read(from: stores.ledger)
        let usable = SetupWorld.usable(
            book: book, accounts: stores.keychain.allAccounts(),
            channelLists: Set(stores.lists.playlists.map(\.id)), keychain: stores.keychain)
        return SetupWorld.start(book: book, usable: usable) { describe($0, stores: stores) }
    }

    /// Where the machine begins when the shell has no tabs to show — **the gate's answer, else the
    /// active profile's A4.** The shell decides by its catalog, and that can be empty while
    /// another profile could play (an adult profile without sources of its own): then the setup
    /// resumes for the one in front, as `SetupState` used to begin it.
    static func entry(stores: Stores) -> SetupMachine.Start {
        if let start = start(stores: stores) { return start }
        let book = ProfileBook.read(from: stores.ledger)
        if let active = book.activeProfile { return .resume(describe(active, stores: stores)) }
        return .fresh(known: book.profile.map { describe($0, stores: stores) })
    }

    static func describe(_ profile: Profile, stores: Stores) -> SetupProfile {
        SetupWorld.describe(profile, keychain: stores.keychain)
    }

    // MARK: - The run

    /// The running model, or a new one for this start — **one per setup**, not one per drawing.
    static func model(deviceID: String, stores: Stores = .device) -> SetupModel {
        if let running { return running }
        let fresh = SetupModel(
            begin(entry(stores: stores), stores: stores), stores: stores, deviceID: deviceID)
        running = fresh
        return fresh
    }

    /// Builds the journey with the phone's steps and starts it.
    static func begin(_ start: SetupMachine.Start, stores: Stores) -> SetupJourney {
        let noticeSeen = (try? stores.ledger.value(for: noticeKey)) == "1"
        let machine = SetupMachine(
            steps: .phone, start: start, isPinSet: ParentalControlsState().isPinSet,
            noticeSeen: noticeSeen, online: NetworkWatch.shared.connected)
        let journey = SetupJourney(machine, services: services(stores, journey: { current }))
        current = journey
        journey.start()
        return journey
    }

    /// The journey the CL-Server calls ask for the found address.
    private static var current: SetupJourney?

    /// The setup is over — **the profiles nobody chose come into the book**, the watches stop.
    static func finish(_ model: SetupModel) {
        model.journey.stop()
        if running === model { running = nil }
        if current === model.journey { current = nil }
        networkPoll?.cancel()
        networkPoll = nil
        waitsForCloud = false
        adoptRemaining()
    }

    // MARK: - Services

    private static var networkPoll: Task<Void, Never>?

    /// The services of this phone.
    ///
    /// **The CL-Server calls take the address the search found**
    /// (``Flows/SetupMachine/clServerAddress``) from the running journey — a fresh device has no
    /// stored address yet (§10.1).
    static func services(_ stores: Stores, journey: @escaping @MainActor () -> SetupJourney?) -> SetupServices
    {
        let calls = SetupClServerCalls(stores: stores)
        return SetupServices(
            probeCloud: { CloudAnswer(await reading(stores: stores)) { describe($0, stores: stores) } },
            wait: { try? await Task.sleep(for: $0) },
            drawReady: {},
            watchNetwork: watchNetwork,
            adoptCloudProfile: { stores.cloud()?.adopt([$0]) },
            activate: { identifier in
                guard stores.management.switchTo(zu: identifier).result != nil else { return false }
                SetupState.notify()
                return true
            },
            rememberNotice: { try? stores.ledger.set("1", for: noticeKey) },
            search: search,
            checkToken: { await checkToken($0, stores: stores) },
            reloadLists: { Set(stores.lists.playlists.map(\.id)) },
            enroll: { await calls.enroll($0, at: journey()?.machine.clServerAddress) },
            requestJoin: { await calls.requestJoin($0, at: journey()?.machine.clServerAddress) },
            copyChannelLists: {
                SetupWorld.copyChannelLists(from: $0, to: $1, in: stores.ledger)
                SetupState.notify()
            },
            storeJellyfin: { stores.setupState.create(jellyfin: $0) },
            applyStartChoice: { StartChoice(store: stores.defaults).set($0) },
            issueCode: { nil },
            revokeCode: { _ in },
            codeValidity: .seconds(180))
    }

    /// The home-network search **after the notice** (§2.5) — the same two calls as on the TV:
    /// Jellyfin through its broadcast, the CL-Server through Bonjour.
    private static func search() async -> SetupServices.SearchReport {
        async let broadcast = ServerDiscovery().search()
        async let lookup = ServerLookup.find()
        let jellyfin = NetworkScan.create(combined: await broadcast, and: [])
        let clServer = await lookup ?? BridgeAddress.effective(from: SecureStore())
        Diagnose.step(
            .network,
            "Setup: search found \(jellyfin.count) Jellyfin server(s), \(clServer == nil ? "no" : "a") CL-Server"
        )
        return SetupServices.SearchReport(jellyfin: jellyfin, clServer: clServer)
    }

    /// A token that outlived the app (§2.1) — **signed in only for the profile that is still
    /// active** (``Flows/SetupKeychainHit/signsIn(_:active:)``).
    private static func checkToken(_ access: Access, stores: Stores) async -> Bool {
        guard
            let credential = await SetupKeychainHit.check(
                access, in: stores.keychain.allAccounts(),
                isValid: SetupKeychainHit.realCheck(deviceID: DeviceIdentity.id())),
            SetupKeychainHit.signsIn(access, active: ProfileBook.read(from: stores.ledger).activeProfile)
        else { return false }
        stores.setupState.create(jellyfin: credential)
        return true
    }

    /// ``Core/NetworkWatch`` from the setup on (§2.4) — **asked every two seconds**, because the
    /// guard reports changes only into the trace.
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
