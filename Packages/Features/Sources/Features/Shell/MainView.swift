import Combine
import Core
import DesignSystem
import Flows
import Household
import JellyfinKit
import ParentalControls
import Playback
import PlaylistKit
import PortalKit
import ProfileKit
import RatingsKit
import SwiftUI

/// The app's frame: a bar along the top edge, with the current area below it.
///
/// Deliberately the system bar and not a hand-built one: it hides when scrolling,
/// behaves like in every other Apple TV app, and can be operated predictably with the
/// remote.
public struct MainView: View {

    /// Only for the focus anchors of the frame's intermediate states — see ``FocusAnchor``.
    /// The views inside manage their own focus.
    @FocusState private var shellFocus: String?

    /// Set after returning from Search, while the focus handoff is running.
    ///
    /// **This is the answer to "after going back, Search suddenly opens again".** When
    /// switching from Search to the library, the hierarchy rebuilds — Search disappears,
    /// the sidebar comes back — and tvOS has to reassign focus. It landed on an icon of
    /// the collapsed bar: the highlight there is barely recognisable as focus from three
    /// metres away, and the next press operated an invisible target — in testing this
    /// accidentally opened Search again.
    ///
    /// While this value is set, a ``FocusAnchor`` lies over the content. Focus is set on
    /// it and is thereby in the content area; when the value drops, the anchor
    /// disappears, and tvOS passes focus on to the next visible target in the content —
    /// the same transition the loading states rely on.
    @State private var returningFromSearch = false

    /// The identifier of the focus anchor for the return from Search.
    static let searchReturnAnchorID = "search-return"

    /// The models of the areas, across the pill switch.
    ///
    /// **This is the answer to "when I go back and forth, the content always reloads".**
    /// A pill switch tears down one branch and builds the other; until now that created
    /// a fresh model every time, whose `task` immediately began with `state = .loading`.
    /// The source's cache did not help here — it saved the transfer, not the empty
    /// screen.
    ///
    /// Here the models survive the switch together with their loaded content. Coming back
    /// then shows what was already there, without a single fetch.
    @StateObject private var models = ShellModels()
    /// Keeps the schedule across area switches — rationale at ``SportKeeper``.
    @StateObject private var sportKeeper = SportKeeper()

    /// The media server — **optional since AP29 (2026-09-11).**
    ///
    /// **This used to be a `let` without a question mark, and two whole screens hung on
    /// it.** ``RootView`` kept its own signpost for "channel list only" and "portals only"
    /// — two dead ends with an "Add server" button, because this view could not handle the
    /// case. As a result these viewers had **no way to Settings**, because Settings hangs
    /// on the sidebar, and the sidebar hung on the media server.
    ///
    /// What really needs it now asks beforehand: the library, the filmography, the
    /// connection measurement, the image store. Everything else goes through
    /// ``AggregateSource``, which works without it.
    private let source: JellyfinSource?
    private let credentials: ServerCredentials?
    private let onSignOut: () -> Void
    /// After an account switch — passes the new credentials through to the session.
    private let onAccountSwitched: (ServerCredentials?) -> Void
    /// Leads into setup to add another account.
    private let onAddAccount: () -> Void

    /// Where the sidebar points.
    /// Where the shell opens.
    ///
    /// **`.media` only if there is a library** (AP29, 2026-09-11). Without a media server
    /// this starting point showed a Home screen that does not exist for this viewer — and
    /// the row for it has not been in the bar since. The starting point therefore follows
    /// ``Core/AccountState/landing``: Live, otherwise portals.
    @State private var destination: AppSidebar.Destination

    /// The starting point of an area — **and the order is not defined here.**
    ///
    /// ``Core/AccountState/landing`` decides **which** area it is; this calculation only
    /// translates it into a row of the sidebar. Two places for the same order drifted
    /// apart with the first new path.
    ///
    /// ``Core/AccountState/Area/setup`` does not arrive here: whoever is there sees the
    /// setup and not the shell.
    static func start(forItem area: AccountState.Area) -> AppSidebar.Destination {
        switch area {
        case .media, .setup: .media
        case .live: .live
        case .portals: .portals
        }
    }

    /// The applicable parental controls — **one per program run, not one per view.**
    ///
    /// They decide what the models filter and which areas the bar shows. An account
    /// switch rewrites the session; ``RootView`` then rebuilds the source.
    ///
    /// **This view is not rebuilt in the process** (finding AP45, 2026-09-25) — a
    /// `@StateObject` survives every new parameter list. The rule is therefore re-read by
    /// ``ChildGuard`` as soon as the active profile changes.
    @StateObject private var lock = ParentalControlsState()

    /// A locked title that was opened directly. `nil` means: none.
    @State private var lockedTitle: MediaItem?
    /// Whether the "Who's watching?" sheet is open — see ``AccountSwitcher``.
    @State private var showsAccountSwitcher = false
    /// The accounts for the sheet. **Read only on press** (``AccountsModel/load()``), not
    /// when the wrapper is built: the list changes in Settings, and the wrapper does not
    /// notice.
    @StateObject private var profile = ProfileModel(deviceLists: { .onDevice() })

    /// The applicable rule, **with an explicit type.**
    ///
    /// Not `lock.rule` at the call site: the body of this view sits at the compiler's
    /// computation budget, and a chain of two dot accesses in a large expression was
    /// enough to make it give up — with an error message that points to an unrelated
    /// line four hundred lines further down.
    private var rule: ProtectionRule { lock.rule }

    /// The build form for the active profile (AP45). An own type at the call site for the
    /// same reason as ``rule``.
    private var surface: Surface { lock.surface }

    /// The scope of the applicable rule (``ParentalControls/ChildScope``). An own type
    /// at the call site for the same reason as ``rule``.
    private var scope: ChildScope { lock.rule.scope }

    /// Whether the areas without approvals drop out — **always for a child, otherwise only
    /// when the lock takes effect** (``ParentalControls/ChildScope/isInChildMode``).
    /// An own `Bool` for the same reason.
    private var isInChildMode: Bool { scope.isInChildMode }

    /// The groups under "Live" in the bar — **none in child mode** (AP52).
    ///
    /// The bar receives the group names of all lists (``loadLiveGroups()``); a child would
    /// see there the names of the groups it may not watch — as an invitation, see
    /// ``ParentalControls/TabScope``. "Live" remains a single entry there, and the
    /// allowed groups are in the Live area itself, filtered.
    private var sidebarGroups: [String] { isInChildMode ? [] : liveGroups }

    /// The same for the provider level.
    private var sidebarProviders: [AppSidebar.LiveProvider] { isInChildMode ? [] : liveProviders }

    /// What open paths and built views hang on — see ``ChildGuard/RuleState``.
    private var ruleState: ChildGuard.RuleState {
        ChildGuard.RuleState(active: profile.active, surface: surface, rule: rule)
    }

    /// Whether "Who's watching?" stands behind the door `accountSwitch` — see
    /// ``AccountSwitcher/Route/sheetBehindDoor``.
    @State private var isSwitcherBehindDoor = false

    /// The focus states of pill and sidebar — held here so that the Menu button can lead
    /// focus out **step by step**: from the grid into the pill, from the pill into the
    /// sidebar, from there out (tvOS). That was the finding of the test days: from the
    /// grid, the button threw you out of the app at once.
    @FocusState private var pillFocus: MediaTabBar.Section?
    @FocusState private var sidebarFocus: AppSidebar.Destination?
    /// The groups of the channel list. Still empty — they arrive once Live TV is set up,
    /// and then hang under "Live".
    @State private var liveGroups: [String] = []
    /// The lists together with their groups for the provider level of the sidebar —
    /// visible only from two enabled lists (roadmap P6).
    @State private var liveProviders: [AppSidebar.LiveProvider] = []
    /// Whether the Home screen is scrolled — the pill then yields via opacity, otherwise
    /// the hero card would visibly slide under the capsule.
    @State private var homeIsScrolled = false

    /// The categories of the provider's library — movies and series on demand.
    ///
    /// Kept apart from the channel groups because they are two different catalogs: one
    /// runs now, the other has runtime and progress.
    @State private var vodCategories: [AppSidebar.VODCategory] = []
    /// The provider's categories **including kind** — movies and series separately.
    ///
    /// ``vodCategories`` does not carry the kind and has only been counted since 2026-08-22:
    /// it decides whether "Movies & Series" exists at all. What the area shows is here.
    @State private var vodLibraries: [Core.Library] = []
    /// The IPTV provider's library — the second implementation of the source contract
    /// (roadmap P8).
    ///
    /// **It arrives wrapped** (AP42, 2026-09-21). The state no longer lives in
    /// ``PlaylistKit/XtreamVODSource`` but in the ``Core/StillLedger`` of the person who is
    /// watching right now — ``PlaylistKit/StateSource`` books it there. Wrapped here and
    /// not in the ``AggregateSource``: this view also passes `vodSource` on to Search, to
    /// Home, and to the player, and each of these paths would otherwise bypass the
    /// wrapper.
    ///
    /// **Built in ``init()`` and not in ``onStart()``** — see the rationale there.
    @State private var vodSource: ProviderSource?

    /// Third-party portals over the bridge in the home network — the **third**
    /// implementation of the source contract (AP20).
    ///
    /// **The address comes from Settings and not from the source code** (G2).
    /// `PortalBridge.standard()` used to be hard-wired to `portals.example:8099`; the portals
    /// therefore existed only where this one name resolves. What stays empty in Settings
    /// still yields exactly this name — see ``BridgeAddress/preset``.
    ///
    /// **Built in ``init()`` and not in ``onStart()``** — see the rationale there.
    @State private var portalSource: PortalSource?
    /// The entry points of all portals as libraries. An entry point — "New episodes",
    /// "All series" — is the same for the library view as a category at the provider.
    @State private var portalLibraries: [Core.Library] = []
    /// The portals for the bar. Empty as long as the bridge does not answer — the entry
    /// then does not appear at all.
    @State private var portals: [AppSidebar.Portal] = []
    /// The focus in the portal selection.
    ///
    /// An own anchor, not a shared one: without anything focusable, tvOS looks for the
    /// next target, and that is always the sidebar here — which then unfolded and stayed
    /// open. The same lesson as in ``PortalLevel``.
    @FocusState private var portalsFocus: String?
    /// Which area of the library is currently visible.
    ///
    /// The initial value can be preset through the environment. That is not a
    /// convenience but the only way to check a view other than Home: from here no keys
    /// can be sent to the simulator, and tvOS has no command for the remote. Without it
    /// only guessing remains — and that has already led to two bug hunts for bugs that did
    /// not exist today.
    ///
    ///     SIMCTL_CHILD_CINELOUNGE_START=series ./scripts/run.sh
    @State private var media: MediaTabBar.Section = MediaTabBar.Section.fromEnvironment
    /// The path through the views, **one per place**. As a path and not as a chain of
    /// individual states — otherwise navigating back cannot be done cleanly.
    ///
    /// **One per place and not per area, and the finding of 2026-08-27 hung on this**
    /// ("when I want to jump to a different view in Portals, the right side stays
    /// stuck"): all portals shared ``Section/portals`` and thereby **one** path. Whoever
    /// switched from Serieshub to Animehub replaced the root — but the path kept
    /// carrying the levels of the old portal, and they lay visibly on top.
    ///
    /// Yesterday's reset, by contrast (an `if` in `onChange(of: destination)` that emptied
    /// the path on a provider switch) did not hold: it required **both** destinations to
    /// have a place, and `location(of:)` returned `nil` for Live, Search, Favorites, Sport and
    /// Settings. Serieshub → Live → Animehub therefore left the old path in place. With
    /// one path per place the reset is dropped without replacement, and every portal keeps
    /// its own way back across an excursion to "Live".
    @State private var paths: [Spot: [MediaItem]] = [:]
    @State private var libraries: [Core.Library] = []
    /// Bumped whenever a library choice is remembered (AP89) — the tab reads the choice
    /// from ``LibraryChoiceMemory`` and needs a state change to draw it.
    @State private var libraryChoiceRevision = 0
    /// Titles per library for the library list at the title (AP89), counted on first need.
    @State private var libraryCounts: [String: Int] = [:]
    /// Whether the next library view should put the focus on its title — set by a choice in
    /// the list, consumed by the view that the choice creates.
    @State private var libraryLandsOnTitle = false
    /// Present only if credentials are stored — without them the app stays fully usable,
    /// only the third-party ratings are missing.
    @State private var ratingsClient: OMDbClient?
    /// The film database for a person's career. `nil` as long as no credentials are
    /// entered — the cast row stays there for viewing.
    @State private var filmographyClient: TMDbClient?
    /// Needs no credentials and is therefore always present. Returns something only if
    /// the server holds an AniList ID for the title — so for anime, otherwise not.
    private let anilistClient = AniListClient()
    /// The anime rating from MyAnimeList including the mapping per season (AP68). Reads
    /// the client ID itself on every request — an entry in Settings applies immediately.
    private var anime: AnimeRating { Self.animeRating }
    /// **One per program**, not per view: MainView is rebuilt on every account switch, and
    /// the mapping and the MAL store should survive that. The store lives on disk —
    /// otherwise every start would query the Home posters anew.
    private static let animeRating = AnimeRating(
        store: FileStore(), key: { SecureStore().malClientID() })
    /// The MAL ratings of the posters, requested only when a poster is visible (AP68) —
    /// for every view below it through the environment.
    @State private var animeRatings: AnimeScores
    /// The stored channel lists. Here and not in Settings, because the Live area needs the
    /// same catalog — two versions drifted apart as soon as something is entered.
    @StateObject private var playlistStore: PlaylistStore
    /// The merged channel catalog.
    ///
    /// As state and not computed: ``LiveLibrary`` remembers the result of the last load.
    /// If it were rebuilt on every evaluation of the body, this memory would be lost, and
    /// every focus change would trigger a reload of all lists — unusable with 5389
    /// channels over a thin line.
    @State private var liveLibrary: LiveLibrary?

    /// What is to be played right now. `nil` means: nothing is playing.
    /// The open certificate question, as soon as the viewer wants to see it.
    ///
    /// **Fetched from the mailbox and not observed** (AP39, 2026-09-20): the question sits
    /// there since the delegate aborted; it is taken out only when the button is pressed.
    /// A sheet that pops up on its own while someone is searching for a film answers a
    /// security question in passing — and that is exactly what it should not do.
    @State private var certificatePrompt: CertificatePrompt.Pending?

    @State private var playing: PlaybackTarget?

    /// The source the current target comes from — **per target, not per house.** A
    /// provider title belongs to the provider, a channel to no one; whoever always hands
    /// over the media server instead makes the player report foreign IDs there and, on
    /// error, fetch addresses from the wrong house. It is set everywhere `playing` is
    /// set.
    @State private var playingSource: (any ContentSource)?

    /// Counts up when the Live area should get its focus back.
    ///
    /// **After returning from the player, nothing was focused there** — and without a
    /// focused element tvOS delivers no movement commands and hands the Menu button to
    /// the system: the app closed (viewer finding 2026-08-11, at night). The full rationale is
    /// at ``LiveView/focusToken``.
    @State private var liveFocusToken = 0

    /// Counts up when the player closes — Favorites then reload.
    /// Why, is explained at the counting site in `onChange(of: playing)`.
    @State private var favoritesReloadToken = 0

    /// The home video whose selection is currently waiting for an answer.
    ///
    /// **Home videos get no second page.** A family recording has neither cast nor trailer
    /// nor seasons — the full detail page would be an empty stage. Instead a popup with
    /// the three actions that really exist there is enough: Resume, From the start, Mark
    /// as watched.
    /// Providers for which the jump to the last channel did not hold.
    ///
    /// The remembered channel may be gone — list changed, group hidden. Then the jump
    /// leads nowhere, and without this note the spinner would stay forever. On the next
    /// startup the area applies.
    @State private var liveJumpFailures: Set<String> = []

    /// Providers into which a jump has already been made on this target change.
    ///
    /// **The finding of 2026-08-29:** "When I am in Live and go back, the app opens again,
    /// although Live is focused in the sidebar, and where the Live preview was there is
    /// now a loading bar — but nothing can be loaded there, because there is nothing to
    /// load."
    ///
    /// That is exactly how it was: after leaving the player, `destination` still stood on
    /// `.live`, the switch still showed the loading area, and the jump did not run again —
    /// the target's identifier had not changed. A spinner without load, forever.
    @State private var liveJumpsDone: Set<String> = []

    @State private var homeVideoChoice: MediaItem?
    /// Why nothing is playing right now — in the source's wording.
    ///
    /// **This did not exist until 2026-08-29**, and it was missing at exactly the spot where
    /// it hurt most: the bridge said "The portal plays through its own proxy in the
    /// container", the player turned that into `NSURLErrorDomain -1008`, and the TV showed
    /// nothing at all. Four identical lines in the diagnostics that explained nothing.
    @State private var playbackRefusal: String?

    /// Whether a title is currently being opened — see
    /// ``startPlayback(of:fromStart:at:via:)``.
    @State private var isStartingPlayback = false

    /// Whether the title that is starting up comes from a portal.
    ///
    /// **Only there to show the right state** (AP25, 2026-09-11). A portal takes the path
    /// over the bridge, and that costs seconds; all other sources deliver their address in
    /// one go.
    @State private var isStartingViaPortal = false

    /// The person whose career currently lies over everything — **and the area it was
    /// opened from.**
    ///
    /// **The window lives here and not in the detail page**, and the reason is documented
    /// on the simulator (2026-08-12): there it lay **inside** the navigation path, and that
    /// evaluates the Menu button itself — a press did not close the window but the whole
    /// detail page. The catcher on the window was set correctly and still never received
    /// the button; the focus trace showed the focus sitting cleanly in the window.
    ///
    /// Here it lies over the entire frame — next to the navigation path instead of in it.
    /// In the player the same window worked from the start, and for exactly that reason:
    /// there is no path there that takes the button first.
    @State private var shownPerson: Person?
    /// Where a title from the window leads. The window sits above all areas, but the path
    /// there belongs to the place one came from.
    @State private var filmographyLocation: Spot = .media
    /// Counts up as soon as the window closes — the detail page takes its focus back from
    /// that. The rationale is at ``DetailView/filmographyToken``.
    @State private var filmographyToken = 0

    /// Whether the sync from the sidebar is currently running — the icon there pulses as
    /// long as this is set.
    @State private var isSyncing = false

