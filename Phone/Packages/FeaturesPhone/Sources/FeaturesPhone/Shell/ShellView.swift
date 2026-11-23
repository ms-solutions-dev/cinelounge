import Combine
import Core
import DesignSystemPhone
import Diagnose
import ProfileKit
import RatingsKit
import SwiftUI

#if canImport(UIKit)
    import Combine
    import UIKit
#endif

/// The shell: tab bar, view, sheet.
///
/// The one place where it is decided what is currently visible. In the prototype that is a
/// state variable on the root element; here it is this file.
///
/// **The model comes from outside and is never built here** (shell check H2, 2026-09-27).
/// Until then `State(initialValue: ShellModel(…))` stood here, and SwiftUI evaluates this
/// expression at **every** build — since AP43/AP46 at every scene and language change of the
/// app. Every discarded instance handed the one ``DownloadsHolder`` its never-started network
/// watch: new downloads then rested forever, and "Wi-Fi only" no longer applied on cellular.
/// The app holds the one model (`CineLoungeApp`).
public struct ShellView: View {

    private let model: ShellModel
    @Environment(\.scenePhase) private var scene

    @MainActor
    public init(model: ShellModel) {
        self.model = model
        TabBar.setUp()
    }

    public var body: some View {
        mainContent.environment(SourceAssembly.animeRatings)
    }

    @ViewBuilder
    private var mainContent: some View {
        content
            // **Codes from the TV via the system camera** (on-device test 2026-09-27, T3) —
            // ``CodeEntry``. **On the whole shell and not on the bar** (device finding 2026-09-30):
            // on a fresh phone the setup is up, and the link was lost — exactly when a profile from the
            // TV would bring everything along.
            .onOpenURL { url in model.open(url) }
    }

    @ViewBuilder
    private var content: some View {
        // **Without a catalog no tabs — and without tabs a BLACK screen.**
        //
        // Seen on 2026-09-05 in the simulator: a start without an entered login showed an empty black
        // surface, without bar, without text. That looks like a crash, and the error was searched
        // for in the view that had just been built.
        //
        // The cause has been in the model since AP12 and was correct: `CatalogState.tabs`
        // returns nothing for an empty state, because a tab over nothing was the error that the
        // first version fixed. Only what came **instead** was wrong — namely nothing. A `TabView`
        // without a `Tab` has no defined display.
        //
        // Until the setup is in place (AP21), that is the state of a freshly loaded device. It
        // therefore gets the job that exists for it, and no stopgap.
        if model.tabs.isEmpty, !model.isManageable {
            // **A child profile without sources gets no setup** (G3): since "Who's watching?" makes
            // profiles without a login selectable, a child can end up here — and the setup is
            // management (``KidsTargets``, decision 20). What remains is the way out, as in the child
            // interface on the TV.
            emptyProfiles
        } else if model.tabs.isEmpty {
            // **Since AP21 the setup stands here and no longer the job.** The job "No media server
            // yet" was right as long as there was nothing its button could lead to — a button into the
            // void is worse than none. Now the path exists, and the job remains anyway: it is one of
            // the nineteen states and appears wherever a **single** source is missing while here none
            // is present at all.
            SetupView(
                model: SetupHub.model(deviceID: SourceAssembly.deviceID),
                done: { model.adopt(SourceAssembly.state()) }
            )
            // **A profile from the system camera does not wait for the setup** — it brings the sources
            // along and often makes them unnecessary. All other codes wait until the bar is up; the
            // ``Navigator`` has remembered them.
            .onChange(of: profileWaiting.wrappedValue, initial: true) { _, pending in
                if pending { SetupHub.running?.linkOpened() }
            }
            .sheet(isPresented: profileWaiting) {
                if let cloud = ProfileCloud.attached {
                    NavigationStack {
                        CloudView(
                            cloud: cloud, opened: model.openedProfileLink,
                            pairingCode: model.openedPairingCode,
                            done: {})
                    }
                }
            }
        } else {
            // **The design variant in ONE place** (G3, finding B3): tiles, header picture and person
            // sheet read it from the environment. Outside on the bar, so that sheets and overlays
            // inherit it too.
            bar
                .environment(\.surface, model.surface)
        }
    }

