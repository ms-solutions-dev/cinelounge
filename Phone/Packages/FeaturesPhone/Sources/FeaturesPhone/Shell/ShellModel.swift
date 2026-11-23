import Core
import DesignSystemPhone
import Diagnose
import Downloads
import Flows
import Foundation
import Household
import NetworkStatus
import Observation
import ParentalControls
import ProfileKit
import SwiftUI

/// The state of the shell: which tab, which view, which sheet.
///
/// What are `data-` attributes on the root element in the prototype are observable
/// properties here — the same separation between state and presentation, just in SwiftUI.
@MainActor
@Observable
public final class ShellModel {

    public let navigator = Navigator()
    public let sheetState = SheetState()

    /// What the download sheet is currently deciding — **on the model and not on the view.**
    ///
    /// **The product owner's finding of 2026-09-09:** when in the library and long-pressing an
    /// item, options such as "download" should be available. The long press can now open the
    /// sheet from anywhere — from the library, from search, from Home, from favorites. Five
    /// screens, one sheet.
    ///
    /// **That is why the request lives here.** The detail page holds its own (it is itself the
    /// host of the sheet there); the four tab screens are not — for them the sheet hangs on the
    /// shell, and a request held in one of the four views would be unreachable for the
    /// ``SheetPlaceholder``.
    public var downloadRequest: DownloadRequest?

    /// The long press on a tile wants to download.
    ///
    /// **The same rule as on the download button of the detail page** (``DetailView``): anyone
    /// who has not queued anything yet gets the sheet — scope, quality tier and language version
    /// are decisions that are made once. If something is already running, the question has long
    /// been answered, and the long press does not even offer the command
    /// (``TileCommands``).
    public func openDownloadSheet(forItem request: DownloadRequest) {
        downloadRequest = request
        sheetState.open(.load)
    }

    /// What the downloads know about this identifier — **one manager, one answer.**
    ///
    /// The four tab screens and the detail page ask the same place; two answers would be the
    /// case that ``downloads`` rules out in its own rationale: a tile in outline above a title
    /// that the downloads list as "downloading".
    public func downloadState(_ identifier: String) -> DownloadState? {
        downloads.map { DownloadState.forItem(.init(identifier), in: $0.downloads) }
    }
    public let scenePhase = SceneState()

    /// Who is watching — **one list for the circle at the top right and for the sheet below.**
    ///
    /// **One and not two.** The profile picture shows a letter, the sheet a list, and both are
    /// the same piece of information. With two ``AccountsModel`` instances, switching the account
    /// in the sheet would leave the letter in the circle unchanged until someone rebuilds the
    /// view — a state in which the screen claims two different things.
    public let accounts: AccountsModel

    /// The profiles of this device — **the shared management** (``Flows/ProfileManagement``),
    /// the same one the TV uses to create, change, remove, merge and switch.
    ///
    /// **Since G3 (2026-09-26), "Who's watching?" on the phone shows profiles and not accounts**
    /// (finding B2): until then a profile without a media server login could not be selected,
    /// and creating a profile worked only on the TV. The ``accounts`` remain — they are the
    /// logins under `Settings → Media server`, not the people.
    public let profile: ProfileManagement

    /// The parental controls — **rule, PIN and pass in one place.**
    ///
    /// **Anyone who rebuilds the rule elsewhere builds the gap back in.** The most serious
    /// finding of the usability pass was that from the child account four taps led to the
    /// "adult channels" switch, without a PIN — found with a rule table and a test suite, not
    /// with the eye.
    public let parentalControls: ParentalControlsState

    /// Whether this **device** is currently in child mode.
    ///
    /// **Kept separate from the account list, and that is the decision of 2026-09-06** A child
    /// account says whom the progress belongs to; child mode says what is locked right now.
    /// Anyone who puts both into one property loses one of the two cases — the child on the
    /// adult's phone or the adult on the child account.
    public var childMode: ChildMode { parentalControls.mode }

    /// What the phone is currently connected to.
    ///
    /// **Until 06.09 there was not a single line `NWPathMonitor` in the whole project** — the
    /// package `NetworkStatus` was there and nobody called it. That made ``PlaybackPhase/networkAirplaneMode``
    /// unreachable: without a network every source reported its own failure, and the screen
    /// sent the viewer to check a server that they had not even asked.
    public let networkMonitor = NetworkStatus.NetworkWatch()

    /// The second piece of information — **am I on the same network as my media server?**
    ///
    /// ``networkMonitor`` does not answer that: it says "Wi-Fi" in a stranger's house as well.
    /// See ``LocationMonitor``.
    ///
    /// **Until 13.09 a ``Quellenwache`` stood here** — "does anyone answer at all?" — and it
    /// also decided about the tab bar. Why it is gone is described in ``BarState``; why it
    /// was built had a different cause than assumed: ``NetworkStatus/NetworkPath/init(_:)``.
    public let locationMonitor = LocationMonitor()

    /// The remote — **one for the app and not one per screen.**
    ///
    /// **Until 2026-09-12 it was created in ``TabPlaceholder``**, that is, when entering the
    /// remote screen, and died when leaving it. That meant "where is playback happening" was
    /// not a question one could ask anywhere else: the button in the header opened a sheet
    /// whose Apple TV row was hard-wired to "unreachable" (`isTVReachable: false`), and
    /// the choice set a value that had no effect. It was reported with a screenshot: the sheet
    /// behind the button between profile and download looked wrong.
    ///
    /// **It lives here because a connection outlives a screen.** Anyone who closes the remote
    /// to search for a title should not lose the TV.
    ///
    /// **It does not search on its own.** A Bonjour browser that runs from the first minute to
    /// the last costs radio and battery for a question nobody asked; it searches as long as the
    /// target sheet or the remote is open.
    /// - Note: **Injectable from outside so the chain can be tested** — in production with
    ///   ``SecondScreen/OwnWire``, in a test with a double that sends nothing into the
    ///   network. Without that, the decision in ``start(_:from:)`` could only be verified on a
    ///   device, and it is exactly that decision that is new.
    public let remote: RemoteModel

    /// A handoff code that the system camera opened (``CodeEntry``) — until the handoff has
    /// picked it up or it is closed.
    var openedHandoffCode: String?
    /// A profile link from the system camera (``ProfileKit/ProfileLink``) — "Devices & Sharing"
    /// accepts it as soon as the page is up.
    var openedProfileLink: ProfileLink?
    /// A pairing code from the system camera, which ``CloudView`` processes after confirmation.
    var openedPairingCode: String?

    /// Where playback happens.
    ///
    /// **Computed and not stored.** A separate field could say "Apple TV" while no connection
    /// exists — and this is exactly the kind of information that is the reason the sheet had no
    /// effect before. The target **is** the connection.
    public var target: PlaybackDestination {
        remote.chosen == nil ? .phone : .tv
    }

    /// Play — **here or on the TV, and the decision is made in one place.**
    ///
    /// **Until 2026-09-12 it was made nowhere.** ``DetailModel/buttonLabel(target:)`` had
    /// labeled the main button "on Apple TV" since 2026-09-06, and the same button then opened the
    /// player of this phone: a label that promised something different from the action. The
    /// handoff itself was fully built (``RemoteModel/pushOver(_:from:)``) and was
    /// called by exactly one screen.
    ///
    /// **What matters is the established connection and not the selected device.** ``target``
    /// hangs on ``RemoteModel/chosen``, and that is the *intent*: it is set while the
    /// connection is still being made, because the header should show the TV in that very
    /// second. A command sent into a connection that is not yet up would arrive nowhere — and
    /// the phone would then sit on a screen that offers pause and seek for something that never
    /// started.
    ///
    /// **If it is not up, playback happens here, without a message.** An error message for a
    /// film that then starts in the hand explains nothing that cannot be seen.
    ///
    /// **And the remote comes along.** Anyone who hands over wants to be able to pause and seek
    /// afterwards; without it the phone would stay on a detail page while something starts in
    /// the other room.
    public func start(_ job: PlaybackJob, from location: TimeInterval) {
        guard remote.state == .connected else {
            navigator.show(.player, job: job)
            return
        }
        Diagnose.step(
            .surface, "Handoff to the TV: \(job.identifier) from \(Int(location)) s")
        remote.pushOver(job, from: location)
        navigator.show(.remote)
    }

