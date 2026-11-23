import CloudSync
import Core
import Features
import Foundation
import PlaylistKit
import ProfileKit
import UIKit

/// Where CloudKit is connected to this program (AP43).
///
/// **The only place that knows the container.** ``CloudSync/CloudKitService`` deliberately
/// has no default for it: The package lives in `grundstock` and is used by three
/// programs; a default would mean that the program that forgets it silently writes into
/// another's container — no error, no message, someone else's data.
///
/// **The subscription prefix must never change.** A new name creates a **second**
/// database subscription instead of replacing the old one, and then every silent push would arrive
/// twice — on every device that already has the app.
///
/// **Without an iCloud sign-in nothing loud happens here.** ``CloudSync/CloudHub/start()``
/// asks for the account status and returns if there is none; the ledgers on the device remain
/// the truth, and the app does not notice. That is the explicit requirement from AP43:
/// "Profile stays local, no storm of notices."
@MainActor
enum CloudStartup {

    static var container: String { AppIdentifier.cloudContainer }
    static let subscriptionPrefix = "cinelounge"
    /// The CloudKit environment of this build — **the same as in `project.yml`**
    /// (`com.apple.developer.icloud-container-environment`). The cloud remembers in which
    /// environment a mirror came into being, and starts over after a change instead of treating the profile
    /// as deleted (grundstock `ProfileZone`, 2026-09-28).
    static let environment = "Production"

    private(set) static var cloud: ProfileCloud?

    /// Builds the connection — once per program run.
    ///
    /// - Parameter dienst: in operation ``CloudSync/CloudKitService``; the checks pass in
    ///   the ``CloudSync/MockCloud``, and `nil` means "without cloud" (preview).
    @discardableResult
    static func build(
        service: (any CloudService)? = CloudKitService(
            container: container, subscriptionPrefix: subscriptionPrefix, environment: environment),
        store: any KeyValueStore = FileStore(),
        listStore: PlaylistStore? = nil
    ) -> ProfileCloud {
        if let cloud { return cloud }
        _ = launchedAt
        Diagnostics.icloudEnvironment = service?.environment
        // The Home screen travels via the cloud (``ProfileKit/DocumentPreference``) — stored means
        // uploaded.
        ShelfOrder.written = { SyncCall.call(.byHand) }
        let hub = CloudHub(
            service: service, file: CloudHub.defaultFile, device: thisDevice)
        // **The migration bundle is the same Keychain** (cross-check strand C, finding 5):
        // PIN, age limit, preferences and token live there, and an ID moves
        // there when it migrates at first iCloud contact or on a migration note.
        let keychain = SecureStore()
        let built = ProfileCloud(
            hub: hub, store: store, moveBundle: keychain,
            mirrorFolder: (store as? FileStore)?.directory)
        // **The channel lists hang off a list store of their own**, and that is no
        // cosmetic flaw but the catalog: `MainView`, `PlaylistAccounts` and
        // ``ProfileStartup`` each already keep one, all over the same Keychain. They
        // are different views of **one** store.
        //
        // **The consequence is in the schedule:** New lists that arrive from the cloud
        // lie in the Keychain immediately — but the UI sees them only when it
        // next builds its own store. For a list coming from another device
        // that is acceptable; for running operation it is not, and
        // that is why it is noted as a line of its own and not as a subordinate clause here.
        let listen = listStore ?? .onDevice()
        built.channelLists = { listen.channelListCredentials() }
        built.adoptsChannelLists = { listen.adopt($0) }
        // **Audio preference and subtitles migrate along** (product decision 4, 2026-09-24).
        // The same Keychain the player reads from via ``Core/ProfileStore/playback`` —
        // a second store for the sync would mean that what arrives is what nobody
        // plays. **And the person marker (AP47) in the same move** — only the
        // preference store stood here, and the marker never migrated in the app.
        built.attachKeychain(keychain)
        // **A "forgot PIN" request announces itself everywhere it is shown** (finding 6) — at the
        // circle in "Who is watching?", in the administration, at the PIN sheets. The silent push
        // to the household zone arrives here; the places read up through the message.
        built.pinEscape = { NotificationCenter.default.post(name: .pinEscape, object: nil) }

        cloud = built
        ProfileCloud.attached = built
        // **The household zone is registered at startup and not only at the first
        // look** (AP43). It carries the escape hatch "forgot PIN"; without the registration with
        // the hub no silent push reaches it, and the device where someone
        // is resetting at that moment would learn of it only at the next start. By then
        // it is too late to cancel.
        _ = built.household()
        // **The switch announces itself.** Whoever has just switched wants to see the state of
        // *this* person, and right now — that is why the trigger runs without a brake.
        // Why it is a hook in the package and not a call at the switcher is explained at
        // ``ProfileKit/ProfileSwitch/trailing``.
        // **One call for all places that want to trigger a sync** — the
        // profile switch in ``ProfileKit``, "Continue Watching" in the views. Neither
        // sees this file; here the call is wired up once. Whether a run really
        // happens is decided by the ``ProfileKit/SyncCadence``.
        SyncCall.notify = { reason in Task { @MainActor in CloudStartup.notify(reason) } }
        return built
    }

