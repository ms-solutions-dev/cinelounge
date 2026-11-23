import AVFoundation
import Core
import DesignSystem
import Features
import Flows
import JellyfinKit
import ParentalControls
import Playback
import PlaylistKit
import PortalKit
import ProfileKit
import SwiftUI

@main
struct CineLoungeApp: App {
    /// **The anchor for the silent pushes** (AP43). SwiftUI has no place of its own for
    /// `didReceiveRemoteNotification`; it arrives through the app delegate.
    @UIApplicationDelegateAdaptor(CloudAnchor.self) private var cloudAnchor
    @StateObject private var language = LanguageStore()
    @StateObject private var session = SessionStore()
    @StateObject private var playlists = PlaylistAccounts()
    @StateObject private var portals = PortalAccess()
    /// **Must sit up here**, not in the settings: its setup applies the
    /// saved color scheme, and that has to happen before the first render —
    /// otherwise the app flashes briefly in the default at launch.
    @StateObject private var themes = ThemeStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // **The crash guard comes before everything else** — it reads what the previous
        // run left behind and then arms itself. Rationale at
        // ``CrashGuard``.
        CrashGuard.install()
        AppExtensions.load()
        // **The audio session set to playback** (F-001, 2026-09-04): Without it
        // the system offers no Picture-in-Picture window — the button stayed away, and
        // the trace stayed silent, because only the start of a window writes a
        // line. It belongs there anyway for AirPlay and Now Playing.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Diagnostics.playbackProblem(
                "Audio session not set to playback — \(Diagnostics.explain(error))", since: nil)
        }
        // And the memory watch: What the system kills dies without a signal —
        // the warning ahead of it is the only number that remains.
        MemoryWatch.start()
        // What a crash left behind in the disk ring goes away (AP9).
        TimeShiftRing.sweep()
        // The remote-controlled tone probe (``ToneProbe``): the device itself
        // answers whether the MPEG audio path holds up — the Mac has lied about that
        // once before (2026-08-16).
        if ToneProbe.isRequested { ToneProbe.run() }
        // **The remote listens from program start and not only after
        // sign-in** (AP39, 2026-09-20).
        //
        // It used to sit in ``MainView/onStart()`` since AP8 — and that only runs once an
        // account is set up. On a fresh TV, though, the sign-in field is
        // exactly the place where typing is most expensive: swiping a server address across
        // a row of letters is the very process AP24 was set up to fight.
        // The fields there have long carried the remote-keyboard tap; what was missing was the
        // listener the phone connects to.
        //
        // ``RemoteControl/start()`` is repeatable since then — the call in `MainView`
        // stays and then does nothing.
        RemoteControl.shared.start()
        // **The child account markers move to the file store** (AP40, 2026-09-20).
        //
        // They used to live here in the Keychain (`accounts.children`) and on the phone in
        // `UserDefaults` (`accounts.children`) — two versions of the same type, and
        // that is why a marker set on the TV never arrived on the other side. Now it is
        // **one** list in ``Core/FileStore``; this call brings over whatever already
        // exists on this device and does nothing once that has happened.
        ChildAccountList().adoptOldLists(
            keychain: SecureStore(), store: .standard)
        // **The shelf order follows** (AP40, 2026-09-21).
        //
        // It used to live as six strings in the Keychain, with `;` between the
        // entries and U+001F between the ID and name of a portal folder; on the phone
        // the same five fields lived under other names and with other separators.
        // Now both are stored as ``Core/ShelfOrder`` in `shelves.json`. The call brings
        // over whatever is already configured here and does nothing once the file exists.
        ShelfPreferences.adopt(from: SecureStore(), in: FileStore())
        // **And profiles come out of it** (AP41, 2026-09-21). This device's catalog —
        // account list, child account markers, channel lists, portal preference and the
        // household person — yields one profile each on first launch; after that the
        // call does nothing. The order matters: it sits **after** the
        // shelf order, because ``ProfileShelves`` passes on the device state that the line
        // above has only just created.
        // **Who is watching is settled before anything reads its state** (AP42,
        // 2026-09-21). ``PlaylistStore/onDevice(…)`` fetches the favorites from the
        // still-frame ledger at setup; if the pointer still said "nobody", it would read the device base —
        // and the next tap on a star would write into the wrong ledger.
        ProfileStartup.pointToActive()
        ProfileStartup.fetch()
        SetupShell.prepare()
        // **And only at the very end the cloud** (AP43, 2026-09-21). It reads the
        // profile ledger and writes into it; if it ran before ``ProfileStartup/fetch()``, it would
        // see an empty ledger on a device with legacy data — and create a second profile for every
        // profile found, next to the one that comes into being right afterwards.
        //
        // **The build is silent, and so is the run.** Without an iCloud sign-in,
        // ``CloudSync/CloudHub/start()`` returns after the account query; the ledgers on the
        // device remain the truth, and the app notices nothing of it.
        CloudStartup.build()
        Task { await CloudStartup.start() }
    }

    var body: some Scene {
        WindowGroup {
            // **The intro lies above everything and outside the identity used for the rebuild**
            // (AP51, 2026-09-24). Underneath, the whole tree stands from the first frame on and
            // loads; the intro only covers the waiting time that passes anyway. Outside
            // the identity, because a change of color scheme would otherwise
            // trigger a second intro. Full rationale at ``Features/IntroStage``.
            IntroStage(active: SidebarProbe.requested == nil) {
                Group {
                    // Before everything else: the minimal sidebar example, when
                    // it was explicitly requested. It hangs off an
                    // environment variable and not off a switch in the source,
                    // so that nothing has to be rebuilt for a measurement.
                    if let probe = SidebarProbe.requested {
                        SidebarProbe(probe)
                    } else {
                        // A single entry point instead of a branch here: Which
                        // account is set up is decided by ``RootView``, via
                        // ``AccountState``. If the branch sat at this point,
                        // there would only be "signed in or not" — and thus no room
                        // for the second path through a channel list, which gets by without a
                        // media server.
                        RootView(
                            credentials: session.credentials,
                            hasPortals: portals.isOn,
                            hasPlaylist: playlists.hasAny,
                            deviceID: session.deviceID,
                            onSignedIn: session.signIn,
                            onPlaylistEntered: playlists.accept,
                            onSignOut: session.signOut,
                            onAccountSwitched: session.switchAccount
                        )
                    }
                }
                // **The identity is the entire switching mechanism.** The colors are read from a global
                // value when a view is built; SwiftUI notices nothing of
                // its change. When the identity changes, it throws the tree away and
                // rebuilds it — crude, but complete. Without that, everything that has not been rebuilt anyway
                // would stay in the old design, and one would see
                // a half-converted app.
                .id(themes.rebuildID)
                .environmentObject(language)
                .environmentObject(themes)
            }
            // One line for the whole app: Both all texts
            // and all date and number formats hang off it.
            .environment(\.locale, language.current.locale)
            .preferredColorScheme(.dark)
            // **Back in the foreground means: check** (AP43). An Apple TV sits in standby
            // for days; whatever happened on the phone in the meantime never arrived
            // without a silent push. The brake from ``SyncCadence`` ensures that
            // going back and forth between two apps does not turn into one sync run per switch.
            .onChange(of: scenePhase) { _, newState in
                guard newState == .active else { return }
                CloudStartup.notify(.foreground)
            }
        }
    }
}