    /// Counts every double tap on the already selected tab — see
    /// ``SwiftUI/EnvironmentValues/scrollToTopRequest``.
    public private(set) var scrollToTopRequest = 0

    /// The downloads — **one manager for the app and not one per screen.**
    ///
    /// Two would know nothing about each other: the detail page would show a button in outline
    /// while the downloads screen listed the same title as "downloading". It lives here because
    /// the network watch also lives here, on which its rule depends.
    ///
    /// **`nil` as long as nothing is set up.** Without a source there is nothing to resolve,
    /// and downloads without resolution would be a list of buttons that do nothing.
    public private(set) var downloads: DownloadsManager?

    /// What is available in the catalog. Determines which tabs appear at all.
    public var catalogs: CatalogState
    /// The identifier that every tab view hangs on. When it counts up, the view is created
    /// anew, with fresh sources.
    ///
    /// **Two triggers, one counter.** A changed setup (``episode(_:)``) and a pressed sync button
    /// (``Synchronization/state``) ask the same question — *are the sources behind this view
    /// still the right ones?* — and require the same answer. Two separate identifiers would be
    /// two truths on top of it; a view would then have to read both, and anyone who forgets one
    /// rebuilds after one trigger and not after the other.
    public var setupState: Int { ownState + synchronization.state }

    /// The half that this shell counts itself — see ``setupState``.
    private var ownState = 0

    /// Whether everything is currently being fetched anew. **Injectable from outside for the
    /// tests**, otherwise the one shared instance — rationale at ``Synchronization``.
    private let synchronization: Synchronization

    /// - Parameter konten: **injectable from outside so the chain can be tested.** It leads from
    ///   the Keychain via ``AccountsModel`` to the letter in the circle, and the finding of 2026-09-06
    ///   hung on exactly this chain: it was severed in one place and hard-wired in another.
    public init(
        catalogs: CatalogState = .fromAccesses(jellyfin: true),
        accounts: AccountsModel = AccountsModel(),
        parentalControls: ParentalControlsState = ParentalControlsState(ledgerStore: FileStore()),
        synchronization: Synchronization = .shared,
        remote: RemoteModel = RemoteModel(),
        profile: ProfileManagement? = nil,
        ledgerStore: any KeyValueStore = FileStore()
    ) {
        self.catalogs = catalogs
        self.ledgerStore = ledgerStore
        self.accounts = accounts
        // **With the device's list catalog**, so that a removed profile takes its channel lists
        // with it (on-device test build 1332, finding 1).
        self.profile =
            profile
            ?? ProfileManagement(
                keychain: accounts.keychain,
                deviceLists: { SourceAssembly.deviceStorage() })
        self.parentalControls = parentalControls
        self.synchronization = synchronization
        self.remote = remote
        // **`CINELOUNGE_OHNE_NETZ=1` switches the offline screen on** — a test hook like
        // `CINELOUNGE_ZUSTAND` and for the same reason: airplane mode cannot be switched on in the
        // simulator (`simctl` cannot do it), and a screen that cannot be opened is not tested. The
        // watch is **not** started in that case — otherwise the first real report would overwrite
        // the preset after a moment.
        //
        // **It lives here and not in ``start()``** because it is not a start but a set value: it
        // costs nothing and may be correct from the very first render.
        if ProcessInfo.processInfo.environment["CINELOUNGE_OHNE_NETZ"] == "1" {
            networkMonitor.adopt(.none)
        }
        // **The downloads are created at start and not only on a setup change.**
        //
        // **The finding of 2026-09-08, reported with a screenshot:** "neither a button up here nor a
        // button or download option in the content". Everything was built — the button, the sheet,
        // the session — and nothing was visible: this line was only in ``episode(_:)``, that is, on
        // the path of a **change**. Anyone who starts the app and changes nothing had
        // `downloads == nil`; with that, ``DownloadState/forItem(_:in:)`` is `nil` everywhere, and every
        // button disappears by exactly the rule that otherwise correctly makes it disappear.
        //
        // **The same type of error as with the store on 2026-09-07 and with the favorites tab:** built,
        // linked, and the path to it never taken.
        buildDownloads()
        // **The lock hangs in ONE place**, and this is it: every path of the app runs through
        // ``Navigator/show(_:)``. Anyone who wrote it into the views instead would have it in
        // forty places and, with the next screen, in thirty-nine.
        navigator.gatekeeper = { [parentalControls] view in
            parentalControls.job(forItem: view.rawValue)
        }
        navigator.lock = { [parentalControls] view in
            KidsTargets.locked(view, rule: parentalControls.rule)
        }
        navigator.onlyStack = { [weak self] in
            self?.barState == .downloadsOnly ? .library : nil
        }
        // **The account says whom the progress belongs to** — the device state says what is locked
        // right now. Both apply, and what either of them locks is locked.
        parentalControls.accountKind = accounts.signedInAccount?.kind == true ? .kind : .adult
        seenRulesState = ruleState
        // **Start directly in a tab** — with `CINELOUNGE_REITER=library`. Without this hook only
        // the start screen can be viewed in the simulator: `simctl` cannot send a touch, and a view
        // that cannot be opened is not tested.
        // **`CINELOUNGE_ANSICHT=settings` opens an overlaid view.** A test hook like
        // `CINELOUNGE_REITER`: Settings is three taps behind the profile picture, and the simulator
        // accepts no tap commands from outside.
        // **With a comma also a whole path:** `CINELOUNGE_ANSICHT=settings,channelLists`
        // sets the root and then **pushes** onto it.
        //
        // **The reason came on 2026-09-07 from an error that four check runs did not see.** The overlay
        // attached `navigationDestination` in the wrong place; as a result **every step** ended on
        // SwiftUI's placeholder "no destination found". It was reported exclusively in the system
        // log — and only **at the first step**. A test hook that can only open roots never gets
        // there: it sees every screen individually and never the path in between. That is exactly
        // what was broken.
        if let name = ProcessInfo.processInfo.environment["CINELOUNGE_ANSICHT"] {
            for part in name.split(separator: ",") {
                guard let view = ViewID(rawValue: String(part)) else { continue }
                navigator.show(view)
            }
        }
        // **And `CINELOUNGE_BLATT=accountSwitch` opens a sheet** (2026-09-07).
        //
        // **The gap existed ever since sheets exist.** There was one hook here each for tab, view,
        // title and player — for the **twenty-four sheets** none. That took its revenge on exactly
        // this day: the account sheet was the only screen of the rework that nobody looked at, and
        // it was the only one that still looked old afterwards. The product owner noticed it on the
        // device.
        //
        // The same rationale as above and the same design: `simctl` cannot send a touch, and a
        // screen that cannot be opened is not tested.
        if let name = ProcessInfo.processInfo.environment["CINELOUNGE_BLATT"],
            let sheet = SheetID(rawValue: name)
        {
            sheetState.open(sheet)
        }
        if let name = ProcessInfo.processInfo.environment["CINELOUNGE_REITER"],
            let tab = Tab(rawValue: name), catalogs.tabs.contains(tab)
        {
            navigator.tabs = tab
        }
        // And directly into a detail page: `CINELOUNGE_TITEL=<identifier>`.
        if let identifier = ProcessInfo.processInfo.environment["CINELOUNGE_TITEL"] {
            navigator.show(.detail, title: identifier)
        }
        // **And directly into the player: `CINELOUNGE_SPIELER=<identifier>`.**
        //
        // Without this hook the player cannot be tested in the simulator: `simctl` cannot send a
        // touch, and it opens only via a button. A view that cannot be opened is not tested — and
        // that is exactly the view in which an error costs the picture.
        //
        // **`CINELOUNGE_SPIELER_HERKUNFT=channelList` in addition, for the live path.** Since
        // 2026-09-06 the origin and no longer the identifier decides which source plays — and a
        // channel identifier carries no attribute by which it could be recognized. Without this
        // second hook ``ChannelPlayerSource`` is not reachable at all in the simulator, and a path
        // that cannot be opened is not tested.
        //
        // **And `CINELOUNGE_SPIELER_AB=0` forces a start at zero.** Without it the server says
        // where to begin — for a half-watched title that is in the middle, and that is exactly
        // where the open finding "the first frame does not appear" sits. A start at zero is the
        // third of the three checks it requires.
        // **`CINELOUNGE_VORRAT_LEGEN=<identifier>` puts a title into the downloads at start** —
        // the test hook that was missing until 2026-09-08.
        //
        // Without it the download path cannot be triggered **at all** in the simulator: `simctl`
        // cannot send a touch, and the button for it sits on a detail page. A chain that cannot be
        // opened is not tested — and exactly this chain hung silently on 2026-09-08 without anyone
        // noticing.
        if let identifier = ProcessInfo.processInfo.environment["CINELOUNGE_VORRAT_LEGEN"] {
            Diagnose.step(
                .network,
                "Downloads: check hook queues \(identifier) — manager "
                    + "\(downloads == nil ? "missing" : "present")")
            downloads?.create(
                DownloadJob(
                    id: .init(identifier), title: identifier, source: .jellyfin, extent: .film,
                    tier: .low),
                resolve: PlaybackJob(identifier: identifier))
        }

        if let identifier = ProcessInfo.processInfo.environment["CINELOUNGE_SPIELER"] {
            let environment = ProcessInfo.processInfo.environment
            let origin = environment["CINELOUNGE_SPIELER_HERKUNFT"]
                .flatMap(Catalog.Origin.init(rawValue:))
            let startAt = environment["CINELOUNGE_SPIELER_AB"].flatMap(TimeInterval.init)
            navigator.show(
                .player,
                job: PlaybackJob(
                    identifier: identifier,
                    origin: origin ?? PlaybackJob.origin(zu: identifier),
                    startAt: startAt))
        }
    }

