import DesignSystemPhone
import FeaturesPhone
import Flows
import PortalKit
import SwiftUI

/// The entry point of the app.
///
/// The target stays thin: things are plugged together here, not decided. Everything visible
/// lives in `FeaturesPhone`, everything checkable without UI in the packages below
/// (`Core`, `NetworkStatus`, `ParentalControls`, `Downloads`, `Diagnose`).
///
/// The appearance is dark and is not switched; that is fixed via `UIUserInterfaceStyle` in
/// `project.yml`, not here — otherwise the same decision would stand in two places.
///
/// - Note: Until AP21 the situation comes from the environment — ``SourceAssembly/state()``.
///   Only the setup decides whether a media server, a channel list or just the portals are
///   there; until then the environment says what is there.
@main
struct CineLoungeApp: App {

    /// **The only reason for an app delegate in this app.**
    ///
    /// SwiftUI manages without one, and this file is deliberately thin. One thing works only
    /// through it, though: when iOS wakes the **terminated** app because a block of the
    /// background session is done, it calls
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. Without a
    /// delegate there is no such call — and without it, downloading would work only in the
    /// foreground. See ``WakeService``.
    @UIApplicationDelegateAdaptor(WakeService.self) private var wakeService

    @Environment(\.scenePhase) private var scenePhase

    /// The app language of the active profile (tvOS schedule AP46, 2026-09-25).
    ///
    /// **Built in `init` and not as the initial value of the property**, because it reads the
    /// ``Core/ProfilePointer`` — and that is only set by ``ProfileStartup/fetch()``.
    @State private var language: LanguageState

    /// **The one model of the shell — here and not in ``FeaturesPhone/ShellView``** (shell
    /// check H2, 2026-09-27).
    ///
    /// This `body` is re-evaluated on every scene change (cloud sync) and every language
    /// change. If the shell built its model itself, each time a second one would be created that
    /// SwiftUI discards immediately — and whose unstarted network watch would take over the one
    /// ``FeaturesPhone/DownloadsManager``. `App.init` runs once per program run. `nil` only in
    /// a test run that draws without the shell.
    @State private var wrapper: ShellModel?

    /// **In `init` and not in a `task`.** A `task` runs after the first screen is drawn — the
    /// color scheme then visibly changed after startup.
    init() {
        AppExtensions.load()
        Startup.forwardImageNotifications()
        // **What a crash left lying in the disk ring of the time offset goes away** — as on the TV
        // (AP9); since AP58 G1 the phone has a ring too.
        TimeShift.cleanUp()
        // **The device ID first** — see there for why the order matters.
        Startup.migrateDeviceIdentifier()
        Startup.applyColorScheme()
        Startup.migrateChildAccounts()
        Startup.migrateParentalControls()
        Startup.migrateBridgeAddress()
        Startup.migrateShelfOrder()
        Startup.migrateStructure()
        // **And profiles are made from it** (AP41, 2026-09-21) — after the shelf order, because
        // ``ProfileShelves`` passes on the device state that the line above has only just created.
        ProfileStartup.fetch()
        // **The gate of the first setup before the cloud** (AP88 wave 6): with a setup waiting, the
        // cloud hands its reading to it instead of adopting into a book without an active profile.
        SetupHub.prepare()
        _language = State(initialValue: LanguageState())
        // **And only after that the cloud** (AP43, 2026-09-21). It reads the profile book and
        // writes into it; if it came before ``ProfileStartup/fetch()``, on a device with legacy data
        // it would see an empty book — and create a second profile for every one it finds, next to
        // the one that arises right afterwards.
        CloudStartup.build()
        Task { await CloudStartup.start() }
        Startup.restoreRecording()
        _wrapper = State(
            initialValue: ProbeRun.requested == nil
                ? ShellModel(catalogs: SourceAssembly.state()) : nil)
    }

    var body: some Scene {
        WindowGroup {
            // The probes branch off **before** the shell: without a configured source there are no
            // tabs, and in a shell without tabs nothing can appear.
            if let probe = ProbeRun.requested {
                ProbeView(probe)
            } else if let wrapper {
                // **The intro here too** (decision 27, C16) — only on a cold start, a tap skips it; the
                // rules are at ``IntroStage``.
                IntroStage {
                    ShellView(model: wrapper)
                        // **On the shell and not on the `WindowGroup`** (AP7). The probe for the regular ↔ compact
                        // switch wants to see the real shell wrap its tab bar; in a ``ProbeView`` there are no
                        // tabs, so nothing that could rearrange itself either. Without `CINELOUNGE_KOMPAKT` it
                        // does nothing.
                        .sizeClassProbe()
                        // **The profile's language applies immediately** (AP46): environment locale for
                        // `Text(app:)`, and a rebuild on a **real** change, so that the texts computed with
                        // ``Core/AppLanguageSetting/bundles`` are recreated too — the same solution as `MainView` on the
                        // TV.
                        .environment(\.locale, language.locale)
                        .id(language.identifier)
                        .task { Startup.cleanUp() }
                        // **Back in the foreground means: check** (AP43). What happened on the TV never arrived
                        // without a silent push. The brake from ``ProfileKit/SyncCadence`` prevents a back and forth
                        // between two apps from turning into one run per switch.
                        .onChange(of: scenePhase) { _, newState in
                            guard newState == .active else { return }
                            CloudStartup.notify(.foreground)
                        }
                }
            }
        }
    }
}
