import CloudSync
import Core
import Diagnose
import FeaturesPhone
import Foundation
import PlaylistKit
import ProfileKit
import UIKit

/// Where CloudKit is connected to this program (AP43).
///
/// **The counterpart of the `CloudStartup` on the TV**, with the same two strings: **one**
/// container for both programs, **one** subscription prefix. That is the whole point — one
/// person, all their devices. Two containers would be two truths about the same viewer, and
/// a second subscription name would create a second database subscription instead of using
/// the existing one.
///
/// **``CloudSync/CloudKitService`` has no default for either**, because the package lives in
/// `grundstock` and StoryShelf uses it too: a default would mean that the program that
/// forgets to set them silently writes into the container of another.
///
/// **Without an iCloud sign-in nothing loud happens.** ``CloudSync/CloudHub/start()``
/// asks for the account status and returns; the books on the device remain the truth.
@MainActor
enum CloudStartup {

    static var container: String { AppIdentifier.cloudContainer }
    static let subscriptionPrefix = "cinelounge"
    /// The CloudKit environment of this build — **the same as in `project.yml`**
    /// (`com.apple.developer.icloud-container-environment`). The cloud remembers in which
    /// environment a mirror came into being, and after a switch starts over instead of
    /// considering the profile deleted (grundstock `ProfileZone`, 2026-09-28).
    static let environment = "Production"

    private(set) static var cloud: ProfileCloud?

    /// Builds the connection — once per program run.
    ///
    /// **The list store sits in the Keychain's default service and not in that of
    /// `PlaylistStore.onDevice()` — deliberately** (clarified in the closing step of AP58,
    /// 2026-09-26). `onDevice()` is the store of the **TV**: there, lists and accesses have
    /// lain in two named services since 2026-07-28, and the function brings the old default service
    /// over once. The phone has kept its lists in the default service from the start, and every
    /// place that reads or writes them opens exactly that: the setup (`SetupState`), the
    /// build-up of the sources (`SourceAssembly.listStore()`) and the handoff to the TV
    /// (`HandoffModel`). If this connection took `onDevice()`, it would put what comes from
    /// the cloud into services that nobody reads on the phone — exactly the bug AP39 found on
    /// the TV. Moving the phone to the named services would be a step of its own for all four
    /// places at once.
    ///
    /// - Parameter listenspeicher: only for checks; `nil` means the default service.
    @discardableResult
    static func build(
        service: (any CloudService)? = CloudKitService(
            container: container, subscriptionPrefix: subscriptionPrefix, environment: environment),
        store: any KeyValueStore = FileStore(),
        listStore: PlaylistStore? = nil
    ) -> ProfileCloud {
        if let cloud { return cloud }
        Diagnostics.icloudEnvironment = service?.environment
        // The Home screen travels via the cloud (``ProfileKit/DocumentPreference``) — saved means up.
        ShelfOrder.written = { SyncCall.call(.byHand) }
        let hub = CloudHub(
            service: service, file: CloudHub.defaultFile, device: thisDevice)
        // **The move bundle is this phone's Keychain** (counter-check strand C, finding 5): PIN,
        // age limit and preferences lie there, and an ID moves there when it migrates on the first
        // iCloud contact or through a move note. Without it they would stay under the dead ID.
        let keychain = SecureStore()
        let built = ProfileCloud(
            hub: hub, store: store, moveBundle: keychain,
            mirrorFolder: (store as? FileStore)?.directory)
        // **The channel lists hang on a list store of their own.** The same situation as on the
        // TV: ``SourceAssembly/listStore()`` already keeps one, and both are views on the same
        // Keychain. What arrives from the cloud lies there immediately — the UI sees it the next
        // time it builds its store.
        let listen =
            listStore
            ?? PlaylistStore(store: SecureStore(), secrets: SecureStore(), ledger: FileStore())
        built.channelLists = { listen.channelListCredentials() }
        built.adoptsChannelLists = { listen.adopt($0) }
        // **Audio preference, subtitles and app language travel along** (tvOS schedule AP46, phone
        // row) — from the same Keychain from which the player reads via
        // ``Core/ProfileStore/playback``. **And the person token in the same go** (AP47): a
        // phone signed in by PIN is the device that fetches the new token after a revocation;
        // without this connection it would never go up and never come down.
        built.attachKeychain(keychain)
        // **A "forgot PIN" request reports itself wherever it stands** (counter-check strand C,
        // finding 6) — in the account list and on the page that confirms or cancels. The silent
        // push to the household zone arrives here; the places read on after the notification.
        built.pinEscape = { NotificationCenter.default.post(name: .pinEscape, object: nil) }

        cloud = built
        ProfileCloud.attached = built
        // **The household zone is subscribed at startup and not only at the first look**
        // (AP43). It carries the way out "forgot PIN"; without the subscription at the hub no
        // silent push reaches it, and the device at which someone is resetting right now would
        // learn of it only at the next start. But exactly then it is too late to cancel.
        _ = built.household()
        // **One call for all places that want to trigger a sync** — the profile switch in
        // ``ProfileKit``, "Continue Watching" in the views. Neither sees this file; here the call is
        // filled once. Whether a run really happens is decided by the ``ProfileKit/SyncCadence``.
        SyncCall.notify = { reason in Task { @MainActor in CloudStartup.notify(reason) } }
        return built
    }

    /// The first run: account status, subscription, find foreign profiles, sync.
    ///
    /// **Find first, then sync** — otherwise a profile created on the TV would have no zone
    /// here yet and would not appear in the sync at all.
    ///
    /// **While the first setup waits** (``FeaturesPhone/SetupHub/waitsForCloud``, AP88 wave 6) the
    /// reading goes to the setup instead of into the book: it adopts only the profile someone
    /// chooses on A2 and makes it active. Adopting everything here would write the book without
    /// an active profile — the ground of finding 1. The rest follows when the setup ends.
    static func start() async {
        guard let cloud else { return }
        await cloud.hub.start()
        SetupHub.adoptRemaining = { Task { await adoptFound(cloud) } }
        if SetupHub.waitsForCloud {
            SetupHub.deliver(await cloud.findReporting())
        } else {
            await adoptFound(cloud)
        }
        await cloud.syncIfNeeded(.start)
    }

    private static func adoptFound(_ cloud: ProfileCloud) async {
        let found = await cloud.find()
        if cloud.adopt(found) > 0 {
            Diagnose.step(
                .login, "Cloud: \(found.count) profile(s) adopted from iCloud")
        }
    }

    static func notify(_ reason: SyncCadence.Occasion) {
        guard let cloud else { return }
        Task { await cloud.syncIfNeeded(reason) }
    }

    static var thisDevice: DeviceDescription {
        DeviceDescription(
            identifier: DeviceIdentity.id(), name: DeviceName.thisDevice,
            model: UIDevice.current.model)
    }
}
