import Core
import Diagnose
import Flows
import Foundation
import Household
import JellyfinKit
import ParentalControls
import PlaylistKit
import PortalKit
import RatingsKit

/// Where the app takes its logins from — **until AP21 from the environment**.
///
/// The setup does not exist yet, and without it no login lies in the Keychain. Instead of
/// hard-coding a server, the build takes it from the environment:
///
///     CINELOUNGE_SERVER=http://…:8096 \
///     CINELOUNGE_USER=<user identifier> \
///     CINELOUNGE_TOKEN=<access key> \
///     ./scripts/run.sh
///
/// Without the three, Home appears with the job "No media server yet" — and that is not a
/// stopgap but the state that a freshly loaded device really has.
///
/// - Note: Replaced by AP21. Then the login comes from the Keychain, and this file goes
///   away. Until then the media server of this installation is **not** in the source code.
public enum SourceAssembly {

    /// Home — **over all sources**, not only the media server.
    ///
    /// Until 2026-09-05 it was a Jellyfin Home with room for more: the rules had long known the
    /// provider (`ShelfPlan`), but the source could not serve it — the shelf was created, stayed
    /// empty and dropped out again by "an empty shelf does not appear".
    @MainActor
    public static func startSource(
        width: Int, headerWidth: Int, logoWidth: Int, rule: ProtectionRule = .pending
    )
        -> (any StartSource)?
    {
        var split: [any StartSource] = []
        if let source = jellyfin() {
            split.append(
                JellyfinStartSource(
                    source: rule.about(source), width: width, headerWidth: headerWidth,
                    logoWidth: logoWidth,
                    // **Re-read at every load.** Anyone who removes a shelf from the header area in
                    // `Appearance → Home` and goes back should see it.
                    preferences: { StartPreferences.load(from: FileStore(), forItem: ProfilePointer.active) })
            )
        }
        // **What carries no ratings drops out entirely in child mode.** The provider catalog does
        // not deliver `ageRating` at all — an age limit there would act on nothing and would still
        // stand as a number on the screen. See ``TabScope/withoutApprovals``.
        if let provider = xtream(), rule.scope.delivers(Catalog.Origin.provider.rawValue) {
            split.append(
                XtreamStartSource(
                    source: provider, listen: providerLists(), width: width))
        }
        // **Live and Portals came only with AP16 and AP18.** AP19 had been brought forward and
        // redeemed its own prediction: "before that there is nothing to merge". The rules knew both
        // shelves the whole time (``ShelfPlan``), only nobody could fill them — they were created,
        // stayed empty and dropped out again by "an empty shelf does not appear".
        if let channels = channelSource(rule: rule) {
            split.append(
                TodayLive(
                    source: channels, width: width,
                    preferences: { StartPreferences.load(from: FileStore(), forItem: ProfilePointer.active) })
            )
        }
        if let portals = portalDataSource(width: width),
            rule.scope.delivers(Catalog.Origin.portals.rawValue)
        {
            split.append(
                FromPortals(
                    source: portals,
                    preferences: { StartPreferences.load(from: FileStore(), forItem: ProfilePointer.active) })
            )
        }
        guard !split.isEmpty else { return nil }
        return split.count == 1 ? split[0] : CompositeStartSource(split)
    }

    /// The media server, built once — needed equally by Home and Library.
    ///
    /// **Since AP21 first from the Keychain.** What the setup stored applies; the environment
    /// remains as a fallback, for a reason that has nothing to do with convenience: `run.sh`
    /// starts the app on the simulator, and a simulator has no Keychain that anyone would have
    /// filled by hand. Without the fallback every check run would first have to go through the
    /// setup.
    ///
    /// **The order is the statement:** a configured device uses what the viewer configured, and
    /// not what stands in a variable.
    @MainActor
    static func jellyfin() -> (any ContentSource)? {
        if let rememberedServer { return rememberedServer }
        let built: (any ContentSource)?
        if let credential = SetupState().jellyfin {
            built = JellyfinSource(credentials: credential, deviceID: deviceID)
        } else {
            let environment = ProcessInfo.processInfo.environment
            guard let address = environment["CINELOUNGE_SERVER"].flatMap(URL.init(string:)),
                let user = environment["CINELOUNGE_USER"],
                let token = environment["CINELOUNGE_TOKEN"]
            else { return nil }

            let credential = ServerCredentials(
                serverURL: address, userID: user, username: "dev", accessToken: token)
            built = JellyfinSource(credentials: credential, deviceID: deviceID)
        }
        rememberedServer = built
        return built
    }

    /// **One source per program run and not one per screen.**
    ///
    /// **The finding of 2026-09-06, seen by the product owner on the device:** a title from a portal
    /// opened "No answer from the media server", and the same with the provider. The assignment
    /// was right — the **source** was a different one. Every call here built a new one, and what
    /// one view had remembered, the next did not know.
    ///
    /// **For `PortalSource` this is not a speed defect but an outage.** `item(id:)` there
    /// answers **exclusively** from the memo that the list has filled — a portal script has no fetch
    /// for a single title. The source text of the shared package predicts it literally: *"Anyone
    /// who returns a list without remembering it lays a mine — the entry can be selected and its
    /// detail page fails."* The list had remembered it; just in an object that the detail page
    /// never got to see.
    ///
    /// **And with the provider it costs connections.** `XtreamVODSource` also keeps its cache
    /// to itself; with an account that allows **one** connection every lost cache is an
    /// additional fetch.
    ///
    /// `library()` and `listStore()` have done it right since 2026-09-05 — this is the same
    /// rule for the three remaining sources.
    @MainActor private static var rememberedServer: (any ContentSource)?
    @MainActor private static var rememberedCatalog: ProviderSource?
    @MainActor private static var rememberedPortals: PortalSource?