    /// Which channel list is currently being edited — **the payload of the edit path.**
    ///
    /// **On the model and not on the view.** ``TabPlaceholder`` is created anew at every
    /// step of the overlay; a `@State` there would not survive the push, and the edit view
    /// would get an empty list. The same consideration as with the payload of the tab stack
    /// (``Navigator/job(zu:)``) — only the overlay so far needs exactly one, and a board
    /// for one entry would be effort without return.
    public var toEdit: Playlist?

    /// Whether the downloads lie as a drawer above Home.
    ///
    /// **On the model and not in the view** — for the same reason as ``toEdit``:
    /// ``TabPlaceholder`` is created anew at every step, and a `@State` there would survive
    /// neither a tab switch nor an opened detail page. Anyone who goes from a download into a
    /// detail page and comes back should stand where they were.
    ///
    /// **Only Home has it.** From elsewhere — from a state, for instance — the downloads still
    /// lead via the stack of the tab one is currently in; there they are a destination and not
    /// the neighbor (``TabPlaceholder/downloadsRoute``).
    public var drawer = false

    /// The name in the profile picture.
    ///
    /// **A question mark as long as nobody is signed in** — and not an invented name. Until
    /// 2026-09-06 a hard-coded user name stood here five times: the circle claimed a person the app
    /// did not know at all, and claimed it even when no account was set up at all.
    public var accountName: String {
        accounts.signedInAccount?.name ?? "?"
    }

    // MARK: - Profile pictures (AP49)

    /// Who wears which profile picture — **read from the profile book in the file store.**
    ///
    /// The same store from which ``SetupState`` reads the profiles; there would be no
    /// second one, and a copy here would be the intermediate store that AP41 abolished.
    public let profileImages = ProfilePictureState(
        store: FileStore(), cloud: { ProfileCloud.attached })

    /// The profile behind the profile picture at the top right — **`nil` as long as there is
    /// none.**
    ///
    /// Then the circle stays as it was before AP49: the letter of the account on the muted
    /// surface.
    public var headerProfile: Profile? {
        profileImages.headerProfile(signedIn: accounts.signedIn)
    }

    /// Which choice the image-choice sheet is currently showing.
    ///
    /// **On the model and not in the view** — for the same reason as ``downloadRequest``: the sheet
    /// hangs on the shell, and the press that opens it comes from the person sheet, which closes
    /// in the process.
    public var profileImageChoice: ProfilePictureChoice?

    /// From the person sheet into the image choice — **first close, then open.**
    ///
    /// Two sheets on top of each other cannot be closed, and swapping both in the same pass
    /// once produced an empty screen (``SheetState/close(following:)``).
    public func openProfileImageChoice() {
        guard isManageable else { return }
        profileImages.load()
        guard let profile = headerProfile else { return }
        profileImageChoice = ProfilePictureChoice(profile: profile)
        sheetState.close { [weak self] in self?.sheetState.open(.profileImage) }
    }

    /// Saves the choice into the profile book and closes the sheet.
    public func saveProfileImage(_ choice: ProfilePictureChoice) {
        profileImages.save(choice)
        profileImageChoice = nil
        sheetState.close()
    }

    /// The tabs that this catalog state shows — **offset against the parental controls.**
    ///
    /// In child mode Live and Portals disappear. **Not dimmed but gone:** a dimmed tab says
    /// "there is something here that you are not allowed to", and that is exactly the
    /// information that makes a child start searching.
    public var tabs: [Tab] {
        let rule = parentalControls.rule
        return catalogs.tabs(
            isInChildMode: rule.scope.isInChildMode, deselected: TabSelection.stored(),
            channelApproval: rule.channelApproval)
    }

    /// Sets the paths to a state — **with the whole rule**, including the allow list for
    /// channels (AP52). One place for all triggers, so that none forgets the list.
    private func adjustRoutes(_ state: CatalogState) {
        let rule = parentalControls.rule
        navigator.adapt(
            state, isInChildMode: rule.scope.isInChildMode, deselected: TabSelection.stored(),
            channelApproval: rule.channelApproval)
        navigator.clearBlocked()
    }

    /// The design variant — **the child interface for a child profile** (G3, finding B3), as on
    /// the TV: larger tiles, less text, few entries, "Switch profile".
    ///
    /// **It follows the kind and not the device lock** (``Styling/Surface``): an adult on
    /// a locked device gets the scope, but their usual app. Read from the same rule as
    /// ``isManageable``, so that design variant and management never refer to different people.
    public var surface: Surface {
        Surface.forItem(kind: parentalControls.rule.accountKind == .kind)
    }

    /// Whether the person sheet shows the management — **not for a child profile**, with or
    /// without a device PIN (``KidsTargets``, decision 20): no profile picture, no profile PIN,
    /// no creating, no settings. What remains are the circles in "Who's watching?" as the way
    /// into an adult profile.
    public var isManageable: Bool {
        !parentalControls.rule.scope.withoutManagement
    }