/// Holds the sign-in across program runs.
///
/// At startup it reads from the Keychain — anyone who is signed in does not
/// see the sign-in screen at all.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var credentials: ServerCredentials?

    private let store = SecureStore()

    /// The same device ID as at sign-in — the server recognizes the
    /// TV by it, instead of creating a new entry every time.
    ///
    /// Through ``DeviceIdentity`` and not read directly: Here there was a fallback
    /// to a fresh UUID that was **never saved** — on first launch
    /// that put two IDs side by side, the one from app start and the one from
    /// sign-in. The full rationale is at ``DeviceIdentity``.
    let deviceID = DeviceIdentity.id()

    init() {
        credentials = try? store.loadCredentials()
        // The saved state of the diagnostics switch, before the first request
        // runs. Until here the only writer of ``DebugMode/current`` was
        // the key press in the settings — after every restart the
        // app recorded sparsely again, whatever the switch claimed.
        DebugMode.activate(from: store)
        // **Renderer and custom decoder are off, whatever is saved**
        // (decision 2026-09-04): The switches are removed from the UI;
        // a device on which they were still on would otherwise never
        // return to the HLS path.
        LiveEngineChoice.hls.save(to: store)
        HardwareVideoDecoder.save(false, to: store)
        // **What the device can do, the device asks** (schedule P11): The answer
        // is then also available to the device profile for the media server,
        // without JellyfinKit having to know about playback.
        DeviceCapabilities.adopt(hasHEVC: DeviceCodecs.hasHEVC, hasAV1: DeviceCodecs.hasAV1)
        // Rewritten at every start, not only at sign-in: The
        // server can renew the token, and the extension should never
        // hold an old one. **For the active profile** (AP52) — ``HomeShelf``.
        HomeShelf.write(credentials: credentials)
    }

    func signIn(_ credentials: ServerCredentials) {
        self.credentials = credentials
        // **The session survives the restart** (2026-11-16): since AP88 wave 5 the setup's sign-in
        // comes here (`storeJellyfin`), and the old sign-in screen that saved it through
        // `LoginFlow(persist:)` is gone — without this line Jellyfin was missing after a restart.
        try? store.saveCredentials(credentials)
        // **Sign-in also writes to the account list** (G1). Until here it
        // wrote only the session, and the list in ``SecureStore`` stayed empty — even after
        // the second sign-in. An account switch would thus never have had anything to switch,
        // and the area in the settings would have stayed permanently single-line
        // without anything having been broken.
        //
        // **Here and not in ``AccountsModel``:** This is the only place that
        // every sign-in passes through — the first, the retrofitted one and the one from a switch.
        // A call in the view would only catch the path the view knows.
        try? store.memorize(credentials)
        // **And into the active profile** (AP41, 2026-09-21). The same rationale as one
        // line up, just one level further: This is the only place that every
        // sign-in passes through. Until here ``AccountState`` remembered in the Keychain *whether*
        // there is a media server — an intermediate copy that someone had to keep updating
        // and that only the device knew, never the person.
        ProfileAccesses.create(
            .jellyfin(
                server: credentials.serverURL, userID: credentials.userID,
                username: credentials.username),
            in: FileStore())
        HomeShelf.write(credentials: credentials)
    }

    /// After an account switch: the same assignment as at sign-in.
    ///
    /// **Expressly no cleanup.** ``signOut()`` takes snapshots, Top Shelf token
    /// and image store with it; a switch must not do exactly that, otherwise it is a sign-out
    /// under another name. That nothing more stands here than in ``signIn(_:)`` is therefore
    /// the statement of this method and not an oversight — it exists as a name of its own so that
    /// nobody later writes a `removeAll()` into it "for tidiness".
    ///
    /// **`nil` means: The new profile has no media server** (final check 2026-09-25,
    /// N-1). ``ProfileKit/ProfileSwitch`` has then emptied the session in the Keychain; here
    /// it also drops out of memory, and the wrapper shows the state without a library.
    /// **No ``signOut()``:** The access list, snapshots and the image store belong
    /// to the account, and whoever switches back finds them again. Only the Top Shelf token goes —
    /// the home screen should not show the predecessor's history.
    func switchAccount(_ credentials: ServerCredentials?) {
        guard let credentials else {
            self.credentials = nil
            HomeShelf.write(credentials: nil)
            return
        }
        signIn(credentials)
    }

    func signOut() {
        // The account's snapshots go with it — **before** deleting the
        // credentials, because the folder is determined from them. They are hashed,
        // true, but the lists of an abandoned account have no business
        // on disk any more; on a re-sign-in with the same account
        // the next start simply loads fresh once.
        if let credentials {
            ListSnapshotStore(serverURL: credentials.serverURL, userID: credentials.userID)
                .removeAll()
            // **Sign out at the server and remove from the account list** (setup check,
            // E11, 2026-09-27) — until then the token stayed valid and the access stayed in the
            // list, and every profile with this account got back in without a password.
            SignOut.signOut(credentials, keychain: store)
        }
        try? store.clearCredentials()
        // **Every one, not the one:** Which one stood there is no longer
        // discoverable a line later — the credentials are deleted.
        ProfileAccesses.removeAll(.jellyfin, in: FileStore())
        credentials = nil
        // The home screen must not keep showing the history of an abandoned account
        // — and the token in the shared entry would be dead anyway.
        HomeShelf.write(credentials: nil)
        // Images of the previous account must not remain.
        Task { await ImageCache.shared.clear() }
    }
}