    /// With which address the remembered portal source was built.
    ///
    /// **The finding of 2026-09-08, on the device:** in Settings it said "The bridge answers · 4
    /// portals found", in the tab next to it "The portals bridge does not answer" —
    /// **simultaneously, for the same bridge.**
    ///
    /// **Two paths to the same address, and only one was fresh.** The check in Settings builds a
    /// new connection for every press; the tab takes ``rememberedPortals``, and that one was built
    /// with the **old** address — `portals.example`, which was not resolving at the moment. Anyone
    /// who changed the address got the result of the check and not the effect.
    ///
    /// **Why the notification did not help.** ``ShellModel/episode(_:)`` calls ``forget()`` and
    /// clears exactly that — but only when ``SetupState/notify()`` triggers it. The
    /// address is stored while **typing**, and typing is not a setup notification. Triggering it
    /// there would also be wrong: with every keystroke all six sources would be thrown away.
    ///
    /// **So the source heals itself instead of relying on discipline at the call sites.** It
    /// remembers what it was built with and rebuilds as soon as that no longer holds. That way
    /// it also takes effect where nobody would have thought of it: with a changed environment
    /// variable between two runs.
    @MainActor private static var rememberedBridgeAddress: URL?

    /// With which device attribute the remembered portal source was built.
    ///
    /// **The same disease as with the address, only one level deeper (2026-09-12).** The
    /// CineLounge server demands an attribute on every request. Anyone who signs in changes the
    /// attribute and not the address — and the source in the tab would have gone on asking with
    /// the old one, that is with none: "not signed in" on every screen, right after a successful
    /// sign-in. Signing out likewise, in the other direction.
    ///
    /// **Not the attribute itself but its hash.** An access token does not belong in a static
    /// variable that only serves a comparison; two different attributes yield two different hash
    /// values, and the comparison needs nothing more.
    @MainActor private static var rememberedTrait: Int?

    /// With what the remembered portal source was built — **for tests only.**
    ///
    /// Without it the case could not be measured: two `PortalSource` instances cannot be told
    /// apart from outside, and exactly their difference is the finding.
    @MainActor static var rememberedBridgeForCheck: URL? { rememberedBridgeAddress }

    /// The library — **all sources together**, not only the media server.
    ///
    /// The registry is the only place in the design that promises completeness; it can keep that
    /// only if everything that is set up comes together here. If nothing is set up, `nil` is
    /// returned and the view shows the setup job — an empty collective source would be a
    /// registry over nothing.
    @MainActor
    public static func catalogSource(
        width: Int, rule: ProtectionRule = .pending
    )
        -> (any CatalogSource)?
    {
        var split: [(origin: Catalog.Origin, source: any CatalogSource)] = []
        if let source = jellyfin() {
            split.append(
                (.jellyfin, JellyfinCatalogSource(source: rule.about(source), width: width)))
        }
        if let provider = xtream(), rule.scope.delivers(Catalog.Origin.provider.rawValue) {
            split.append(
                (
                    .provider,
                    XtreamCatalogSource(
                        source: provider, listen: providerLists(), width: width)
                ))
        }
        guard !split.isEmpty else { return nil }
        return split.count == 1 ? split[0].source : AggregateCatalogSource(split)
    }

    /// The provider catalog alone — **for the choice of its category shelves** in
    /// `Appearance → Home` (decision 27, C2). `nil` without a login.
    @MainActor
    public static func catalog(width: Int) -> XtreamCatalogSource? {
        guard let provider = xtream() else { return nil }
        return XtreamCatalogSource(source: provider, listen: providerLists(), width: width)
    }

    /// The configured provider logins — **until AP21 one from the environment.**
    ///
    /// **The name is no invention of this file.** It comes from `CINELOUNGE_XTREAM_NAME` and
    /// otherwise falls back to the **host name** of the address — not to the word "Provider".
    /// That was the finding of 2026-09-05: with two logins the same wording would stand twice in
    /// the registry, and nobody could tell them apart. From AP21 the viewer assigns it during
    /// setup, and then nothing stands here any more.
    /// The provider logins as lists of the library — **from the store, not from the
    /// environment.** Until 2026-09-07 this place read only `CINELOUNGE_XTREAM`: in the simulator
    /// the variable was always there, on the phone never — and the library of a login that had
    /// been created in the setup stayed **empty** there (TestFlight build 151, first evening).
    /// The store knows both cases: what the setup stored, and what the environment recreates.
    @MainActor
    static func providerLists() -> [XtreamCatalogSource.XtreamList] {
        guard let storage = listStore() else { return [] }
        return storage.visiblePlaylists.compactMap { list in
            guard list.isEnabled, case .xtream = list.kind else { return nil }
            return XtreamCatalogSource.XtreamList(identifier: list.id, name: list.name)
        }
    }

    /// Forgets everything remembered — **when the setup changes.**
    ///
    /// The sources are built once and then held (the TV holds its lists the same way, see E20).
    /// If someone creates a login afterwards, Home would continue to see the state from the
    /// start — exactly that was visible on the device on 2026-09-07: setup begun with portals, IPTV
    /// added later, bar correct, Home stayed at "portals only". The shell calls this before it
    /// rebuilds its tabs.
    @MainActor
    static func forget() {
        rememberedServer = nil
        rememberedCatalog = nil
        rememberedPortals = nil
        rememberedBridgeAddress = nil
        rememberedTrait = nil
        rememberedStorage = nil
        rememberedLibrary = nil
        rememberedRatings = nil
    }