    /// The path **of a specific** tab — as a binding for its `NavigationStack`.
    ///
    /// **One per tab, not a shared one.** A shared one read the stack of the selected tab in the
    /// non-selected tab; see ``Navigator/subscript(_:)``.
    public func path(forItem tab: Tab) -> Binding<[ViewPath]> {
        Binding(
            get: { [navigator] in navigator[tab] },
            set: { [navigator] fresh in navigator[tab] = fresh })
    }

    /// Applies a changed setup.
    ///
    /// **In one round with the change of the tab list.** A selection that points for one frame
    /// at a tab the bar does not have shows not a switch but an empty surface.
    public func adopt(_ incoming: CatalogState) {
        catalogs = incoming
        // **Re-read the accounts too.** What the setup has just stored is in the Keychain and not
        // in this class; without this line the circle keeps showing a question mark after the
        // setup.
        accounts.load()
        parentalControls.accountKind = accounts.signedInAccount?.kind == true ? .kind : .adult
        sheetState.close()
        adjustRoutes(incoming)
    }

    /// Follows a changed setup **during operation** — bar and paths, nothing else.
    ///
    /// **Not ``adopt(_:)``:** that one closes the sheet and re-reads the accounts because it
    /// sits at the end of the setup. Anyone who creates a channel list in Settings is in the
    /// middle of a screen and should stay there — only the bar below gets its tab added.
    public func episode(_ incoming: CatalogState) {
        // **Forget the sources first, then rebuild the tabs.** Even if the state stays the same (a
        // second channel list does not change a tab), the sources behind it are different — that is
        // why the counter always counts up and every tab view is created anew.
        SourceAssembly.forget()
        builtWindow = ChannelListView.window(SourceAssembly.deviceStorage())
        ownState += 1
        // **The management is rebuilt along with the sources.** It holds a player source to resolve
        // addresses; one from the previous setup pointed to a server that no longer exists — and
        // that was noticed only at the next block.
        buildDownloads()
        guard incoming != catalogs else { return }
        catalogs = incoming
        adjustRoutes(incoming)
    }

    /// Builds the download management from the current sources.
    ///
    /// **The running jobs do not survive this, and that is right.** Anyone who changes a login
    /// changes the address under which a block is fetched; continuing a run across that would
    /// mean writing into the same file from a different source. The partial files stay in
    /// place — ``BackgroundSession`` checks at the next start whether it is the same file and
    /// otherwise starts over.
    /// Starts the three watches — **once, and not at every render.**
    ///
    /// **The finding (E64):** all of that stood in the initializer. SwiftUI evaluates the
    /// expression in `State(initialValue: ShellModel(…))` at **every** build of the shell and
    /// keeps the first instance of them; every further one still ran through the initializer and
    /// left behind a second `NWPathMonitor` session that nobody ever stops. The same trap that
    /// the ``DownloadsManager`` once hung on — the whole trail is there.
    ///
    /// **It is called from where a view really appears** (`task`), and that hits only the
    /// instance that SwiftUI kept.
    ///
    /// **Calling it several times is harmless.** ``NetworkWatch/start()`` checks itself whether it
    /// is already running; the two questions below cost one fetch and none, respectively. A
    /// watcher that crashes on the second call would be the worse guarantee.
    public func start() {
        restoreActiveProfile()
        showLaunchCurtain()
        guard ProcessInfo.processInfo.environment["CINELOUNGE_OHNE_NETZ"] != "1" else { return }
        // **Before the watch**, so that even its first report is in the log (finding 11).
        NetworkLog.wireWithDiagnostics()
        networkMonitor.start()
        // **And where we stand** — the same opportunity, a different question. It costs no fetch;
        // the answer is in the interfaces of this device.
        Task { await locationMonitor.verify() }
        Task { await downloads?.backfillSeriesClearances() }
        Task { await registerCLServer() }
    }

    /// The active profile on the CL-Server — **signed in itself with its person token**, as on
    /// the TV (`MainView.loadPortals`), the token then refreshed.
    ///
    /// **The finding (2026-09-28):** since the CL-Server attribute is stored per profile, an
    /// adopted profile on the phone had none, and the portals answered with `401 auth.required`
    /// — the selected Animehub shelves stayed empty. The TV signs in itself with the token from
    /// the cloud; the phone never did. If it succeeds, the sources are rebuilt.
    ///
    /// Called at start, after a profile switch and when something arrives from the cloud — the
    /// token of an adopted profile can arrive after the start.
    func registerCLServer() async {
        guard SourceSwitch.portals else { return }
        if await SelfSignIn.onDevice()?.attempts(.open) == .signedIn {
            Diagnose.step(.login, "CL-Server: profile signed in with its person token")
            episode(catalogs)
        }
        await TokenReconciliation.onDevice()?.reconcile()
    }

    /// "Who's watching?" at start — **the same rule as on the TV** (G3, finding B2;
    /// ``Flows/ProfilePicker/asksNow(_:protectionActive:)``).
    ///
    /// **Once per program run and not per model** (shell check H3, 2026-09-27): choosing a
    /// profile with a different app language rebuilds the shell (`.id(language.identifier)`), and
    /// ``start()`` runs again afterwards — the question came a second time right after the
    /// answer. The marker is ``Core/ProfilePointer/curtainIsDue()``, as on the TV in
    /// `MainView.onStart`.
    ///
    /// **Only after the intro** (H7), as on the TV (AP51): a sheet lies over the whole window
    /// and thus over the clip; the tap to skip would hit the sheet.
    ///
    /// **Not across a test hook** (`CINELOUNGE_BLATT`, `CINELOUNGE_ANSICHT`) and not over an
    /// already open sheet or the latch that ``restoreActiveProfile()`` has just
    /// prepared. Anyone who has chosen "Start automatically as this profile" never sees the
    /// question (``ProfileKit/StartCurtain``).
    ///
    /// **Without an active profile the question always comes** (finding 2026-11-09, the same
    /// rule as on the TV, ``Flows/ProfilePicker/asksWithoutActive(active:profiles:protectionActive:)``):
    /// a rebuilt shell would otherwise stand without a person after the curtain of this run was
    /// used, and the CL-Server key, the join request and the lists all hang on the person.
    func showLaunchCurtain() {
        let environment = ProcessInfo.processInfo.environment
        let protection = parentalControls.rule.applies
        let book = profile.activeAndCount
        let asksByRule = ProfilePicker.asksNow(profile.launchGate, protectionActive: protection)
        let asksForLack = ProfilePicker.asksWithoutActive(
            active: book.active, profiles: book.count, protectionActive: protection)
        Diagnose.step(
            .login,
            "Start: profile \(book.active?.rawValue.prefix(8) ?? "none") of \(book.count), protection \(protection), asks \(asksByRule || asksForLack)"
        )
        guard
            asksByRule || asksForLack,
            environment["CINELOUNGE_BLATT"] == nil, environment["CINELOUNGE_ANSICHT"] == nil
        else { return }
        afterIntro { [weak self] in
            guard let self, !sheetState.isOpen, profilePinState == nil else { return }
            sheetState.open(.accountSwitch)
        }
    }

    /// When a sheet may open at start — **only once the cover of the intro is open** (shell
    /// check H7). Without an intro, immediately.
    ///
    /// Injectable from outside so that the test holds its own ``Core/IntroCover``.
    var afterIntro: @MainActor (@escaping @MainActor () -> Void) -> Void = { action in
        PhoneIntro.afterIntro(action)
    }