    /// The sync behind the sidebar entry: discard the stores and refill them right away.
    /// Discarding alone would be done in the blink of an eye — the viewer would see only a
    /// twitch and not know whether anything happened. Only with the refetch is the pulse
    /// an honest indicator: it stays on as long as work is really going on. The open views
    /// reload by themselves through the change stream, the images through the prewarm loop
    /// in the start `task`.
    /// Refresh — **everything that is currently set up**, not only the media server.
    ///
    /// **Viewer finding 2026-08-28:** "Currently Refresh is exclusively Jellyfin only. If I
    /// have an active channel list, it should refresh it directly too … or the portals as
    /// well, maybe I have hidden some in the meantime."
    ///
    /// The button dates from the time when there was only one source. Three have been
    /// added since, and each has its own memory — whoever does not take them along leaves
    /// the viewer guessing what the button actually does.
    ///
    /// The four run **side by side** and not one after another: the channel catalog is the
    /// slowest of them, and a refresh that waits for it before touching the portals feels
    /// like a hang. What fails, fails on its own — a provider that is not answering right
    /// now must not take the others down.
    private func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        let jellyfin = source
        let channelLibrary = liveLibrary
        Task {
            async let fromJellyfin: Void = {
                // Without a media server there is nothing to sync — the channel list below still
                // syncs.
                guard let jellyfin else { return }
                await jellyfin.forgetCachedLists()
                await jellyfin.prewarm()
            }()

            // The channel catalog is **forcibly** refetched — otherwise it would come back from
            // the cache and the button would do nothing there.
            //
            // **And the TV guide along with it** (E1 of the sports concept). Until 2026-08-29.
            // `syncGuide()` had exactly one trigger in the whole project: the button of a SINGLE
            // channel list under Settings. The general refresher fetched channels and portals,
            // but never the programme — and the schedule lives on that alone. One after another
            // and not side by side: the guide needs the channels that the preceding step
            // fetches.
            async let fromLists: Void = {
                guard let channelLibrary else { return }
                _ = await channelLibrary.load(forceReload: true)
                _ = await channelLibrary.syncGuide()
            }()

            _ = await (fromJellyfin, fromLists)

            // After that the sidebar labels — both from the catalog that was just fetched,
            // without a second request. And the portals: in the workshop one may have been
            // switched on or off while the app was running.
            await loadLiveGroups()
            await loadPortals()
            isSyncing = false
        }
    }

    /// The language choice should also be reachable after sign-in — on tvOS there is no
    /// place for it in the system settings.
    let languages: LanguageSelection

    public init(
        source: JellyfinSource?,
        credentials: ServerCredentials?,
        languages: LanguageSelection,
        onSignOut: @escaping () -> Void,
        onAccountSwitched: @escaping (ServerCredentials?) -> Void,
        onAddAccount: @escaping () -> Void,
        start: AccountState.Area = .media
    ) {
        self.source = source
        self.credentials = credentials
        _animeRatings = State(initialValue: AnimeScores(rating: Self.animeRating))
        _destination = State(initialValue: Self.start(forItem: start))
        self.languages = languages
        self.onSignOut = onSignOut
        self.onAccountSwitched = onAccountSwitched
        self.onAddAccount = onAddAccount

        // **The three Home sources are in place before the first frame** (2026-09-23). Until
        // here ``onStart()`` set them — and `.task` runs only once the view is standing.
        // The source state known to ``ShellModels`` therefore changed right after startup,
        // ``ShellModels/home(…)`` created a **second** ``HomeModel``, and
        // `.id(ObjectIdentifier(home))` threw away the standing ``HomeView`` together with
        // its state. Home was built twice on every start; the first run fetched the catalog
        // over the line and was cancelled in the middle. How expensive that was depended on
        // the day's form of the sources — hence "sometimes fast, sometimes not".
        //
        // **None of the three needs an `await`.** They are constructions over the list
        // catalog and the Keychain; they stood there only because they need
        // ``playlistStore`` and that is a `@StateObject`.
        //
        // **The list catalog is built once and passed on three times.**
        // ``PlaylistStore/onDevice(…)`` returns a **new** one on every call; a second one
        // next to it would learn nothing of the first one's writes. Exactly this kind of
        // second catalog was the finding on the phone, "the channel list that arrived only
        // appears at the next start".
        //
        // Counter-check: ``startSourcesStandBeforeTheFirstFrame()``.
        // **Through the window of the active profile** (on-device test build 1332,
        // 2026-09-27, findings 1 and 3): the lists live on the device, but only those of the
        // profile are seen and played — the same calculation as on the phone
        // (``Flows/ChannelListView``).
        let listen = ChannelListView.set(PlaylistStore.onDevice())
        _playlistStore = StateObject(wrappedValue: listen)
        _liveLibrary = State(initialValue: LiveLibrary(store: listen))
        _vodSource = State(
            initialValue: ProviderSource(XtreamVODSource(store: listen), ledger: FileStore()))
        _portalSource = State(initialValue: Self.portalDataSource())
    }

    /// The areas of the **sidebar** — the app as a whole. The library is subdivided once
    /// more underneath via the pill; see ``MediaTabBar``.
    enum Section: Hashable {
        /// The library with its own pill inside.
        case media
        case search, live, settings
        /// **A separate path for Movies & Series at the provider.** It leads its own detail
        /// pages with its own source; stacked on the library's path, the detail page asked the
        /// media server for a title it does not know.
        case vod
        /// **And for the same reason a separate one for the portals.** Their identifiers are
        /// addresses of the bridge; stacked on the library's path, the detail page asked
        /// Jellyfin for `serieshub|…`.
        case portals

        /// For the navigation path: every library area keeps its own, so that a switch does
        /// not discard it.
        static func of(_ media: MediaTabBar.Section) -> Section { .media }
    }

    /// **Who owns a navigation path:** area *and* provider.
    ///
    /// An area alone is not enough. "Portals" is an area, but Serieshub and Animehub
    /// are two places inside it — each with its own levels that have nothing to do with
    /// each other. The same applies to the providers under "Movies & Series".
    ///
    /// The full rationale is at ``paths``.
    struct Spot: Hashable {
        let area: Section
        /// The provider within the area — empty where there is only one.
        let id: String

        init(area: Section, id: String = "") {
            self.area = area
            self.id = id
        }

        /// The library together with the pill — one place, because a pill switch should not
        /// discard the path (``Section/of(_:)``).
        static let media = Spot(area: .media)
        static let search = Spot(area: .search)
    }

    /// Which place an **entry** belongs to — or `nil` for the library.
    ///
    /// **The fourth edition of the same bug** (2026-08-15, 2026-08-23, and on 2026-08-28 twice
    /// in a row): an entry was opened at the wrong place, and the detail page then asked
    /// the media server for an identifier it has never seen —
    /// `serieshub|arrow:2012|…`. The TV then shows "The server reports a fault", while
    /// the same title opens flawlessly through its portal.
    ///
    /// That the identifier itself carries the answer is no coincidence: it leads with the
    /// portal in its first part, precisely so that an entry never becomes homeless. That
    /// is why the rule is here and not in every callback that opens entries — there are
    /// four of them by now.
    static func location(forItem item: MediaItem) -> Spot? {
        // An Xtream identifier has the same form (`xtream|…|…`) — ask the origin first.
        guard Origin.forItem(identifier: item.id) == .portals, let identifier = PortalItemID(item.id)
        else { return nil }
        return Spot(area: .portals, id: identifier.portal)
    }

    /// Which place stands behind a sidebar target.
    ///
    /// **Never `nil`**, and that is the difference to the version of 2026-08-26: that one
    /// returned nothing for Live, Search, Favorites, Sport and Settings, and the reset,
    /// which depended on two places, therefore did not kick in on any path across one of
    /// these areas. Every area has a place; where there are no providers, its identifier
    /// is empty.
    ///
    /// Not `private`, so that the mapping can be tested: yesterday's attempt went to the
    /// device untested — and did not hold.
    static func location(of destination: AppSidebar.Destination) -> Spot {
        switch destination {
        case .portals: Spot(area: .portals)
        case .portalProvider(let id): Spot(area: .portals, id: id)
        case .vod: Spot(area: .vod)
        case .vodProvider(let id): Spot(area: .vod, id: id)
        case .search: .search
        // Live, Favorites, Sport, sync and Settings keep no path of their own — they open no
        // detail pages over a stack. What they select ends up on the library's path, as it
        // always has.
        case .media, .jellyfin, .live, .liveGroup, .liveProvider, .liveProviderGroup,
            .favorites, .sport, .settings, .sync, .accounts:
            .media
        }
    }

    /// Leads into the Live area and keeps the catalog ready for it.
    ///
    /// **A startup that was taken back again** (2026-08-11): for a short time, a press on
    /// "Live" opened playback directly. The idea was right — channels, groups and
    /// programme are reachable in the player —, but it took more from the overview than
    /// it gave: search across all channels, marking favorites and the programme overview
    /// live there.
    private func openLive(provider: String?) {
        let library = liveLibrary ?? LiveLibrary(store: playlistStore)
        let rule = rule
        Task {
            let result = await library.load()
            let preferences = LivePreferences.load(from: ProfileStore.playback)
            // **First the child's filter** (AP52), then the preferences — see
            // ``ParentalControls/ChildScope/channels(_:)``.
            let stock = rule.scope.channels(result.channels).filter { channel in
                guard !channel.isSectionMarker else { return false }
                guard provider == nil || channel.playlistID == provider else { return false }
                return preferences.allows(group: channel.group, isAdult: channel.isAdult)
            }
            liveChannels = stock
            destination = provider.map { .liveProvider($0) } ?? .live
        }
    }

    /// Resets the library to its starting point.
    ///
    /// **Both belong to it, not just one.** The navigation path carries the detail pages,
    /// the pill the area within it — whoever empties only the path lands on "Movies"
    /// instead of Home, and whoever switches only the pill sees Home lying under a detail
    /// page.
    /// The sidebar — **as a property of its own and not in the body.**
    ///
    /// **Not for tidiness but because the compiler otherwise gives up.** The body of this
    /// view sits at the computation budget; when G3 gave the bar one more argument
    /// (`isInChildMode`), it reported "unable to type-check this expression in reasonable
    /// time" — and pointed at an unrelated line three hundred and fifty lines further
    /// down, in the middle of a `.task`. Whoever builds this property back in gets the
    /// same error at yet another place.
    private var sidebar: some View {
        AppSidebar(
            selection: $destination,
            scope: scope,
            surface: surface,
            // **Home needs no media server** (T13, 2026-09-27): it builds through
            // ``AggregateSource`` from media server, provider and portals. With portals only,
            // "Home" was missing entirely, although the portal shelf is there.
            showsLibrary: source != nil || vodSource != nil || portalSource != nil,
            hasJellyfin: source != nil,
            hasChannels: !playlistStore.enabledPlaylists.isEmpty,
            liveGroups: sidebarGroups,
            liveProviders: sidebarProviders,
            vodCategories: vodCategories,
            vodProviders: vodProviders,
            portals: portals,
            profileImage: profile.activeProfile.map {
                SidebarProfile(avatar: $0.avatar, letter: $0.initial)
            },
            onSync: syncNow,
            // **Through the stored area choice and not through a second state.** Settings opens
            // where one was last anyway (``SettingsSection/load(from:)``); setting the area
            // beforehand is the same path and not a new one.
            onAccounts: {
                // **A sheet instead of a jump** (2026-09-13) — and the two cases in which it stays a
                // jump are documented at ``AccountSwitcher/route(canSwitch:parentalControlsApply:)``.
                profile.load()
                switch AccountSwitcher.route(
                    parentalControlsApply: rule.applies, surface: surface)
                {
                case .sheet:
                    isSwitcherBehindDoor = false
                    showsAccountSwitcher = true
                case .sheetBehindDoor:
                    isSwitcherBehindDoor = true
                    showsAccountSwitcher = true
                }
            },
            onLive: openLive(provider:),
            onHome: goToStart,
            isSyncing: isSyncing,
            onFirstExpansion: { Task { await loadLiveGroups() } },
            focus: $sidebarFocus
        )
    }

    /// "Who's watching?" — **as a property of its own**, because there are two paths to
    /// it: open and behind the door `accountSwitch` (AP45). Written out twice in the body,
    /// the two would drift apart with the next button.
    ///
    /// **From the child interface only with the circles** (``AccountSwitcher/switchOnly``):
    /// creating and managing lead into Settings, and those do not exist there.
    private var accountSwitcher: some View {
        AccountSwitcher(
            model: profile,
            onSwitched: { credential in
                showsAccountSwitcher = false
                // **First the rule, then the source** (counter-check AP45, M1): if the switch ran
                // first, the new source would be built for one frame with the rule of the previous
                // person — and a child would see the adult's shelves flash up.
                profile.load()
                lock.load()
                discardRunning()
                followPortalHeader()
                onAccountSwitched(credential)
            },
            onManage: {
                showsAccountSwitcher = false
                SettingsSection.profiles.save(to: SecureStore())
                destination = .settings
            },
            // Settings open where one was last (``SettingsSection/load(from:)``).
            onSettings: {
                showsAccountSwitcher = false
                destination = .settings
            },
            onStay: { showsAccountSwitcher = false },
            switchOnly: surface == .kind)
    }

    /// What the button of a ``PlaybackPhase`` triggers — **in one place for the whole app.**
    ///
    /// **The view knows the target but not the path** (AP25, 2026-09-11).
    /// ``ActionTarget`` is an enumeration on purpose and not a callback: a `() -> Void`
    /// in the state would mean ``PlaybackPhase`` is neither comparable nor testable, and that is
    /// exactly what ``InfoVersusAction`` needs. The translation into an action
    /// therefore belongs where the paths are — here.
    ///
    /// **`.retry` is explicitly not here.** "Load again" means something different in
    /// every view; it keeps it and passes only the rest on.
    ///
    /// **The phone's targets** (download rules, system settings) do not exist here; the
    /// states that carry them are never produced by the TV (``PlaybackPhase/phoneOnly``). If
    /// one arrives anyway, it appears in the trace instead of being swallowed silently.
    func go(zu target: ActionTarget) {
        switch target {
        case .retry:
            // Should have been intercepted by the view itself. If it does arrive here, it is
            // worth a line in the trace and not a silent non-handling.
            Diagnostics.cursorKey("Zustand", "“Retry” reached the wrapper")
        case .accounts, .setup, .channelLists, .liveSettings, .portalSettings:
            // **The build form first** (counter-check AP45, K1) — see
            // ``ChildGuard/settingsArea(forItem:rule:)``.
            guard
                let area = ChildGuard.settingsArea(
                    forItem: target, rule: rule)
            else { return }
            area.save(to: SecureStore())
            destination = .settings
        case .sync:
            syncNow()
        case .certificate:
            certificatePrompt = CertificatePrompt.shared.current
        case .downloadRules, .systemSettings:
            Diagnostics.cursorKey("Zustand", "Phone target on the TV: \(target.rawValue)")
        }
    }

    /// The bar selects "Jellyfin" — the pill goes to a library if it was on Home.
    private func followSidebar(_ target: AppSidebar.Destination) {
        if target == .jellyfin, media == .home { media = .movies }
    }

    /// The pill switches — the bar follows between "Home" and "Jellyfin".
    private func followPill(_ area: MediaTabBar.Section) {
        if area == .home, destination == .jellyfin { destination = .media }
        if area != .home, destination == .media, source != nil { destination = .jellyfin }
    }

    /// The Menu button at the top edge of an area — **one level up, not straight into the
    /// bar** (AP59 N5).
    ///
    /// The bar no longer shows providers; whoever is in one of several therefore returns
    /// first to their list, and only from there into the bar. And whoever opened the
    /// libraries via "Jellyfin" also lands on this row and not on "Home".
    private func leave(_ origin: Origin) {
        switch (origin, destination) {
        case (.provider, .vodProvider) where vodProviders.count > 1:
            destination = .vod
        case (.portals, .portalProvider) where portals.count > 1:
            destination = .portals
        case (.jellyfin, .jellyfin):
            sidebarFocus = .jellyfin
        default:
            sidebarFocus = origin.sidebarDestination
        }
    }

    private func goToStart() {
        paths[Spot.media] = []
        media = .home
    }

    public var body: some View {
        mainContent.environment(animeRatings)
    }

    @ViewBuilder
    private var mainContent: some View {
        // Sidebar and content **side by side**, not on top of each other.
        //
        // That is the whole trick: if the bar lies to the left of the content, "left" is
        // actually left, and the focus movement follows from the arrangement. The previous
        // version used the system bar, which lies over the content — there every movement
        // had to be forced, and that is exactly where it got stuck.
        // Bar and content are **siblings** in the same HStack. That is not a question of
        // style but the prerequisite for the focus movement to work: tvOS tells apart only
        // elements that lie next to each other reliably.
        //
        // An intermediate step had put the bar into an `overlay` so that the content stays
        // still while it unfolds. The price was too high — one could no longer get out of the
        // bar, because overlay and content lie in separate layers and are not neighbours.
        // Better a picture that moves aside than a bar that lets nobody go.
        HStack(spacing: 0) {
            // **Search gets the full picture, everything else gets the bar.**
            //
            // The reason is not taste but ownership: the search field, the keyboard row and the
            // hint about switching keyboards belong to tvOS and are drawn across the full WINDOW
            // width — not inside our view. They therefore cannot be shifted with any spacing or
            // edge setting; that was tried three times without success. If a sidebar sits next to
            // them, two owners fight over the same area: the keyboard row begins flush with the
            // bar, and the hint is cut off on the right.
            //
            // Apple solves it the same way — Search there is a full-screen area of its own. The
            // Menu button leads back, as everywhere else.
            // **Always the full screen height, independent of the neighbour** (2026-09-13). The
            // bar took its height from the row, and that depended on the content next to it:
            // library and portals ignore the safe area, Settings does not — and when switching
            // there, sync, account and gear wheel moved up by sixty points. A bar that ends
            // somewhere else per area is not a bar. The height calculation
            // (``AppSidebar/maximumVisibleGroups``) assumes the full screen height anyway.
            if destination != .search { sidebar.ignoresSafeArea(edges: .vertical) }

            content
                // **Newly tagged with every rule state** (counter-check AP45, B4): Search and
                // Favorites hold their model as a `@StateObject` together with the filter.
                .id(ruleState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // **Disabled while the career lies over it** — page AND bar. The catcher in the
        // window alone is not enough: tvOS picks its target by position, and on the left
        // there is a bar that no navigation path disables. That is exactly where the focus
        // fell (viewer finding 2026-08-12: "click left in Movies, and the cursor jumps out of the
        // view"). What is disabled is not even considered as a target.
        .disabled(shownPerson != nil)
        // **And the window above it, outside of both.** As an overlay over the whole frame:
        // it does not hang on the disabled subtree — otherwise the window would be disabled
        // too — and it lies next to the navigation paths instead of in one of them.
        .overlay {
            if let person = shownPerson {
                let context = filmographyContext(in: filmographyLocation)
                if let context {
                    FilmographySheet(
                        person: person,
                        source: context.source,
                        library: context.library,
                        onOpen: { itemID in
                            // Close first, then open: if the window stayed, it would lie over the page that just
                            // called it.
                            shownPerson = nil
                            context.open(itemID)
                        },
                        onClose: {
                            shownPerson = nil
                            filmographyToken += 1
                        },
                        // The trailer of a foreign title from the short profile (AP78) runs in the wrapper's
                        // one player — like every other title, and not in a second cover over the sheet.
                        onPlay: { target in
                            playingSource = source
                            playing = target
                        }
                    )
                    .transition(.opacity)
                }
            }
        }
        .background(ColorRole.reason.color)
        // The outer frame may take all edges: the sidebar sits in it at the far left and
        // begins at the screen edge. What needs the spacing to the left is the content next to
        // it — and that handles it itself.
        .ignoresSafeArea()
        // The player lies over everything and in ONE place, not per area. Otherwise it would
        // exist several times, and on an area switch the sound would keep playing while the
        // picture disappears.
        //
        // Only for the TV: `fullScreenCover` does not exist on the Mac, and the checks of
        // this package run there. Without the condition the package no longer compiles on
        // macOS — and with that not a single check would run any more.
        // See ``homeVideoChoice`` — the one place for the popup, as with the player: home
        // videos are reachable from Home, grid and Search, and three dialogs in three places
        // drifted apart.
        // The answer to the press while the address is being fetched (AP5 · B1).
        .overlay {
            if isStartingPlayback {
                ZStack {
                    ColorRole.reason.color.opacity(0.55).ignoresSafeArea()
                    if isStartingViaPortal {
                        // **Instead of a spinner, it shows what is happening right now** (AP25, 2026-09-11).
                        // A portal takes the path over the bridge, and that costs seconds;
                        // ``StepwiseFallback`` says so in the head of this file: whoever reads what is
                        // happening waits — whoever sees a spinner presses Back from second eight. The
                        // walkthrough counted 13 of 54 selection presses repeated within two seconds.
                        //
                        // **The `.load` form and no focus target of its own** — ``StateBlock`` draws only
                        // spinner and sentence for it. A focus target would hold the button while the app is
                        // working.
                        StateBlock(state: .portalFetchAddress)
                            .frame(maxWidth: 760)
                    } else {
                        LoadingBand()
                    }
                }
                // Without hit testing: it lies over the controls but consumes no press — the way out
                // remains the Menu button.
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isStartingPlayback)
        // **The certificate question during operation** (AP39, 2026-09-20).
        //
        // The same dialog exists in the setup's Jellyfin sheet (``JellyfinConfirmView``), and until
        // 2026-09-20 it existed **only** in the old sign-in: whoever set up their server anew after setup got "No answer" from then on,
        // while the fingerprint sat in the mailbox. In a home lab, rebuilding is not an edge
        // case.
        //
        // **The same wording as in setup**, and the known digest is shown below it if there is
        // one — a *changed* certificate is the warning the procedure was built for, an unknown
        // one in the home network is the normal case.
        .confirmationDialog(
            Text(app: "cert.title"),
            isPresented: Binding(
                get: { certificatePrompt != nil },
                set: { if !$0 { certificatePrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button {
                guard let query = certificatePrompt else { return }
                try? CertificateTrustStore().trust(query.fingerprint, for: query.host)
                CertificatePrompt.shared.answer(query)
                certificatePrompt = nil
                // The sync is the "again" here: it queries both sources anew, and now the branch that
                // accepts the confirmed certificate takes effect.
                syncNow()
            } label: {
                Text(app: "cert.trust")
            }
            Button(role: .cancel) {
                if let query = certificatePrompt { CertificatePrompt.shared.answer(query) }
                certificatePrompt = nil
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            // The fingerprint in groups of four — in one piece it cannot be compared from three
            // metres with what is on the computer, and that comparison is the point of the whole
            // thing.
            Text(
                verbatim: AppLanguageSetting.text("cert.explain") + "\n\n"
                    + (certificatePrompt?.fingerprint.readable ?? "")
                    + (certificatePrompt?.known.map {
                        "\n\n" + AppLanguageSetting.text("cert.changed") + "\n"
                            + $0.readable
                    } ?? "")
            )
        }
        .confirmationDialog(
            Text(app: "player.refused"),
            isPresented: Binding(
                get: { playbackRefusal != nil },
                set: { if !$0 { playbackRefusal = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(role: .cancel) {
                playbackRefusal = nil
            } label: {
                Text(app: "common.ok")
            }
        } message: {
            Text(verbatim: playbackRefusal ?? "")
        }
        .confirmationDialog(
            Text(verbatim: homeVideoChoice?.title ?? ""),
            isPresented: Binding(
                get: { homeVideoChoice != nil },
                set: { if !$0 { homeVideoChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let video = homeVideoChoice {
                if video.progress?.isResumable == true {
                    Button {
                        Task { await startPlayback(of: video) }
                    } label: {
                        Text(app: "detail.resume")
                    }
                }
                Button {
                    Task { await startPlayback(of: video, fromStart: true) }
                } label: {
                    Text(app: "detail.restart")
                }
                Button {
                    // Through the Home model, not directly to the source: its path switches the shelves
                    // immediately and then carries the note to the server — otherwise the card would stay
                    // unchanged after the press.
                    let model = models.home(
                        source: source, provider: vodSource, portals: portalSource,
                        channels: liveLibrary, anime: anime, rule: rule,
                        surface: surface)
                    Task { await model.toggleWatched(for: video) }
                } label: {
                    Text(app: video.isWatched ? "detail.markUnwatched" : "common.markWatched")
                }
            }
        }
        #if os(tvOS)
            // The player does not give the focus back; the area takes it.
            //
            // **And here — and only here — what the playback changed is refreshed** (roadmap
            // AP3). This binding is the only place that knows the player has just closed; the
            // views only know that they are back. Which identifiers are affected is told by
            // ``PlaybackRefresh/staleIDs(after:)``, and what follows from that is known to the
            // source.
            .onChange(of: playing) { previous, current in
                guard current == nil, let previous else { return }
                liveFocusToken += 1
                let stale = PlaybackRefresh.staleIDs(after: previous)
                // **Only the media server remembers where one was.** A channel has no state, a
                // provider catalog does not keep one.
                if let source { Task { await source.refreshAfterPlayback(ids: stale) } }
                // The Favorites reload as well (on-device finding 2026-08-16: "Reset not possible"):
                // their tiles carried the state from BEFORE playback — a freshly watched title had no
                // progress on its tile, so neither a bar nor the long-press reset, although resuming
                // had long worked.
                favoritesReloadToken += 1
            }
            // **Back from the Picture-in-Picture window** (AP8): the system wants the full
            // screen, the holder names the target, the view comes back — with the holder's engine
            // and model, see ``PlayerScreen``.
            .onReceive(PictureInPictureKeeper.shared.$restoreRequest) { request in
                guard let request else { return }
                PictureInPictureKeeper.shared.restoreRequest = nil
                Task { await restore(request) }
            }
            .fullScreenCover(item: $playing) { target in
                PlayerScreen(
                    target: target,
                    // **The source of the TARGET, not of the house.** The media server always stood here —
                    // also for provider titles and channels. The player then asked Jellyfin for
                    // identifiers like `…#movie#821479#mkv` (`badRequest` in every trace), and the
                    // repackager fallback fetched an address into nowhere from the server (on-device
                    // finding 2026-08-15, evening: "VOD content no longer plays at all").
                    source: playingSource,
                    quality: StreamQuality.load(from: SecureStore()),
                    interfaceLanguage: languages.currentCode,
                    neighbourChannel: target.kind == .live ? neighbourChannel(from:offset:) : nil,
                    live: target.kind == .live ? livePlayerContext : nil,
                    // Also while the film is running: whoever recognises a face does not want to leave
                    // playback first just to look it up.
                    filmography: filmographyContext(in: .media),
                    // Read and set at the channel list, not in the player: it carries the mark, and the
                    // mark survives a reload there. Explicitly `@MainActor @Sendable`, as the parameter
                    // requires: from the switch expression with `nil` Swift does not infer the isolation
                    // otherwise and warns of data races that cannot exist here.
                    channelFavorite: target.kind == .live
                        ? { @MainActor @Sendable in
                            playingChannel.map(playlistStore.isFavorite) ?? false
                        } : nil,
                    setChannelFavorite: target.kind == .live
                        ? { @MainActor @Sendable wanted in
                            guard let channel = playingChannel else { return }
                            playlistStore.setFavorite(wanted, for: channel)
                        } : nil,
                    mayPlay: mayPlay
                )
            }
        #endif
        // **Every change to the channel lists discards the Live catalog.** The discarding was
        // built (``LiveLibrary/invalidate()``) — only nobody called it: a deleted or switched-off
        // list therefore kept broadcasting until the app restarted, and deleting in Settings
        // looked as if it did not take effect (roadmap P6). `dropFirst`, because `@Published`
        // delivers the catalog once immediately on sign-in — that would be a discard before
        // the first load.
        // **And a profile switch too** (on-device test build 1332): the window of the catalog
        // (``Flows/ChannelListView``) then shows other lists; the remembered Live
        // catalog and the bar's groups belonged to the previous profile.
        .onReceive(NotificationCenter.default.publisher(for: ProfilePointer.switched)) { _ in
            // **The CL-Server follows every switch** (finding 2026-11-09), not only those through
            // the switcher: its key lives in the profile, and a bridge built before the switch
            // keeps asking with the old one — or with none.
            followPortalHeader()
            playlistStore.objectWillChange.send()
            Task {
                await liveLibrary?.invalidate()
                await loadLiveGroups()
            }
        }
        .onReceive(playlistStore.$playlists.dropFirst()) { _ in
            Task {
                await liveLibrary?.invalidate()
                // And the sidebar afterwards: its groups are a copy of the names and would otherwise
                // know nothing of the discarding — the groups of the deleted list would stay there
                // until the next unfolding.
                await loadLiveGroups()
            }
        }
        // **Live and the library remember the last group** (user request 2026-08-07): whoever
        // jumps from another area to "Live" or "Movies & Series" lands directly in the
        // group visited last — together with the bar unfolded, because the unfolding follows
        // the selection. Whoever, on the other hand, deliberately goes up from a group to the
        // area (Menu button) gets the overview: otherwise there would be no way left to it,
        // the jump would catch one right away again.
        // **Bar and pill show the same thing** (AP59 N5): "Jellyfin" sets the pill to a
        // library, "Home" to the Home screen — and whoever switches in the pill, the bar
        // follows. Otherwise "Jellyfin" would light up above Home.
        .onChange(of: destination) { _, fresh in followSidebar(fresh) }
        .onChange(of: media) { _, fresh in followPill(fresh) }
        .onChange(of: destination) { previous, current in
            // **A press on "Live" is a jump, not a state.**
            //
            // The note records that a jump happened. It is emptied on every target change and set
            // again right afterwards when the jump takes place — the order is right because it is
            // set only after the change. Whoever leaves the channel thereby ends up in the
            // overview area and not back in the channel; whoever leaves the area and later goes
            // to "Live" again jumps again.
            //
            // **Since 2026-09-04 only when leaving the Live family** (F-041): every target change
            // within Live — group, provider — emptied the note, and the area jumped back into the
            // channel the viewer had just come from. In between stood the spinner.
            Diagnostics.verbose("Target: \(previous) → \(current)")
            if !Self.isLiveFamily(current) {
                liveJumpsDone.removeAll()
            }

            // **The reset for the provider switch used to be here — it has been dropped without
            // replacement** (2026-08-28). It emptied the area's path as soon as two targets of the
            // same area named different providers, and for that it required that BOTH targets have
            // a place. `location(of:)` returned `nil` for Live, Search, Favorites, Sport and Settings,
            // though: Serieshub three levels deep → Live → Animehub produced no reset, the old
            // path stayed.
            //
            // Since ``paths`` is kept per **place**, there is nothing to reset: every provider has
            // its own path, and it stays with it even across an excursion into another area.
            //
            // Whoever leaves Settings may have reordered or hidden groups — the sidebar catches up
            // immediately, from the remembered catalog, without a new request.
            if previous == .settings {
                profile.load()
                lock.load()
                Task { await loadLiveGroups() }
                // The portals too: in the workshop one may have been switched on or off while the app
                // was running.
                Task { await loadPortals() }
            }
            switch current {
            case .liveGroup(let name):
                try? SecureStore().set("group|" + name, for: Self.lastLiveKey)
            case .liveProvider(let provider):
                try? SecureStore().set("provider|" + provider, for: Self.lastLiveKey)
            case .liveProviderGroup(let provider, let group):
                try? SecureStore().set(
                    "providerGroup|" + provider + "|" + group, for: Self.lastLiveKey)
            case .vodProvider(let id):
                try? SecureStore().set(id, for: Self.lastVODKey)
            case .portalProvider(let id):
                try? SecureStore().set(id, for: Self.lastPortalKey)
            case .live:
                // **Only providers now, no more groups.**
                //
                // Here lay the reason for "I always end up at HEVC" (viewer finding 2026-08-11, at night):
                // there were **two** memories of the same question. This one only remembers what was
                // selected in the **sidebar**, and it overruled the other — whoever changed the group
                // in the Live area still ended up, on the next opening, at the group they had once
                // chosen in the bar.
                //
                // The Live area now remembers the group itself, and on **every** change — also the one
                // from the sidebar. Its memory is thereby always the more recent one, and this one has
                // become superfluous. For providers it remains: they are a view identity and not merely
                // a filter.
                guard !Self.isLiveFamily(previous),
                    let stored = storedLiveDestination(),
                    Self.isProviderDestination(stored)
                else { break }
                destination = stored
            case .vod:
                // **On the list, not on the category** (2026-08-22): the category is now remembered by the
                // area itself, separately per kind — see ``VODMemory``. The same change as for "Live",
                // and for the same reason: two memories of the same question overrule each other.
                guard !Self.isVODFamily(previous),
                    let id = try? SecureStore().value(for: Self.lastVODKey),
                    vodProviders.contains(where: { $0.id == id })
                else { break }
                destination = .vodProvider(id)
            default:
                break
            }
        }
        // **The way back from the Home screen.** The Top Shelf extension opens titles as
        // `cinelounge://item/<identifier>`; here the title is fetched completely once and
        // opened through the same branching point as every other selection — so home videos
        // get their popup from there too instead of a detail page. An unknown or deleted
        // target fizzles out silently: the app simply stands where it stood.
        #if os(tvOS)
            .fullScreenCover(item: $lockedTitle) { title in
                LockedDoorView(title: title) { lockedTitle = nil }
            }
            // **The Menu button closes the sheet by itself** — a full screen on tvOS has this way
            // back built in, and a catcher of our own would take it away from it.
            .fullScreenCover(isPresented: $showsAccountSwitcher) {
                if isSwitcherBehindDoor {
                    ParentalControlsDoor("kontowechsel") { accountSwitcher }
                } else {
                    accountSwitcher
                }
            }
        #endif
        .onOpenURL { url in
            guard url.scheme == "cinelounge", url.host() == "item" else { return }
            let id = url.lastPathComponent
            guard !id.isEmpty, id != "/" else { return }
            // **Across all sources** (2026-09-28): until then only the media server fed the Top
            // Shelf extension, and a deep link meant only it. Since the shelf also carries IPTV
            // VOD and CL-Server, ``AggregateSource`` forwards the identifier to its origin. An
            // unknown target still fizzles out silently.
            let source = aggregateSource
            Task {
                guard let item = try? await source.item(id: id) else { return }
                destination = .media
                open(item, in: .media, using: source)
            }
        }
        .modifier(
            ChildGuard(
                active: profile.active, surface: surface, rule: rule,
                destination: $destination,
                reread: {
                    // **Also the session, if a remote move has relocated the active profile** (strand F)
                    // — rationale at ``ProfileModel/loadAfterArrival()``. First the rule, then the source,
                    // as with the switch by hand (M1).
                    let episode = profile.loadAfterArrival()
                    lock.load()
                    // **And the portals, when the head has moved** (strand G) — also with `.remains`: the
                    // session hangs on the media server, the head on the portal person, and the two do not
                    // switch together.
                    followPortalHeader()
                    if case .migrate(let credential) = episode { onAccountSwitched(credential) }
                },
                discard: {
                    // Counter-check AP45, B4 — rationale at ``ChildGuard``. The target stays where it is
                    // allowed (A2-1).
                    paths = [:]
                    media = .home
                    discardRunning()
                    destination = ChildGuard.target(
                        afterDiscarding: destination, rule: rule)
                })
        )
        // **The shelf on the Home screen follows the same state** (AP52) — rationale at
        // ``HomeShelf``.
        .modifier(ShelfGuard(state: ruleState, portals: portalSource))
        .task { await onStart() }
    }

    /// **What happens once at startup** — as a method and not as a body in the tree.
    ///
    /// **The compiler could no longer get through** (2026-09-11, AP29): with the optional
    /// media server this body grew by a few `if let`, and the tvOS build aborted with
    /// "unable to type-check this expression in reasonable time" — at a line that had
    /// nothing to do with it. A view tree is **one** expression; what is in it is checked
    /// as a whole. A method is checked on its own.
    ///
    /// **"Who's watching?" once per program run** (shell check H3, 2026-09-27):
    /// `.id(languageDeferral…)` rebuilds this view after choosing a profile with a different
    /// language, and `onStart` then ran a second time — curtain included. Hence
    /// ``Flows/ProfilePicker/asksNow(_:protectionActive:)``, the same rule as on the
    /// phone.
    private func onStart() async {
        // **"Who's watching?" comes before the library if nobody is determined** (AP45,
        // 2026-09-23). When that is the case is calculated by ``ProfileKit/StartCurtain`` — and
        // the expensive side of this decision is the false yes: a TV set to "start
        // automatically as family" should never see the question again.
        //
        // **If parental controls apply, the curtain does not come** — the same rule as at
        // ``AccountSwitcher/route(parentalControlsApply:)`` and for the same reason: a child that
        // saw the circles would see an invitation. The way out then leads through the door
        // with PIN in Settings.
        //
        // **Only after the intro** (AP51): the full screen would otherwise lie over the clip,
        // and in a multi-profile household nobody would see a frame of it. Rationale at
        // ``DrawReadiness``.
        let gate = profile.launchGate
        let book = profile.administration.activeAndCount
        let asksByRule = ProfilePicker.asksNow(gate, protectionActive: rule.applies)
        let asksForLack = ProfilePicker.asksWithoutActive(
            active: book.active, profiles: book.count, protectionActive: rule.applies)
        // **One line per start** (finding 2026-11-09): which profile is active, and why the
        // question comes or not — the protocol of that evening could not say it.
        Diagnostics.step(
            "Start: profile \(book.active?.rawValue.prefix(8) ?? "none") of \(book.count), gate \(gate), protection \(rule.applies), asks \(asksByRule || asksForLack)",
            since: nil, area: "Anmeldung")
        if asksByRule || asksForLack {
            DrawReadiness.shared.afterIntro { showsAccountSwitcher = true }
        }
        // **The remote listens from startup and not only in the player** (AP8). A phone that
        // presses "continue watching on the TV" meets exactly then a TV that plays
        // **nothing** — and in the first version nobody was listening there.
        RemoteControl.shared.start()
        // **The network guard listens from startup** (AP25, 2026-09-11). It answers the one
        // question that comes before any interpretation of faults: is this device on the
        // network at all? Without it, a TV without a network cable reported "No answer from
        // the media server" — and one looked at the wrong device.
        NetworkWatch.shared.start()
        // **"Continue watching on the TV" — the Jellyfin branch** (AP24, 2026-09-11).
        // ``RemoteControl/openTitle`` had **zero** call sites; the command arrived, found no
        // path and was explicitly rejected ("no way to open a title"). Honestly rejected — but
        // rejected nonetheless.
        //
        // **The same path as `cinelounge://item/<identifier>`** a few lines further up: fetch
        // completely once, then open through the same branching point. Two paths to a detail
        // page drift apart sooner or later — and home videos would get their popup on one and
        // not on the other.
        //
        // **Only `jellyfin`, and that is deliberate.** The origin is
        // `Catalog.Origin.rawValue` from the phone. Portals and provider catalogs need a
        // different resolution and a **start position** that ``open(_:in:using:)`` does not
        // take at all — that touches the same funnel as AP29 and is documented there. What is
        // not handled here continues to fall into the honest rejection and not into "the
        // closest match".
        RemoteControl.shared.openTitle = { identifier, origin, startPosition in
            // **A channel plays, it has no detail page** (AP29). The path for it has existed since
            // 2026-09-11 and was just not called here — "Open channel on the TV" fell into the
            // rejection although everything was there for it.
            if origin == "senderliste" {
                Task { await playChannel(identifier) }
                return
            }
            // **The downloads are on the phone and nowhere else.** A downloaded file lies in its
            // sandbox; the TV cannot reach it, and "the closest match" — fetching the same title
            // over the network — would be something different from what someone tapped.
            if origin == "vorrat" {
                Diagnostics.playbackStep(
                    "Remote: downloads are on the phone, not on the TV",
                    since: nil)
                return
            }
            // **The identifier states the origin itself** (``Origin/forItem(identifier:)``):
            // `animehub|…` is a portal, an Xtream identifier a provider catalog, everything else
            // the media server. Translating the phone's string alongside would be a second truth
            // about the same question.
            let source = contentSource(forItem: Origin.forItem(identifier: identifier))
            guard let source else {
                Diagnostics.playbackStep(
                    "Remote: no source for origin \(origin)", since: nil)
                return
            }
            Task {
                // **No silent return** (AP25): the command has arrived, and if the title cannot be
                // fetched — an identifier from an old list, a server that is not answering right now
                // —, that is the information missing in the report. Before, a `return` without a word
                // stood here.
                guard let item = try? await source.item(id: identifier) else {
                    Diagnostics.playbackProblem(
                        "Remote: title \(identifier) cannot be fetched from \(origin)",
                        since: nil)
                    return
                }
                destination = .media
                // **With a start position it plays, without it shows the page** — both through the same
                // funnel so that the filter takes effect.
                open(item, in: .media, using: source, playFrom: startPosition)
            }
        }
        // **The profile switch has to reach the list catalog** (AP42, 2026-09-21): the
        // favorites live in the person's ledger, the catalog holds them in memory. Linked here
        // and not in the construction of the two holders — a `@StateObject` knows its
        // neighbour only once the view is standing.
        profile.listen = playlistStore
        // Right here and not only on unfolding — see ``loadPortals()``.
        await loadPortals()
        restoreVODCategories()
        // Measure the line once per start — delayed, so that the measurement does not fight
        // the startup downloads for bandwidth. The result feeds the automatic quality choice;
        // when a measurement may have a say at all is documented at ``ThroughputMemory``.
        Task.detached(priority: .utility) { [source] in
            // **What is measured is the line to the media server.** Without it there is nothing to
            // measure — the quality choice is then made by the provider, and its streams carry
            // their bitrate themselves.
            guard let source else { return }
            try? await Task.sleep(for: .seconds(8))
            let result = await ConnectionProbe(source: source).run()
            if let throughput = result.throughput {
                ThroughputMemory.save(mbps: throughput, to: SecureStore())
            }
        }
        // **`await loadLiveGroups()` used to be here, and that was the most expensive call of
        // the whole app.** At the Xtream provider it fetches the complete channel list — 5389
        // entries — and ran at every start simultaneously with Home. Over the TV's line this
        // choked the requests to the media server in the same house: the diagnostic report
        // shows a timeout on `Items/Resume` twice in a row, while requests to the internet
        // kept running — with a server that answers from another computer in 40 milliseconds.
        //
        // The list is needed when someone opens the sidebar. From there it is now requested,
        // see ``AppSidebar/onFirstExpansion``.
        if let key = SecureStore().omdbAPIKey() {
            ratingsClient = OMDbClient(apiKey: key, store: SecureStore())
        }
        // **The credentials may come from the environment for check runs too**, like the start
        // area (see ``media``). Without that it cannot be told apart on the simulator whether
        // the career does not open or whether it does not exist for lack of credentials —
        // both look the same: you press, and nothing happens. Exactly this question triggered
        // a false alarm on 2026-08-12.
        //
        //     SIMCTL_CHILD_CINELOUNGE_TMDB=<schlüssel> ./scripts/run.sh
        // **With the type spelled out**, and that is not a cosmetic flaw: without it the
        // compiler needed "unreasonable time" for this expression and aborted as soon as the
        // body of this task grew further.
        let fromStore: String? = SecureStore().tmdbAPIKey()
        let fromEnvironment: String? = ProcessInfo.processInfo.environment["CINELOUNGE_TMDB"]
        let tmdbKey: String? = fromStore ?? fromEnvironment
        if let key = tmdbKey, !key.isEmpty {
            // With the language of the interface: a Turkish viewer expects Turkish film titles,
            // and the film database can deliver them.
            filmographyClient = TMDbClient(
                apiKey: key, language: languages.currentCode, store: SecureStore())
        }

        // **Fetch everything once at startup, then nothing more.**
        //
        // Before, every view loaded by itself on first entry, and once more after two
        // minutes. On this line every request means: up to six seconds in front of an empty
        // screen. Now everything is there after startup, the cache holds for an hour, and
        // whoever has added something new presses "Sync now" in Settings.
        //
        // One after another and not concurrently — simultaneous requests are exactly what
        // this connection cannot take. The store lets Home go first anyway (see its
        // `delayedBy` parameter), and at the end the first posters of every library go into
        // the image store — rationale at ``StartupPrefetch``.
        if let sourceItem = source {
            await sourceItem.prewarm()
            await StartupPrefetch.warmPosters(from: sourceItem)
            await StartupPrefetch.warmResumableStills(from: sourceItem)
        }

        // And the channels from the store — **from disk, not from the network**: afterwards
        // the Live area is there immediately on first entry. At the end, so that the Home
        // posters go first.
        await liveLibrary?.warmFromStore()
        await warmLiveLogos()

        // **What the sync brings in later is warmed along** (finding of the test days: Flaihuski Freipri
        // Taspreis arrived anew through the background sync, and every image popped in only when
        // looked at). The source reports every silent list exchange — on each report the first
        // posters per library and the Continue Watching cards are laid in afterwards. What is
        // already in the image store the store skips; only what is really new is fetched.
        // **Without a media server there is no silent list exchange** — the channel list
        // reports its own through ``LiveLibrary``, and the Live area listens there itself.
        guard let sourceItem = source else { return }
        for await _ in await sourceItem.listChanges() {
            await StartupPrefetch.warmPosters(from: sourceItem)
            await StartupPrefetch.warmResumableStills(from: sourceItem)
        }
    }

    // The documentation of `liveArea` together with its `@ViewBuilder` used to be here,
    // after the function itself had been moved further down. The orphaned attribute
    // attached itself to the next declaration — `loadLiveGroups` — and its `return`
    // triggered the warning "result builder disabled" on every rebuild. Attributes belong
    // to their function, not to their neighbour.

    /// The last visited Live group and VOD category — store keys.
    private static let lastLiveKey = "sidebar.lastLive"
    private static let lastVODKey = "sidebar.lastVOD"
    /// The portal opened last — so that "Portals" leads back there.
    private static let lastPortalKey = "sidebar.lastPortal"
    /// The focus anchor of the portal selection when no portal is reachable.
    private static let portalsEmptyAnchor = "portals-none"
    private static let vodCategoriesKey = "sidebar.vodCategories"
    /// A separate place, because the content is a different one: the kind is part of it
    /// here. The old key stays so that a rollback loses nothing.
    private static let vodLibrariesKey = "sidebar.vodLibraries"

    private static func isLiveFamily(_ destination: AppSidebar.Destination) -> Bool {
        switch destination {
        case .live, .liveGroup, .liveProvider, .liveProviderGroup: true
        default: false
        }
    }

    /// Whether a target means a **provider** and not merely a group.
    ///
    /// The difference decides who remembers what: a provider is a view of its own
    /// (``LiveView`` carries its identifier as identity), a group only a filter within it —
    /// and that one is kept by the area itself.
    private static func isProviderDestination(_ destination: AppSidebar.Destination) -> Bool {
        switch destination {
        case .liveProvider, .liveProviderGroup: true
        default: false
        }
    }

    private static func isVODFamily(_ destination: AppSidebar.Destination) -> Bool {
        switch destination {
        case .vod, .vodProvider: true
        default: false
        }
    }

    static func isPortalFamily(_ destination: AppSidebar.Destination) -> Bool {
        switch destination {
        case .portals, .portalProvider: true
        default: false
        }
    }

    /// Reads the remembered Live group back — checked against the catalog, if it is
    /// already loaded. A group that no longer exists should not lead into an empty area;
    /// before the first load the jump is risked, since the view loads by itself anyway.
    private func storedLiveDestination() -> AppSidebar.Destination? {
        guard let raw = try? SecureStore().value(for: Self.lastLiveKey) else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)

        switch parts.first {
        case "group" where parts.count == 2:
            guard liveGroups.isEmpty || liveGroups.contains(parts[1]) else { return nil }
            return .liveGroup(parts[1])
        case "provider" where parts.count == 2:
            guard liveProviders.isEmpty || liveProviders.contains(where: { $0.id == parts[1] })
            else { return nil }
            return .liveProvider(parts[1])
        case "providerGroup" where parts.count == 3:
            if let provider = liveProviders.first(where: { $0.id == parts[1] }) {
                guard provider.groups.contains(parts[2]) else { return nil }
            } else if !liveProviders.isEmpty {
                return nil
            }
            return .liveProviderGroup(provider: parts[1], group: parts[2])
        default:
            return nil
        }
    }

    /// Puts the channel logos of the last visited group into the image store.
    ///
    /// **The same reasoning as for the Home posters:** whoever opens the Live area lands,
    /// thanks to the group memory, in their last group — so its logos are predictable.
    /// Fetching them only when drawing means the list appears and then fills with images
    /// from top to bottom.
    ///
    /// **Only this one group.** Preloading all 5389 logos would be the Home mistake in green:
    /// a lot of network for images nobody looks at.
    private func warmLiveLogos() async {
        guard let liveLibrary else { return }
        let result = await liveLibrary.load()

        let group: LiveLibrary.Group? =
            switch destination {
            case .liveGroup(let name): result.groups.first { $0.name == name }
            case .liveProviderGroup(_, let name): result.groups.first { $0.name == name }
            default: result.groups.first
            }
        guard let group else { return }

        let urls = group.channels.prefix(24).compactMap(\.logoURL)
        guard !urls.isEmpty else { return }
        // **The same size and the same margin as the row** (AP7 · L4): 120×120 with the
        // default margin stood here, the row draws 78×50 without — two keys, two entries, and
        // the preload warmed nothing.
        await ImageCache.shared.prefetch(
            Array(urls),
            decodeLimit: ImageSizing.decodeLimit(points: ChannelRow.logoSize, headroom: 1)
        )
    }

    /// Fetches the groups of the stored lists for the sidebar.
    ///
    /// **The unfolding mechanics were built and never got anything to show.** Without these
    /// lines `liveGroups` stayed empty, and under "Live" there was nothing — which looks as
    /// if the provider knew no groups, while it holds 79 of them.
    ///
    /// **Complete, not shortened.** Once it was limited to twelve here, because the bar was
    /// a stack without scrolling and overflowed at 79 entries. It has one now, so all of
    /// them go in — and the row that pointed to the rest is thereby obsolete.
    /// The portals — **a load of their own, and right at startup**.
    ///
    /// **Viewer finding 2026-08-28:** "When I open the app, I first have to go to Settings for
    /// Portals to become visible in the sidebar."
    ///
    /// They hung on as a by-catch of ``loadLiveGroups()``, and that was the mistake. That
    /// load begins with the channel catalog — 5389 entries —, and the design keeps it away
    /// from startup for good reason: it once choked the requests to the media server in the
    /// same house. When the bar unfolds it starts, but is not through yet; an excursion into
    /// Settings kicks it off a second time, and then it is there. Exactly that was visible.
    ///
    /// The portals do not need that: `/portals` plus one `/menu` per portal, measured at
    /// eight milliseconds for a meter reader and half a second for a large portal with many
    /// sections. That belongs at startup and not in someone else's load.
    ///
    /// If the bridge fails, the list stays empty and the entry does not appear at all — a
    /// portal that is missing is something one looks for in the app; one that stands there
    /// with a warning sign is not.
    /// Rebuilds the portal source from the entered address.
    ///
    /// **As a function of its own and not as an expression in the view.** The body of this
    /// view is large enough that the compiler gives up at one more chain of `map` and
    /// constructor ("unable to type-check in reasonable time") — and the error message then
    /// points at an unrelated line thirty lines further up.
    private func setPortalSource() {
        portalSource = Self.portalDataSource()
    }

    /// The portal source from what is in the Keychain — **without a standing view.**
    ///
    /// Separate from ``setPortalSource()``, because ``init()`` needs it before there is a
    /// state to set. It reads only the Keychain and no `@StateObject`; that is the condition
    /// for it being allowed to stand here.
    /// **Only for a profile that wants the CL-Server** (simulator 2026-09-28): a freshly
    /// created profile got the same source as the previous one — without a person, so with
    /// `401` on every request and a settings page that looked "set up". Without profiles
    /// (before setup) the device still applies.
    private static func portalDataSource() -> PortalSource? {
        let keychain = SecureStore()
        // **First pull a trait from the device into the profile** (2026-09-28) — otherwise an
        // older profile would fall back on it and stand at the server as the device's person.
        TraitMigration.migrate(device: keychain, ledgerStore: FileStore())
        let book = ProfileBook.read(from: FileStore())
        // **No person, no key — and so no request** (finding 2026-11-09). With profiles but
        // none active, the key of the device base would go out, which `TraitMigration` has
        // emptied: 401, again and again, and the sidebar dropped the CL-Server. Without a
        // source nothing is asked; the switch to a profile builds it (``followPortalHeader()``).
        if !book.profile.isEmpty, book.activeProfile == nil { return nil }
        // **Portals off means: no source** (decision 27, C12) — no entry in the sidebar, no
        // shelf, no results; the bridge stays entered.
        guard book.activeProfile?.wantsPortals ?? true,
            PortalSwitch.on(in: keychain),
            let bridgeAddress = BridgeAddress.effective(from: keychain)
        else {
            return nil
        }
        // **The trait travels along with every request from here** (2026-09-12). It is `nil`
        // as long as nothing has been redeemed, and always with the old bridge —
        // ``PortalBridge`` sets the header only if the dialect knows it.
        //
        // **And the borrowed profile beside it.** A device that belongs to no person — the
        // living-room TV —, names on every request the profile currently sitting in front of
        // it. Without it the server answers everything with `401 auth.profile_required`.
        return PortalSource(
            bridge: PortalBridge(
                basis: bridgeAddress,
                trait: DeviceTrait.load(from: keychain),
                profile: DeviceTrait.profile(from: keychain)))
    }

    /// Rebuilds the portal source **if it is no longer the one of the active profile** —
    /// after every profile switch, by hand or remote. The decision is documented at
    /// ``PortalHeaderGuard``; here it is only asked and acted on.
    private func followPortalHeader() {
        guard PortalHeaderGuard.isStale(portalSource, expectedValue: Self.portalDataSource()) else { return }
        newBridge()
    }

    /// Like ``setPortalSource()``, and reloads afterwards — after a change of the address
    /// the row above would otherwise show the new address and the old one would be queried.
    private func newBridge() {
        setPortalSource()
        Task { await loadPortals() }
    }

    /// Load the portals — **and beforehand, if necessary, sign in with the person's token**
    /// (AP47).
    ///
    /// **Two occasions, at most one attempt each, and no clock.** On loading: a device
    /// without a trait whose profile carries a token signs in by itself. And if the server
    /// says `auth.required`: after a revocation the trait is dead, and if the profile now
    /// holds a new token, it silently signs in again with it — afterwards it reloads
    /// **once**, not in a loop. Whether a token is new or has already failed is decided by
    /// ``SelfSignIn/expectedValue(_:hasTrait:tag:used:failed:)``.
    ///
    /// **Last, once the portals have answered, update the token** (``TokenReconciliation``): a
    /// signed-in device of its own fetches the new token into the profile after a
    /// revocation — only then, so that the sidebar does not wait for it.
    private func loadPortals() async {
        // **The new source is built and held here**, not read back from the state: whether an
        // assignment to `@State` is already readable in the same pass is a question for
        // SwiftUI, and the answer should decide nothing here.
        var source = self.portalSource
        if await SelfSignIn.onDevice()?.attempts(.open) == .signedIn {
            source = Self.portalDataSource()
            self.portalSource = source
        }
        guard var portalSource = source else { return }
        var found: [(id: String, name: String, ready: Bool, state: String, reason: String?)]
        do {
            found = try await portalSource.availablePortals()
        } catch let rejection as PortalBridge.TestError where rejection.code == "auth.required" {
            Diagnostics.defect(
                "Portals require a login, self-registration follows: \(Diagnostics.explain(rejection))",
                since: nil, area: "Anmeldung")
            found = []
            if await SelfSignIn.onDevice()?.attempts(.dismissed) == .signedIn {
                if let fresh = Self.portalDataSource() {
                    self.portalSource = fresh
                    portalSource = fresh
                    found = (try? await fresh.availablePortals()) ?? []
                }
            }
        } catch {
            Diagnostics.defect(
                "Portals not loaded: \(Diagnostics.explain(error))", since: nil, area: "Oberfläche")
            found = []
        }
        portals = found.map {
            AppSidebar.Portal(
                id: $0.id, name: $0.name,
                state: $0.ready ? .ready : PortalState($0.state, reason: $0.reason))
        }
        portalLibraries = (try? await portalSource.libraries()) ?? []
        if !found.isEmpty, await TokenReconciliation.onDevice()?.reconcile() == .fresh {
            self.portalSource = Self.portalDataSource()
        }
    }

    private func loadLiveGroups() async {
        guard let liveLibrary else { return }
        let result = await liveLibrary.load()
        // Only the names: the sidebar shows labels, not channels. Carrying the whole groups
        // along would mean holding the catalog a second time. In the viewer's order (Settings
        // → Live) — the sidebar must show the same sequence as the area itself.
        let livePreferences = LivePreferences.load(from: ProfileStore.playback)
        liveGroups = livePreferences.ordered(result.groups.map(\.name))
        // And per list individually, for the provider level — calculated from the same
        // catalog, no second request.
        liveProviders = await liveLibrary.providerGroups().map {
            AppSidebar.LiveProvider(
                id: $0.id, name: $0.name, groups: livePreferences.ordered($0.groups))
        }
        // The categories come from the VOD source itself — with identifiers, not only names:
        // "Action" exists twice at two providers.
        if let vodSource {
            let categories = (try? await vodSource.libraries()) ?? []
            vodLibraries = categories
            vodCategories = categories.map {
                AppSidebar.VODCategory(id: $0.id, name: $0.name)
            }
            if !categories.isEmpty,
                let data = try? JSONEncoder().encode(categories),
                let json = String(data: data, encoding: .utf8)
            {
                try? SecureStore().set(json, for: Self.vodLibrariesKey)
            }
            // The snapshot for the next start: without it the "Movies & Series" entry would be
            // missing after every restart until the categories had been loaded once — and the
            // group memory would seem forgotten, although there was merely no entry to press
            // (user finding 2026-08-08).
            if !vodCategories.isEmpty,
                let data = try? JSONEncoder().encode(vodCategories),
                let json = String(data: data, encoding: .utf8)
            {
                try? SecureStore().set(json, for: Self.vodCategoriesKey)
            }
        }
    }

    /// The lists that carry movies or series — derived from the categories.
    ///
    /// **Not kept separately but calculated.** The library identifier already carries the
    /// list (`<list>|vod|<category>`); a second source for it could deviate from the first,
    /// and then the bar would show a provider that has no category.
    private var vodProviders: [AppSidebar.VODProvider] {
        var seen: Set<String> = []
        var result: [AppSidebar.VODProvider] = []
        for library in vodLibraries {
            guard let parsed = XtreamVODSource.parseLibraryID(library.id),
                seen.insert(parsed.playlistID).inserted
            else { continue }
            let name = playlistStore.playlist(withID: parsed.playlistID)?.name
            result.append(
                .init(id: parsed.playlistID, name: name ?? parsed.playlistID))
        }
        return result
    }

    /// The category snapshot of the last run — only so that the entry is there immediately;
    /// ``loadLiveGroups()`` fetches the truth afterwards.
    private func restoreVODCategories() {
        guard vodCategories.isEmpty,
            let json = try? SecureStore().value(for: Self.vodCategoriesKey),
            let data = json.data(using: .utf8),
            let stored = try? JSONDecoder().decode([AppSidebar.VODCategory].self, from: data)
        else { return }
        vodCategories = stored

        if vodLibraries.isEmpty,
            let json = try? SecureStore().value(for: Self.vodLibrariesKey),
            let data = json.data(using: .utf8),
            let libraries = try? JSONDecoder().decode([Core.Library].self, from: data)
        {
            vodLibraries = libraries
        }
    }

    /// Turns a title into a playback target and starts it.
    ///
    /// **This bridge was missing, and that is why the library played nothing although Live
    /// worked.** The path via the channel list delivers a finished ``PlaybackTarget``; a
    /// title from Jellyfin, by contrast, is only a ``MediaItem``. In between lie three steps
    /// that nobody took: choose the engine, request the address from the server, and
    /// assemble both into a target.
    ///
    /// The details about the file are the reason why this does not work in passing: without
    /// ``MediaSource``, ``PlaybackEngineSelector`` would know nothing about containers and
    /// tracks and would send an MKV file to the system player — black picture. If they do
    /// not come along in the list, the title is fetched completely once.
    /// - Parameter provider: The source that delivers title and address — the media
    ///   server by default; the IPTV library passes its own along. Everything used is part
    ///   of the contract of ``ContentSource``.
    private func startPlayback(
        of item: MediaItem,
        fromStart: Bool = false,
        at fixedStart: TimeInterval? = nil,
        via provider: (any ContentSource)? = nil
    ) async {
        // **Without a source there is nothing to play.** The case arises only without a media
        // server and with a title that brings no source of its own — and such a title does not
        // exist then.
        guard let provider: any ContentSource = provider ?? source else { return }

        // **A press on "Play" needs an answer, and immediately** (AP5 · B1, expert walkthrough
        // 2026-08-24). Until the player appears, up to **two network round trips** lie in between —
        // the file details and the stream address —, and during that time nothing at all
        // happened on the screen. Whoever considers a press without effect presses again: the
        // walkthrough counts 13 of 54 selection presses that were repeated within two seconds.
        //
        // `defer` and not at the end: this function returns at nine places, and forgetting one
        // of them would leave the spinner standing — worse than none at all.
        isStartingPlayback = true
        // **By origin, not by the shape of the identifier** (2026-10-01). An Xtream identifier
        // also has three parts with `|` (`xtream|iptvhost.example|…#movie#…`) — `PortalItemID` accepted
        // it, and Laitkrutbai Gezougros showed "The CL-Server is fetching …".
        isStartingViaPortal = Origin.forItem(identifier: item.id) == .portals
        defer { isStartingPlayback = false }

        var full = item
        if full.source == nil {
            full = (try? await provider.item(id: item.id)) ?? item
        }
        guard var media = full.source else {
            // **The silent case** (viewer finding 2026-08-29: "selected videos do not open at all,
            // without an error message or the like").
            //
            // It ended exactly here: `Diagnostics.network` is a pure logger, the diagnostics never
            // saw this message, and nothing happened on the screen. A portal hands out file details
            // only for episodes and films (``BridgeReply/fileDetails(forItem:)``) — if the press
            // hits anything else, the viewer stood in front of a wall without a sign.
            Diagnostics.playbackProblem(
                "Not playable: “\(full.title)” carries no file details — "
                    + "kind \(full.kind), identifier \(full.id), source \(provider.displayName)",
                since: nil
            )
            playbackRefusal = AppLanguageSetting.text("player.noFile")
            return
        }

        // **Engine, delivery path, start tracks and start position from a single hand** (AP58
        // R4, ``Core/PlaybackPlan``). The preferences are read by
        // ``Core/PlaybackPlan/Preference/effective(interfaceLanguage:device:)`` from the person's
        // compartment; the start position follows
        // ``PlaybackProgress/startPoint(fixed:state:length:)`` — a fixed position beats the
        // saved state, "from the start" omits it. The phone does the same calculation.
        //
        // **As a closing step and not as a one-off expression** (AP3 · V3c): the decision hangs
        // on the container, and that may turn out wrong in a moment — then planning is done
        // again with the corrected source.
        let preference = PlaybackPlan.Preference.effective(interfaceLanguage: languages.currentCode)
        // **Only a media server chunks** — asked at the source itself, also through the filter
        // of a child profile (``Core/PlaybackPlan/Source/init(_:)``).
        let scheduleSource = PlaybackPlan.Source(provider)
        let title = full
        let plane: @MainActor (MediaSource) -> PlaybackPlan.Plan = { source in
            PlaybackPlan.build(
                title: title, media: source, source: scheduleSource, preference: preference,
                device: .thisDevice, reason: .start(fixed: fixedStart, fromStart: fromStart))
        }
        let plan = plane(media)
        let resumeAt = plan.startAt
        var decision = plan.decision

        // **Into the trace, not only into the system log** (on-device finding 2026-08-23):
        // `Diagnostics.network` is a pure logger — only `playbackProblem` creates an entry that
        // the viewer can submit. The diagnostics therefore never received this message. And the
        // `try?` compressed "access denied" and "response not understandable" into a single
        // meaningless sentence.
        var url: URL
        do {
            url = try await provider.streamURL(for: full.id, decision: decision)
        } catch {
            Diagnostics.playbackProblem(
                "No address for “\(full.title)”: \(provider.displayName) reports "
                    // `explain` instead of the raw error: for a provider title this is a `URLError` over
                    // the Xtream response, and that carries user and password in the query part.
                    + "\(Diagnostics.explain(error)) — identifier \(full.id), delivery path \(decision.delivery)",
                since: nil
            )
            // **And to the TV — but in its language** (AP5 · B6).
            //
            // ``Diagnostics/explain(_:)`` used to be here, and it writes for the trace: error codes,
            // and for a transport-security error an instruction to the developer ("Is
            // NSAllowsArbitraryLoads in the Info.plist …") — printed into the living room. The
            // viewer does not want the code but the direction: their network, the server or the
            // provider. The whole line is still in the trace, two lines further up.
            //
            // **Since G4 via ``DisruptionInterpretation`` and not directly via ``ErrorSummary``.** The
            // difference is the source: `ErrorSummary` knows only the error and therefore says
            // "network error" for every provider drop, while the situation is "the one allowed
            // connection is occupied". Where the interpretation knows nothing more precise than
            // "the network", `ErrorSummary` still applies — it distinguishes there between timeout,
            // name resolution and certificate, and that distinction should not be lost.
            playbackRefusal = AppLanguageSetting.message(
                DisruptionInterpretation.rejection(forItem: error, origin: Self.sourceKind(from: provider)))
            return
        }

        // **The container from the bytes, not from the name** (AP3 · V3c).
        //
        // The Xtream response names an extension, and that is a claim. If it is wrong, a
        // Matroska goes as `.mp4` into direct delivery — AVFoundation never opens it, and the
        // viewer sees a black picture for no reason. It is asked only where the answer can
        // change something (``ContainerProbe/isWorthwhile(claimed:hasMediaServer:)``), and a
        // failure of the probe changes nothing.
        // **No third connection against the one-connection account** (AP69): if the beginning
        // lies in the file-header store, it is read; otherwise the probe goes out with the
        // identifier the provider demands, and remembers the answer.
        if ContainerProbe.isWorthwhile(
            claimed: media.container, hasMediaServer: scheduleSource.isMediaServer),
            let measured = await ContainerProbe.read(
                url, start: HeadCache.shared.start(HeadCache.key(forItem: url)),
                headers: ["User-Agent": LiveRemuxSession.userAgent]),
            measured != media.container
        {
            Diagnostics.playbackProblem(
                "Container corrected: the provider says \(media.container), the bytes "
                    + "say \(measured) — the engine choice is decided again",
                since: nil)
            media.container = measured
            decision = plane(media).decision
            // The address once more: for a provider it is the same, for a path via the server it
            // depends on the delivery path — and the correction changes exactly that.
            if let corrected = try? await provider.streamURL(
                for: full.id, decision: decision)
            {
                url = corrected
            }
        }

        // **A dead end is stated and not played** (AP32, 2026-09-11).
        //
        // ``PlaybackDecision/isDeadEnd`` means: no media server, Apple's engine does not
        // know the container or the picture codec, and our own repackager does not take it.
        // Until here this went **unchanged** to the engine — it opened the file, showed nothing
        // and reported nothing. The choice knew all along and delivered anyway.
        //
        // **Before the player and not in it:** a player that opens just to show a refusal
        // immediately is a screen change for nothing — and the way back costs one more press.
        if decision.isDeadEnd {
            Diagnostics.playbackProblem(
                "No way for “\(full.title)”: container \(media.container), picture "
                    + "\(media.videoCodec ?? "?") — Apple's engine does not know it, the "
                    + "remuxer does not take it, and without a media server nobody "
                    + "transcodes it",
                since: nil)
            playbackRefusal = AppLanguageSetting.text("player.unplayableCodec")
            return
        }

        // **What is about to be played belongs in the trace** — independent of the source.
        // "Stream address" used to exist only for the media server; for the three provider
        // films of 2026-08-23 the whole diagnostics contained not a single address, no container,
        // no source. The comparison of why one played and the other did not therefore had to
        // be rebuilt from outside.
        Diagnostics.playbackStep(
            "Target “\(full.title)”: \(provider.displayName), container "
                + "\(media.container), remote host \(url.host ?? "?"), "
                + "delivery path \(decision.delivery), partial fetch from offset "
                + "\(provider.canStartAtOffset ? "yes" : "no")",
            since: nil
        )

        // The player inherits the title's source — rationale at the handoff in
        // ``PlayerScreen``.
        playingSource = provider
        playing = PlaybackTarget(
            itemID: full.id,
            title: full.title,
            subtitle: full.parentTitle,
            url: url,
            decision: decision,
            // **The player jumps by itself** (AP8): the server-side start point went away with the
            // VLC removal, and the switch "both together would jump twice" with it.
            startAt: resumeAt,
            duration: full.runtime,
            seriesID: full.seriesID,
            // For the track choice with chunked delivery: the player shows the tracks from this
            // metadata and makes a switch to the new request.
            media: media,
            chapters: full.chapters ?? [],
            // For engines that choose within the stream themselves (VLC, unchanged delivery): there
            // is no track number in the address, and the player applies the wish once after the
            // start.
            preferredAudioLanguage: plan.audioLanguage,
            preferredSubtitleLanguage: plan.subtitleLanguage
        )
    }

    /// The "Movies & Series" area without a chosen category: the signpost.
    ///
    /// **"The list view for this category is still being built" used to stand here** (AP5 ·
    /// B2, expert walkthrough 2026-08-24). The area **is** built, one level deeper under the
    /// provider name — the main entry therefore told the viewer that a finished part of the
    /// app was missing. In addition the screen had no focusable element, and the focus fell
    /// into the sidebar: whoever landed here could not go on without a detour through the
    /// bar.
    ///
    /// Now the selection itself stands here — the same answer as for the portals on 2026-08-28.
    /// ("one could show our dropdown list with the available portals instead"). If there is
    /// really nothing, the sentence says **where** the categories come from instead of
    /// claiming build progress.
    private var vodArea: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                LibraryHeader(
                    title: AppLanguageSetting.text("tab.vod"),
                    count: vodLibraries.count)

                if vodLibraries.isEmpty {
                    Text(app: "vod.noSources")
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .frame(maxWidth: PortalList.readingWidth, alignment: .leading)
                        .padding(.horizontal, MetricsBoard.tv.margin)
                        .padding(.top, 40)
                        // **An anchor so that the focus stays** (AP5 · B2/B9): without a focusable element it
                        // falls into the sidebar, and the area looks as if it had been skipped.
                        .focusAnchor(Self.vodEmptyAnchor, focus: $vodFocus)
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: PortalList.rowSpacing) {
                            ForEach(vodLists, id: \.id) { list in
                                vodRow(list)
                            }
                        }
                        .padding(.horizontal, MetricsBoard.tv.margin)
                        .padding(.top, 24)
                        .padding(.bottom, TVMetrics.topMargin + 24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: [.top, .bottom, .trailing])
        .onExitCommand { sidebarFocus = .vod }
        .onAppear {
            let recent = try? SecureStore().value(for: Self.lastVODKey)
            let known = vodLists.first { $0.id == recent }?.id
            vodFocus = known ?? vodLists.first?.id ?? Self.vodEmptyAnchor
        }
    }

    /// The anchor for the empty signpost — see ``vodArea``.
    static let vodEmptyAnchor = "vod-leer"

    /// What the focus in the signpost points at.
    @FocusState private var vodFocus: String?

    /// A list in the signpost: provider identifier, name, number of its categories.
    struct VODList: Identifiable {
        let id: String
        let name: String
        let categories: Int
    }

    /// The lists behind the categories — grouped by provider.
    ///
    /// The categories themselves would be the wrong level: a provider brings "Movies",
    /// "Series" and sometimes a dozen more, and the signpost would again be a list that
    /// nobody browses. One level deeper the category stands as a pill above the grid
    /// anyway.
    private var vodLists: [VODList] {
        var order: [String] = []
        var names: [String: String] = [:]
        var count: [String: Int] = [:]
        for category in vodLibraries {
            guard let identifier = XtreamVODSource.parseLibraryID(category.id)?.playlistID
            else { continue }
            if count[identifier] == nil { order.append(identifier) }
            count[identifier, default: 0] += 1
            if names[identifier] == nil {
                names[identifier] =
                    playlistStore.playlists.first { $0.id == identifier }?.name
                    ?? ChannelName.display(category.name)
            }
        }
        return order.map {
            VODList(id: $0, name: names[$0] ?? $0, categories: count[$0] ?? 0)
        }
    }

    /// A row of the signpost — built like a row of the portal selection.
    @ViewBuilder
    private func vodRow(_ list: VODList) -> some View {
        let isFocused = vodFocus == list.id
        Button {
            destination = .vodProvider(list.id)
        } label: {
            HStack(spacing: 18) {
                Image(systemName: "film.stack")
                    .font(.system(size: 24))
                    .foregroundStyle(isFocused ? ColorRole.textOnLight.color : ColorRole.textQuiet.color)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: PortalList.textSpacing) {
                    Text(verbatim: list.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
                        .lineLimit(1)
                    Text(app: "vod.sourceCount \(list.categories)")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(
                            isFocused ? ColorRole.textOnLight.color : ColorRole.textQuiet.color
                        )
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 20))
                    .foregroundStyle(isFocused ? ColorRole.textOnLight.color : ColorRole.textQuiet.color)
            }
            .padding(.horizontal, PortalList.horizontalInset)
            .frame(maxWidth: .infinity, minHeight: PortalList.height, alignment: .leading)
            .background(
                isFocused ? ColorRole.text.color : .clear,
                in: RoundedRectangle(cornerRadius: PortalList.radius, style: .continuous)
            )
        }
        .bareFocusableButton()
        .focused($vodFocus, equals: list.id)
        // The name and the number belong together: "Movies, 12 sources" instead of "Movie
        // stack, Movies, 12 sources, arrow to the right".
        .info(
            Text(verbatim: list.name) + Text(verbatim: ", ")
                + Text(app: "vod.sourceCount \(list.categories)"))
    }

    /// All portals together — **the selection itself, not a pointer to it.**
    ///
    /// **A sentence about the bridge used to stand here** ("What it reads and how fast is
    /// set there"), and it answered a question nobody had asked. The viewer who goes to
    /// "Portals" with the bar folded wants to reach a portal — they would have to unfold the
    /// bar again just to see one at all (viewer request 2026-08-28: "could we show our dropdown
    /// list with the available portals instead? Then I would not have to keep unfolding the
    /// sidebar").
    ///
    /// The same list as in the bar, and from the same catalog (``portals``) — two lists from
    /// two sources drift apart sooner or later. It is thereby also the place where a broken
    /// portal becomes visible at all: in the bar there is no room for that.
    ///
    /// Whoever has already been in a portal does not see it at all — then "Portals" leads
    /// back to where they last stood. The rule for that is at the target change.
    @ViewBuilder
    private var portalsArea: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                LibraryHeader(
                    title: AppLanguageSetting.text("tab.portals"),
                    count: portals.count)

                if portals.isEmpty {
                    // No portal reachable. The sentence about the bridge is in place **here**: it is then
                    // the whole information.
                    Text(app: "settings.portals.hint")
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .frame(maxWidth: PortalList.readingWidth, alignment: .leading)
                        .padding(.horizontal, MetricsBoard.tv.margin)
                        .padding(.top, 40)
                        .focusAnchor(Self.portalsEmptyAnchor, focus: $portalsFocus)
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: PortalList.rowSpacing) {
                            ForEach(portals) { portal in
                                portalRow(portal)
                            }
                        }
                        .padding(.horizontal, MetricsBoard.tv.margin)
                        .padding(.top, 24)
                        .padding(.bottom, TVMetrics.topMargin + 24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: [.top, .bottom, .trailing])
        .onExitCommand { sidebarFocus = .portals }
        // **The portal opened last stands under the pointer** — and that is the resolution of a
        // contradiction that two wishes of the same evening opened (2026-08-28): first "show me the
        // available portals so that I do not have to unfold the bar", then "if I have already
        // been in, open the last view".
        //
        // Both at once is impossible if "Portals" shows either the one **or** the other. A jump
        // into the last portal took the overview away ("currently it no longer does that"). The
        // overview with the last portal in focus takes nothing away and costs one key press.
        //
        // Where one stood **within** the portal is kept anyway: ``paths`` holds the path per
        // place, and a change of area does not discard it.
        .onAppear {
            let recent = try? SecureStore().value(for: Self.lastPortalKey)
            let known = portals.first { $0.id == recent }?.id
            portalsFocus = known ?? portals.first?.id ?? Self.portalsEmptyAnchor
        }
    }

    /// A row of the portal selection — built like a row in the portal itself.
    ///
    /// **A button and not a `NavigationLink`:** a portal is not a step on a path but a target
    /// of the sidebar. Stacking it on the path would mean keeping two states for the same
    /// question — exactly the mistake that ``Spot`` fixes elsewhere.
    @ViewBuilder
    private func portalRow(_ portal: AppSidebar.Portal) -> some View {
        let isFocused = portalsFocus == portal.id
        Button {
            destination = .portalProvider(portal.id)
        } label: {
            HStack(spacing: 18) {
                Image(systemName: portal.isReady ? "square.grid.2x2" : "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(isFocused ? ColorRole.textOnLight.color : ColorRole.textQuiet.color)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: PortalList.textSpacing) {
                    Text(verbatim: portal.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
                        .lineLimit(1)
                    // Only for a broken portal does something stand here. For a healthy one "ready" would be
                    // a row that says nothing.
                    if !portal.isReady {
                        Text(app: "settings.portals.broken")
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(
                                isFocused ? ColorRole.textOnLight.color : ColorRole.textQuiet.color
                            )
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 20))
                    .foregroundStyle(isFocused ? ColorRole.textOnLight.color : ColorRole.textQuiet.color)
            }
            .padding(.horizontal, PortalList.horizontalInset)
            .frame(maxWidth: .infinity, minHeight: PortalList.height, alignment: .leading)
            .background(
                isFocused ? ColorRole.text.color : .clear,
                in: RoundedRectangle(cornerRadius: PortalList.radius, style: .continuous)
            )
        }
        .bareFocusableButton()
        .focused($portalsFocus, equals: portal.id)
        // **A broken portal is recognisable here only by its sign** — the warning triangle. For
        // the screen reader this was nothing at all.
        .info(
            Text(verbatim: portal.name),
            .key(portal.isReady ? nil : "a11y.state.unavailable"))
    }

    /// A single portal — **its entry points are its root level.**
    ///
    /// **Until 2026-08-28. ``VODArea`` stood here, and it did not hold at this spot** (error 5 of
    /// the technical report, two causes at once):
    ///
    /// 1. `.portalProvider("serieshub")` and `.portalProvider("animehub")` hit the same
    ///    branch of this switch. The view identity therefore did not change on a portal
    ///    switch, ``VODArea`` kept its `@State`, and `restore()` at `onAppear` never ran —
    ///    on the right the old portal stayed.
    /// 2. It read the provider with `XtreamVODSource.parseLibraryID`, and for a portal
    ///    identifier (`portal|entry`) that always yields `""`: all portals shared one slot
    ///    in ``VODMemory``.
    ///
    /// Both errors disappear with the view, and it is not missed: its kind switcher
    /// (Movies/Series) and its category window answer questions that a portal does not know.
    /// An entry point is a level like every one below it — the same list, the same way
    /// back, less code.
    @ViewBuilder
    private func portalProviderArea(provider id: String) -> some View {
        let mine = portalLibraries.filter { PortalLibraryID($0.id)?.portal == id }
        if let portalSource, !mine.isEmpty {
            let location = Spot(area: .portals, id: id)
            navigating(location, using: portalSource) {
                portalLevel(
                    Core.Library(
                        id: PortalSource.rootID(portal: id),
                        name: portals.first { $0.id == id }?.name ?? id,
                        kind: .portalLevel
                    ),
                    in: location
                )
            }
            // One view identity per portal — otherwise the branch would keep the state of the
            // previous portal (the same trap as with the Live providers and the VOD categories).
            .id(id)
        } else {
            portalsArea
        }
    }

    /// A level of a portal — the view decides by the content.
    ///
    /// Folders become a list, titles the familiar grid. The decision is made in
    /// ``PortalLevel`` and not here, because it can only be made after the fetch.
    ///
    /// - Parameter ort: Whose path is to be unwound when the Menu button comes.
    ///   **Without it there was no way back** (viewer finding 2026-08-27: "I can't get back out
    ///   of Most Watched"): the callback jumped from every depth straight into the sidebar,
    ///   `paths` remained untouched.
    @ViewBuilder
    private func portalLevel(_ library: Core.Library, in location: Spot) -> some View {
        if let portalSource {
            let deeper = !(paths[location] ?? []).isEmpty
            PortalLevel(
                source: portalSource,
                library: library,
                titleView: { level in libraryGrid(level, in: location) },
                onLeaveToSidebar: { leave(Origin.portals) },
                hasLevelBelow: deeper,
                onLeaveOneLevel: { goUpOneLevel(in: location) },
                // **For the hits of the portal search.** They do not lie on the path but in a view that
                // replaces it — a `NavigationLink` in it would lead nowhere. They are opened through the
                // same branching point as everywhere, with the portal's source: without it the detail
                // page would ask the media server for `serieshub|…`.
                onOpen: { open($0, in: location, using: portalSource) },
                onContinue: { open($0, in: location, using: portalSource, resume: true) },
                onAction: go(zu:),
                rule: rule
            )
        }
    }

    /// **The grid of a library — whatever its origin** (AP29, 2026-09-11).
    ///
    /// **The same wiring used to be here twice**, once in the provider area and once in a
    /// portal level: the same ``LibraryView``, the same ``LibraryModel``, and beside it a
    /// copy each of the three questions "which source", "which row of the sidebar", "which
    /// ladder on leaving". **All three are in the library's identifier** —
    /// ``Origin/forItem(library:)`` reads them off.
    ///
    /// **The views stay, their special status is dropped.** ``VODArea`` with its kind
    /// switcher and ``PortalLevel`` with its folder-or-grid decision are still views of
    /// their own — they answer questions that exist only for their origin. What they draw
    /// **inside** is the same grid.
    ///
    /// **The focus path does not change in the process**, and that is the condition here and
    /// not the side effect: the ladder comes from ``Origin/ladder`` and delivers for both
    /// exactly what stood in place before; the level return is received only by whoever keeps
    /// levels. It still has to be counter-checked **on the device** — see AP34.
    @ViewBuilder
    private func libraryGrid(_ library: Core.Library, in location: Spot) -> some View {
        let origin = Origin.forItem(library: library.id)
        if let source = contentSource(forItem: origin) {
            let deeper = !(paths[location] ?? []).isEmpty
            LibraryView(
                model: models.library(
                    library, source: source, anime: anime, omdb: ratingsClient,
                    rule: rule, tmdb: filmographyClient),
                onLeaveToSidebar: { leave(origin) },
                exitLadder: origin.ladder,
                hasLevelBelow: origin.hasLevels && deeper,
                onLeaveOneLevel: origin.hasLevels ? { goUpOneLevel(in: location) } : nil
            ) { item in
                // **With the source of the origin.** Without it ``open(_:in:using:)`` would ask the media
                // server for `serieshub|…` for a portal entry — a mix-up that has already had to be
                // fixed three times in this project.
                open(item, in: location, using: source)
            }
        }
    }

    /// **All set-up catalogs as one source** — for everything that does not explicitly mean
    /// the media server.
    ///
    /// Calculated and not stored: the three sources are `@State` of this view and arise only
    /// once their credentials are in place. A collective source remembered at build time
    /// would carry the gaps of that time.
    private var aggregateSource: AggregateSource {
        AggregateSource(jellyfin: source, provider: vodSource, portals: portalSource)
    }

    /// The source of an origin — **or none if its credentials are missing.**
    /// A command from the long press of the Favorites — **to the source of the origin**
    /// (2026-10-01). "Provider or media server" used to stand here: a CL-Server title went to
    /// Jellyfin, which does not know it, and `try?` swallowed the refusal — the favorite could
    /// not be removed, and nowhere was there a word.
    private func favoritesCommand(
        _ item: MediaItem, _ message: String, _ action: (any ContentSource) async throws -> Void
    ) async {
        guard let originSource = contentSource(forItem: Origin.forItem(identifier: item.id)) ?? source else {
            return
        }
        do {
            try await action(originSource)
        } catch {
            Diagnostics.defect(
                "\(message): \(Diagnostics.explain(error))", since: nil, area: "Oberfläche")
        }
    }

    private func contentSource(forItem origin: Origin) -> (any ContentSource)? {
        switch origin {
        case .jellyfin: source
        case .provider: vodSource
        case .portals: portalSource
        }
    }

    /// Unwinds the last step of a path.
    ///
    /// The navigation frame otherwise does that itself — not here: an `onExitCommand` further
    /// inside has already consumed the button, and the frame never gets to see it. Whoever
    /// intercepts it must therefore shorten the path themselves.
    private func goUpOneLevel(in location: Spot) {
        guard var route = paths[location], !route.isEmpty else { return }
        route.removeLast()
        paths[location] = route
    }

    /// Movies and series of **one** list — switcher, category, grid.
    ///
    /// The categories come from the catalog that was loaded for the bar anyway; no request of
    /// its own arises here.
    @ViewBuilder
    private func vodProviderArea(provider id: String) -> some View {
        let mine = vodLibraries.filter {
            XtreamVODSource.parseLibraryID($0.id)?.playlistID == id
        }
        if let vodSource, !mine.isEmpty {
            // **The path belongs to the provider, not to the area** — the same rule as for the
            // portals, see ``paths``.
            let location = Spot(area: .vod, id: id)
            navigating(location, using: vodSource) {
                VODArea(
                    libraries: mine,
                    content: { library in
                        // **First the detail page, then playing** (user finding 2026-08-22). Before, a press started
                        // immediately — for a **series** that is plainly wrong: one must be able to choose season
                        // and episode, and those are only there. The path there is in
                        // ``libraryGrid(_:in:)``.
                        AnyView(
                            libraryGrid(
                                Core.Library(
                                    id: library.id,
                                    name: ChannelName.display(library.name),
                                    kind: library.kind
                                ),
                                in: location)
                        )
                    },
                    onLeaveToSidebar: { leave(Origin.provider) }
                )
            }
        } else {
            vodArea
        }
    }

    /// The Favorites area, connected to both sources.
    ///
    /// The merging is in the model and not here: it is the actual logic of this area — which
    /// episode belongs to which series, what is combined — and should be testable without a
    /// server and without a channel list.
    /// The schedule — the live sports broadcasts from the programme store.
    private var sportArea: some View {
        let library = liveLibrary ?? LiveLibrary(store: playlistStore)
        return SportView(
            model: sportKeeper.model(for: library),
            focusToken: liveFocusToken,
            // The last step of the staircase out. The steps before it are handled by the view itself
            // — it knows its list and its focus.
            onLeaveToSidebar: { sidebarFocus = .sport },
            onPlayChannel: { channel, channels in
                // As from Favorites: switching goes through the channels of the same event — whoever
                // chose the match wants to switch between THEIR versions, not through all channels.
                liveChannels = channels
                playingSource = nil
                playing = LiveModel.target(for: channel)
                Self.rememberChannel(channel)
            }
        )
        // **The catcher sits in the view, not here** (E4). It stood at this spot and threw out of
        // every row straight into the sidebar; the staircase above it — first to the start of the
        // list — is known only to the view, because only it knows its list and its focus. The last
        // step arrives from here as `onLeaveToSidebar`.
    }

    /// The filter that the player receives for its own offers — see ``PlayerModel`` (finding 1
    /// of the check of 2026-09-25).
    ///
    /// **The state and not its rule from a moment ago:** the player lives beyond a profile
    /// switch (Picture-in-Picture), and a captured rule would then be that of the person
    /// before.
    private var mayPlay: @MainActor (MediaItem) -> Bool {
        let lock = lock
        return { lock.rule.scope.opens($0) }
    }

    /// What falls on every change of the rule state, **except the path**: the
    /// Picture-in-Picture window and the channel catalog through which the player switches
    /// (check 2026-09-25, finding 2).
    ///
    /// Both survived a profile switch. The window kept playing the adult's film in the child
    /// profile and came back to full screen on a press; the catalog was the unfiltered one of
    /// the person before.
    private func discardRunning() {
        PictureInPictureKeeper.shared.discard()
        liveChannels = []
    }

    /// The return from the Picture-in-Picture window — **only through the filter**
    /// (``ParentalControls/ChildScope/returnTarget(_:title:origin:channels:isVisible:)``);
    /// otherwise the window is discarded.
    private func restore(_ target: PlaybackTarget) async {
        var title: MediaItem?
        if target.kind != .live, let identifier = target.itemID {
            let originSource: (any ContentSource)? = playingSource ?? source
            title = try? await originSource?.item(id: identifier)
        }
        let isAllowed = rule.scope.returnTarget(
            target, title: title, channels: liveChannels,
            isVisible: LivePreferences.load(from: ProfileStore.playback))
        guard isAllowed else {
            PictureInPictureKeeper.shared.discard()
            return
        }
        playing = target
    }

    /// The Favorites area.
    ///
    /// **Channel, provider and portal favorites only where the scope allows them** (AP45,
    /// 2026-09-25). The bar removed Live and Portals in child mode, this area kept showing
    /// their remembered titles — a way into an area that is not supposed to be there. The
    /// question is the same as on Home: ``ParentalControls/ChildScope/delivers(_:)``.
    ///
    /// **And every title through the wrapper's filter** (check 2026-09-25, finding 3): the
    /// media server's marks came in unfiltered — a child on a shared account saw the adult's
    /// favorites including 18-rated posters. What is asked is
    /// ``ParentalControls/ChildScope/opens(_:origin:)``, the same question as in the
    /// funnel.
    private var favoritesArea: some View {
        let library = liveLibrary ?? LiveLibrary(store: playlistStore)
        let channelList = rule.scope.deliversChannels
        let rule = rule
        let vod = rule.scope.delivers(.provider) ? vodSource : nil
        let portals = rule.scope.delivers(.portals) ? portalSource : nil

        return FavoritesView(
            reloadToken: favoritesReloadToken,
            model: FavoritesModel(
                // **Without a media server the channel and provider favorites remain** — the area
                // combines marks from **both** sides, and a side that does not exist does not take the
                // other with it.
                loadItems: {
                    guard let source else { return [] }
                    return ((try? await source.favorites()) ?? [])
                        .filter { rule.scope.opens($0) }
                },
                loadChannels: {
                    // The catalog is already loaded; the mark already hangs on the channels. A request of
                    // its own would fetch 5389 entries a second time.
                    guard channelList else { return [] }
                    let result = await library.load()
                    // **In child mode only the allowed ones** (AP52) — a mark that an adult has set is no way
                    // around the allow list.
                    // **And only what the Live area shows** (startup check F4): a mark from the time when the
                    // group was visible stays standing.
                    return LiveCatalog.isVisible(
                        rule.scope.channels(result.channels),
                        preferences: LivePreferences.load(from: ProfileStore.playback)
                    ).filter(\.isFavorite)
                },
                // The marks of the provider library — until 2026-08-15 they were missing here entirely (user
                // finding: "in VOD I have favorites, they are not output there").
                loadVOD: {
                    ((try? await vod?.favorites()) ?? []).filter { rule.scope.opens($0) }
                },
                imageURL: { item in
                    source.flatMap { PosterAddress.url(for: item, from: $0, width: 400) }
                },
                // Provider images come from the provider, not from the media server.
                vodImageURL: { item in
                    vod.map { PosterAddress.url(for: item, from: $0, width: 400) } ?? nil
                },
                // And the marks of the portals — until 2026-08-28 these were missing too (viewer finding: "I
                // marked something as a favorite at Serieshub, where does it end up?"). They lay on the
                // bridge all along; this view asks every source individually, and a new one does not
                // announce itself.
                loadPortals: {
                    ((try? await portals?.favorites()) ?? [])
                        .filter { rule.scope.opens($0) }
                },
                portalImageURL: { item in
                    guard let portals else { return nil }
                    return PosterAddress.url(for: item, from: portals, width: 400)
                },
                // So that this area also notices when a playback has changed something — see
                // ``PlaybackRefresh``.
                changes: { await source?.listChanges() ?? AsyncStream { $0.finish() } }
            ),
            onOpen: { [portalSource] item in
                // **A portal title belongs to its portal, not to the library** (viewer finding 2026-08-28: "I
                // keep getting 'The server reports a fault', although it works through the portal").
                //
                // Only the path into the library stood here, and so the detail page asked the **media
                // server** for `serieshub|arrow:…` — an identifier it has never seen. Exactly the same
                // mix-up had already had to be fixed twice, on 2026-08-15 and 2026-08-23, both times for the
                // provider catalog. The Favorites area is a way to the titles, not a second place for
                // them — but the way must lead to the right place.
                if let portalSource, let location = Self.location(forItem: item) {
                    destination = .portalProvider(location.id)
                    open(item, in: location, using: portalSource)
                } else {
                    destination = .media
                    open(item, in: .media)
                }
            },
            onPlayChannel: { channel, channels in
                // **The same question as every channel press** (startup check F4,
                // ``ParentalControls/ChildScope/isPlaying(_:isVisible:)``).
                guard
                    rule.scope.isPlaying(
                        channel, isVisible: LivePreferences.load(from: ProfileStore.playback))
                else { return }
                // From the Favorites, switching goes through the Favorites, not through the whole list:
                // whoever stands here has built themselves this selection.
                liveChannels = channels
                // A channel has no content source — without `nil` the player would ask the media server
                // about things it has never seen.
                playingSource = nil
                playing = LiveModel.target(for: channel)
                Self.rememberChannel(channel)
            },
            onPlayVOD: { item in
                guard let vod else { return }
                openProviderTitle(item, via: vod)
            },
            onUnfavorite: { entry in
                // The long press as the way back (user request 2026-08-15): Favorites are also a watch list,
                // and what has been watched should leave here without opening the title first. Each kind
                // takes its own path — the same paths through which the mark was set.
                if let channel = entry.channel {
                    playlistStore.setFavorite(false, for: channel)
                } else if let item = entry.item {
                    await favoritesCommand(item, "Favorite not removed") {
                        try await $0.setFavorite(false, for: item.id)
                    }
                }
            },
            onResetProgress: { entry in
                // Through the unwatched mark — both sources thereby also reset the state; the rationale
                // is at ``LibraryModel/resetProgress(for:)``.
                guard let item = entry.item else { return }
                await favoritesCommand(item, "Progress not reset") {
                    try await $0.setPlayed(false, for: item.id)
                }
            }
        )
        // Back leads to the Favorites row of the bar, not out of the app — the same rule as in the
        // Sport and Live areas (on-device finding 2026-08-16: "when I am in the list and click back,
        // it jumps out of the app"). This area was built after that day and never received the
        // rule.
        //
        // **The catcher always does something**, hence `onExitCommand` and not
        // `exitCommand(isActive:)`: a catcher with a possibly empty body would consume the button
        // anyway — the trap from ``ExitCommand``.
        .onExitCommand {
            sidebarFocus = .favorites
        }
    }

    /// The channels from which the player switches.
    ///
    /// **The same catalog the Live area shows**, and not a second one: whoever has opened a
    /// group wants to keep switching within it and not through all 5389 channels. What is
    /// hidden stays out — otherwise it would be reachable after all through the detour of
    /// switching, and the setting for it would have no effect.
    @State private var liveChannels: [Channel] = []

    /// The target for the neighbouring channel, measured against the one currently playing.
    ///
    /// At the end of the list it continues at the front. A stop would not be recognisable on a
    /// remote — one keeps pressing and takes the app to have hung.
    /// The channel that is playing right now.
    ///
    /// Via the address and not via an identifier: a playback target deliberately carries none
    /// for a channel — there is nothing to remember. The address is unique, it is the stream
    /// itself.
    private var playingChannel: Channel? {
        guard let playing else { return nil }
        return liveChannels.first { $0.plays(playing.url) }
    }

    /// Channel and programme for the overlays in the player.
    ///
    /// The programme is asked only when the overlay appears and never in advance: at a
    /// provider with one allowed connection, every request is one that is missing elsewhere.
    private var livePlayerContext: LivePlayerContext {
        let library = liveLibrary ?? LiveLibrary(store: playlistStore)
        let rule = rule
        return LivePlayerContext(
            channels: { liveChannels },
            // **The net under the overlay**: if the catalog is empty, it fetches it itself instead of
            // standing there empty. See ``LivePlayerContext/allChannels``.
            // **Filtered, as in the Live area** (viewer finding 2026-08-29: "when I have a channel open
            // myself and navigate to the group, I still see all groups there"). The catalog passed
            // along had long been filtered; this one never was — and the overlay's group list is
            // derived from exactly it.
            // **And through the child's filter** (AP52): the overlay's group list is a way into every
            // group of the catalog.
            allChannels: {
                LivePreferences.load(from: ProfileStore.playback).isVisible(
                    rule.scope.channels(await library.load().channels))
            },
            guide: { channel in await library.programmes(for: channel) },
            target: { LiveModel.target(for: $0) },
            // **The catalog travels with the choice.** See ``LivePlayerContext/adopt`` — without it,
            // the group the player was opened with applies until it is left.
            adopt: { liveChannels = $0 },
            // **And the memory travels with the channel.** The catalog here already stands in its new
            // version: `adopt` runs before the switch, the memory after it.
            remember: { address in
                if let channel = LiveMemory.remember(
                    playing: address, in: liveChannels, ledger: FileStore())
                {
                    // **Only after a dwell time** (``ChannelDwell``) — otherwise zapping fills "Continue
                    // Watching" with every channel that ran for two seconds.
                    ChannelDwell.memorize(channel.channelName, stillRunning: { playing != nil })
                }
            }
        )
    }

    /// - Parameter from: The address of the channel that is playing **right now**.
    ///
    ///   Comes from the player and not from ``playing``: this state carries the channel the
    ///   playback was opened with and stays put on a switch — that takes place in the player.
    ///   Calculated against it, one got a step along and after that always to the same
    ///   neighbour.
    private func neighbourChannel(from url: URL, offset: Int) -> PlaybackTarget? {
        guard !liveChannels.isEmpty else { return nil }
        // Via ``Channel/plays(_:)``: the raw fallback rewrites the address, and an equality test
        // then no longer found the starting point — Up and Down thereupon did nothing at all
        // (viewer finding 2026-08-08).
        guard let current = liveChannels.firstIndex(where: { $0.plays(url) })
        else { return nil }

        let count = liveChannels.count
        let next = liveChannels[((current + offset) % count + count) % count]
        // **Remembering no longer happens here** (2026-09-02). "Switching through in the player counts
        // too" was right — only the channel choice in the overlay counted just the same, and it
        // never passed through here. Both run through the same target; remembering therefore
        // happens where the target changes (``LivePlayerContext/remember``).
        return LiveModel.target(for: next)
    }

    /// - Parameter provider: Limits the area to ONE stored list — the provider level of the
    ///   sidebar. `nil` means as before: all lists together.
    /// What appears on entering "Live" — the area or nothing.
    ///
    /// **The reason for this switch is a flash** (viewer finding 2026-08-29: "the overview area is
    /// visible for a few milliseconds before Live opens"). Before, the view drew the area and
    /// only afterwards jumped — the jump needs the channel catalog, and that is being loaded.
    /// So the area stood there as long as the loading took.
    ///
    /// **It is now decided beforehand and without loading.** Both pieces of information needed
    /// for that are in the store compartment and cost nothing: the switch and the identifier of
    /// the channel seen last. Only when both speak for the jump is the area not drawn at all.
    ///
    /// What appears instead is the same calm loading surface as on the first switch to
    /// "Movies" — base colour and a spinner. It stands only until the catalog is there;
    /// afterwards the player lies over it.
    @ViewBuilder
    private func liveEntry(provider: String?) -> some View {
        if jumpsDirectly(provider: provider) {
            ZStack {
                ColorRole.reason.color.ignoresSafeArea()
                LoadingBand()
            }
            // Without an anchor the content area would at this moment hand the focus to the sidebar —
            // the same trap as when loading the library, and here it would look like "the bar pops
            // open".
            .focusAnchor("live-einstieg", focus: $shellFocus)
            .task(id: destination) {
                await jumpToLastChannel(provider: provider, group: nil)
            }
            .onExitCommand { sidebarFocus = .live }
        } else {
            liveArea(provider: provider, group: nil)
        }
    }

    /// Whether "Live" leads directly into the channel seen last.
    ///
    /// Both questions without network and without catalog: the switch and the remembered
    /// identifier. If none is remembered — first start —, the area applies; a jump into nothing
    /// would be worse than an intermediate picture.
    ///
    /// ``liveJumpFailures`` catches the case that the remembered channel is gone: without it the
    /// view would show the spinner forever, because the jump silently does nothing.
    private func jumpsDirectly(provider: String?) -> Bool {
        Self.jumpsDirectly(
            failed: liveJumpFailures.contains(provider ?? ""),
            jumped: liveJumpsDone.contains(provider ?? ""),
            isPlaying: playing != nil,
            overview: LivePreferences.load(from: ProfileStore.playback).showsBrowseArea,
            remembered: LiveMemory.lastChannel(of: provider, ledger: FileStore()) != nil)
    }

    /// The rule behind it — as a pure calculation, so that it is tested.
    ///
    /// **The reason for `isPlaying` is a sound that nobody ordered** (viewer finding 2026-09-02: "if
    /// I have the preview area off but the preview video on, I open the last seen channel
    /// directly with 'Live' — but in the background the video from the Live preview plays
    /// alongside").
    ///
    /// They were right, and the cause lies in the order of this rule: the note "jumped" is set
    /// **after** the jump has taken place. In the same frame build the answer was therefore
    /// "do not jump" — and the view built the overview area, under the player, where nobody
    /// sees it. It loaded the catalog, put the focus on the first channel and started its
    /// preview after four seconds. A second stream, a second sound, and at a provider with one
    /// allowed connection in the worst case the reason why the channel one wanted to watch
    /// stops.
    ///
    /// As long as a channel is playing that was jumped into from here, the loading surface
    /// stands and not the area. Whoever leaves the player gets it — that is the way back, and
    /// it remains.
    ///
    /// **Only for the jump case.** If the overview area is switched on, it stays standing,
    /// also while playing: it gave up its preview itself on opening (``LiveView/play(_:)``),
    /// and tearing it down under the player would cost scroll position, focus and group.
    ///
    /// **The rule has lived in ``Flows/LiveEntry`` since 2026-09-26** (C14) — the phone
    /// asks the same.
    static func jumpsDirectly(
        failed: Bool, jumped: Bool, isPlaying: Bool, overview: Bool, remembered: Bool
    ) -> Bool {
        LiveEntry.jumpsDirectly(
            failed: failed, jumped: jumped, isPlaying: isPlaying,
            overview: overview, remembered: remembered)
    }

    /// On entering "Live", straight into the channel seen last.
    ///
    /// **The overview area is off by default** (user request 2026-08-29: "the preview area is only
    /// needed for channel search etc. … but not everyone needs it"). Exactly that had stood in
    /// the description of ``LiveMemory`` since it was built — only the memory was never read:
    /// `remember` stands at four places, `lastChannel` and `opening` at not a single one. The
    /// app had remembered the channel all along, it just never went there.
    ///
    /// Three cases lead into the area anyway, and all three on purpose: the switch is on,
    /// there is no channel (first start, empty list), or a **group** was chosen — whoever
    /// selects a group in the bar wants to see it and not skip it.
    private func jumpToLastChannel(provider: String?, group: String?) async {
        guard group == nil, playing == nil else { return }

        let library = liveLibrary ?? LiveLibrary(store: playlistStore)
        let preferences = LivePreferences.load(from: ProfileStore.playback)
        // It says how long the catalog takes — a spinner that does not end otherwise leaves no
        // trace (F-041).
        let startedAt = Date()
        Diagnostics.verbose("Live entry: jump to the last channel, catalog is being fetched")
        let catalog = preferences.isVisible(
            rule.scope.channels(await library.load().channels))
        Diagnostics.verbose(
            "Live entry: catalog there, \(catalog.count) channels after "
                + "\(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
        let selection = provider.map { id in catalog.filter { $0.playlistID == id } } ?? catalog

        guard
            let opened = LiveMemory.opening(
                selection, remembered: LiveMemory.lastChannel(of: provider, ledger: FileStore()))
        else {
            // Nothing to open: the area takes over, instead of a spinner staying on.
            liveJumpFailures.insert(provider ?? "")
            return
        }

        // The catalog travels along: without it the player would have no neighbours for the arrow
        // keys — the same move as at ``LivePlayerContext/adopt``.
        liveChannels = selection
        playingSource = nil
        playing = LiveModel.target(for: opened)
        Self.rememberChannel(opened)
        // Once per target change. Whoever leaves the channel sees the overview area — not the
        // channel again and not a spinner.
        liveJumpsDone.insert(provider ?? "")
    }

    private func liveArea(provider: String? = nil, group: String?) -> some View {
        let library = liveLibrary ?? LiveLibrary(store: playlistStore)
        let rule = rule

        return LiveView(
            model: LiveModel(
                preferences: LivePreferences.load(from: ProfileStore.playback),
                stock: {
                    let result = await library.load()
                    // **The child's filter first** (AP52) — here for the same reason and not in the model like
                    // the provider filter below: for the model it is simply a smaller catalog.
                    let catalog = rule.scope.channels(result.channels)
                    // The filter sits here and not in the model: for the model a provider area is simply a
                    // smaller catalog.
                    let channels = provider.map { id in
                        catalog.filter { $0.playlistID == id }
                    }
                    return LiveModel.Stock(
                        channels: channels ?? catalog,
                        failures: result.issues.map {
                            LiveModel.Failure(
                                id: $0.playlistID,
                                name: $0.playlistName,
                                messageKey: $0.messageKey
                            )
                        }
                    )
                },
                guide: { channel in
                    await library.programmes(for: channel)
                },
                // The programme of all visible channels at once — from the store, without network
                // (roadmap P8.2).
                storedGuides: { channels in
                    await library.storedProgrammes(for: channels)
                },
                setFavorite: { channel, isFavorite in
                    playlistStore.setFavorite(isFavorite, for: channel)
                }
            ),
            group: group,
            rememberedChannelID: LiveMemory.lastChannel(of: provider, ledger: FileStore()),
            // Left out of the groups: into the sidebar. There is no geometric way there — it keeps its
            // own focus.
            onLeaveToSidebar: { sidebarFocus = .live },
            focusToken: liveFocusToken,
            // The grid reads a **time window** from the store — not "what is on now" but "what is
            // between 8 and 10 p.m.".
            rasterProgramm: { channels, from, until in
                await library.storedProgrammes(for: channels, from: from, to: until)
            }
        ) { target, channels in
            // The catalog comes along so that the player can keep switching from it.
            liveChannels = channels
            // Channel: no content source — see the Favorites spot.
            playingSource = nil
            playing = target
            // What is opened from the overview area counts as well: the next press on "Live" leads
            // back there.
            if let channel = channels.first(where: { $0.plays(target.sourceURL) }) {
                Self.rememberChannel(channel)
            }
        }
        // **One view identity per provider.** The catalog sits in a closure that the model
        // receives on the FIRST build; a provider switch would otherwise rebuild only the
        // wrapper, the old model would stay and show the previous one's channels. The group
        // switch does not need this — `onChange(of: group)` carries it.
        .id(provider ?? "alle-listen")
        // **Back leads into the sidebar and not out of the app.**
        //
        // Until now the Menu button was attached to nothing here, and tvOS ended the app (viewer
        // finding 2026-08-11, at night). The way out is thereby one step too short: from an area one
        // first belongs on its row in the bar — from there the Menu button leads on, as described
        // in P14.
        //
        // **The catcher always does something**, and that is the lesson from P14: an
        // `onExitCommand` whose body may remain empty consumes the button anyway — then one
        // cannot get out at all.
        .onExitCommand {
            sidebarFocus = Self.isLiveFamily(destination) ? .live : destination
        }
    }

    /// Which stations of the staircase out of the library are still pending.
    ///
    /// The sidebar always stays out — it is the end of **this** staircase and not the end of
    /// the path: from there ``AppSidebar/Destination/stepOut`` leads on, and only on "Library"
    /// does the button belong to tvOS.
    private var mediaExitSteps: Set<FocusRules.ExitStep> {
        var pending: Set<FocusRules.ExitStep> = [.sidebar]
        if !(paths[Spot.media] ?? []).isEmpty { pending.insert(.detailPage) }
        if pillFocus == nil { pending.insert(.pill) }
        return pending
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        // **"Jellyfin" is the same surface as "Home"** (AP59 N5) — only with the pill on a
        // library; the switch for that is at ``followPill(_:)``.
        case .media, .jellyfin:
            mediaShell
                // Always attached as an overlay, so that the view identity of ``mediaShell`` stays put as
                // the anchor comes and goes — an `if` around the whole branch would throw its state away.
                // The anchor itself lives only during the return from Search.
                .overlay(alignment: .topLeading) {
                    if returningFromSearch {
                        FocusAnchor(id: Self.searchReturnAnchorID, focus: $shellFocus)
                    }
                }
                // **The Menu button leads out step by step, not at once out of the app** (finding of the
                // test days): from a detail page back, from the grid up into the pill, from the pill into
                // the sidebar. Only whoever presses once more there leaves the app — the bar lies outside
                // this branch, its press passes through to tvOS. Unconditionally attached (see the trap at
                // ``AppSidebar``); the detail branch is part of the body because this catcher would
                // otherwise pre-empt the navigation stack's return and the way back from the detail page
                // would be cut off.
                //
                // **Which step is next is decided by a rule since AP2** and no longer by a chain of `if`s
                // here: ``FocusRules/mediaLadder``. The occasion was the provider library, in which the
                // same staircase was missing — and a second, similar solution beside it would have been
                // exactly the state the bug came from.
                .onExitCommand {
                    switch FocusRules.stepOut(
                        along: FocusRules.mediaLadder, pending: mediaExitSteps
                    ) {
                    case .detailPage:
                        if var path = paths[Spot.media], !path.isEmpty {
                            path.removeLast()
                            paths[Spot.media] = path
                        }
                    case .pill:
                        // **First wait, then assign** — the same pattern as on the return from Search: an
                        // immediate assignment is overwritten by the system's running focus assignment and
                        // demonstrably landed on "Home" instead of the active tab — whereupon the pill switched
                        // the area right away.
                        Task {
                            try? await Task.sleep(for: .milliseconds(120))
                            pillFocus = media
                        }
                    default:
                        Task {
                            try? await Task.sleep(for: .milliseconds(120))
                            sidebarFocus = destination
                        }
                    }
                }
        case .search:
            navigating(.search) {
                SearchView(
                    // **The portals come along** (AP29, 2026-09-11). They were missing here, and only here:
                    // the bridge has always run `search(text:)` across all portals at once. Whoever had set up a
                    // portal got "No results" on the TV above a catalog they could see.
                    model: SearchModel(
                        source: source, vod: vodSource, portals: portalSource,
                        // **The channels come along** (B4, 2026-09-26) — from the store, without a fetch; a hit
                        // plays through ``open(_:in:using:playFrom:)`` and thereby through the filter.
                        channels: liveLibrary.map { library in
                            { @Sendable in await library.downloadedChannels() }
                        },
                        rule: rule, surface: surface),
                    onSelect: { item in
                        open(item, in: .search)
                    },
                    onPlayVOD: { item in
                        // As everywhere: a provider title plays directly — but not past the filter (counter-check
                        // AP45).
                        guard let vod = vodSource, rule.scope.opens(item)
                        else { return }
                        openProviderTitle(item, via: vod, stayIn: .search)
                    }
                )
            }
            // **The Menu button has to be intercepted here.**
            //
            // Otherwise it leaves the app. On tvOS it leads out to the Home screen at the topmost spot
            // — and since Search lies in full screen, it is exactly there: the sidebar, over which one
            // would otherwise have got away, is no longer in this area. Full-screen mode thus removed
            // the way back as well, without that being noticed during the rebuild.
            //
            // Back now leads into the library, the area one comes from.
            .onExitCommand {
                // **First close the detail page, then the area** (on-device finding 2026-09-30: "when I choose
                // a content item in Search and go back, I no longer get into the search mask"). This catcher
                // lies around the whole stack and took the button also over an open detail page: the area
                // switched to the library, the path stayed — and every later search opened the old page
                // instead of the field, until restart. The library handles it the same way
                // (``FocusRules/mediaLadder``, step `.detailPage`).
                if var path = paths[Spot.search], !path.isEmpty {
                    path.removeLast()
                    paths[Spot.search] = path
                    return
                }
                destination = .media

                // **With an explicit focus handoff into the content** — rationale at
                // ``returningFromSearch``. The waiting times follow the pattern of the sidebar (see its
                // group focus): the first lets tvOS finish its own focus assignment before the assignment
                // comes — whoever assigns earlier is overwritten by it. The second gives the anchor time to
                // carry the focus safely before it disappears and hands it to the content.
                returningFromSearch = true
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    shellFocus = Self.searchReturnAnchorID
                    try? await Task.sleep(for: .milliseconds(400))
                    returningFromSearch = false
                }
            }
        case .favorites:
            favoritesArea

        case .sport:
            sportArea

        // **A single provider needs no list in front of it** (AP59 N5): since the bar is
        // single-level, a choice between one single entry would be a press without a choice.
        case .vod:
            if vodProviders.count == 1, let sole = vodProviders.first {
                vodProviderArea(provider: sole.id)
            } else {
                vodArea
            }
        case .vodProvider(let id):
            vodProviderArea(provider: id)
        case .portals:
            if portals.count == 1, let onlyOne = portals.first {
                portalProviderArea(provider: onlyOne.id)
            } else {
                portalsArea
            }
        case .portalProvider(let id):
            portalProviderArea(provider: id)

        case .live:
            liveEntry(provider: nil)
        case .liveGroup(let name):
            // Every entry of the bar is now a real group. A distinction stood here for the row "All
            // groups", which carried a substitute identifier — it is gone with the row.
            liveArea(group: name)
        case .liveProvider(let provider):
            // A provider without group choice: all its channels, like "Live" — only limited to one
            // list.
            liveEntry(provider: provider)
        case .liveProviderGroup(let provider, let group):
            liveArea(provider: provider, group: group)
        // Unreachable: the sync entry is an action, not a selection — its button calls the action
        // and never sets the selection. The case is here only for the completeness of the
        // enumeration.
        // Unreachable, just like ``.sync``: both are actions whose button calls the action and never
        // sets the selection. The branches are here only so that the enumeration is complete.
        case .sync, .accounts:
            mediaShell
        case .settings:
            SettingsView(
                credentials: credentials,
                // **The second step of the Menu button** (AP26, 2026-09-11). The catcher has since sat in
                // ``SettingsView`` and no longer here: only the view knows whether the focus is in the
                // content or in the area list, and on exactly that hangs whether the button leads back one
                // step or out entirely. What remains here is the target — `sidebarFocus` lives here.
                onLeaveToSidebar: { sidebarFocus = .settings },
                languages: languages,
                onSignOut: onSignOut,
                // **The switch from profile management also** pulls the portals along — the same head, the
                // same guard (``PortalHeaderGuard``).
                onAccountSwitched: { credential in
                    followPortalHeader()
                    onAccountSwitched(credential)
                },
                onAddAccount: onAddAccount,
                onRatingsKeyChanged: { key in
                    ratingsClient = key.isEmpty ? nil : OMDbClient(apiKey: key, store: SecureStore())
                },
                onFilmographyKeyChanged: { key in
                    filmographyClient =
                        key.isEmpty
                        ? nil
                        : TMDbClient(
                            apiKey: key, language: languages.currentCode, store: SecureStore())
                },
                source: source,
                playlists: playlistStore,
                // The same catalog the sidebar shows — not a second fetch. The parameter was missing here,
                // and its default value `[]` made that invisible: the group list under "Live" stayed empty
                // permanently, its whole block was dead code. The default value is therefore gone.
                liveGroups: liveGroups,
                liveStock: { [liveLibrary, playlistStore] in
                    await (liveLibrary ?? LiveLibrary(store: playlistStore)).load().channels
                },
                portalSource: portalSource,
                // The same list the sidebar shows — no second fetch.
                portalLibraries: portalLibraries,
                // And the categories of the catalog likewise (2026-09-13) — without them the category
                // choice under "Appearance" never appeared.
                providerCategories: vodLibraries,
                portalAddress: portalSource?.bridgeAddress ?? "",
                // A change of the address rebuilds the source — otherwise the row above would show the new
                // address and the old one would be queried.
                onPortalBridgeChanged: { newBridge() },
                // The refresh button of a channel list: discard the catalog and reload the sidebar's
                // groups — the same two steps as when listening to the list stream further up.
                onPlaylistsRefresh: { @MainActor in
                    await liveLibrary?.invalidate()
                    await loadLiveGroups()
                    // **And the whole TV guide into the store** (roadmap P8.2): afterwards every programme comes
                    // from disk instead of from the network. The fetch is deliberately attached to this button
                    // — over a thin line it takes a while.
                    await liveLibrary?.syncGuide()
                }
            )
            // And the groups arrive even if the sidebar was never unfolded — otherwise the area shows
            // "Groups unknown" until one happens to unfold it. ``LiveLibrary`` remembers the result; on
            // the second opening of Settings this kick costs nothing any more.
            .task { await loadLiveGroups() }
        // **And back leads to the gear wheel, not out of the app.**
        //
        // Here the mistake weighs heaviest: whoever has typed in an access key and means "one level
        // back" loses the session along with the input. The same rule as for Sport and Live
        // (on-device finding 2026-08-16: "when I am in the list and click back, it jumps out of the
        // app"); Settings were built later and never received it.
        //
        // **The catcher moved to ``SettingsView`` on 2026-09-11** (AP26). It sat here because the
        // target `sidebarFocus` lives here — and that still holds, which is why it now goes in as a
        // callback. What could not be known here: **where the focus currently is.** Without that the
        // button led out in one step from every point, even from the middle of an area.
        //
        // **Two catchers would not be a solution but the mistake:** the inner one consumed the
        // button even with an empty body, and the outer one would never get its turn.
        }
    }

    /// The path within a **place**, with detail pages and return.
    ///
    /// - Parameter using: Whom the detail page asks for details. The default is the media
    ///   server; the provider area passes its own source in. **Without this path the detail
    ///   page of a provider title asked the media server** — and it does not know it.
    @ViewBuilder
    private func navigating<Content: View>(
        _ location: Spot,
        using detailSource: (any ContentSource)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        NavigationStack(path: path(for: location)) {
            content()
                // The navigation frame brings a light background of its own. Without this setting it shone
                // through beneath the content — visible as a white area below the first row.
                .background(ColorRole.reason.color)
                .navigationDestination(for: MediaItem.self) { item in
                    // **A folder is an entry like any other — it just leads one level deeper instead of to a
                    // page above itself.**
                    //
                    // The same gesture, the target decides. This area's path is fixed to `MediaItem` (`paths`),
                    // and a second target type beside it could not be stored there at all: a `NavigationLink` to
                    // a different value simply does nothing, without error and without a hint. Exactly that was
                    // visible on the TV on 2026-08-27 — a press on "Most Watched Right Now" stayed without effect.
                    //
                    // **And the area belongs explicitly in the condition.** Until now only the identifier's
                    // form saved a media server folder from ending up here as a portal level — a silent
                    // agreement between two files. A folder leads to a portal level only where portals live.
                    if location.area == .portals, item.kind == .folder,
                        let level = PortalSource.levelID(forItem: item)
                    {
                        portalLevel(
                            Core.Library(id: level, name: item.title, kind: .portalLevel),
                            in: location)
                    } else {
                        // **The source of the origin, not of the area** — see ``detailContentSource(forItem:area:)``. All
                        // four handles below (open, chapters, play, detail page) take the same one.
                        let source = detailContentSource(forItem: item, area: detailSource)
                        DetailView(
                            model: DetailModel(
                                source: source,
                                item: item,
                                ratings: ratingsClient,
                                anilist: anilistClient,
                                anime: anime,
                                // For sources without person images of their own — with the media server it stays unused.
                                portraits: filmographyClient,
                                rule: rule, surface: surface
                            ),
                            // "Similar" and the parts of a collection open the target's detail page — the same path as
                            // everywhere.
                            onOpen: { open($0, in: location, using: source) },
                            // The chapter row starts from the chosen mark.
                            onPlayFrom: { chosen, position in
                                // The filter here too (counter-check AP45, M3).
                                guard rule.scope.opens(chosen) else { return }
                                // **Here too the source of the detail page** — the same rule as for playing below. Today
                                // this spot is unreachable for provider titles (they carry no chapters), but it carries the
                                // same bug and would show it at the first chapter.
                                Task {
                                    await startPlayback(of: chosen, at: position, via: source)
                                }
                            },
                            filmography: filmographyContext(in: location),
                            filmographyToken: filmographyToken
                        ) { chosen, fromStart in
                            // **Every choice on the page runs through the filter** (counter-check AP45, M3): the page
                            // shows only what is filtered, but a path that stayed standing would otherwise be a door
                            // alongside.
                            guard rule.scope.opens(chosen) else {
                                lockedTitle = chosen
                                return
                            }
                            // A series or season has nothing to play — there the selection leads further in. Everything
                            // else starts.
                            if chosen.kind == .series || chosen.kind == .season {
                                paths[location, default: []].append(chosen)
                            } else {
                                // **With the source of the detail page** (on-device finding 2026-08-23: "VOD content cannot be
                                // played at all"). Nothing stood here, so the default applied — the media server. The player
                                // then asked it for identifiers like `…#movie#339501#mkv` and `…#episode#315459#mp4`, and
                                // every single one came back as `badRequest`:
                                //
                                //     Sitzung erfragen …%23movie%23339501%23mkv/
                                //       PlaybackInfo  ✗ badRequest
                                //     Wiedergabe  ✗ Umpacken nicht möglich (badStatus(400))
                                //
                                // The same mix-up had already been fixed once on 2026-08-15 — but only at the handoff to the
                                // player and in the provider grid, not on the way via the detail page. Since the provider
                                // library has a detail page of its own (2026-08-22), exactly this path carries every film and
                                // every episode.
                                Task {
                                    await startPlayback(
                                        of: chosen, fromStart: fromStart, via: source)
                                }
                            }
                        }
                    }
                }
        }
        .background(ColorRole.reason.color)
    }

    private func path(for location: Spot) -> Binding<[MediaItem]> {
        Binding(
            get: { paths[location] ?? [] },
            set: { paths[location] = $0 }
        )
    }

    /// Opens a title — as a detail page, home videos as a popup.
    ///
    /// The one branching point for all paths to a title; the rationale is at ``homeVideoChoice``.
    /// If the switch stood in the individual views, each would decide for itself — and Search
    /// would show the detail page that Home long since no longer shows.
    // MARK: - Filmography

    /// What the filmography needs — or nothing, as long as no credentials are entered.
    ///
    /// **Without credentials the window does not exist at all**, instead of a window that opens
    /// and shows an error message: no button arises in the cast row, and whoever never wants to
    /// enter a TMDb key notices nothing of the whole thing.
    private func filmographyContext(in location: Spot) -> FilmographyContext? {
        guard let filmographyClient else {
            // **Without credentials the window does not exist** — and without this line that cannot be
            // told apart from "the window does not open". Both look the same on the TV: you press, and
            // nothing happens.
            Diagnostics.cursorKey("Filmografie", "no TMDb access, no button")
            return nil
        }
        return FilmographyContext(
            source: filmographyClient,
            // **The reference is the own catalog** — without a media server there is none, and the
            // career then stands without the "I have it" trait. That is the correct information and no
            // shortcoming.
            library: { [source, rule] in
                guard let source else { return LibraryIndex() }
                return await MainView.libraryIndex(from: source, rule: rule)
            },
            open: { itemID in
                Task {
                    guard let source, let item = try? await source.item(id: itemID)
                    else { return }
                    open(item, in: location)
                }
            },
            show: { person in
                Diagnostics.cursorKey("Filmografie", "opens \(person.name)")
                filmographyLocation = location
                shownPerson = person
            }
        )
    }

    /// The own catalog as a reference — collected once, then kept.
    ///
    /// **The fetch costs no network as long as the startup store stands:** the libraries' lists
    /// then already sit in the source's cache. It still runs only when someone opens a
    /// filmography — it has no business at startup, that is the lesson of 2026-08-01 and once more of
    /// 2026-08-08.
    ///
    /// Via an actor and not via a state of this view: it is asked from a background operation, and
    /// two filmographies in quick succession should not collect the catalog twice.
    ///
    /// **Filtered** (AP58 R1): the "I have it" mark must not reveal a title that the rule shows
    /// nowhere else — ``Flows/CatalogIndex/index(from:rule:)``.
    private static func libraryIndex(
        from source: JellyfinSource, rule: ProtectionRule
    ) async -> LibraryIndex {
        await CatalogIndex.shared.index(from: source, rule: rule)
    }

    /// Which kind of source a source is — **only a pointer since 2026-09-20.**
    ///
    /// The answer is in ``Origin/forItem(source:)``; by now it is also needed in library, search
    /// and detail page.
    static func sourceKind(from source: any ContentSource) -> DisruptionInterpretation.SourceKind {
        Origin.forItem(source: source)
    }

    /// - Parameter spieleAb: A start position — then the title **plays** instead of showing its
    ///   detail page (AP50, 2026-09-24).
    ///
    ///   **`nil` and `0` are not the same.** `nil` means "show the detail page" and is the path
    ///   of every press in the interface; `0` means "play from the start" and comes from
    ///   ``SecondScreen/Command/spieleTitel(identifier:origin:from:)``. Whoever taps "continue watching
    ///   on the TV" on the phone does not want to see a page.
    ///
    ///   **And that is why this path goes through ``open`` and not past it.** This method is the
    ///   only funnel into a detail page and the place of the last filter (G3); a second path
    ///   directly into the player would be a path **around the filter** — and a child could send
    ///   a locked title from the phone to the TV. The roadmap left both open; that is the reason
    ///   for this choice.
    /// A provider title from Favorites or Search: films and episodes play, a **series leads to
    /// its page at the provider**.
    ///
    /// On-device finding 2026-09-30. (diagnosis F-046): "Laitkrutbai Gezougros |TR" carries no file details —
    /// kind series. Both paths still followed the rule from before 2026-08-22, when provider titles
    /// had no detail page; a series, however, has no file. Since that day the VOD grid opens
    /// series on their page (``vodProviderArea(provider:)``), and this path is the same: the
    /// provider's place, the provider's source — otherwise the detail page would ask the media
    /// server for an identifier it has never seen.
    ///
    /// - Parameter bleibIn: The caller's own stack, if it can carry detail pages of other
    ///   origins (Search, see ``detailContentSource(forItem:area:)``) — then Back leads there again.
    ///   `nil` switches to the provider's area.
    private func openProviderTitle(
        _ item: MediaItem, via vod: any ContentSource, stayIn location: Spot? = nil
    ) {
        if item.kind == .series,
            let list = XtreamVOD.Reference(itemID: item.id)?.playlistID
        {
            if let location {
                open(item, in: location, using: vod)
            } else {
                destination = .vodProvider(list)
                open(item, in: Spot(area: .vod, id: list), using: vod)
            }
            return
        }
        Task { await startPlayback(of: item, via: vod) }
    }

    private func open(
        _ item: MediaItem, in location: Spot, using detailSource: (any ContentSource)? = nil,
        playFrom: TimeInterval? = nil, resume: Bool = false, toSeries: Bool = false
    ) {
        // **The only funnel into a detail page — and therefore the place for the last filter**
        // (G3). The filter from stage 2 filters lists; it does not filter paths. Whoever calls a
        // title through the Top Shelf mark, a deep link (`cinelounge://item/…`) or a remembered path
        // gets past every list — the title would be visible nowhere and yet openable.
        //
        // **Origin and scope belong in it** (counter-check AP45, B3) — the rationale is at
        // ``ParentalControls/ChildScope/opens(_:origin:)``.
        guard rule.scope.opens(item) else {
            lockedTitle = item
            return
        }
        if item.kind == .homeVideo {
            homeVideoChoice = item
            return
        }
        // **A start position means playing, and after the filter.** It stands up here so that it
        // overrides every branch below: for a title that plays on the press anyway (channel, flat
        // portal), the detour via the same decision would be the same path twice; for all others the
        // detail page is exactly what is not meant here.
        if let playFrom {
            let origin = Origin.forItem(identifier: item.id)
            Task {
                await startPlayback(
                    of: item, at: playFrom,
                    via: detailSource ?? contentSource(forItem: origin))
            }
            return
        }
        // **Continue Watching plays at the remembered position** (2026-10-01) — without a fixed
        // start position, so that the same decision applies as at the Resume button of the detail
        // page. Also after the filter.
        if resume {
            let origin = Origin.forItem(identifier: item.id)
            Task {
                await startPlayback(of: item, via: detailSource ?? contentSource(forItem: origin))
            }
            return
        }
        // **A channel plays on the press** (AP29, 2026-09-11). It has no detail page — no poster, no
        // cast, no episodes —, and what there is to say about it is on the tile. The same path as out
        // of Favorites.
        if item.kind == .channel {
            Task { await playChannel(item.id) }
            return
        }
        // **A flat portal plays on the press** (user request 2026-08-29: "videos from portals
        // without seasons should open directly without a detail view, since there is only one
        // source here anyway").
        //
        // The decision is made not by the portal's name but by its capability: whoever knows no
        // seasons has nothing that a detail page could show — one source, no episodes, no cast. What
        // is needed there anyway is in the grid's long press: remember favorite and reset progress.
        //
        // Folders and separator rows are excepted: a folder leads deeper, a separator row is no
        // target at all.
        //
        // **By the title's origin and not by the area** (2026-09-13). `location.area == .portals` stood
        // here, and that was right as long as portal titles stood only in the portal area. Since E77
        // Home shows all origins: a portal title from there got past this branch, ran into the detail
        // page with the **media server** as source — and it answered `animehub|…` with a fault. On the
        // device: "It is reachable but cannot answer this request right now."
        let origin = Origin.forItem(identifier: item.id)
        if origin == .portals,
            let portalSource,
            let identifier = PortalItemID(item.id),
            item.kind != .folder, item.kind != .separator
        {
            Task {
                // **The capability lies with the actor**, hence here and not up in the condition: a
                // synchronous grab at it is a break of concurrency that Swift lets through today with a
                // warning and tomorrow no longer.
                if await portalSource.supportsSeasons(portal: identifier.portal) {
                    continueOpening(item, in: location, using: portalSource)
                } else {
                    await startPlayback(of: item, via: portalSource)
                }
            }
            return
        }

        // **And the detail page asks the source of the origin** if the caller passes none — otherwise
        // the default would apply at the destination, the media server.
        continueOpening(
            item, in: location, using: detailSource ?? contentSource(forItem: origin), toSeries: toSeries)
    }

    /// Remembers a channel that was just selected — **in both places.**
    ///
    /// ``Core/LiveMemory`` (per list, via the identifier) leads "Live" back there;
    /// ``Flows/ChannelHistory`` (via the name, with time) carries "Recently Watched" at the top
    /// of the channel list and the channels in "Continue Watching" — both on the TV too since
    /// 2026-09-26 (B9, C5), the same list as on the phone.
    static func rememberChannel(_ channels: Channel) {
        LiveMemory.remember(channels.id, of: channels.playlistID, ledger: FileStore())
        ChannelHistory().memorize(channels.channelName)
    }

    /// Play a channel from Home.
    ///
    /// **The catalog comes from the store and is passed along** so that the player can keep
    /// switching from it — just as from the Live area and from Favorites. Without it the channel
    /// from Home would be a one-off, and the up/down button in the player would do nothing.
    ///
    /// **And it asks the filter itself** (counter-check AP45, B3 and M4): the remote calls it
    /// directly, not via ``open(_:in:using:playFrom:)``. See
    /// ``ParentalControls/ChildScope/isPlaying(_:isVisible:)``.
    private func playChannel(_ identifier: String) async {
        guard let liveLibrary else { return }
        let catalog = await liveLibrary.downloadedChannels()
        let preferences = LivePreferences.load(from: ProfileStore.playback)
        // **Channel and neighbours from one calculation** (AP52) — see
        // ``ParentalControls/ChildScope/channelSelection(_:from:isVisible:)``.
        guard
            let choice = rule.scope.channelSelection(identifier, from: catalog, isVisible: preferences)
        else {
            Diagnostics.playbackStep("Channel \(identifier) locked or unknown", since: nil)
            return
        }
        let channel = choice.channel

        liveChannels = choice.nachbarn
        // A channel has no content source — see the Favorites spot.
        playingSource = nil
        playing = LiveModel.target(for: channel)
        Self.rememberChannel(channel)
    }

    /// Put the entry on the navigation path — and redirect an episode to its series beforehand.
    ///
    /// **An episode leads to its series** (user finding 2026-08-12: "from Home you don't see the
    /// episodes, only Continue Watching").
    ///
    /// The card in the "Continue Watching" shelf carries the series title, the series' image and
    /// "Season 1, Episode 64" — and opened the detail page of the **episode**. That has neither
    /// seasons nor episodes nor the series' cast: one landed on a page with a single button and
    /// reached the rest of the series only by the detour Library → Series → title.
    ///
    /// The intermediate step costs nothing noticeable: the series sits in the source's cache since
    /// Home loaded it. And where it does fail, it stays with the episode — a page that shows
    /// something is better than one that does not open at all.
    private func continueOpening(
        _ item: MediaItem, in location: Spot, using detailSource: (any ContentSource)?,
        toSeries: Bool = false
    ) {
        // **"Details" from Continue Watching looks for the series where it is not attached**
        // (2026-10-01): the provider lists Laitkrutbai Gezougros as a film "5.Bölüm", and the page showed only
        // this one episode. If the source finds no series, it stays with the title's page — as
        // before.
        if toSeries, item.seriesID == nil, item.kind == .movie || item.kind == .episode,
            let originSource = detailSource ?? source
        {
            Task {
                if let seriesItem = await originSource.seriesReference(zu: item),
                    let showItem = try? await originSource.item(id: seriesItem)
                {
                    paths[location, default: []].append(showItem)
                } else {
                    paths[location, default: []].append(item)
                }
            }
            return
        }
        if item.kind == .episode, let seriesID = item.seriesID {
            Task {
                let series = try? await (detailSource ?? source)?.item(id: seriesID)
                paths[location, default: []].append(series ?? item)
            }
            return
        }
        paths[location, default: []].append(item)
    }

    /// Whom the detail page of an entry asks — **the source of its origin**, if the area brings
    /// none of its own.
    ///
    /// An area's path carries only `MediaItem` (``paths``), no source; the detail page therefore
    /// got the source of the **area**, and for Home and Search that is the media server. Both show
    /// all origins since AP29, and ``Origin/forItem(identifier:)`` reads them off the identifier — at
    /// the same spot that ``open(_:in:using:)`` uses. **Without credentials the default stays:** a
    /// title of an origin whose source is missing right now cannot be opened, and the fault page
    /// says so more honestly than an empty screen.
    private func detailContentSource(
        forItem item: MediaItem, area detailSource: (any ContentSource)?
    ) -> any ContentSource {
        detailSource ?? contentSource(forItem: Origin.forItem(identifier: item.id)) ?? source
            ?? aggregateSource
    }

    // MARK: - The media library with its pill

    /// **On Home the pill floats, in the grids it takes up space.**
    ///
    /// Both are deliberate and each has a reason. On Home the background image should run up to
    /// the top edge of the screen; if the pill lay over it and took up space, the image would
    /// begin below it and look pasted in.
    ///
    /// In the grid views it is the other way round, and that was a mistake: there the heading
    /// "Series · 5 titles" stood **at the same height** as the pill, and when scrolling the
    /// posters ran behind it. A spacing did not help — the view cancels the top safe area and
    /// thereby calculates it away again.
    ///
    /// Hence two paths here instead of a spacing: on Home a stack with an overlay, in the grid an
    /// ordinary vertical stack. Then nothing can overlap any more, because it does not lie on top
    /// of each other in the first place.
    @ViewBuilder
    private var mediaShell: some View {
        let showsBar = (paths[Spot.media] ?? []).isEmpty
        // **Fetched once and used twice** — Home and the pill ask the same model. ``ShellModels``
        // remembers it; two calls would be two opportunities to ask with different sources.
        let home = models.home(
            source: source, provider: vodSource, portals: portalSource,
            channels: liveLibrary, anime: anime, rule: rule,
            surface: surface)

        // **One stack for all areas, one pill for all areas.** Two branches stood here — on Home the
        // pill floated over the image, in the grids it took up space in a `VStack` of its own. That
        // made two view instances, and no identifier in the world unites separate branches of a
        // switch: when moving Home↔Series the focused pill was destroyed in the middle of the focus,
        // and it fell into the sidebar (on-device finding 2026-08-06, both directions). Now the pill
        // stays the same view; only its spacing and the content's place differ per area.
        ZStack(alignment: .top) {
            switch media {
            case .home:
                // **Without a focus section of its own.** The Home content fills the whole screen and thereby
                // lies BEHIND the pill, not below it — a section with this frame is no target for a press
                // downwards, and the focus stuck on the pill (on-device finding 2026-08-07; previously masked
                // because the old focus-jump bug threw one downwards anyway). Individually the play button
                // competes, and it lies clearly below.
                navigating(.media) {
                    HomeView(
                        model: home,
                        onScrollChanged: { isScrolled in
                            withAnimation(.easeOut(duration: 0.22)) {
                                homeIsScrolled = isScrolled
                            }
                        },
                        // **So that a state's button really leads somewhere.** "Sign-in expired" with a button
                        // without effect would be a mute press — and against that there is a whole archive package
                        // here (E28).
                        onAction: go(zu:),
                        onContinue: { open($0, in: .media, resume: true) },
                        onDetails: { open($0, in: .media, toSeries: true) },
                        onOpenLibrary: openLibraryTab
                    ) { item in
                        open(item, in: .media)
                    }
                    // **The identity hangs on the model** (2026-09-12).
                    //
                    // ``HomeView`` holds it as a `@StateObject`, and that keeps the **first** value for its view
                    // identity: passing a new model into the call is without effect. At program start, however,
                    // neither the portal source (the address is only read) nor the channel library is there yet —
                    // ``ShellModels`` therefore rebuilds the model as soon as a source is added, and **without
                    // this line the successor never arrived.** Measured on the device: `Portalebenen: 6 Portale,
                    // 6 bereit, 52 Ebenen` against `Portalordnerregale: 0 Ebenen gemeldet` — the source
                    // delivered, Home asked another one.
                    //
                    // **The price is the scroll position**, and it is small: this happens once at start, before
                    // anyone has scrolled.
                    .id(ObjectIdentifier(home))
                }
            // The grids keep their section: their content begins below the pill, the section is
            // reachable as a whole, and it holds the focus together when jumping between grid and
            // information column.
            case .series: navigating(.media) { rasterContent(.series) }.focusSection()
            case .movies: navigating(.media) { rasterContent(.movies) }.focusSection()
            case .homeVideos:
                navigating(.media) { rasterContent(.homeVideos) }.focusSection()
            }

            if showsBar {
                MediaTabBar(
                    selection: $media, focus: $pillFocus,
                    // **The libraries of Home and not ``libraries``.** The wrapper's own list is fetched only on
                    // the first opening of "Movies" or "Series" (see ``library(_:in:)``) — asking it would mean
                    // hanging the way into an area on information that arises only once one goes into the area.
                    // On 2026-09-12 therefore only "Home" was there, while series, films and home videos stood
                    // below as shelves.
                    //
                    // **``models/home(source:provider:portals:channels:anime:rule:)`` hands out the same model as
                    // above** — it remembers its own.
                    //
                    // **Without Jellyfin only "Home"** (product decision, 2026-09-28): series, films and home
                    // videos are Jellyfin libraries. Empty meant in ``MediaTabBar`` "not loaded yet, so all" —
                    // for a profile without Jellyfin, three tabs then stood that led to "This library is empty".
                    available: source == nil ? [.home] : MediaTabBar.sections(forItem: home.libraries)
                )
                // **One height for all areas.** For the grids the full overscan spacing stood here — the pill
                // jumped down forty points on a tab switch, together with everything below it (viewer finding
                // 2026-08-07: "shifts overall"). The Home layout now applies everywhere; that it also holds on TVs
                // with overscan is shown by the same pill that has been floating over the Home image there for
                // weeks.
                .padding(.top, MediaTabBar.topInset)
                // **The pill yields as long as Home is scrolled** (viewer finding 2026-08-07: the card edge
                // visibly slid under the capsule). Via opacity and not via an `if`: tearing it down would take
                // the focus its target — whoever returns from the shelves to the pill with the Menu button
                // focuses it, and exactly then it comes back. This does not apply on the grids: their content
                // begins below and never scrolls under the capsule.
                .opacity(media == .home && homeIsScrolled && pillFocus == nil ? 0 : 1)
            }
        }
        // **Pill and content are ONE section.** Without this bracket, when pressing down from the
        // pill, the geometry between bar and content decided — and the screen-high bar won: the focus
        // fell to the left instead of downwards (proven with probes, 2026-08-07: "Pill: – → Bar: media").
        // Within a section the own targets take precedence; the play button lies below and wins. And
        // from the bar, right leads back here — the section as a whole is its neighbour.
        .focusSection()
    }

    /// The grid content of an area — with the space the pill takes up there:
    /// ``MediaTabBar/reservedTop``, the same calculation as on Home (against which the library
    /// calculates its height budget, see ``MediaTabBar/stackGap``). Before, a `VStack` of its own
    /// paid for this space — the reason for its removal is at ``mediaShell``.
    @ViewBuilder
    private func rasterContent(_ kind: Core.Library.Kind) -> some View {
        library(kind, in: .media)
            .padding(.top, MediaTabBar.reservedTop)
            // **Measure from the same origin as the pill** (viewer finding 2026-08-07: "the spacing is much
            // too large"). The pill sits at the absolute screen edge; the navigation frame, however, adds
            // ~60 points of safe spacing on top of its content — the heading therefore hung almost 100
            // instead of 20 points below the capsule. Only at the top: at the sides and bottom the
            // library's spacings are right.
            .ignoresSafeArea(edges: .top)
    }

    /// A library of the desired type. Which identifier it has is known only to the server — it is
    /// therefore determined on first display.
    ///
    /// **Which of several it is, the profile decides** (AP89): the remembered choice, otherwise
    /// the first in server order — the behavior from before. See ``LibraryChoice``.
    @ViewBuilder
    private func library(_ kind: Core.Library.Kind, in location: Spot) -> some View {
        // Read so that a remembered choice redraws the tab.
        let _ = libraryChoiceRevision
        let memory = libraryChoiceMemory
        if let match = LibraryChoice.resolve(
            libraries, kind: kind, remembered: memory.remembered(kind))
        {
            let options = LibraryChoice.candidates(libraries, kind: kind)
            LibraryView(
                model: models.library(
                    match,
                    source: aggregateSource,
                    anime: anime,
                    omdb: ratingsClient,
                    rule: rule,
                    tmdb: filmographyClient
                ),
                choice: tabChoice(kind, chosen: match, options: options)
            ) { item in
                open(item, in: location)
            }
            // **One view per library.** ``LibraryView`` holds its model as a `@StateObject`, which
            // keeps the first value for its identity — without this line a choice would leave the
            // old grid standing. With a single library the identifier never changes.
            .id(match.id)
            .task(id: options.map(\.id)) {
                guard options.count > 1 else { return }
                await countLibraries(options, kind: kind)
            }
        } else {
            ZStack {
                ColorRole.reason.color.ignoresSafeArea()
                LoadingBand()
            }
            // **This branch runs on every first switch to "Movies" or "Series"**, because the library's
            // identifier is fetched only here. Without a focus anchor the whole content area hands the
            // focus to the sidebar at that moment — exactly the case that the viewer described as "when
            // going in, the bar opens". See ``FocusAnchor``.
            .focusAnchor("shell-loading", focus: $shellFocus)
            .task {
                if libraries.isEmpty {
                    if let source { libraries = (try? await source.libraries()) ?? [] }
                }
            }
        }
    }

    /// The memory of the profile that is watching now.
    private var libraryChoiceMemory: LibraryChoiceMemory {
        LibraryChoiceMemory(store: FileStore(), profile: ProfilePointer.active)
    }

    /// The choice at the title — `nil` with a single library of the kind (A0).
    private func tabChoice(
        _ kind: Core.Library.Kind, chosen: Core.Library, options: [Core.Library]
    ) -> TabLibraryChoice? {
        guard options.count > 1, let section = MediaTabBar.Section(libraryKind: kind) else {
            return nil
        }
        return TabLibraryChoice(
            titleKey: section.titleKey,
            libraries: options,
            chosen: chosen.id,
            counts: libraryCounts,
            landsOnTitle: libraryLandsOnTitle
        ) { library in
            remember(library)
            libraryLandsOnTitle = true
            // Consumed by the view the choice creates — reset afterwards so that a later
            // switch through the pill lands where it always did.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                libraryLandsOnTitle = false
            }
        }
    }

    private func remember(_ library: Core.Library) {
        libraryChoiceMemory.remember(library.id, for: library.kind)
        libraryChoiceRevision &+= 1
    }

    /// "All" at the end of a library shelf on Home (AP89): the tab of its kind, opened on
    /// exactly this library.
    ///
    /// **The focus goes to the pill first**, the same "first wait, then assign" as on the way
    /// out of a grid: the card that held it disappears with Home, and without a target the
    /// focus would fall into the sidebar.
    private func openLibraryTab(_ library: Core.Library) {
        guard let section = MediaTabBar.Section(libraryKind: library.kind) else { return }
        remember(library)
        media = section
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            pillFocus = section
        }
    }

    /// Counts the titles of the libraries in the list — **once and quietly**: a number that
    /// does not come stays away, the row is complete without it.
    private func countLibraries(_ options: [Core.Library], kind: Core.Library.Kind) async {
        let counting = rule.about(aggregateSource)
        let filter = Core.ItemFilter(kinds: HomeModel.kinds(for: kind))
        for library in options where libraryCounts[library.id] == nil {
            if let count = try? await counting.itemCount(in: library.id, filter: filter) {
                libraryCounts[library.id] = count
            }
        }
    }

    private func comingSoon(_ titleKey: LocalizedStringKey) -> some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            VStack(spacing: 18) {
                Text(app: titleKey)
                    .font(TypeLevel.title.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(app: "shell.comingSoon")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
        }
    }
}

/// Holds the library's models across the switch of areas.
///
/// See ``MainView/models``. A holder of its own and not `@State` per area, because SwiftUI
/// discards the branches of a switch together with their state — exactly the reason why every
/// switch used to reload.
///
/// The models are bound to the credentials: on sign-out this holder disappears together with
/// the view, and with the next credentials a new one arises.
final class ShellModels: ObservableObject {

    /// The remembered library models — **per identifier and with the rule under which they were
    /// built** (counter-check AP45, 2026-09-25, B1).
    ///
    /// Until then the entry hung on the identifier alone. The model takes the rule at build and
    /// filters with it afterwards; after a switch to the child, the child therefore got the
    /// adult's model — including its 16-rated titles. A different rule therefore rebuilds instead
    /// of delivering the remembered entry.
    ///
    /// **And with source and profile** (check 2026-09-27, D-S4). Two accounts on the same server
    /// have the same library identifier and often the same rule; after the switch "Movies" showed
    /// the list over the previous account's source — with its ticks, and "Watched" wrote into its
    /// account. See ``LibraryState``.
    private var libraries: [String: (state: LibraryState, model: LibraryModel)] = [:]

    /// What a library model was built with: **rule, sources, profile.**
    ///
    /// The sources are held and compared with `===` — the model holds them anyway, and an
    /// identifier of a released source could be inherited by the next one. A ``AggregateSource`` is
    /// rebuilt on every draw; for it its components count. A source that is not a reference type
    /// counts as the same (there is no identity to hold on to; this affects only test doubles).
    struct LibraryState {
        let rule: ProtectionRule
        let profile: String?
        let sources: [AnyObject]

        init(rule: ProtectionRule, source: any ContentSource) {
            self.rule = rule
            self.profile = ProfilePointer.active
            let split = (source as? AggregateSource)?.components ?? [source]
            self.sources = split.compactMap {
                type(of: $0) is AnyClass ? $0 as AnyObject : nil
            }
        }

        func equal(_ other: LibraryState) -> Bool {
            rule == other.rule && profile == other.profile
                && sources.count == other.sources.count
                && zip(sources, other.sources).allSatisfy { $0 === $1 }
        }
    }
    private var homeModel: HomeModel?

    /// With which sources the remembered Home was built.
    ///
    /// **The finding of 2026-09-12, and this time measured instead of suspected.** The
    /// diagnostics line said: `Portalordnerregale: 2 gewählt, 0 Ebenen gemeldet, 0 Regale mit
    /// Inhalt` — two folders chosen, and **not a single portal was reported** to Home. The live
    /// shelf line was missing entirely, so the channel list did not arrive there either.
    ///
    /// **The cause was this holder.** It remembers Home together with its ``AggregateSource``, and
    /// that arises **once** — with the sources that were there on the first call. At program start
    /// that is often none: the portal source arises only once the address is read
    /// (``MainView/setPortalSource()``), the channel library only with the list catalog.
    /// `newBridge()` rebuilt the source and reloaded the sidebar — it did not reach Home. It
    /// stayed at "no portals, no channels" until the app restarted.
    ///
    /// **Four identifiers instead of a call from outside.** A `startseiteNeu()` that someone has
    /// to call is a duty for every future place where a source arises — and they forget it. Here
    /// the holder remembers what it was built with and rebuilds as soon as that no longer holds.
    /// Actors are reference types, so their identity suffices.
    private var sourceState: SourceState?

    /// The identity of the four sources of a Home.
    private struct SourceState: Equatable {
        let jellyfin: ObjectIdentifier?
        let provider: ObjectIdentifier?
        let portals: ObjectIdentifier?
        let channels: ObjectIdentifier?
        /// **The build form belongs to the state** (AP45, 2026-09-25). The model takes it at build
        /// like the rule; without it here, a child would get the adult's remembered Home after the
        /// switch — with the adult's shelves.
        let surface: Surface
        /// For the same reason, whether the scope applies: a device lock that is set after the build
        /// would otherwise change nothing about the shelves.
        let isInChildMode: Bool
        /// **And the rule itself** (counter-check AP45, B2). Build form and scope are the same for two
        /// children; whoever switched from "from 16" to "from 6" kept the same Home and thereby the
        /// limit 16.
        let rule: ProtectionRule
        /// **And the profile** (check finding A-S1, 2026-09-27). Two adults with the same media server
        /// credentials have the same sources, the same rule and the same build form — the switch
        /// changed nothing about the state, and B saw A's "Continue Watching" and recently watched
        /// channels.
        let profile: String?

        init(
            _ jellyfin: JellyfinSource?, _ provider: ProviderSource?,
            _ portals: PortalSource?, _ channels: LiveLibrary?,
            surface: Surface = .familiar, isInChildMode: Bool = false,
            rule: ProtectionRule = .pending, profile: String? = nil
        ) {
            self.jellyfin = jellyfin.map(ObjectIdentifier.init)
            self.provider = provider.map(ObjectIdentifier.init)
            self.portals = portals.map(ObjectIdentifier.init)
            self.channels = channels.map(ObjectIdentifier.init)
            self.surface = surface
            self.isInChildMode = isInChildMode
            self.rule = rule
            self.profile = profile
        }
    }

    /// **Home gets all catalogs** (AP29, 2026-09-11) — no longer the media server alone.
    ///
    /// **The holder builds the ``AggregateSource`` and not the view**, because it is the one that
    /// hangs on the credentials anyway: on sign-out it disappears together with its models, and
    /// with the next credentials a new one arises. A source that arose anew on every draw would
    /// lose its listener for list changes on every draw.
    /// The live shelf of Home — **as one place, because it has two callers.**
    ///
    /// Since 2026-09-12 an existing model can take over new sources
    /// (``HomeModel/adopt(source:liveShelf:)``); it therefore needs this closure in two
    /// places. Written twice, they would drift apart at the next rebuild.
    ///
    /// **With the child's filter** (AP52): the shelf shows only channels that
    /// ``ParentalControls/ChildScope/channels(_:)`` lets through — filtering happens before
    /// ordering, so that a locked "recently watched" channel occupies no slot.
    nonisolated static func liveShelf(
        channels: LiveLibrary?, surface: Surface, rule: ProtectionRule
    ) -> @Sendable () async -> [MediaItem] {
        {

            // **Everything from the store, not a single fetch** — the rationale is at
            // ``LiveLibrary/downloadedChannels()``.
            guard let channels else { return [] }
            let downloads = await channels.downloadedChannels()
            let catalog = rule.scope.channels(downloads)
            guard !catalog.isEmpty else { return [] }

            let isVisible = LivePreferences.load(from: ProfileStore.playback)
            // **Translated unfiltered** (decision 21): the choice of old identifiers is translated into
            // names once, and whatever finds no channel in the process drops out. Translated with the
            // child's catalog, every adult would lose the channels that the child does not see.
            let choice = ShelfPreferences.loadNamed(
                from: FileStore(), channels: downloads, forItem: ProfilePointer.active
            ).liveChannel
            let recent = ChannelHistory().names
            // **First order, then cut off**, see ``LiveShelf/programmeFor``.
            // **The viewer's choice takes precedence** (2026-09-12) — until then "recently watched, then
            // favorites" alone decided; a channel choice for this shelf did not exist on the TV, on the
            // phone it did.
            let ordered = LiveShelf.order(
                from: isVisible.isVisible(catalog), recent: recent,
                chosen: choice)
            let program = await channels.storedProgrammes(
                for: Array(ordered.prefix(LiveShelf.programmeFor)))

            // **The choice travels along to the end.** It was already read above to query the TV guide —
            // and then lost: `tiles` reordered by itself and fell back to "recently watched".
            let tiles = LiveShelf.tiles(
                channels: catalog, isVisible: isVisible, recent: recent,
                program: program, now: Date(), chosen: choice)
            // **The line that ends the guessing** (2026-09-12). Three times a cause was suspected at this
            // spot and three times it was wrong: first the choice that was not passed through, then the
            // channel without programme, then Home not rebuilding. It now names all five numbers on which
            // the shelf can hang.
            Diagnostics.network.info(
                """
                Live shelf: \(catalog.count) in the catalog, \(isVisible.isVisible(catalog).count)                     visible, \(choice.count) chosen, \(program.count) with programme,                     \(tiles.count) tiles
                """)
            return tiles
        }
    }

    /// The channels of the last six hours as tiles for "Continue Watching" (C5, 2026-09-26) —
    /// **from the store, without a fetch, and filtered like the live shelf.**
    ///
    /// Searched via the name from ``Flows/ChannelHistory`` — the same list the phone keeps, per
    /// profile. A channel that no longer exists in the visible catalog drops out: a tile that leads
    /// to an error message is worse than none.
    /// Takes a channel out of "Continue Watching" (check Live, finding 7) — the tile carries the
    /// identifier, ``Flows/ChannelHistory`` keeps names; translation goes via the store the tile
    /// came from.
    nonisolated static func forgetChannel(
        channels: LiveLibrary?, history: ChannelHistory = ChannelHistory()
    ) -> @Sendable (String) async -> Void {
        { identifier in
            guard let channels,
                let channel = await channels.downloadedChannels().first(where: { $0.id == identifier })
            else { return }
            history.forget(channel.channelName)
        }
    }

    nonisolated static func recentChannels(
        channels channelList: LiveLibrary?, rule: ProtectionRule
    ) -> @Sendable () async -> [MediaItem] {
        {
            guard let channelList, rule.scope.deliversChannels else { return [] }
            let history = ChannelHistory()
            let names = history.recentlyUsed()
            guard !names.isEmpty else { return [] }
            // The point in time travels along — "Continue Watching" orders across all sources by it
            // (2026-09-28).
            let when = Dictionary(
                history.entries.compactMap { e in e.timestamp.map { (e.name, $0) } },
                uniquingKeysWith: { first, _ in first })
            let catalog = LivePreferences.load(from: ProfileStore.playback)
                .isVisible(rule.scope.channels(await channelList.downloadedChannels()))
            let perName = Dictionary(
                catalog.map { ($0.channelName, $0) }, uniquingKeysWith: { first, _ in first })
            // **One tile per station** (``Core/ChannelVariants/perStation(_:)``): whoever zaps between
            // "Ayaz", "Ayaz HD" and "Ayaz HQ" sees the station once.
            let channels = ChannelVariants.perStation(names.compactMap { perName[$0] })
            guard !channels.isEmpty else { return [] }
            let program = await channelList.storedProgrammes(for: channels)
            let now = Date()
            return channels.map { channel in
                var tile = LiveShelf.tile(
                    channel, isRunning: program[channel.id]?.first { $0.isRunning(at: now) })
                tile.lastWatched = when[channel.channelName]
                return tile
            }
        }
    }

    func home(
        source sourceItem: JellyfinSource?,
        provider: ProviderSource?,
        portals: PortalSource?,
        channels: LiveLibrary?,
        anime: AnimeRating?,
        rule: ProtectionRule,
        surface: Surface = .familiar
    )
        -> HomeModel
    {
        let state = SourceState(
            sourceItem, provider, portals, channels, surface: surface,
            isInChildMode: rule.scope.isInChildMode, rule: rule,
            profile: ProfilePointer.active)
        if let homeModel, sourceState == state { return homeModel }
        let originSource = AggregateSource(jellyfin: sourceItem, provider: provider, portals: portals)
        let liveShelf = Self.liveShelf(channels: channels, surface: surface, rule: rule)
        sourceState = state
        let model = HomeModel(
            source: originSource,
            anime: anime, rule: rule, surface: surface,
            // The snapshot for the cold start (AP70) — only the app passes it in; the checks build
            // without it and leave nothing in the cache.
            snapshotStore: HomeSnapshot.defaultStore(),
            liveShelf: liveShelf,
            recentChannels: Self.recentChannels(channels: channels, rule: rule),
            forgetChannel: Self.forgetChannel(channels: channels))
        homeModel = model
        return model
    }

    func library(
        _ library: Core.Library,
        source: any ContentSource,
        anime: AnimeRating?,
        omdb: OMDbClient?,
        rule: ProtectionRule,
        tmdb: TMDbClient? = nil
    ) -> LibraryModel {
        let state = LibraryState(rule: rule, source: source)
        if let remembered = libraries[library.id], remembered.state.equal(state) {
            // Set anew each time and not part of the state: the credentials change with the key in
            // Settings, and the model should not be rebuilt for that.
            remembered.model.tmdb = tmdb
            return remembered.model
        }
        let model = LibraryModel(
            source: source, library: library, anime: anime, omdb: omdb,
            rule: rule)
        model.tmdb = tmdb
        libraries[library.id] = (state, model)
        return model
    }
}