    /// The first run: account status, subscription, find foreign profiles, sync.
    ///
    /// **Find first, then sync.** A profile that this device does not yet know
    /// has no zone here and would not appear in the sync — the order is the
    /// difference between "appears immediately in the switcher" and "appears at the
    /// start after next".
    ///
    /// **With a first setup waiting, the setup decides what is adopted** (AP88 §2.6, §5.1). The
    /// reading goes to ``reading()`` instead of into the book: the setup adopts only the profile
    /// someone chooses on A2 and makes it active. Adopting everything here would write the book
    /// without an active profile — the ground of finding 1. The rest follows when the setup ends
    /// (``adoptRemaining()``).
    static func start() async {
        guard let cloud else { return }
        await cloud.hub.start()
        if SetupShell.waitsForCloud {
            let reading = await cloud.findReporting()
            Diagnostics.step(
                "Cloud: setup reading \(describe(reading))", since: launchedAt, area: "Wolke")
            deliver(reading)
        } else {
            await adoptFound(cloud)
        }
        await cloud.syncIfNeeded(.start)
    }

    private static func adoptFound(_ cloud: ProfileCloud) async {
        let found = await cloud.find()
        if cloud.adopt(found) > 0 {
            Diagnostics.step(
                "Cloud: \(found.count) profile(s) adopted from iCloud", since: launchedAt,
                area: "Wolke")
        }
    }

    // MARK: - The first setup

    /// When this program run began — **the iCloud lines carry their duration** (AP88 §10: how
    /// long the answer takes on the device was never measured).
    private static let launchedAt = Date()
    private static var launchReading: ProfileCloud.Reading?
    private static var launchReadingDelivered = false
    private static var waiting: [CheckedContinuation<ProfileCloud.Reading, Never>] = []

    /// What iCloud answered for the first setup — **the launch reading once, after that a fresh
    /// question.** A setup that begins later in the run (after "Reset everything") asks itself.
    static func reading() async -> ProfileCloud.Reading {
        if let launchReading {
            self.launchReading = nil
            return launchReading
        }
        if SetupShell.waitsForCloud, !launchReadingDelivered, cloud != nil {
            return await withCheckedContinuation { waiting.append($0) }
        }
        guard let cloud else { return .unread }
        return await cloud.findReporting()
    }

    private static func deliver(_ reading: ProfileCloud.Reading) {
        launchReadingDelivered = true
        guard !waiting.isEmpty else {
            launchReading = reading
            return
        }
        let now = waiting
        waiting = []
        for continuation in now { continuation.resume(returning: reading) }
    }

    /// The profiles from iCloud that nobody chose on A2 — **into the book once the setup is over**,
    /// so that they stand in "Who is watching?" (§2.6 point 4). The active profile stays.
    static func adoptRemaining() {
        guard let cloud else { return }
        launchReading = nil
        Task { await adoptFound(cloud) }
    }

    private static func describe(_ reading: ProfileCloud.Reading) -> String {
        switch reading {
        case .found(let profiles): "\(profiles.count) profile(s)"
        case .noAccount: "no account"
        case .restricted: "restricted"
        case .unread: "unread"
        }
    }

    /// A trigger from the UI — the brake decides whether a run really happens.
    static func notify(_ reason: SyncCadence.Occasion) {
        guard let cloud else { return }
        Task { await cloud.syncIfNeeded(reason) }
    }

    /// This device, as it stands in the zone.
    static var thisDevice: DeviceDescription {
        DeviceDescription(
            identifier: DeviceIdentity.id(), name: DeviceName.thisDevice,
            model: UIDevice.current.model)
    }
}

/// The app delegate anchor for the silent pushes.
///
/// SwiftUI has no place of its own for `didReceiveRemoteNotification`; on tvOS as on
/// iOS it arrives through the app delegate.
///
/// **Without registration with the push service the sync stays intact nonetheless.** It then runs on
/// the UI's triggers (startup, profile switch, foreground) — just not in
/// seconds, but at the next look.
final class CloudAnchor: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Diagnostics.defect(
            "Cloud: no push registration — \(error.localizedDescription)", since: nil,
            area: "Wolke")
    }

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let cloud = CloudStartup.cloud else { return .noData }
        return await cloud.process(push: userInfo) ? .newData : .noData
    }
}