    public func buildDownloads() {
        let width = ImageSizes.pixels(
            forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference)
        // **Via the holder and not with `DownloadsManager(…)`** (2026-09-09). This line stood here
        // as a rebuild, and it runs more often than it looks: SwiftUI evaluates the expression in
        // `State(initialValue: ShellModel(…))` at every build of the shell and keeps the first
        // instance of them. Every further one built a second manager here that nobody sees and that
        // still writes into the same book. The whole trail is at ``DownloadsManager/source``.
        downloads = SourceAssembly.playerSource(width: width).map {
            DownloadsHolder.ready(
                source: $0,
                // **Home supplies the travel suggestions.** It fetches Continue Watching, favorites and
                // recently added anyway; a separate query next to it would be the same question to the same
                // server, just without the cache.
                start: SourceAssembly.startSource(
                    width: width, headerWidth: width, logoWidth: width),
                // **The episode list of a series — for the standing orders.** The same detail source as
                // behind the detail page; a second one next to it would be the place where both say
                // different things about the same series. **Open and explicit:** the standing orders belong
                // to the device, not to a profile; filtering happens when showing and playing (check
                // 2026-09-27, D1).
                detail: SourceAssembly.detailContentSource(
                    width: width, headerWidth: width, logoWidth: width, rule: .pending),
                // **The ratings belong to the download** (2026-09-09), namely the same ones that were on the
                // page from which it was queued. Without this line the downloads store only the number from
                // the media server — IMDb and Metacritic would then be missing exactly where they cannot be
                // fetched afterwards. Requirement of 2026-09-09: downloads are stored with OMDb, TMDb etc.
                // ratings.
                external: SourceAssembly.ratingsSource(),
                networkMonitor: networkMonitor)
        }
    }

    /// Whether the tab bar stands or the downloads remain alone.
    ///
    /// **Read and not remembered.** A stored value would be wrong after the first network
    /// change, and nobody would notice: the screen would look as before. The decision itself is
    /// in ``BarState`` — there it can be tested without a simulator, here it could be only
    /// with the radio switched off.
    public var barState: BarState {
        BarState.forItem(
            route: networkMonitor.route, measured: networkMonitor.reported,
            playerRunning: navigator.current == .player)
    }

    /// The path to the favorites — **`nil` as long as they have their own tab.**
    ///
    /// **They move, and that is why there are two paths.** If a slot in the bar remains free
    /// after the services, they sit at the bottom; otherwise as a heart in the header — that is
    /// how `CatalogState.tabs` decides. **Until 2026-09-06 only one half existed:** the tab was a
    /// placeholder, and the heart was built in ``HeaderRow`` but operated by nobody. With a full
    /// setup — and a full setup is the common case — the favorites were thus reachable from
    /// **nowhere**.
    ///
    /// **Both buttons at once would be one too many.** Anyone who has the tab does not need the
    /// heart; a heart above a tab that does the same is a second path to the same place on the
    /// same screen.
    /// Which tab lights up — **clamped to the tabs that exist.**
    ///
    /// **Since the favorites are a screen, the signpost can point to a tab that the bar does not
    /// carry:** anyone who opens them via the heart stands in a view whose tab does not exist in
    /// a full setup. Unclamped, **none** would light up — and a viewer who is nowhere does not
    /// know how to get back.
    public var highlightedTab: Tab? {
        guard let intended = navigator.highlightedTab else { return nil }
        return tabs.contains(intended) ? intended : navigator.tabs
    }

    public var toFavorites: (() -> Void)? {
        guard !catalogs.favoritesAtBottom,
            parentalControls.rule.scope.remains(Tab.favorites.rawValue)
        else { return nil }
        return { [weak self] in self?.navigator.show(.favorites) }
    }

    // MARK: - Routes that lead through parental controls

    /// Choose another account — **the door through which all others would be reachable.**
    ///
    /// **It is not a view and still needs the PIN.** An account switch leads nowhere and removes
    /// every boundary; without it the whole lock would be one tap away. The sheet closes in the
    /// process, because two sheets on top of each other can no longer be closed at 393 points.
    public func switchAccount(_ account: Account) {
        sheetState.close()
        guard let job = parentalControls.job(forItem: "kontowechsel") else {
            lock(account)
            return
        }
        navigator.query(job) { [weak self] in
            self?.parentalControls.consume()
            self?.lock(account)
        }
    }

    /// "Who's watching?" — **choose a profile, through the same door as an account switch** (G3,
    /// finding B2).
    ///
    /// **The door `accountSwitch` first, then the latch of the profile PIN** — the same sequence
    /// as on the TV (``ParentalControls/LockedDoors``, ``ProfileKit/ProfileSwitch``). A profile
    /// without a media server login is selectable; the shared switch then empties the session,
    /// and the shell shows "no media server" instead of the previous person's library.
    /// **A press on one's own profile does nothing**
    /// (``Flows/ProfilePicker/triggers(_:active:)``).
    public func switchProfile(_ profile: Profile) {
        sheetState.close()
        guard ProfilePicker.triggers(profile.identifier, active: self.profile.active) else { return }
        guard let job = parentalControls.job(forItem: "kontowechsel") else {
            chooseProfile(profile)
            return
        }
        navigator.query(job) { [weak self] in
            self?.parentalControls.consume()
            self?.chooseProfile(profile)
        }
    }

    /// The switch without PIN — **if the target requires one, the latch opens and nothing
    /// else.** ``ProfileKit/ProfileSwitch`` touches neither book nor session on `.pinRequired`.
    ///
    /// **First close, then open:** the person sheet and, where applicable, the PIN sheet of the
    /// parental controls are just closing (``SheetState/close(following:)``).
    private func chooseProfile(_ profile: Profile) {
        let outcome = self.profile.switchTo(zu: profile.identifier)
        switch ProfilePicker.reply(to: outcome) {
        case .pin:
            profilePinState = .lock(account: nil, profile: profile)
            sheetState.close { [weak self] in self?.sheetState.open(.profilePin) }
        case .switched:
            followProfileChoice()
        case .nothing:
            break
        }
    }

    /// What follows after a profile choice — **accounts, account kind, rule and paths.**
    ///
    /// When the ``Core/ProfilePointer`` reports the switch, ``profileSwitched()`` recomputes the
    /// sources; here is only what must be right immediately, so that the first render does not
    /// draw with the predecessor's rule.
    func followProfileChoice() {
        Diagnose.step(.login, "Profile chosen")
        Task { await registerCLServer() }
        accounts.load()
        parentalControls.accountKind = accounts.signedInAccount?.kind == true ? .kind : .adult
        parentalControls.rereadProfile()
        profileImages.load()
        adjustRoutes(catalogs)
        followRulesState()
    }

    /// "Create profile" from "Who's watching?" — **always there, for adults** (decision 3).
    ///
    /// **Through the door `profileChanged`**, like `newAccount` on the TV: a new profile is one without
    /// a boundary. A child profile does not see the card at all (decision 20).
    public func createProfile() {
        guard isManageable else { return }
        sheetState.close { [weak self] in self?.navigator.show(.profileChanged) }
    }

    /// "Manage profiles" — change, remove, merge, start choice.
    public func manageProfiles() {
        guard isManageable else { return }
        sheetState.close { [weak self] in self?.navigator.show(.profile) }
    }

    /// "Add login" — **the same path as in `Settings → Media server`**; the login ends up with
    /// the active profile.
    public func addCredentials() {
        guard isManageable else { return }
        sheetState.close { [weak self] in self?.navigator.show(.newAccount) }
    }

    /// Take in a freshly signed-in account and **switch to it through the same door.**
    ///
    /// ``AccountsModel/accept(_:asChild:)`` only puts it into the list; the switch goes via
    /// ``switchAccount(_:)`` — parental controls door, profile PIN latch, profile switch. That
    /// way "Add account" also updates the account kind, which until then stayed with the
    /// previous account.
    public func addAccount(_ credential: ServerCredentials, asChild kind: Bool) {
        accounts.accept(credential, asChild: kind)
        guard let account = accounts.accounts.first(where: { $0.id == Account.Identifier(credential) }) else {
            return
        }
        switchAccount(account)
    }