    /// Whether a profile code from the camera is open during setup. Closing clears it — and
    /// re-reads the state, because an accepted profile brings sources along.
    private var profileWaiting: Binding<Bool> {
        Binding(
            get: { model.openedProfileLink != nil || model.openedPairingCode != nil },
            set: { pending in
                guard !pending else { return }
                model.openedProfileLink = nil
                model.openedPairingCode = nil
                SetupHub.running?.linkClosed()
                model.adopt(SourceAssembly.state())
            })
    }

    /// A child profile without a configured source — **only the way back**, plus the sheet and
    /// door through which "Who's watching?" leads.
    private var emptyProfiles: some View {
        VStack(spacing: MetricsBoard.phone.section) {
            LargeTitle(title: "profiles.emptyTitle", isStretching: false)
            Footnote(message: "profiles.emptyChild")
            Button {
                model.sheetState.open(.accountSwitch)
            } label: {
                Text(app: "sidebar.switchProfile")
            }
            .buttonStyle(.loud)
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorRole.reason.color)
        .environment(\.surface, model.surface)
        .sheet(model.sheetState) { identifier in
            SheetPlaceholder(identifier: identifier, model: model)
        }
        .lockedDoor(model.navigator, state: model.parentalControls, isResponsible: true)
        .onReceive(NotificationCenter.default.publisher(for: ProfilePointer.switched)) { _ in
            model.profileSwitched()
        }
        .task { model.start() }
    }