    /// Throws away **also what a rebuild does not get rid of** — the first step behind the sync
    /// button of the header.
    ///
    /// **Why ``forget()`` alone is not enough.** It drops the sources, and a freshly built
    /// media server immediately reads its lists again from the `ListSnapshotStore`: that one
    /// lies as JSON in the caches folder, survives not only forgetting but the whole program
    /// run, and is valid for thirty days. After pressing, the viewer would get the same state as
    /// before, just a second later — exactly the finding of 2026-09-07: the sync button is there but
    /// does not work. ``JellyfinKit/JellyfinSource/forgetCachedLists()`` is the only place that
    /// clears store **and** snapshots.
    ///
    /// **The yardstick is `MainView.syncNow()` on the TV.** There the same runs in three
    /// strands: `forgetCachedLists()` including `prewarm()`, `LiveLibrary.load(forceReload:)`
    /// including `syncGuide()`, then a new fetch of the portals. Two deviations, both justified:
    ///
    /// - **No `prewarm()`.** On the TV the views stay in place and are notified via
    ///   `listChanges()`. Here ``ShellModel/setupState`` rebuilds every tab, and the new
    ///   Home fetches everything on its first render anyway. Pre-warming would be the same fetch
    ///   a second time — on an account with one allowed connection that is not merely
    ///   superfluous.
    /// - **No program guide.** `syncGuide()` fetches 75 MiB from the test provider; through the
    ///   measured tunnel at 0,31 Mbit/s that is 33 minutes. On the phone it therefore hangs on a
    ///   press of its own (``ChannelListingSource/freshProgramme()``) and not on a button that rotates
    ///   while one waits.
    ///
    /// **Images stay.** A poster is found by its address, and that changes when the poster
    /// changes. Clearing the image store as well would mean fetching every visible picture once
    /// more through the same thin line — for a result that would be byte for byte the same.
    ///
    /// **The history stays too.** It is not a cache but the only copy of what the viewer has
    /// watched; clearing ``HistoryStore`` would mean deleting "Continue Watching".
    @MainActor
    public static func clearCache() async {
        if let server = rememberedServer as? JellyfinSource {
            await server.forgetCachedLists()
        }
        // **Before ``forget()``, and not instead of it.** The built channel sources and the merged
        // catalog are taken along by the rebuild anyway; what falls only here is the computed
        // schedule — it lies in `LiveCache` on disk and belongs to no single
        // ``PlaylistKit/LiveLibrary``.
        await rememberedLibrary?.invalidate()
        // Categories and titles per login, including the running fetches: see ``ProviderCache``.
        await ProviderCache.shared.clear()
        // And finally the provider catalog, the portals and the ratings — they keep their cache to
        // themselves and lose it with themselves.
        forget()
        Diagnose.step(.network, "Sync: cache cleared")
    }

    /// Fetches the channel catalog anew from the provider — **the second step of the sync.**
    ///
    /// **Forced and not merely triggered.** ``PlaylistKit/LiveLibrary/load(forceReload:)`` serves
    /// itself without this attribute from the store on disk and goes to the network only if that
    /// is older than six hours. That is the right rule for opening the Live tab and the wrong
    /// one for a button called "sync": anyone who presses it has a reason that the clock does
    /// not know.
    ///
    /// **What this relies on so that it does not become a request storm:** the
    /// ``PlaylistKit/ConnectionLock`` queues every panel request **per account**. This
    /// installation's provider account allows one simultaneous connection
    /// (`max_connections = 1`, measured on 2026-09-07); without the lock the panel answers the
    /// second one with HTTP 512, and the view reported "not reachable" for a login that works.
    /// All Xtream fetches run through `XtreamClient.fetchData` and thus through the same lock —
    /// this channel fetch, the library's categories and the titles of Home that come immediately
    /// after. They are thereby answered **one after another** instead of being rejected. What
    /// the lock cannot do, ``ProviderCache`` can: two views that want the same category
    /// attach to **one** operation instead of queuing behind each other.
    ///
    /// **Without a provider login nothing happens.** ``library()`` would otherwise run on
    /// ``emptyStorage()`` and perform a fetch over zero lists — work whose result is already
    /// known.
    @MainActor
    public static func reloadChannels() async {
        guard listStore() != nil else { return }
        let catalog = await library().load(forceReload: true)
        Diagnose.step(
            .network, "Sync: \(catalog.channels.count) channels refetched")
    }

    /// The provider — **until AP21 from the environment**, like the media server.
    ///
    /// **The login is only put together, not checked.** The account allows **one** connection,
    /// and a connection storm leads to an IP throttle that also blocks the interface and lasts
    /// minutes (documented on 2026-08-15). A check query at start would be a connection that nobody
    /// needs — it is asked only when someone opens the categories.
    /// **In the state wrapper and not raw** (AP42, 2026-09-21). An Xtream panel keeps no viewer
    /// state: `XtreamVODSource` has not answered `resumable`, `setPlayed`, `setFavorite` and
    /// `favorites` at all since AP42, and ``ProviderSource`` books them into the person's
    /// ``StillLedger``. **Here and not on the screen**, because the same catalog is passed on at
    /// five places — Home, Library, Search, detail page, player; one wrapper per screen would be
    /// the same rule five times, of which the sixth is missing.
    @MainActor
    static func xtream() -> ProviderSource? {
        if let rememberedCatalog { return rememberedCatalog }
        let built = listStore().map {
            ProviderSource(XtreamVODSource(store: $0), ledger: FileStore())
        }
        rememberedCatalog = built
        return built
    }

    @MainActor private static var rememberedStorage: PlaylistStore?