    // MARK: - The profile PIN (AP52)

    /// What the profile PIN is called with — **injectable from outside for the tests**, in the
    /// program the connected cloud and its migration bundle.
    var profilePins: @MainActor () -> ProfilePinManagement = { .live() }

    /// What the sheet ``SheetID/profilePin`` is currently showing — `nil` if nothing.
    public private(set) var profilePinState: ProfilePinState?

    /// **The latch of the profile PIN** — after the door of the parental controls and **before**
    /// the session is switched (``ProfileKit/ProfileSwitch/lock(account:ledgerStore:pinStore:)``).
    ///
    /// **First close, then open:** the person sheet and, where applicable, the PIN sheet of the
    /// parental controls are just closing; a second sheet in the same pass would not get out
    /// (``SheetState/close(following:)``).
    private func lock(_ account: Account) {
        guard
            let shielded = ProfileSwitch.lock(
                account: account.id.stored, ledgerStore: ledgerStore,
                pinStore: profilePins().keychain)
        else {
            adoptAccount(account, pin: nil)
            return
        }
        profilePinState = .lock(account: account, profile: shielded)
        sheetState.close { [weak self] in
            self?.afterIntro { [weak self] in self?.sheetState.open(.profilePin) }
        }
    }

    /// The PIN typed at the latch — **if it is right, the switch happens; otherwise everything
    /// stays.**
    ///
    /// - Returns: whether it was right. On `false` the sheet stays up and reports it.
    public func openLatch(_ digits: String) -> Bool {
        guard case .lock(let account, let profile) = profilePinState else { return false }
        guard let account else {
            // **The latch in front of a profile from "Who's watching?"** (G3): the shared switch checks
            // the PIN itself — a wrong one switches nothing, not even the session.
            guard self.profile.switchTo(zu: profile.identifier, pin: digits).result != nil else {
                return false
            }
            profilePinState = nil
            sheetState.close()
            followProfileChoice()
            return true
        }
        guard profilePins().matches(digits, forItem: profile.identifier) else { return false }
        profilePinState = nil
        sheetState.close()
        adoptAccount(account, pin: digits)
        return true
    }

    /// "Forgot PIN" has been resolved at the latch — **the PIN has dropped household-wide**, and
    /// the switch continues without it.
    public func latchReleased() {
        guard case .lock(let account, let profile) = profilePinState else { return }
        profilePinState = nil
        sheetState.close()
        if let account {
            adoptAccount(account, pin: nil)
        } else {
            chooseProfile(profile)
        }
    }

    /// Set, change or remove the profile PIN — **with the door of the parental controls in
    /// front**, as on the TV (``ProfilePinManagement/door``).
    ///
    /// **The door asks only when the parental controls apply.** An adult on an open phone gets
    /// through without the device PIN; for a child with a lock the button demands it.
    public func maintainProfilePin(forItem profile: Profile) {
        guard isManageable else { return }
        sheetState.close()
        let open: @MainActor () -> Void = { [weak self] in
            self?.profilePinState = .maintain(profile)
            self?.sheetState.close { [weak self] in self?.sheetState.open(.profilePin) }
        }
        guard let job = parentalControls.job(forItem: ProfilePinManagement.door) else {
            open()
            return
        }
        navigator.query(job) { [weak self] in
            self?.parentalControls.consume()
            open()
        }
    }

    /// The sheet is done or was swiped away.
    public func closeProfilePin() {
        profilePinState = nil
        sheetState.close()
    }

    /// Whether the displayed profile carries a PIN — for the row in the person sheet.
    public func isProfilePinSet(_ profile: Profile) -> Bool {
        profilePins().isSet(profile.identifier)
    }

    /// Sets session, account kind and profile to this account — **through the same switch as on
    /// the TV**
    /// (``ProfileKit/ProfileSwitch/episode(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``).
    ///
    /// **The latch is there and only there** (AP58 R2): until then this place checked the PIN a
    /// second time itself, and a separate rebuild switched book and pointer — without the portal
    /// header and without the emptied session. Anyone who comes here without the matching PIN
    /// switches nothing at all, not even the media server session.
    ///
    /// **Only without a profile for this account** (or if it is already in front of it) does
    /// ``AccountsModel/switchTo(zu:)`` switch the session alone.
    private func adoptAccount(_ account: Account, pin: String?) {
        let keychain = accounts.keychain
        switch ProfileSwitch.episode(
            account: account.id.stored, ledgerStore: ledgerStore, keychain: keychain,
            pinStore: profilePins().keychain, deviceStore: keychain, pin: pin)
        {
        case .pinRequired, .wrongPin:
            return
        case .switched:
            Diagnose.step(.login, "Profile follows the account")
            accounts.load()
        case .unknown, .unchanged:
            let previous = accounts.signedIn
            accounts.switchTo(zu: account)
            if accounts.signedIn != previous { episode(SourceAssembly.state()) }
        }
        parentalControls.accountKind = account.kind ? .kind : .adult
        // If the pointer reports a switch, ``profileSwitched()`` recomputes the rest.
        parentalControls.rereadProfile()
        adjustRoutes(catalogs)
        followRulesState()
    }

    /// If **nobody is active**, the profile of the signed-in account applies again — via
    /// ``lock(_:)``, that is, with the profile PIN in front
    /// (``ProfileKit/ProfileSwitch/restorable(account:ledgerStore:)``).
    ///
    /// **Without the door of the parental controls**, because it is not a switch to another
    /// account: session and account stay, only the book finds its person again. If the latch is
    /// already open, it is not opened a second time.
    private func restoreActiveProfile() {
        guard profilePinState == nil, let account = accounts.signedInAccount,
            ProfileSwitch.restorable(account: account.id.stored, ledgerStore: ledgerStore)
                != nil
        else { return }
        lock(account)
    }

    /// Where the ``ProfileKit/ProfileBook`` lives — the same file store as everywhere; **injectable
    /// from outside**, so that an account switch without a profile can be tested without the
    /// real store.
    private let ledgerStore: any KeyValueStore

    /// Another profile is active — **recompute everything that hangs on it.**
    ///
    /// **Called from the shell as soon as ``Core/ProfilePointer`` reports a real switch**
    /// (``Core/ProfilePointer/switched``): after an account switch, after a migration of the
    /// identifier from the cloud. Parental controls (boundary, lock, assignments, kind), profile
    /// picture and the sources behind it (channel lists and portals belong to the profile since
    /// AP41) — without this step the app would draw with the rule of the previous person.
    /// Something arrived in the books from remote — **parental controls and header picture
    /// re-read**, without rebuilding the sources (for that there is ``profileSwitched()`` and
    /// the setup).
    public func cloudArrived() {
        restoreActiveProfile()
        parentalControls.rereadProfile()
        profileImages.load()
        adjustRoutes(catalogs)
        followRulesState()
        assignLists()
        Task { await registerCLServer() }
    }

    /// Give IPTV lists without a profile to the active one
    /// (``Flows/ChannelListView/assignOrphans(_:ledgerStore:keychain:)``) — after
    /// an arrival from the cloud or a profile switch.
    ///
    /// **On the device catalog, not on the list store** (on-device test 2026-09-28): if the
    /// active profile saw no list, there was no store at all, and the assignment never ran —
    /// exactly in the case it exists for. **And it is rebuilt as soon as the window has
    /// changed**, not only when something was assigned here: if the list arrives with a profile
    /// from the cloud, the book changes elsewhere.
    func assignLists() {
        let storage = SourceAssembly.deviceStorage()
        ChannelListView.assignOrphans(storage)
        let window = ChannelListView.window(storage)
        // Without a remembered window there is nothing to compare — then the current one counts as
        // built. A rebuild discards the signpost (shell check H4).
        guard let built = builtWindow else {
            builtWindow = window
            return
        }
        guard window != built else { return }
        episode(SourceAssembly.state())
    }