/// Holds the third path: whether the portals are switched on.
///
/// **A holder of its own beside ``SessionStore`` and ``PlaylistAccounts``**, for the same
/// reason as their separation: The three paths are independent of each other, and each
/// suffices on its own. Keeping them in one holder would create exactly the coupling that
/// ``AccountState`` is meant to avoid.
///
/// **And it holds less than the other two.** There, an access is stored — an
/// access token, a list. Here there is nothing to store: What a portal is, the
/// bridge knows, and where it stands is a setting (``BridgeAddress``).
/// What the user decides is **whether they want it**.
@MainActor
final class PortalAccess: ObservableObject {

    /// **Read once and no longer switched here** (AP88 wave 5): the wish came from the old
    /// sign-in's "Switch on the portals", which A6 replaced with a request; the settings and the
    /// CL-Server sheet write it into the profile themselves.
    @Published private(set) var isOn: Bool

    private let fileStore: any KeyValueStore = FileStore()

    /// **Since AP41 from the ``ProfileKit/ProfileBook``** and no longer from the Keychain:
    /// The preference belongs to the person. A child profile for whom nobody switched the portals
    /// on does not see them — even if the adult next to them has them.
    init() {
        isOn = ProfileBook.read(from: fileStore).state.wantsPortals
    }
}