    /// The one list store — **in memory and not in the Keychain.**
    ///
    /// Until AP21 there is no setup; what would be stored here would survive the program run and
    /// stand in the way as legacy data at the real setup.
    ///
    /// **One for all.** Catalog and channel list use the same access; two stores would be two
    /// truths about a connection of which there is exactly one.
    @MainActor
    static func listStore() -> PlaylistStore? {
        if let rememberedStorage { return rememberedStorage }

        // **What the setup stored applies.** Only when nothing stands there does the fallback to
        // the environment apply — see ``jellyfin()``.
        //
        // **And only what belongs to the profile** (on-device test build 1332, 2026-09-27, findings
        // 1 and 3): the window asks the profile book at every read. A new profile without a list
        // thus has no list store — no Live, no catalog, no channel favorites of someone else, and
        // Settings says the same as the overview.
        let isConfigured = inWindow(deviceStorage())
        if !isConfigured.visiblePlaylists.isEmpty {
            rememberedStorage = isConfigured
            return isConfigured
        }

        let environment = ProcessInfo.processInfo.environment
        let new = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())

        // **More than one login, since 2026-09-06** The TV simulator carries two lists; here exactly
        // one was provided for, and the second was never visible on the phone. Enumerated and not
        // patterned: two logins are two, and a loop over `CINELOUNGE_XTREAM3`, `4`, `5` would be a
        // promise that nobody has redeemed.
        for (number, prefix) in [(1, "CINELOUNGE_XTREAM"), (2, "CINELOUNGE_XTREAM2")] {
            guard let address = environment[prefix].flatMap(URL.init(string:)),
                let user = environment["\(prefix)_USER"],
                let password = environment["\(prefix)_PASS"]
            else { continue }
            new.add(
                Playlist(
                    id: "xtream\(number)",
                    name: environment["\(prefix)_NAME"] ?? address.host() ?? "IPTV",
                    kind: .xtream(server: address, username: user)),
                password: password)
        }
        guard !new.playlists.isEmpty else { return nil }
        rememberedStorage = new
        return new
    }

    /// Sets the ``PlaylistKit/PlaylistStore/viewport`` to the lists of the active
    /// profile — **the same calculation the overview makes** (``SetupState/channelLists``)
    /// and the TV (``Flows/ChannelListView``).
    @MainActor
    static func inWindow(
        _ storage: PlaylistStore, ledgerStore: any KeyValueStore = FileStore()
    ) -> PlaylistStore {
        ChannelListView.set(storage, ledgerStore: ledgerStore)
    }

    /// The list catalog **of the device**, without a window — for the places that work across
    /// all profiles: clearing when a profile is removed (``Flows/ProfileManagement``). For
    /// displaying and playing there is ``listStore()``.
    @MainActor
    static func deviceStorage() -> PlaylistStore {
        PlaylistStore(store: SecureStore(), secrets: SecureStore(), ledger: FileStore())
    }

    /// An empty store — only so that ``library()`` has a value when nothing is set up.
    /// ``unfilteredChannelSource()`` returns `nil` in this case, so the library is never asked.
    @MainActor
    static func emptyStorage() -> PlaylistStore {
        PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
    }

    /// The channels of a provider login.
    ///
    /// **One list store for all sources, not a new one per call.** ``xtream()`` built its own at
    /// every call until 2026-09-05 — for the catalog that suffices, because only the credentials are
    /// needed there. ``LiveLibrary``, by contrast, remembers its catalog in the list store; with
    /// a new one at every call each visit to the Live tab would be a full fetch of 5.389
    /// channels. On an account with **one** allowed connection that is not merely slow.
    ///
    /// **Unfiltered, and therefore only for Settings** — behind the door where an adult sits:
    /// channel lists, groups, arranging Home and the choice "Live for children", which must show
    /// the whole catalog so that one can choose from it. Every path on which something is
    /// **watched** takes ``channelSource(rule:)``.
    @MainActor
    public static func unfilteredChannelSource() -> (any ChannelListingSource)? {
        guard let storage = listStore() else { return nil }
        return ProviderChannelSource(library: library(), listen: storage)
    }

    /// The channels, **as the parental controls let them through** (tvOS roadmap AP52,
    /// decision 14).
    ///
    /// * **Outside child mode** the whole catalog, as before.
    /// * **In child mode without an allow list** `nil` — no Live, on any path. Child mode
    ///   applies to a child **even without a device PIN**
    ///   (``ParentalControls/ProtectionRule/isInChildMode``, check evening 2026-09-25).
    /// * **In child mode with a list** only its channels (``KidsChannelSource``).
    ///
    /// **Without a default for `rule`, on purpose:** a forgotten argument would otherwise fall
    /// back to "without lock" and look exactly as before — the same finding as at
    /// ``playerSource(width:rule:)``.
    @MainActor
    public static func channelSource(rule: ProtectionRule) -> (any ChannelListingSource)? {
        filtered(unfilteredChannelSource(), rule: rule)
    }

    /// The filter itself — **without the list store**, so that the tests ask exactly the
    /// calculation that ``channelSource(rule:)`` and thus every channel path of the app uses.
    static func filtered(
        _ source: (any ChannelListingSource)?, rule: ProtectionRule
    )
        -> (any ChannelListingSource)?
    {
        guard rule.scope.delivers(Catalog.Origin.channelList.rawValue), let source else {
            return nil
        }
        guard rule.scope.isInChildMode else { return source }
        return KidsChannelSource(source: source, approval: rule.channelApproval)
    }

    /// Which origins the player does **not** play at all — in child mode, what may not deliver
    /// titles. Since AP52 the channel list is missing from it as soon as the allow list permits
    /// something; which channels then play is decided by the filter (``filtered(_:rule:)``).
    static func blockedOrigins(_ rule: ProtectionRule) -> Set<Catalog.Origin> {
        Set(
            [Catalog.Origin.provider, .channelList, .portals].filter {
                !rule.scope.delivers($0.rawValue)
            })
    }

    @MainActor private static var rememberedLibrary: LiveLibrary?

    @MainActor
    static func library() -> LiveLibrary {
        if let rememberedLibrary { return rememberedLibrary }
        let incoming = LiveLibrary(store: listStore() ?? emptyStorage())
        rememberedLibrary = incoming
        return incoming
    }

    /// Search — **one source per catalog, in a fixed order.**
    ///
    /// First one's own, then the provider, then third-party — the same ranking as on Home.
    /// Whoever answers first would otherwise decide what stands at the top.
    @MainActor
    public static func searchSources(
        width: Int, rule: ProtectionRule = .pending
    )
        -> [any SearchSource]
    {
        var split: [any SearchSource] = []
        if let server = jellyfin() as? JellyfinSource {
            split.append(
                JellyfinSearch(
                    source: server, rule: rule, width: width,
                    // **The host name and not the full address.** A name answers "which server"; scheme,
                    // number and path would only carry along what leaves this app nowhere.
                    bridgeAddress: ProcessInfo.processInfo.environment["CINELOUNGE_SERVER"]
                        .flatMap(URL.init(string:))?.host() ?? ""))
        }
        if let provider = xtream(), rule.scope.delivers(Catalog.Origin.provider.rawValue) {
            split.append(
                ProviderSearch(
                    source: provider, width: width,
                    name: providerLists().first?.name ?? "IPTV"))
        }
        if let portals = portalSourceForProfile(), rule.scope.delivers(Catalog.Origin.portals.rawValue) {
            split.append(PortalSearchSource(source: portals, width: width))
        }
        // **Channels last, and that is the ranking of this screen.** First one's own, then the
        // provider catalog, then third-party — a channel is not a title but a running picture, and
        // whoever searches is usually searching for a title.
        if let channels = channelSource(rule: rule) {
            split.append(
                ChannelSearchSource(
                    source: channels, preferences: { LivePreferences.load(from: ProfileStore.playback) }))
        }
        return split
    }

    /// The favorites — **from every source that knows a star.**
    ///
    /// **First one's own, then third-party, then the channels.** The same ranking as on Home and
    /// in Search: whoever answers first would otherwise decide what stands at the top. A channel
    /// comes last because it is not a title but a running picture.
    ///
    /// **The provider catalog has been included since AP58 R6.** It used to say here that it was
    /// missing on purpose because `XtreamVODSource` keeps no favorites — that was outdated since
    /// AP42: ``xtream()`` lies in the state wrapper, and that keeps the marks in the person's
    /// ``StillLedger``. On the TV they had been in the favorites all along.
    ///
    /// **The media server is split** into movies and series — the TV's order
    /// (``Flows/FavoritesOrder``).
    @MainActor
    public static func favoritesSources(
        width: Int, rule: ProtectionRule = .pending
    )
        -> [any FavoritesSource]
    {
        var split: [any FavoritesSource] = []
        if let server = jellyfin() {
            split.append(
                CatalogFavorites(
                    source: rule.about(server), origin: .jellyfin,
                    headline: .key("stock.mediaServer"), width: width, isShared: true))
        }
        if let provider = xtream(), rule.scope.delivers(Catalog.Origin.provider.rawValue) {
            split.append(
                CatalogFavorites(
                    source: rule.about(provider), origin: .provider,
                    headline: .key("stock.provider"), width: width))
        }
        if let portals = portalSourceForProfile(), rule.scope.delivers(Catalog.Origin.portals.rawValue) {
            // **What belongs in its own area does not stand here** (2026-09-07). The switch lies in the
            // portal settings; it is read when the source is built, that is at every opening of the
            // favorites. An identifier without a readable portal stays — the same rule as in
            // ``History``.
            let preferences = PortalPreferences.load(from: SecureStore())
            split.append(
                CatalogFavorites(
                    source: portals, origin: .portals,
                    headline: .key("tab.portals"), width: width,
                    accepts: { identifier in
                        PortalPreferences.portal(zu: identifier).map(preferences.countsTogether) ?? true
                    }))
        }
        if let channels = channelSource(rule: rule) {
            split.append(
                ChannelFavorites(
                    source: channels, preferences: { LivePreferences.load(from: ProfileStore.playback) }))
        }
        return split
    }

    /// The portals — **via the bridge in the home network.**
    ///
    /// **The address is not in the source code.** `PortalBridge.standard()` knows the host name
    /// `portals.example` and the number 8099 as defaults; that is not a home address but the
    /// agreement of the contract. `CINELOUNGE_PORTALE` overrides it as long as there is no
    /// setup.
    ///
    /// **Without the variable there are portals anyway**, provided the bridge answers under its
    /// name — unlike the media server, whose login nobody can guess.
    @MainActor
    public static func portalDataSource(width: Int) -> (any PortalContentSource)? {
        // **The gate that carries the most** (2026-09-07, ROADMAP A1). Without a source there is no
        // shelf on Home, no search over the portals, no view in the tab and no list in Settings —
        // fourteen files name the portals, and almost all hang on this one line. See
        // ``SourceSwitch``.
        guard SourceSwitch.portals, let source = portalSourceForProfile() else { return nil }
        return BridgePortalSource(source: source, width: width)
    }

    /// The detail page — **over all sources**, decided by the identifier.
    ///
    /// Despite its name, `JellyfinDetailSource` is not tied to the media server: it works via
    /// `Core.ContentSource` and works with any source that fulfills the contract. What was
    /// missing was the **assignment** — see ``AggregateDetailSource``.
    ///
    /// **The rule without a default** (check 2026-09-27, D1): a default `.pending` meant that every
    /// call site that forgot it built an unfiltered detail page.
    @MainActor
    public static func detailContentSource(
        width: Int, headerWidth: Int, logoWidth: Int, rule: ProtectionRule
    )
        -> (any DetailSource)?
    {
        let server = jellyfin().map {
            JellyfinDetailSource(
                source: rule.about($0), width: width, headerWidth: headerWidth,
                logoWidth: logoWidth)
        }
        // **Provider and portals only where the rule lets them deliver** (AP45, 2026-09-25). The
        // detail page is an open door because it "only shows what is visible anyway" — for a child
        // profile, however, a portal title is visible nowhere, and a path via a remembered
        // identifier (history, downloads) would otherwise lead in after all.
        let catalog = (rule.scope.delivers(Catalog.Origin.provider.rawValue) ? xtream() : nil).map {
            JellyfinDetailSource(
                source: $0, width: width, headerWidth: headerWidth, logoWidth: logoWidth)
        }
        // **A portal is no special case for the detail page.** `PortalSource` fulfills
        // `Core.ContentSource`, and `JellyfinDetailSource` is, despite its name, not tied to the
        // media server — it works via the contract. What was missing was only the assignment by
        // identifier.
        let portal =
            (rule.scope.delivers(Catalog.Origin.portals.rawValue) ? portalSourceForProfile() : nil)
            .map {
                JellyfinDetailSource(
                    source: $0, width: width, headerWidth: headerWidth, logoWidth: logoWidth)
            }
        // **The downloads count too, and that is the finding of 2026-09-12** (requirement: in
        // airplane mode the content with posters is visible, but forward navigation does not work).
        // Here stood `server != nil || catalog != nil || portal != nil` — **without the
        // downloads.** Anyone who has only downloads and no reachable catalog got `nil`, and then
        // no poster led anywhere any more: the page exists, the file lies on disk, and the path to
        // it was missing.
        //
        // **The downloads are passed explicitly, with the profile's rule.** ``AggregateDetailSource``
        // no longer has a default (check 2026-09-27, D1).
        let downloads = DownloadsDetailSource.standard(rule: rule)
        guard server != nil || catalog != nil || portal != nil || downloads != nil else {
            return nil
        }
        return AggregateDetailSource(
            jellyfin: server, provider: catalog, portals: portal, downloads: downloads)
    }

    /// The portal source **for the profile sitting in front** — `nil` if it does not want the
    /// portals. Every path on which something is watched takes this one.
    ///
    /// **The finding of the on-device test (build 1332, 2026-09-27, finding 1):** address and
    /// attribute lie on the device, and ``portalSource()`` built the source for whoever sat in
    /// front. A freshly created profile without portals saw the predecessor's portal titles in
    /// favorites and search — including `401 auth.required` and `404 state.unknown_key` in the
    /// report, because the app asked for states for this profile that it never had. The same
    /// question that decides the tab (``state()``).
    @MainActor
    static func portalSourceForProfile(
        state setup: SetupState = SetupState(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        source: @MainActor () -> PortalSource? = { portalSource() }
    ) -> PortalSource? {
        guard wantsPortals(setup, environment: environment) else { return nil }
        return source()
    }

    /// The portal source as `ContentSource` — **unfiltered**; watching goes via
    /// ``portalSourceForProfile(state:environment:source:)``.
    @MainActor
    static func portalSource() -> PortalSource? {
        let environment = ProcessInfo.processInfo.environment
        // **The configured address takes precedence — the same order as for the media server.** It
        // was not available at all until 2026-09-06: the service was hard-wired to `portals.example:8099`,
        // and `CINELOUNGE_PORTALE` exists only in the simulator. On a real phone the portals thus
        // worked only where this one name resolves.
        //
        // **And since 2026-09-12 the chain ends here.** Below it stood `?? PortalBridge.standard()` — a
        // guessed address as the last resort. Product decision: **if nothing is entered, nothing
        // should work.** Without an entered address there is no portal source, and the interface
        // therefore says "not set up" instead of "does not answer" — the difference between an
        // answer and a riddle.
        // **The attribute travels along from here on every request** (2026-09-12) — `nil` as long
        // as nobody is signed in, and always with the old bridge.
        //
        // **No `X-CL-Profile` on the phone**, and that is a decision: whoever operates the app
        // stands at the attribute and not at a parameter that a child's device could send along.
        // Anyone who wants to change the profile signs in again.
        TraitMigration.migrate(device: SecureStore(), ledgerStore: FileStore())
        let trait = DeviceTrait.load(from: SecureStore())
        let bridge =
            SetupState().bridgeURL.map {
                PortalBridge(basis: $0, trait: trait)
            }
            ?? environment["CINELOUNGE_PORTALE"].flatMap(URL.init(string:)).map {
                PortalBridge(basis: $0, trait: trait)
            }
        // **Only now held against the remembered address** — see ``rememberedBridgeAddress``. The
        // check stands behind building the address and not before it: anyone who returned the
        // remembered source first would never get to compare the address.
        let spread = trait?.hashValue
        if let rememberedPortals, rememberedBridgeAddress == bridge?.basis,
            rememberedTrait == spread
        {
            return rememberedPortals
        }
        let built = bridge.map { PortalSource(bridge: $0) }
        rememberedPortals = built
        rememberedBridgeAddress = bridge?.basis
        rememberedTrait = spread
        if built != nil {
            Diagnose.step(.network, "Portal source rebuilt")
        }
        return built
    }

    /// A playback source over a content source — **through the same filter as the lists.**
    ///
    /// Until 2026-09-25 ``JellyfinPlayerSource`` got the raw source. The next episode
    /// (``JellyfinPlayerSource/nextEpisode(after:)``) thereby came unfiltered: a child who saw
    /// a released episode was offered the next one at the end, even if it was above their limit
    /// or its series release was open. Via ``ParentalControls/ProtectionRule/about(_:)``
    /// `nextEpisode` asks the rule; with a lock there is no offer.
    static func playbackSource(
        _ source: any ContentSource, width: Int, origin: Catalog.Origin,
        rule: ProtectionRule
    ) -> JellyfinPlayerSource {
        JellyfinPlayerSource(source: rule.about(source), width: width, origin: origin)
    }

    /// Playback — **over all four sources**, decided by the origin.
    ///
    /// **The short-circuit line fell on 2026-09-06** Here stood
    /// `guard let server, catalog != nil else { return server ?? catalog }`: with a
    /// single-source setup **everything** thereby went unchecked to the same source — a portal
    /// title to the media server, a channel to the provider catalog. The outcome was `.networkJellyfin`
    /// again, and the shortcut saved nothing: the switch costs one `switch`, the error cost two
    /// tabs.
    @MainActor
    public static func playerSource(
        width: Int, rule: ProtectionRule = .pending
    ) -> (any PlayerSource)? {
        let server = jellyfin().map {
            playbackSource($0, width: width, origin: .jellyfin, rule: rule)
        }
        // **What may not deliver titles in child mode does not play either** (AP45, 2026-09-25) —
        // the same rule as for Home shelves, search and favorites, now at the last step too. See
        // ``CompositePlayerSource/locked``.
        let locked = blockedOrigins(rule)
        let catalog = xtream().map {
            playbackSource($0, width: width, origin: .provider, rule: rule)
        }
        // **Portals play through the same build.** `PortalSource` fulfills `ContentSource`, and
        // what the player needs — address, progress, next episode — is in this contract. The same
        // experience as with the detail page: the assignment belongs in the switch above, not in
        // the source.
        let portal = portalSourceForProfile().map {
            playbackSource($0, width: width, origin: .portals, rule: rule)
        }
        // **Through the same filter as the Live tab** (AP52): a channel that is not on the child's
        // allow list cannot be found here and does not play.
        let channels = channelSource(rule: rule).map { ChannelPlayerSource(source: $0) }

        // **The downloads stand before all four, and they hang on no setup** (2026-09-09). What lies on
        // disk is played from disk — regardless of whether it came from Jellyfin, from the provider
        // or from a portal. That is the whole point of a download and at the same time the reason
        // why it works at all without a network.
        let disk = DownloadsPlayerSource()

        // **And therefore it is also in this condition.** It returned `nil` as soon as no source
        // was set up — on a device without a reachable server the finished download would thereby
        // not have been played either. The downloads are the one catalog that can do something
        // without a setup; hiding it behind a setup check would mean switching it off exactly where
        // it is needed.
        guard
            server != nil || catalog != nil || portal != nil || channels != nil
                || disk.hasContent
        else {
            return nil
        }
        return CompositePlayerSource(
            downloads: disk,
            jellyfin: server, provider: catalog, channels: channels, portals: portal,
            locked: locked, rule: rule)
    }

    /// The access to the rating services.
    ///
    /// **Keychain first, the environment as a fallback.** `SecureStore` is shared: anyone who
    /// entered the key on the TV has it there — on the phone it arrives only after AP22, when
    /// the setup migrates over via a token. Until then the build takes it from `CINELOUNGE_OMDB`,
    /// like the server too.
    ///
    /// **Nothing is broken without a key.** AniList answers without one, and the media server's
    /// numbers are already on every tile anyway. The key buys the more precise information, not
    /// the information.
    /// **Built once and held** — like every other source here.
    ///
    /// Until 2026-09-07 it was created in every pass of `TabPlaceholder.body`, that is several
    /// times per render, each time with a fresh cache and a fresh `URLSession`. A fetched rating
    /// thereby did not even survive scrolling on Home. ``forget()`` clears it when the setup
    /// changes.
    @MainActor
    public static func ratingsSource() -> any RatingSource {
        if let remembered = rememberedRatings { return remembered }
        let fromEnvironment = ProcessInfo.processInfo.environment["CINELOUNGE_OMDB"]
        let source = ExternalRatingsSource(
            omdbKey: SecureStore().omdbAPIKey() ?? fromEnvironment,
            // **On disk and not in memory** — see ``NoteStore``.
            anilist: AniListClient(store: NoteStore()),
            tmdbKey: SecureStore().tmdbAPIKey()
                ?? ProcessInfo.processInfo.environment["CINELOUNGE_TMDB"],
            // Reads the client ID at every question — an entry in Settings applies immediately, also in
            // this remembered source (AP68).
            anime: animeRating)
        rememberedRatings = source
        return source
    }

    @MainActor private static var rememberedRatings: ExternalRatingsSource?

    /// **One anime rating for the whole program** (AP68) — detail page, header area and posters
    /// share the mapping and the MAL store. The store lies on disk, otherwise every start would
    /// re-ask the posters of Home. The client ID is read at every question; an entry in Settings
    /// applies immediately.
    static let animeRating = AnimeRating(
        store: FileStore(),
        key: { SecureStore().malClientID() ?? ProcessInfo.processInfo.environment["CINELOUNGE_MAL"] })

    /// The MAL ratings of the posters, asked only when a tile is visible.
    @MainActor public static let animeRatings = AnimeScores(rating: animeRating)

    /// The access to the film database — faces and careers.
    ///
    /// **The same path as for the rating access and for the same reason:** `SecureStore` is
    /// shared, anyone who entered the key on the TV has it there. Until the setup migrates over
    /// via a token (AP22), the build takes it from `CINELOUNGE_TMDB`.
    ///
    /// **Nothing is broken without a key, but something is different:** the person circles then
    /// show placeholders instead of faces and stop being buttons — instead of remaining
    /// ineffective ones. That is the rule from AP13, and it hangs on exactly this piece of
    /// information.
    public static func careerSource() -> any CareerSource {
        let fromEnvironment = ProcessInfo.processInfo.environment["CINELOUNGE_TMDB"]
        return FilmDatabase(key: SecureStore().tmdbAPIKey() ?? fromEnvironment)
    }

    /// What is set up — derived from the environment until AP21.
    ///
    /// **Derived and not hard-set to "everything".** The bar shows a tab exactly when its source
    /// is there; with a fixed ``Aufenthalt/complete`` this rule would never be seen in the
    /// running program, and an error in it would be noticed only after the setup — that is, at
    /// the latest possible point.
    ///
    /// **`CINELOUNGE_AUFENTHALT=everything` forces the full bar.** As long as Live and Portals are
    /// only placeholders, one needs a way to open them at all.
    /// The catalog's age ratings — for the "Age ratings" sheet.
    @MainActor
    public static func approvalsSource() -> (any ApprovalsSource)? {
        jellyfin().map { JellyfinApprovalsSource(source: $0) }
    }

    /// What the media server says about the signed-in account.
    ///
    /// **`nil` means "no media server or no answer".** It does not mean "no policy" — the
    /// difference is carried by ``ServerPolicy/hasContent``, and the sheet shows the two
    /// differently.
    @MainActor
    public static func accessPolicy() async -> ServerPolicy? {
        guard let source = jellyfin() as? JellyfinSource,
            let read = try? await source.userPolicy()
        else { return nil }
        return ServerPolicy(
            // **Passed on as raw text, like everything else.** Jellyfin carries a number; sending it
            // through the same ``ApprovalInterpretation`` as the rest is the only version in which server and
            // app mean the same thing.
            maximumRating: read.maximumRating.map(String.init),
            isRestricted: read.disabled,
            blockedCatalogs: read.blockedCatalogs)
    }

    /// Whether the portals are wanted — from the setup or from the simulator's environment.
    /// **One rule for bar and value column:** until 2026-09-07 the value column read only the setup
    /// and said "off" while the tab (from the environment) was there and running.
    @MainActor
    static func wantsPortals(
        _ setup: SetupState,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        setup.portalsWanted || environment["CINELOUNGE_PORTALE"] != nil
    }

    /// Whether a source comes **from the environment** instead of from the setup.
    ///
    /// **The finding from AP4, which had been standing as an open item since 2026-09-06:** on the
    /// screen "Channel lists · nothing" stands in gold while the app runs with a provider login.
    /// Both are true — Settings shows what is **set up**, and a login from `CINELOUNGE_XTREAM`
    /// is not set up; it cannot be changed or deleted there either.
    ///
    /// **Correct and still misleading.** Gold in this app means "something is missing here that
    /// can be added" — and exactly that does not apply: nothing is missing, it just stands
    /// elsewhere. The roadmap wrote: "with the first real setup the contradiction disappears."
    /// That is true and not an answer: the test hook exists so that one can look **without** a
    /// setup, and the value column lied in the process.
    ///
    /// **It now says where it comes from.** No number, no gold, no "nothing" — the sentence
    /// "from the environment" answers the question one has in front of the row and at the same
    /// time names the reason why the row has nothing to edit.
    ///
    /// **On the device this never occurs.** Neither `run.sh` nor `device.sh` pass the variables
    /// on to a shipped app; anyone who loads the app from the store does not see this value.
    /// That is why it is not shown as an error case either.
    /// - Parameter umgebung: **for tests only.** The same design as for
    ///   ``wantsPortals(_:environment:)`` next to it — without it the one case this is about
    ///   could not be produced: the check run does not have the variables.
    public static func fromEnvironment(
        _ origin: Catalog.Origin,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CINELOUNGE_AUFENTHALT"] == "alles" { return true }
        return switch origin {
        case .jellyfin: environment["CINELOUNGE_SERVER"] != nil
        case .channelList, .provider: environment["CINELOUNGE_XTREAM"] != nil
        case .portals: environment["CINELOUNGE_PORTALE"] != nil
        case .downloads: environment["CINELOUNGE_VORRAT"] != nil
        }
    }

    @MainActor
    public static func state() -> CatalogState {
        let environment = ProcessInfo.processInfo.environment
        if environment["CINELOUNGE_AUFENTHALT"] == "alles" {
            return .fromAccesses(
                jellyfin: true, channelList: true, portals: true, downloads: true,
                provider: true)
        }
        let setup = SetupState()
        return .fromAccesses(
            jellyfin: setup.jellyfin != nil || environment["CINELOUNGE_SERVER"] != nil,
            // **A provider login brings both** — channels for the Live tab and a catalog for the
            // library. It is the same login and still not the same; see ``Catalog/Origin/provider``.
            channelList: !setup.channelLists.isEmpty || environment["CINELOUNGE_XTREAM"] != nil,
            portals: wantsPortals(setup, environment: environment),
            // Until AP26 there are no downloads and thus nothing to derive. The variable stands here so
            // that the one case remains viewable for which the fourth attribute was built at all: loaded
            // content without a media server.
            downloads: environment["CINELOUNGE_VORRAT"] != nil,
            provider: !setup.channelLists.isEmpty || environment["CINELOUNGE_XTREAM"] != nil)
    }

    /// A fixed identifier per installation.
    ///
    /// Jellyfin keeps sessions per device; an identifier that changes at every start leaves a
    /// growing list of devices on the server that never existed.
    ///
    /// **Since 2026-09-20 via ``Grundstock/DeviceIdentity``** (AP40): the same identifier was
    /// called `app.deviceID` here and `device.id` on the TV, and both sides had their own "read,
    /// otherwise create" branch — exactly the design that the header of that building block
    /// warns about. The old name is adopted at startup
    /// (``Startup/migrateDeviceIdentifier(from:)``); **without this step the media server would
    /// see a new device.**
    static var deviceID: String { DeviceIdentity.id() }
}