    /// The lists with which the sources were last built — ``assignLists()``.
    @ObservationIgnored private var builtWindow: Set<String>?

    /// Another profile — **the sources, the rule and the paths follow it**, and the location is
    /// determined anew too: the profile can have a different media server (shell check H11).
    public func profileSwitched() {
        restoreActiveProfile()
        parentalControls.rereadProfile()
        profileImages.load()
        episode(SourceAssembly.state())
        adjustRoutes(catalogs)
        followRulesState()
        Task { await locationMonitor.verify() }
        assignLists()
        Task { await registerCLServer() }
    }

    // MARK: - The rule state (check wrapper H4/H8, start F5)

    /// Who is watching, in which design variant, under which rule — **the same measure as
    /// `ChildGuard.RuleState` on the TV.**
    public struct RuleState: Hashable {
        public let active: String?
        public let surface: Surface
        public let rule: ProtectionRule
    }

    /// The state under which drawing currently takes place. The profile part comes from the
    /// ``Core/ProfilePointer``, which every switch sets — including one from the cloud.
    public var ruleState: RuleState {
        RuleState(
            active: ProfilePointer.active, surface: surface, rule: parentalControls.rule)
    }

    /// What every filtered root view hangs on — **setup and rule together.**
    ///
    /// **Finding F5 of the start check (2026-09-27):** search, favorites and library build their
    /// sources once, filtered with the rule of the first build, and keep them in `@State`. They
    /// were rebuilt only via ``setupState`` — an age limit set on the device, a device
    /// lock or a profile that the cloud turns into a child left the search open. On the TV
    /// `.id(ruleState)` solves that; here the same answer.
    public var rootState: RootState {
        RootState(setup: setupState, rule: ruleState)
    }

    /// Siehe ``rootState``.
    public struct RootState: Hashable {
        public let setup: Int
        public let rule: RuleState
    }

    /// The state the shell last saw — **for the comparison in ``followRulesState()``.**
    @ObservationIgnored private var seenRulesState: RuleState?

    /// Discards the paths **as soon as profile, design variant or rule change** — like
    /// `ChildGuard.discard` on the TV (shell check H4, decision 25/27).
    ///
    /// **The finding:** when switching to the child, the adult's detail page stayed in the
    /// stack, as did a pushed downloads view with the adult's rule — and a running player when
    /// the cloud made the active profile a child.
    /// ``Navigator/adapt(_:isInChildMode:deselected:channelApproval:)`` kept every prefix that
    /// the state reaches.
    ///
    /// **Another person or another design variant discards everything**, including the overlays
    /// and thus the player. **Another rule alone** — an age limit set in Settings — discards the
    /// stacks of the tabs but leaves the overlay in which it was set; on the TV the target
    /// likewise stays in that case.
    ///
    /// Called from every switch path of this model and from the shell at every change of the
    /// state; a second call for the same state does nothing.
    public func followRulesState() {
        let fresh = ruleState
        guard let old = seenRulesState, old != fresh else {
            seenRulesState = fresh
            return
        }
        seenRulesState = fresh
        Diagnose.step(.surface, "Rule state changed — routes discarded")
        drawer = false
        if old.active != fresh.active || old.surface != fresh.surface {
            navigator.discardAll()
        } else {
            navigator.discardStack()
        }
    }

    /// The server has confirmed the password — **the PIN drops, and the lock with it.**
    ///
    /// **It is deleted and not displayed.** A PIN that can be read out is none; anyone who knows
    /// the password of an account without a boundary may **assign a new one** and not learn the
    /// old one.
    ///
    /// **And the waiting job drops with it.** Without a PIN nothing applies
    /// (``ProtectionRule/applies``); a sheet that afterwards kept demanding four digits would
    /// demand them against nothing. The path leads instead to where a new one is assigned.
    public func unlocked() {
        parentalControls.clearPin()
        navigator.back()
        navigator.giveUp()
        if navigator.overlay.last != .parentalControls {
            navigator.show(.parentalControls)
        }
        adjustRoutes(catalogs)
    }

    /// Sets the signpost to the one stack that exists without the bar.
    ///
    /// **The finding of 2026-09-13, on the device:** "I cannot select and play downloaded content."
    /// The tap on a poster did what it should — ``Navigator/show(_:title:)`` put the detail
    /// page on the stack. Just on which one: ``Navigator/create`` writes into the stack of the
    /// **current** tab, and that stood at `.start` after start (or at whatever was open last
    /// time). The view without a bar shows only the stack of the library, however —
    /// `ShellView.offline` binds `path(forItem: .library)`. The press landed in a stack that
    /// nobody displays, and nothing happened on the screen.
    ///
    /// **Here and not in the view**, because it is a rule about the signpost and not about
    /// presentation: without a bar there is exactly one tab, and it is called Library — the
    /// downloads lie in its stack (``ViewID/tabs``).
    ///
    /// **The stack stays.** Anyone who went from the library into a detail page and then lost
    /// the network keeps seeing it; anyone who closes it stands in the downloads. Clearing it
    /// would be a screen change that nobody triggered.
    public func enterDownloadsAlone() {
        navigator.tabs = .library
    }

    /// Switches the tab and closes an open sheet in the process.
    ///
    /// A sheet that survives a tab switch belongs to a screen that is no longer visible.
    public func select(_ new: Tab) {
        guard tabs.contains(new) else { return }
        // **A second press on one's own tab tidies up** — the system convention, and here at the
        // same time the emergency brake: anyone who has the downloads drawer open and cannot find
        // the way back presses "Home" and stands on Home. A screen from which only one gesture
        // leads out would be the trap that this project has already cleaned up twice.
        if new == navigator.tabs, new == .start, drawer {
            drawer = false
        }
        // **And it does what every iOS app does at this point** (AP7, 2026-09-10): if a stack stands,
        // it leads to the root; if the root already stands, it scrolls to the top.
        //
        // **In this order and not both at once.** Anyone who comes three levels deep from a detail
        // page wants out first — scrolling to the top while still inside would answer a question
        // nobody asked. Only the second press scrolls.
        //
        // **The drawer counts as a stack here.** It lies above Home and is the place from which the
        // way back is hardest to find — that is why it stands one line higher and not here.
        if new == navigator.tabs, !drawer {
            if navigator[new].isEmpty {
                scrollToTopRequest &+= 1
            } else {
                navigator[new] = []
            }
        }
        sheetState.close()
        navigator.tabs = new
    }
}

/// The running sync — **one place above the whole shell.**
///
/// **It cannot live in the Home model, although the button sits there.** Sync clears the
/// remembered sources, and afterwards every tab must be created anew with fresh ones — via
/// ``ShellModel/setupState``, the path that already exists for this. In the process
/// Home dies along with its ``StartModel``, and with it would die the attribute that the
/// icon's rotation hangs on: the button would stop rotating in the middle of the operation,
/// and the rebuilt Home would know nothing about the running sync. Here both survive the
/// rebuild that it triggers itself.
///
/// **It is done when both halves are back** — the forced channel fetch and the rebuilt Home.
/// Only waiting until it is cleared would be over in a tenth of a second and would tell the
/// viewer nothing about the fetch they are waiting for.
@MainActor
@Observable
public final class Synchronization {

    /// **One for the app.** Two would know nothing about each other, and then the button of one
    /// would rotate while the other rebuilds the tabs.
    public static let shared = Synchronization()