    private var bar: some View {
        Group {
            // **Without a network the bar drops, and the downloads remain** — the rule for this is in
            // ``BarState``, including both exceptions.
            if model.barState == .downloadsOnly {
                offline
            } else {
                tabBar
            }
        }
        .tint(ColorRole.brandLight.color)
        .background(ColorRole.reason.color)
        // **The watches start here and not in the model's initializer** (E64) — the whole trail at
        // ``ShellModel/start()``.
        .task { model.start() }
        // **Sheet, overlay and door hang on both versions.** Without a network the profile picture
        // in the downloads header leads into the person sheet and from there into Settings; if they
        // hung on the tab bar, it would be the only screen of the app without a way out — and
        // exactly the one that one then looks at for a while.
        // **The bar follows the setup, not the restart** (2026-09-07): a channel list created in
        // Settings used to get its Live tab only at the next start — and until then Live showed
        // "No groups read yet" above a login that had long been there.
        .onReceive(NotificationCenter.default.publisher(for: SetupState.changed)) { _ in
            // **The parental controls re-read too** — a changed setup can be a changed profile book
            // (kind of a profile, from the cloud).
            model.parentalControls.rereadProfile()
            model.episode(SourceAssembly.state())
        }
        // **Another profile is active** (tvOS roadmap AP45) — parental controls, picture and
        // sources follow it. See ``ShellModel/profileSwitched()``.
        .onReceive(NotificationCenter.default.publisher(for: ProfilePointer.switched)) { _ in
            model.profileSwitched()
        }
        // **And when something arrived from remote** (TV finding C2-5, strand E): another device
        // makes a profile a child, changes the boundary or the picture — the pointer stays, the
        // book does not. Without this line the remembered state would apply until the next switch.
        .onReceive(NotificationCenter.default.publisher(for: ProfileCloud.arrived)) { _ in
            model.cloudArrived()
        }
        .sheet(model.sheetState) { identifier in
            SheetPlaceholder(identifier: identifier, model: model)
        }
        .overlay(isPresented: overlayOpen) {
            OverlaidView(
                navigator: model.navigator, parentalControls: model.parentalControls
            ) { view in
                TabPlaceholder(view: view, model: model)
            }
        }
        // **The locked door hangs on both levels and still opens only once.** On iOS an overlay is
        // a `fullScreenCover`; a sheet that hangs here would end up underneath.
        // ``LockedDoor/isResponsible`` says which level is currently the topmost — exactly one.
        .lockedDoor(
            model.navigator, state: model.parentalControls,
            isResponsible: model.navigator.overlay.isEmpty
        )
        // **The only memory brake built — and until 2026-09-06 nobody pulled it.**
        // ``ImageCacheActor/shrink(to:)`` has been there since E10 and was called only by tests;
        // on the device the system's warning arrived and nobody listened. On iOS it is the
        // harbinger of termination: anyone who ignores it is cleared out in the background, and the
        // viewer sees a restart on coming back instead of their place in the film.
        //
        // **Here and not in the image store.** An actor without a surface should not register with
        // the system — otherwise a test that builds it hangs on a notification that does not exist
        // on the computer at all.
        .onMemoryWarning {
            PhoneEvent.memoryWarning.note()
            Task {
                let unrestricted = await ImageCacheActor.shared.shrink()
                Diagnose.step(.surface, "Image cache cleared, \(unrestricted) bytes free")
            }
        }
        .onChange(of: scene) { _, fresh in
            // The first application of the recording. A scene change is a step and appears in the log
            // only with verbose recording — but then it is there, and when searching for "why did
            // playback break off" it is the first line one needs.
            switch fresh {
            case .background:
                model.scenePhase.wentToBackground()
                PhoneEvent.movedToBackground.note()
                // **From here on the downloads may report** (AP8): anyone who has the app open sees the
                // list; a notification about it would be a banner above what is there anyway.
                model.downloads?.isInForeground = false
            case .active:
                let wasAwayLong = model.scenePhase.cameBack()
                PhoneEvent.returnedToForeground.note(wasAwayLong ? "reload due" : nil)
                model.downloads?.isInForeground = true
                // A background sync may have brought a picture from the TV.
                model.profileImages.load()
            default:
                break
            }
        }
        // **The sixth event, and it was the only one that appeared nowhere yet.** ``PhoneEvent``
        // has six; this view writes three, the ``AudioSession`` two, and the network change was
        // written by none.
        //
        // **Here and not in the network watch.** `NetworkStatus` does not depend on the diagnostics
        // package, and a dependency for one line would be bought dearly — the path is observed at
        // this place anyway.
        //
        // **On the phone a network change ends a playback**, and right in the middle of the
        // picture: Wi-Fi off when leaving the apartment, cellular on the train. Without this line
        // the log says only "it stopped".
        .onChange(of: model.networkMonitor.route) { _, _ in
            // **With the interfaces behind it** (2026-09-13): the translation in
            // ``NetworkStatus/NetworkPath/init(_:)`` carries an assumption about the tunnel, and whether it
            // holds on the device is told only by this line — `none · utun3` or `wifi · utun3, en0`.
            PhoneEvent.networkChanged.note(
                "\(model.networkMonitor.route.kind.rawValue) · \(model.networkMonitor.interfaces.joined(separator: ", "))"
            )
            // **And the downloads are re-evaluated** — see ``DownloadsManager/recheck()``. Until
            // 2026-09-08 nobody listened to the network path: a download paused on cellular stayed paused
            // even after Wi-Fi was back.
            model.downloads?.recheck()
            Task { await model.downloads?.backfillSeriesClearances() }
            // **And the location all the more.** A network change is the occasion for a change of
            // place — one leaves the house, Wi-Fi drops, cellular takes over. Exactly then "at home"
            // is no longer true.
            Task { await model.locationMonitor.verify() }
        }
        // **Whoever is watching has priority over what is downloading** (2026-09-09). The provider
        // account allows **one** connection; without this line a running download gets a `509`
        // when the player is entered, falls back to a host that a provider catalog does not have at
        // all, and ends as a red warning triangle — for something that goes away by itself. The
        // rule for this is in ``Downloads/ConnectionScarcity``; the consideration was built and
        // nobody set it.
        //
        // **On the signpost and not in the player.** It alone knows that a picture is running right
        // now — even when it was started via a state, a tile or the downloads. In the player itself
        // the same line would stand three times.
        .onChange(of: model.navigator.current == .player, initial: true) { _, isPlaying in
            model.downloads?.claim = isPlaying ? .playbackHere : .unrestricted
        }
        .onChange(of: model.barState, initial: true) { _, state in
            if state == .downloadsOnly { model.enterDownloadsAlone() }
        }
        .onChange(of: model.ruleState) { _, _ in model.followRulesState() }
        // **The profile behind the profile picture, once for all headers** (AP49) — also for those
        // in sheets and overlaid views, hence as the last addition.
        .environment(\.headerProfile, model.headerProfile)
    }