/// Holds the stored channel lists across program runs.
///
/// Separate from ``SessionStore``, because the two accesses are independent
/// of each other: Whoever only uses channel lists has no sign-in, and whoever only uses a
/// media server has no list. Keeping both in one holder would have created
/// exactly the coupling that ``AccountState`` is meant to avoid.
@MainActor
final class PlaylistAccounts: ObservableObject {

    /// Whether at least one list is stored. Initially `nil` — not yet read.
    ///
    /// The difference from `false` counts: With `false` the setup appears for a moment,
    /// although a list has long been entered. The rationale
    /// is at ``RootView/hasPlaylist``.
    @Published private(set) var hasAny: Bool?

    private let store: PlaylistStore

    init() {
        store = .onDevice()
        hasAny = !store.playlists.isEmpty
    }

    /// Accepts an entered access, **after** it has been queried.
    ///
    /// Returns a translation key if it is unusable, otherwise `nil`.
    ///
    /// **It is checked before saving, not after.** A mistyped server or
    /// a wrong password otherwise counts as set up, the Live area appears
    /// empty, and the cause cannot be told apart from a provider without
    /// channels. With an access whose password is in every address, that
    /// is particularly unpleasant: One searches at the provider, not at oneself.
    func accept(_ access: PlaylistAccess) async -> String? {
        switch access.kind {
        case .xtream:
            return await acceptXtream(access)
        case .m3u:
            return acceptM3U(access)
        }
    }

    private func acceptXtream(_ access: PlaylistAccess) async -> String? {
        // Normalizing the address lives in ``XtreamEndpoint`` and stays
        // there. If it fails here, the address is unusable — and that before a
        // network access is attempted.
        guard
            let endpoint = XtreamEndpoint(
                server: access.address,
                username: access.username,
                password: access.password
            )
        else { return "login.playlistBadAddress" }

        let playlist = Playlist(
            // Derived from the host name, because on tvOS the name would be one more
            // field to type and can be changed in the settings.
            name: endpoint.server.host() ?? access.address,
            kind: .xtream(server: endpoint.server, username: endpoint.username)
        )

        do {
            let info = try await XtreamClient(playlist: playlist, credentials: endpoint).verify()
            // Two separate messages, because there are two different causes:
            // a mistyped password and an expired account. A shared
            // message would send the user to the wrong place — they check their
            // input although the account has simply run out.
            guard info.isAuthorized else { return "login.playlistRejected" }
            guard info.isActive else { return "login.playlistExpired" }
        } catch {
            Diagnostics.defect(
                "Channel list unreachable: \(Diagnostics.explain(error))", since: nil,
                area: "Anmeldung")
            return "login.playlistUnreachable"
        }

        store.add(playlist, password: endpoint.password)
        ProfileAccesses.create(.channelList(identifier: playlist.id), in: FileStore())
        hasAny = true
        return nil
    }

    private func acceptM3U(_ access: PlaylistAccess) -> String? {
        guard let url = URL(string: access.address.trimmingCharacters(in: .whitespaces)),
            url.scheme != nil
        else { return "login.playlistBadAddress" }

        // Not fetched, only adopted: An M3U list can be megabytes
        // in size, and fetching belongs in the Live area, which loads anyway.
        // A failure there is visible; a fetch here would only hold up the
        // setup.
        let playlist = Playlist(
            name: url.host() ?? access.address,
            kind: .m3u(url)
        )

        store.add(playlist)
        ProfileAccesses.create(.channelList(identifier: playlist.id), in: FileStore())
        hasAny = true
        return nil
    }
}