    /// Whether fetching is currently going on. Controls the rotation of the icon in
    /// ``HeaderRow``.
    public private(set) var isRunning = false

    /// How often it has been cleared — the second half of ``ShellModel/setupState``.
    public private(set) var state = 0

    /// How long to wait for Home's acknowledgment before the button calms down on its own.
    ///
    /// **There is a path on which it never comes:** anyone who presses the button and
    /// immediately switches tab leaves behind a Home that is no longer loaded at all. An icon
    /// that then rotates for the rest of the session claims an operation that does not exist —
    /// and the button would stay locked meanwhile.
    ///
    /// Ninety seconds, because loading itself may take long: through the measured tunnel at
    /// 0,31 Mbit/s a Home with four shelves is not an operation of seconds.
    public static let patience: Duration = .seconds(90)

    private let clear: @MainActor () async -> Void
    private let channels: @MainActor () async -> Void
    private let patience: Duration

    private var pageIsReady = false
    private var channelsAreReady = false

    /// When the button was pressed — **for the duration in the log.**
    ///
    /// **The finding of 2026-09-07:** "Why does the sync take so long?" could be answered from the
    /// log only by subtracting two timestamps from each other — and the two halves were not
    /// reported individually at all. In the simulator it was then **two seconds**; what feels
    /// long is what reloads **afterwards**, because the sync rebuilds every tab. The line now
    /// makes exactly this difference visible: it names the duration and which half it cost.
    private var started: ContinuousClock.Instant?
    private var channelsReadyAfter: Duration?
    private var pageReadyAfter: Duration?
    private var expectedState = 0
    /// The watchdog of the running sync — **open so that the test can wait for it** instead of
    /// running a clock against its patience.
    private(set) var watchdog: Task<Void, Never>?

    /// The run that ``start()`` kicks off — **so that the test can wait for it.**
    ///
    /// Without it the test would have to guess how many rounds the scheduler needs until it is
    /// cleared; such tests are not wrong, but worse: they are sometimes green.
    private(set) var run: Task<Void, Never>?

    /// - Parameters:
    ///   - raeumen: What is thrown away. **Injectable so that the test manages without Keychain
    ///     and without network** — ``SourceAssembly`` reads the setup when building its sources.
    ///   - sender: The forced channel fetch. Kept separate from clearing because the tabs
    ///     should already be created anew while it is still running: it is the longer of the
    ///     two.
    public init(
        clear: @escaping @MainActor () async -> Void = {
            await SourceAssembly.clearCache()
        },
        channels: @escaping @MainActor () async -> Void = { await SourceAssembly.reloadChannels() },
        patience: Duration = Synchronization.patience
    ) {
        self.clear = clear
        self.channels = channels
        self.patience = patience
    }

    /// The press on the button.
    ///
    /// **Does not run twice.** A second attempt would not be faster but the reason for the next
    /// "busy" — see ``SourceAssembly/reloadChannels()``.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        pageIsReady = false
        channelsAreReady = false
        started = ContinuousClock.now
        channelsReadyAfter = nil
        pageReadyAfter = nil
        Diagnose.step(.network, "Sync: triggered")
        run = Task { @MainActor [self] in
            await clear()
            // **Clear first, then rebuild.** The other way round, the tabs would get the same sources
            // once more, and the sync would become a refresh — exactly what the button did before.
            state += 1
            expectedState = state
            startWatchdog()
            await channels()
            channelsAreReady = true
            channelsReadyAfter = elapsedSince
            checkReady()
        }
    }

    /// Wait until the clearing and the channel fetch are through.
    ///
    /// **Needed since the pull gesture triggers the sync** (2026-09-08). `refreshable` holds its
    /// spinner exactly as long as its body runs — without this waiting it would vanish at once
    /// while the tabs are still being created anew. That would be the worst of the three
    /// options: the viewer would see "done" and then a list that changes once more.
    ///
    /// No state of its own — it waits for ``run``, which ``start()`` holds anyway. If nothing is
    /// running, it returns immediately.
    public func wait() async {
        await run?.value
    }

    /// The rebuilt Home reports that it is up.
    ///
    /// - Parameter stand: The state it found when it began loading. **Without it the wrong
    ///   report would end the operation:** between the press and the counting up lies the
    ///   clearing, and a Home that finishes its old loading in that time would report itself
    ///   for a sync it knows nothing about.
    public func homeIsReady(after state: Int) {
        if pressesItself, !alreadyPressed, self.state == 0 {
            alreadyPressed = true
            start()
            return
        }
        guard isRunning, state == expectedState else { return }
        pageIsReady = true
        pageReadyAfter = elapsedSince
        checkReady()
    }

    /// **`CINELOUNGE_SYNCHRO=1` presses the button by itself.**
    ///
    /// `simctl` cannot send a touch, and the button sits in the header — without this hook the
    /// sync cannot be viewed at all in the simulator, and a path that cannot be opened is not
    /// tested. The same rationale as for `CINELOUNGE_REITER` and `CINELOUNGE_SPIELER` in
    /// ``ShellModel``.
    ///
    /// **At the first standing of Home and not at program start.** Before that nobody has built
    /// a source yet; a sync at that moment would clear an empty store and prove nothing — least
    /// of all that the media server's snapshots really drop.
    private let pressesItself =
        ProcessInfo.processInfo.environment["CINELOUNGE_SYNCHRO"] != nil
    private var alreadyPressed = false

    private func checkReady() {
        guard isRunning, pageIsReady, channelsAreReady else { return }
        finish("done")
    }

    /// Ends a run that has not reported back after ``patience``.
    ///
    /// **A recalled watchdog no longer barks** (2026-09-26). `Task.sleep` returns immediately on
    /// cancellation; without the cancellation check the watchdog of a finished run would end the
    /// **next** one as soon as the button was pressed again right away — because then `isRunning`
    /// is already true again.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self, patience] in
            try? await Task.sleep(for: patience)
            guard !Task.isCancelled, let self, isRunning else { return }
            finish("gave up — the Home screen did not report back")
        }
    }

    /// How long the run has been going — `nil` if none is running.
    private var elapsedSince: Duration? {
        started.map { ContinuousClock.now - $0 }
    }

    /// A duration in seconds with one decimal place.
    ///
    /// **Seconds and not milliseconds.** The question is "does it take long?", and nobody
    /// answers that in thousandths; `Duration` itself otherwise writes itself into the book as
    /// `2.041666666 seconds`.
    static func readable(_ duration: Duration) -> String {
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", seconds)
    }

    private func finish(_ reason: String) {
        watchdog?.cancel()
        watchdog = nil
        isRunning = false
        // **The duration and both halves individually.** Which of the two cost the time is the
        // actual information: the channel fetch is a single full pull over the line, Home is four
        // shelves from four services. Anyone who knows only the sum does not know where to start.
        let split = [
            elapsedSince.map { "in " + Self.readable($0) },
            channelsReadyAfter.map { "Channels after " + Self.readable($0) },
            pageReadyAfter.map { "Home after " + Self.readable($0) },
        ].compactMap { $0 }
        started = nil
        Diagnose.step(
            .network,
            "Sync: \(reason)"
                + (split.isEmpty ? "" : " — " + split.joined(separator: ", ")))
    }
}

/// What the profile PIN sheet shows (AP52).
public enum ProfilePinState: Equatable {
    /// Set, change or remove — from the person sheet.
    case maintain(Profile)
    /// The latch in front of the switch to this profile — **with an account from `Settings →
    /// Media server`, without an account from "Who's watching?"** (G3).
    case lock(account: Account?, profile: Profile)

    /// Wessen PIN.
    public var profile: Profile {
        switch self {
        case .maintain(let profile), .lock(_, let profile): profile
        }
    }
}