    private var tabBar: some View {
        TabView(selection: tabSelection) {
            ForEach(model.tabs) { tab in
                SwiftUI.Tab(value: tab) {
                    NavigationStack(path: model.path(forItem: tab)) {
                        TabPlaceholder(tabs: tab, model: model)
                            .id(model.rootState)
                            .navigationDestination(for: ViewPath.self) { route in
                                TabPlaceholder(route: route, model: model)
                            }
                    }
                } label: {
                    Label {
                        Text(appKey: tab.titleKey)
                    } icon: {
                        Image(
                            systemName: tab.icon.zu(active: tab == model.highlightedTab)
                        )
                    }
                    .environment(\.symbolVariants, .none)
                }
            }
        }
        // **On iPad a sidebar instead of the floating capsule** (AP7, 2026-09-24). In regular,
        // iPadOS laid the five tabs as a capsule in the middle over the content — over header
        // pictures and over the first grid row. The sidebar can be collapsed and then becomes the
        // bar at the top again. In compact, that is on the phone **and** in a half-width window,
        // the style changes nothing: there the bar stays at the bottom, with the look from
        // ``TabBar`` — which does not carry over into the sidebar itself, see there.
        .tabViewStyle(.sidebarAdaptable)
        // **The path of the number from the bar into every scroll surface.** Passing it through the
        // views would mean touching four files for one gesture — and forgetting the fifth at the
        // next tab.
        .environment(\.scrollToTopRequest, model.scrollToTopRequest)
        // **And the network information for the download sheets below** (AP6). Neither of the two
        // has a network watch; here it is attached.
        .environment(\.largeVolumesAcceptable, model.networkMonitor.route.largeVolumesAcceptable)
    }

    /// Without a network: **one screen, one band, no bar.**
    ///
    /// **The downloads lie in the library's stack**, which is where they belong with a bar too
    /// (``ViewID/tabs``) — so "Store" here as there leads one level deeper and back
    /// again, instead of opening a second stack next to the first.
    private var offline: some View {
        NavigationStack(path: model.path(forItem: .library)) {
            VStack(spacing: 0) {
                InFlightBand { model.networkMonitor.lookUp() }
                TabPlaceholder(view: .downloads, model: model)
                    .id(model.rootState)
            }
            .background(ColorRole.reason.color)
            .navigationDestination(for: ViewPath.self) { route in
                TabPlaceholder(route: route, model: model)
            }
        }
    }

    /// The tab choice — **clamped when read**, not in a reaction to it.
    ///
    /// An `onChange` that repairs a choice that has become invalid comes one pass too late: for
    /// this one frame the selection points at a tab that the bar does not have, and SwiftUI has
    /// no defined display for that.
    private var tabSelection: Binding<Tab> {
        Binding(
            get: {
                model.tabs.contains(model.navigator.tabs)
                    ? model.navigator.tabs : (model.tabs.first ?? .start)
            },
            set: { model.select($0) })
    }

    private var overlayOpen: Binding<Bool> {
        Binding(
            get: { !model.navigator.overlay.isEmpty },
            set: { if !$0 { model.navigator.done() } })
    }
}

extension View {

    /// Calls `action` when the system asks for memory back.
    ///
    /// **With a platform switch at exactly this place** — the same rule as with
    /// ``withoutNavigationBar()``: `didReceiveMemoryWarningNotification` does not exist on
    /// macOS, and macOS is built here only so that `swift test` runs on the computer instead of
    /// in the simulator.
    func onMemoryWarning(_ action: @escaping () -> Void) -> some View {
        #if canImport(UIKit)
            onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification)
            ) { _ in action() }
        #else
            self
        #endif
    }
}
