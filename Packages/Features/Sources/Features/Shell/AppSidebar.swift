import Core
import DesignSystem
import Flows
import Foundation
import ParentalControls
import ProfileKit
import SwiftUI

/// The sidebar on the left — built by hand.
///
/// It is always there, but narrow: only the symbols. **It expands as soon as
/// focus moves into it**, and closes again when focus reaches the content.
/// So it is visible at all times and never in the way.
///
/// **Why not the system one.** `TabView` with `.sidebarAdaptable` expands and
/// collapses at its own discretion, its width can't be determined, and it knows
/// subdivisions only as flat sections. Three requirements fail because of that:
/// predictable expansion, reliable focus movement, and groups under "Live".
///
/// Rebuilding it solves all three at once, for a simple reason: If the bar sits
/// **next to** the content instead of above it, "left" really is left. Focus
/// movement follows from the arrangement instead of having to be wrested from it.
/// That is exactly where the previous version got stuck twice.
struct AppSidebar: View {

    /// Where it leads. Subgroups carry the identifier of their group, so that
    /// later each M3U group has its own destination.
    nonisolated enum Destination: Hashable {
        /// "Start" — the Home screen across all sources.
        case media
        /// The libraries of the Jellyfin server (AP59 N5) — the same surface as ``media``,
        /// but with the pill on a library instead of on Home.
        case jellyfin
        case search
        /// Movies, series and channels that were marked — across sources.
        case favorites
        case live
        /// A group within the channel list, such as "TR · Genel".
        case liveGroup(String)
        /// A stored list as its own level — appears only when
        /// several lists are enabled (schedule P6).
        case liveProvider(String)
        /// A group within a specific list. Carries both
        /// identifiers: "News" exists twice at two providers.
        case liveProviderGroup(provider: String, group: String)
        /// Movies and series of the provider — not channels, but media library.
        case vod
        /// A stored list as the source of the provider media library.
        ///
        /// **The bar answers "where from", the surface "what"** (product decision
        /// 2026-08-22). Previously the genres stood here — with two providers that would
        /// mean "Action" twice, one below the other, with no visible difference. The
        /// genre is chosen in the surface, where the kind (movies or
        /// series) is also switched.
        case vodProvider(String)
        /// The schedule: the day's live sports broadcasts from the EPG.
        case sport
        /// Foreign sources via the portal bridge (AP20).
        ///
        /// **At the very bottom, and that is a statement.** The order of the bar
        /// is a ranking: What belongs to you — media library, favorites — stands
        /// at the top, what comes from outside, below it. Portals are the outermost.
        case portals
        /// A single portal — Serieshub, Animehub, the ARD media library.
        ///
        /// **The sublist is not fixed.** It is whatever the loader
        /// found in the bridge's folder. One more portal means one more
        /// folder there and no row here.
        case portalProvider(String)
        case settings
        /// The account switch — **not a destination but a hand grip** (G1), like ``sync``.
        ///
        /// **Why it belongs in the bar.** On the phone the switch hangs on the
        /// profile picture, because that is the only place that looks the same on every
        /// tab. On the TV there is no such place: The header area belongs to the
        /// content, and the pill changes with the area. What always stands the same
        /// here is the bar — so it goes here.
        ///
        /// **It opens Settings in the Accounts area and is not a screen of its own.**
        /// A second place with the same list would be a second place
        /// with the same bugs; what it saves is the three presses to get there — and
        /// that was the whole objection.
        case accounts
        /// Not a destination but a hand grip: triggers the sync. Still
        /// in the destination enum, because every bar entry
        /// needs a focus identifier — it can never be selected.
        case sync
    }

    @Binding var selection: Destination
    /// The scope of the applicable rule — **which areas drop out and what a child
    /// can reach** (AP58 R1). The rule and its rationale are at
    /// ``ParentalControls/ChildScope``; here it is only applied.
    ///
    /// **Gone and not dimmed.** A dimmed entry is an invitation.
    var scope = ProtectionRule.pending.scope

    /// The form factor — **for a child four entries instead of nine** (AP45, 2026-09-25).
    ///
    /// Which ones is stated at ``ParentalControls/ChildScope/isAllowed(_:)``; here it is only
    /// applied, via ``mainDestinations(scope:hasPortals:)`` and thus for rows and
    /// cycling alike. The form factor now only determines the label of the profile entry.
    ///
    /// **For a child the profile entry says what it does** — "Switch profile" instead of
    /// "Profile": It is the only way out there, and "Profile" alone didn't say that
    /// it is one.
    var surface: Surface = .familiar

    /// The main entries of the bar in order — **without the expanded sub-rows.**
    ///
    /// **One computation for drawing and cycling**, and with reason: The child surface
    /// removes entries, and an entry that would still be in the cycle but is no longer
    /// drawn would be a jump into nothing. Until AP45 the conditions stood once each
    /// at the rows and in the cycle; for two reasons (scope, portals present) that
    /// worked, for three it becomes the place where the two diverge.
    ///
    /// **Testable without a view** — the child surface promises "no way into
    /// Settings", and here that is one line in a list.
    ///
    /// **The provider catalog drops out as soon as the scope applies** (AP45, 2026-09-25).
    /// ``ParentalControls/TabScope/withoutApprovals`` has handled it since 2026-09-06, and the
    /// bar never asked it: "Movies & Series" stayed in child mode, with
    /// ten thousand titles without a single age rating.
    ///
    /// **"Live" comes back with the allow list, "Sport" does not** (AP52, decision
    /// 14). The schedule switches through the channels of an event, regardless of which
    /// group — there is no list for it, so it stays away in child mode.
    ///
    /// **"Live" and "Sport" only with channels** (on-device test 2026-09-27, T13): Both asked
    /// only the child scope. Anyone who had set up only portals saw two entries
    /// that led to "No channels set up yet". The schedule switches through channels
    /// and needs the same condition.
    nonisolated static func mainDestinations(
        scope: ChildScope, hasPortals: Bool, hasChannels: Bool = true,
        hasJellyfin: Bool = false
    ) -> [Destination] {
        // **In the order in which the rows stand** (on-device test 2026-09-30): Since AP59 N3
        // the profile is at the top; here it still stood before Settings — "down" from
        // Settings ended up on "Search"/"Start" instead of on the profile. In addition, Search and
        // Start, Favorites, and Sport and Movies & Series stood differently here than in `body`.
        var targets: [Destination] = [.accounts, .search, .media]
        if hasJellyfin { targets.append(.jellyfin) }
        if hasChannels, scope.remains("live") { targets.append(.live) }
        if hasChannels, scope.showsSports { targets.append(.sport) }
        if scope.delivers("anbieter") { targets.append(.vod) }
        if hasPortals, scope.remains("portale") { targets.append(.portals) }
        // **"Update all services" is back** (AP63, 2026-10-01, owner request). On
        // 2026-09-30. (AP59 N5) it had been removed, because it was unclear what gets synced —
        // the name says it now: all services, Jellyfin, channels, IPTV, CL-Server.
        targets += [.favorites, .sync, .settings]
        return targets.filter { scope.isAllowed($0) }
    }

    private var targets: [Destination] {
        Self.mainDestinations(
            scope: scope, hasPortals: !portals.isEmpty, hasChannels: hasChannels,
            hasJellyfin: hasJellyfin)
    }
    /// The groups of the configured channel list. Empty as long as none exists —
    /// then "Live" stays a single entry without expanding.
    ///
    /// **All, not the first twelve.** The list has its own scrolling, and
    /// with that every group is reachable. A cap with a row "All groups
    /// (79)" below it stood here while scrolling was missing; it is gone because
    /// it would now only be a second way to what already stands next to it.
    /// Whether the media library gets a row at all.
    ///
    /// **All four areas behind it come from the media server** — Home, Series,
    /// Movies, Home Videos. Without it there would be a row with four empty pages, and
    /// that looks like a bug, not like missing setup.
    /// ``Core/AccountState/showsMediaBar`` answers the same question — until
    /// 2026-09-11 it was built and had **no reader**, because this state did not exist
    /// in the UI at all.
    var showsLibrary = true
    /// Whether a Jellyfin server is set up — only then does "Jellyfin" appear in the bar.
    var hasJellyfin = false
    /// Whether a channel list is set up — see ``mainDestinations(scope:hasPortals:hasChannels:)``.
    var hasChannels = true
    let liveGroups: [String]

    /// A stored list with the names of its groups — the provider level.
    struct LiveProvider: Identifiable, Equatable {
        let id: String
        let name: String
        let groups: [String]
    }

    /// The enabled lists including groups. Only from **two** entries on does
    /// "Live" get the provider level — with a single list it would be
    /// a step that only lengthens paths and distinguishes nothing.
    var liveProviders: [LiveProvider] = []

    /// A genre of the provider media library: the library identifier of the
    /// VOD source plus display name. The identifier goes into the destination — names are
    /// not unique with two providers ("Action" exists twice).
    struct VODCategory: Identifiable, Equatable, Codable {
        let id: String
        let name: String
    }

    /// The genres of the provider's media library. Empty as long as no channel list with
    /// movies is set up — then the entry doesn't appear at all.
    ///
    /// Since 2026-08-22. **no longer shown in the bar**, only
    /// counted: It decides whether there is anything to offer at all.
    var vodCategories: [VODCategory] = []

    /// The lists that carry a provider media library — the level below
    /// "Movies & Series". Just as with "Live" (see ``liveProviders``).
    var vodProviders: [VODProvider] = []

    /// A stored list as the source for movies and series.
    struct VODProvider: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// A portal, as the bridge reports it.
    ///
    /// `isReady` is **carried along and not filtered out**: A broken
    /// portal should be there, not missing. Otherwise you search in the app for
    /// something the server long ago recognized as broken.
    ///
    /// **Since decision 27 (C11) with its state** (``Flows/PortalState``) — as
    /// on the phone you see already in the list whether a portal is ready, needs a login or
    /// a missing setting, or is silent, and not only after entering it.
    struct Portal: Identifiable, Equatable {
        let id: String
        let name: String
        var state: PortalState = .ready

        var isReady: Bool { state.isReady }

        /// The symbol of the row — a different one per state, never color alone.
        var icon: String {
            switch state {
            case .ready: Glyph.network.name
            case .login: Glyph.login.name
            case .needsSetting: Glyph.settings.name
            case .muted, .other: Glyph.disruption.name
            }
        }
    }

    /// The portals of the bridge. Empty as long as none is reachable — then
    /// the entry doesn't appear at all, as with the provider's media
    /// library.
    var portals: [Portal] = []

    /// **Who is watching right now** — their profile picture instead of the generic symbol in the
    /// profile entry (2026-09-29, product decision). `nil` or without a chosen picture:
    /// the symbol as before.
    var profileImage: SidebarProfile? = nil

    /// Triggers the sync — the implementation lies with the wrapper, which knows the source
    /// and warm-up. The entry here is only the reachable place:
    /// without a detour through Settings (request from the test days).
    var onSync: () -> Void = {}
    /// Opens Settings in the Accounts area. See ``Destination/accounts``.
    var onAccounts: () -> Void = {}

    /// Called when "Live" or a channel list is **pressed**.
    ///
    /// **One press opens the channel, no intermediate screen.** Since channels, groups
    /// and program are reachable in the player itself, the overview area
    /// before it is a step without a task — see ``LiveMemory``. `nil` means: all
    /// lists together.
    var onLive: (String?) -> Void = { _ in }

    /// Called when "Media library" is **pressed**.
    ///
    /// Not on every switch to this area — the rationale is at the
    /// row itself.
    var onHome: () -> Void = {}

    /// Whether a sync is currently running — the symbol pulses then.
    var isSyncing = false

    /// Called as soon as the bar is expanded for the first time.
    ///
    /// **A bug hung on this that one would never have suspected at this spot.** The
    /// group names for the Live area were fetched at program start — and
    /// "fetched" at the Xtream provider means: the complete channel list, 5389
    /// entries. That ran concurrently with Home, and over the TV's connection
    /// it choked the requests to the media server in the same house: The diagnostic report
    /// shows a timeout on `Items/Resume` twice in a row — on a server that answers
    /// in 40 milliseconds from another machine.
    ///
    /// The list is needed only when someone opens the bar. Until then
    /// you see six entries, none of which needs it.
    var onFirstExpansion: () -> Void = {}

    /// Held by the wrapper, not here: The menu button on the pill should be able to put
    /// focus **into the bar** — for that ``MainView`` has to
    /// reach it. It explicitly does not expand it (the bar opens only
    /// on a left press, see below) — focus then stands narrow on the
    /// active entry.
    @FocusState.Binding var focus: Destination?

    /// Which of the two lists is expanded — at most one.
    ///
    /// **As one value and not as two switches.** Live carries 79 groups, the
    /// media library dozens of genres; two expanded lists one above the other burst the
    /// bar, and "Settings" would fall out of the picture at the bottom. With two switches
    /// this case would be possible and would have to be prevented at every place where one
    /// of the two is set. One value cannot represent it.
    @State private var expanded: Expandable?

    enum Expandable {
        case live
        case vod
        case portals
    }

    /// Which provider within "Live" is expanded — at most one,
    /// for the same reason as ``expanded``: Two open group lists
    /// one above the other burst the bar.

    /// Width at rest — only the symbols.
    ///
    /// When expanding, the content actually moves aside. That is deliberate:
    /// An attempt to keep it still required the bar in a
    /// layer of its own above the content — and then you could no longer get out of it,
    /// because separate layers are not neighbors. The movement is the price
    /// for the operation being right.
    static let collapsedWidth: CGFloat = 116

    /// Width when expanded — symbol and label.
    ///
    /// Raised from 340 because the label grew from 25 to 29 points. For
    /// the text, 232 points remain after inner padding, symbol and spacing — enough for
    /// "Movies & Series" on one line. Too narrow would mean not a line break but
    /// cut-off entries: They are set with `lineLimit(1)`.
    ///
    /// **The upper limit is 352, and it doesn't come from here.** Expanded, the bar
    /// pushes the content aside, and the Live area additionally needs room for list *and*
    /// board. A first attempt with 380 left it 12 points of
    /// air instead of the required 40 — found by `expandedSidebarLeavesThePanel`,
    /// not on screen. Whoever turns this up further has to give something up there first.
    static let expandedWidth: CGFloat = 348

    // MARK: - Height
    //
    // The bar can overflow, and silently: A `VStack` that becomes taller than
    // the screen is centered by SwiftUI — the topmost and the
    // bottommost entries then simply disappear, without warning and without
    // a way to scroll. With 79 groups under "Live" that is not the exception
    // but the rule. That is why the measurements stand here as values and are computed
    // against the screen height in `LiveModelTests`.

    /// Screen height of an Apple TV display in points.
    static let screenHeight: CGFloat = 1080

    /// Height of a main entry: font size 29 with 18 points of inner padding on each side.
    ///
    /// **Raised from 62 after a finding on the 55-inch TV.** The bar
    /// labeled its entries with `caption` (25 pt) and the groups with `caption2`
    /// (23 pt) — sizes that ``Tokens/Typography`` explicitly assigns to *accessories*,
    /// with a declared lower limit of 29 pt for everything that has to be read. A
    /// navigation entry has to be read. That was not a judgment of taste but
    /// a violation of the project's own rule.
    ///
    /// At 55 inches and three meters' distance, 23 pt is about 16.7 arcminutes, 25 pt
    /// 18.2 and 29 pt 21.1. Below about 18, reading becomes an effort.
    ///
    /// **Why not much higher:** The height competes with the group list. Every
    /// point the six main entries grow is missing from it six times over, and under eight
    /// visible groups expanding is not worth it — recorded in
    /// `LiveModelTests`. 66 and 56 are the most that both allow. Whoever wants to raise the rows
    /// further must first decide where the groups belong otherwise.
    static let rowHeight: CGFloat = 66

    /// Height of an indented group entry, likewise with font size 29.
    ///
    /// Lower than a main entry, but not labeled smaller: The hierarchy is
    /// carried by indentation, symbol size and stroke weight. Carried by font size
    /// it would mean: unreadable.
    static let groupRowHeight: CGFloat = 56

    static let rowSpacing: CGFloat = 6

    // MARK: - What the label leaves in space
    //
    // These five values stood as bare numbers in the body. They belong here because
    // ``labelWidth`` computes against them and a test case against ``labelWidth``: As
    // literals this computation would be a mere claim — whoever enlarges the symbol
    // would leave the check green and the entries cut off. The same rationale as
    // for the heights further up, the same trap, only horizontal.

    /// Inner padding of the bar to its two edges.
    static let horizontalPadding: CGFloat = 18

    /// Indent of a main entry within the bar.
    static let rowLeadingInset: CGFloat = 16

    /// Distance from the entry to the right edge — the expand indicator sits there.
    static let rowTrailingInset: CGFloat = 16

    /// Space for the symbol. Fixed, so that the labels of all rows begin at the same
    /// place, even with symbols of unequal width.
    static let iconWidth: CGFloat = 32
    /// The profile picture in the profile entry — slightly larger than a symbol, because a face
    /// is no longer recognizable at 28 pt; it extends beyond the symbol column without shifting
    /// the row.
    static let profileSize: CGFloat = 40

    /// Distance between symbol and label.
    static let iconGap: CGFloat = 16

    /// What remains for the label of a main entry when expanded: 232 points.
    ///
    /// **Computed, because truncation goes unnoticed.** The entries are set with
    /// `lineLimit(1)`; too little space therefore means not a line break but a word
    /// with an ellipsis — and that looks like a long group name, not like a
    /// space error.
    ///
    /// Re-measured with CoreText at 29 pt semibold: The widest entry in the three
    /// shipped languages is "Movies & Series" at 209 points, closely followed by
    /// "Filmler & Diziler" at 203. German is **not** the worst case — whoever checks only
    /// "Filme & Serien" considers 188 points sufficient.
    static var labelWidth: CGFloat {
        expandedWidth - 2 * horizontalPadding - rowLeadingInset - iconWidth - iconGap
            - rowTrailingInset
    }

    /// The spacing at top and bottom, from ``body``.
    static let verticalPadding: CGFloat = 40

    /// What the name badge at the top occupies, with its spacing below.
    static let brandHeight: CGFloat = 57

    /// How tall the group list may become: **everything that is left over.**
    ///
    /// A fixed number stood here, and it was too small — a third of the bar stayed empty
    /// below the list while the top had to be scrolled. An estimated number
    /// can't hit this at all: It would have to be adjusted by hand with every change to font size or
    /// spacing, and whoever forgets doesn't notice.
    ///
    /// It is computed against everything that stands there anyway — the two spacings, the
    /// name badge, the **six** main entries and the eight gaps of the stack. What
    /// remains belongs to the list. As a result it reaches up to "Settings",
    /// and that entry stays in the picture: It sits below in the same stack, so
    /// a list that gets only the remainder never takes its place.
    ///
    /// **This is the upper limit, not the height.** What a list really
    /// gets is computed by ``listHeight(forRows:)`` from its row count — otherwise
    /// half the screen stands empty under a single entry.
    /// All main entries the bar **can** carry.
    ///
    /// Media library, Search, Favorites, Live, Movies & Series, Sport, Portals,
    /// Refresh, Settings. The computation uses all of them, even if one
    /// is currently missing — for example "Movies & Series" without a configured provider. Otherwise
    /// an expanded list would get room that is taken from it as soon as the
    /// entry is added, and "Settings" would fall out of the picture.
    ///
    /// **This number was two too low** and was hard-wired as `6` in
    /// the computation: Sport and Portals were added later and were never
    /// added to it.
    static let mainRows = 9

    static var groupListHeight: CGFloat {
        // **The refresh entry now counts too** (viewer finding 2026-08-28:
        // "the Refresh button disappears every now and then").
        //
        // It used to yield while a group list was expanded — with the
        // rationale that otherwise only six of the required eight visible groups
        // would remain. Recomputed, that hasn't been true for a long time: With the
        // entries actually drawn, it is five groups without it and
        // four with it. Hiding it thus buys **one** row, while the
        // target of eight is missed by three anyway — and it costs a control that is suddenly
        // gone. The trade was right once and is no longer.
        let fixed =
            2 * verticalPadding + brandHeight
            + CGFloat(mainRows) * rowHeight
            + CGFloat(mainRows + 2) * rowSpacing
        return max(0, screenHeight - fixed)
    }

    /// The height an expanded list **actually** gets.
    ///
    /// **The difference from ``groupListHeight`` is the whole point**
    /// (user finding 2026-08-22): That one is the rest of the screen, i.e. the
    /// upper limit — and a `ScrollView` always takes what it is
    /// offered. With `maxHeight`, half a screen of emptiness therefore stood under a single channel list,
    /// and "Movies & Series" was pushed to the bottom end. It became visible only when
    /// "Live" also expanded with **one** list: With eighty groups the content fills the area anyway.
    ///
    /// Computed instead of estimated, and that works exactly here: The rows carry
    /// a fixed height (``groupRowHeight``), the gaps ``rowSpacing``.
    static func listHeight(forRows count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let content = CGFloat(count) * groupRowHeight + CGFloat(count - 1) * rowSpacing
        return min(content, groupListHeight)
    }

    /// How many groups are visible without scrolling.
    ///
    /// Only for the check: It records that expanding is worthwhile at all.
    /// The display doesn't depend on it — all are visible, scrolling takes care
    /// of that.
    static var visibleGroupCount: Int {
        Int(groupListHeight / (groupRowHeight + rowSpacing))
    }

    /// Not reachable in the first moments.
    ///
    /// tvOS puts focus on the first focusable element at launch, and that
    /// is the bar — so it stood expanded when the app opened and
    /// took up a quarter of the picture. Three ways to steer the initial focus
    /// had no effect: `prefersDefaultFocus(in:)` on the content,
    /// `defaultFocus` on the play button, and a delayed expansion.
    ///
    /// What works is the reverse path: Whoever is **not reachable** when the initial focus is
    /// distributed doesn't get it. After that the bar is operable
    /// normally again.
    ///
    /// A quarter of a second, while the content is still loading anyway.
    ///
    /// **And it belongs to the program run, not to this view** (AP4 · K9):
    /// As `@State` with its own `.task` it ran again on every rebuild of the
    /// view identity — after every return from Search the
    /// bar was dead for a quarter of a second, for no reason. See ``EntryWindow``.
    @ObservedObject private var entry = EntryWindow.shared
    /// The running wait of the wraparound — see ``AppSidebar/wrapDelay``.
    @State private var wrapTask: Task<Void, Never>?
    /// What it runs for: from which edge, in which direction. So that a second
    /// press of the same kind doesn't restart it.
    @State private var wrapPending: (from: Destination?, step: Int)?

    /// When focus last moved **by tvOS** — for the edge-press
    /// check of the wraparound, see
    /// ``AppSidebar/isEdgePress(lastFocusMove:now:)``. Own assignments
    /// don't count, see ``AppSidebar/isNativeStep(from:to:assigned:)``.
    @State private var focusMovedAt = Date.distantPast

    /// What the bar assigned to itself — valid once, then
    /// used up. Its own `onChange` pass is not a focus step
    /// from tvOS and therefore leaves no straggler that would
    /// need to be intercepted.
    @State private var selfSet: Destination?

    /// Whether focus in the bar was **navigated to** or merely assigned —
    /// see ``AppSidebar/litRow(focus:chosen:selection:)``.
    @State private var focusWasChosen = false

    /// Whether the channel lists have already been requested. Once is enough — the holder remembers
    /// the result, a second call would be a second fetch.
    @State private var didAskForContent = false

    /// Whether the viewer opened the bar **on purpose**.
    ///
    /// **This corrects a rule that never held.** Previously it was
    /// "open as soon as focus is in the bar" — and focus lands there even
    /// without any action: tvOS has to reassign it on every rebuild, and if it finds
    /// nothing focusable in the content, it takes the bar. It then expanded on its own,
    /// when opening a movie, when switching the pill, when going back.
    ///
    /// The rule now reads as the viewer described it: It opens
    /// when you go **left** from the content or press **back** at the top level.
    /// Otherwise not. If it receives focus without this intent, it stays
    /// narrow — focus is then in it, but it takes up no space.
    @State private var isOpen = false

    private var isExpanded: Bool { isOpen && focus != nil }

    /// The entries in the order in which they stand — for the wraparound.
    ///
    /// **Built from the same source as the rows themselves**, so that the two don't
    /// drift apart: The sync yields as soon as a list is expanded,
    /// and a wraparound over an entry that doesn't currently exist would lead
    /// into nothing.
    private var rows: [Destination] {
        // **The wraparound must see the same list as the rows.** An area that
        // is no longer there when drawn but still is in the wraparound would be a jump into
        // nothing — and in child mode of all places. Both therefore read ``targets``.
        var result: [Destination] = []
        for target in targets {
            result.append(target)
            switch target {
            case .live where expanded == .live && isExpanded && showsProviders:
                result += liveProviders.map { .liveProvider($0.id) }
            case .vod where expanded == .vod && isExpanded && showsVODProviders:
                result += vodProviders.map { .vodProvider($0.id) }
            case .portals where expanded == .portals && isExpanded && showsPortals:
                result += portals.map { .portalProvider($0.id) }
            default:
                break
            }
        }
        return result
    }

    var body: some View {
        // Spacing and inner padding come from the same values against which
        // ``maximumVisibleGroups`` computes. As bare numbers here, the computation
        // there would be a mere claim: Whoever enlarges the spacing would leave the check green
        // and the bar overflowing — Settings at the bottom would fall out of the picture.
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            brand

            // **Who is watching stands at the top** (AP59 N3, 2026-09-30) — as on Netflix and in the
            // Apple TV app. At the bottom between sync and Settings, the profile picture was the
            // second-to-last entry, and "Who's watching?" lay behind a path through the whole bar.
            row(
                .accounts,
                titleKey: surface == .kind ? "sidebar.switchProfile" : "sidebar.accounts",
                symbol: "person.crop.circle",
                profile: profileImage,
                action: onAccounts
            )

            // **A press on "Media library" always leads to its start** — it
            // doesn't only select the area, it resets it. Whoever
            // selects it means the start and not the place where they
            // left off; otherwise they land on yesterday's detail page and
            // first have to press their way out.
            //
            // **Only on press, not on every destination change.** The return from
            // Search sets the same destination and should **not** lead to the
            // start — one comes from the area there and wants to go back to where
            // one was.
            if targets.contains(.search) {
                row(.search, titleKey: "tab.search", symbol: "magnifyingglass")
            }
            // **Home is called "Start" and no longer "Mediathek"** (AP59 N5) — as on the
            // phone. "Mediathek" also stood for the movies of the IPTV provider.
            if showsLibrary, targets.contains(.media) {
                row(.media, titleKey: "tab.home", symbol: "play.tv") {
                    selection = .media
                    onHome()
                }
            }
            if targets.contains(.jellyfin) {
                row(.jellyfin, title: "Jellyfin", symbol: "film.stack")
            }
            // Live and Sport hang on the same basis: channels without allowances.
            if targets.contains(.live) { liveSection }
            if targets.contains(.sport) {
                row(.sport, titleKey: "tab.sport", symbol: "sportscourt")
            }
            if targets.contains(.vod) { vodSection }
            if targets.contains(.portals) { portalsSection }
            if targets.contains(.favorites) {
                row(.favorites, titleKey: "tab.favorites", symbol: Glyph.favorite.pair.outlined)
            }

            Spacer(minLength: 0)

            // At the bottom by Settings, where it stood until AP59 — ``MainView/syncNow()``.
            if targets.contains(.sync) {
                row(
                    .sync,
                    titleKey: "sidebar.sync",
                    symbol: "arrow.triangle.2.circlepath",
                    pulses: isSyncing,
                    action: onSync
                )
            }
            if targets.contains(.settings) {
                row(.settings, titleKey: "settings.title", symbol: "gearshape")
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth, alignment: .leading)
        .background {
            // Collapsed almost transparent, so that the symbols float
            // above the picture; expanded opaque, so that the labels stay
            // readable, no matter what lies behind.
            if isExpanded {
                ColorRole.surface.color.opacity(0.97)
            } else {
                ColorRole.reason.color.opacity(0.55)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
        // **Not `.task`, but the first focus.** A `task` would run at build time and
        // thus again at launch — exactly what is to be avoided here.
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, !didAskForContent else { return }
            didAskForContent = true
            onFirstExpansion()
        }
        // **Stay first, then expand.**
        //
        // A focus that merely slips through is not an intent. tvOS parks it here when
        // it finds nothing focusable in the content — when opening a movie,
        // when switching the pill, when going back — and takes it along again
        // on the next pass. An expansion on that the viewer sees as the app
        // having a life of its own.
        //
        // Whoever goes left to navigate, on the other hand, stays. A third of a second
        // separates the two reliably and is short enough that an intended opening
        // doesn't feel sluggish.
        // **It opens only on press, not on focus — not even after a wait.**
        //
        // The previous attempt let it open after a third of a second if
        // focus stayed. That wasn't enough: tvOS also parks it longer when rebuilding an
        // area, and it kept opening on its own.
        //
        // Now exactly the rule the viewer described applies: Whoever stands in
        // the bar and presses left once more opens it. Whoever merely has focus
        // assigned sees it narrow. When focus leaves it, it
        // closes again.
        .onMoveCommand { direction in
            Diagnostics.cursorKey("Seitenleiste", FocusTrail.name(direction))
            if direction == .left { isOpen = true }
            // **At the top and bottom the bar wraps around.** See
            // ``AppSidebar/wrapped(from:by:in:)`` — what has arrived here is only what
            // focus did not consume itself, that is, the press beyond the
            // edge.
            if direction == .up || direction == .down {
                // **The wraparound waits, and that is the earlier bug.**
                //
                // Measured (focus trace, 2026-08-12, fast presses): Our jump to the
                // other end stood after 14 ms — and **261 ms later** the
                // movement from tvOS for the same press came along behind and pushed on from the
                // new end. That is the double jump.
                //
                // A follow-up didn't help: It ran after 50 ms and thus long
                // before the movement. So the other way around — **wait first, then
                // wrap.** If focus is still at the same edge after the wait,
                // the press had no effect, and only then does it belong to us.
                //
                // Every new press discards the old wait: Whoever holds the key
                // down wraps once and not five times.
                let on = focus
                let step = direction == .down ? 1 : -1

                // **A second press must not restart the wait.**
                //
                // The trace of 2026-08-22 shows exactly that: The viewer presses
                // at the bottom edge, nothing visible happens, they press once more after
                // 310 ms — and the second press discarded the
                // running wait and started over. 350 ms became 662.
                // Impatience thus made the bar slower, and the more often
                // it was pressed, the longer it took.
                //
                // A wraparound that is still running **in the same direction from the same
                // edge** is already the right one; it keeps running. Only what no longer fits
                // is discarded.
                if let wrapPending, wrapPending.from == on, wrapPending.step == step {
                    return
                }
                wrapTask?.cancel()
                wrapPending = nil
                // **Only a real edge press schedules a wraparound** — the command
                // of a press that has only just moved focus ONTO the edge
                // is the documented straggler and schedules nothing.
                // Without this check, the press that lands on the
                // last entry doubled exactly (numeric finding 2026-08-16: seven
                // entries, every sixth press). See
                // ``AppSidebar/isEdgePress(lastFocusMove:now:)``.
                guard Self.isEdgePress(lastFocusMove: focusMovedAt) else { return }
                guard Self.wrapped(from: on, by: step, in: rows) != nil else { return }
                wrapPending = (on, step)
                wrapTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Self.wrapDelay))
                    defer { wrapPending = nil }
                    guard !Task.isCancelled, focus == on,
                        let wrapped = Self.wrapped(from: on, by: step, in: rows)
                    else { return }
                    selfSet = wrapped
                    focus = wrapped
                }
            }
        }
        .onChange(of: focus) { previous, current in
            // **Only a step WITHIN the bar leaves a
            // straggler**, and the timestamp exists for that alone. Entry
            // from outside and every own assignment produce none —
            // they stamped here anyway and thereby blocked the first
            // real edge press for a quarter of a second. It wasn't merely
            // slow but lost entirely: At the edge tvOS itself moves
            // nothing, so no second attempt comes from there either.
            if Self.isNativeStep(from: previous, to: current, assigned: selfSet) {
                focusMovedAt = Date()
            }
            // Read first, then consume — the registration is valid for exactly one
            // pass. On leaving it lapses anyway, otherwise it would stay
            // armed until the next entry.
            if current == selfSet || current == nil { selfSet = nil }
            // Whoever navigated there has chosen — see ``litRow(focus:chosen:selection:)``.
            // The order matters: Leaving must take the choice back
            // again, otherwise the geometrically hit row lights up again
            // on the next entry from outside.
            if previous != nil { focusWasChosen = true }
            if current == nil {
                focusWasChosen = false
                isOpen = false
                return
            }
            // **The return from the content lands on the entry of the open
            // area** (product requirement 2026-08-07): Whoever stands in a Live group or
            // VOD genre and goes left should arrive at "Live"
            // or "Movies & Series" respectively — not where
            // the geometry happens to point. `previous == nil` means: Focus came
            // from outside; whoever navigates within the bar is left undisturbed.
            // Expanding afterwards puts focus on the open group —
            // that mechanism already exists, it only lacked the entry point.
            guard previous == nil, let current,
                current != Self.mainEntry(for: selection)
            else { return }
            Diagnostics.cursorKey("Seitenleiste", "Entry corrected")
            selfSet = Self.mainEntry(for: selection)
            focus = Self.mainEntry(for: selection)
        }
        // An edge toward the content, so that the bar doesn't seem to float in the picture
        // when a bright background image lies there.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ColorRole.text.color.opacity(0.06))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        // A section of its own: Focus jumps in and out as a whole,
        // instead of sliding back and forth between bar and content.
        .focusSection()
        // **The entry should be announced, not corrected afterwards.**
        //
        // Whoever went left from the content used to land first where the
        // geometry pointed, and was moved to the right entry one pass later. That is
        // visible: With a series from the media library, "Movies & Series"
        // flashed up before focus jumped to "Media library". The jump was right, just one
        // frame build too late.
        //
        // Here the target is set **before** the assignment. The correction below
        // stays as a safety net in case tvOS ignores the hint on re-entry — if it
        // kicks in, it is a silent no-op pass.
        //
        // **And it applies only from outside** (focus trace, 2026-08-12). As a fixed hint
        // it pulled focus permanently to the entry of the open area: Whoever
        // pressed down from "Live" stood on "Live" again five milliseconds later —
        // up and down didn't get you away. `defaultFocus`
        // applies to entering a section, but tvOS applies it again on
        // every rebuild, and this bar rebuilds often: Its width,
        // its arrows and its row count depend on focus.
        //
        // If focus is already in the bar, the default is therefore focus
        // itself — then every re-application is a no-op. Only when
        // it stands outside (`nil`) does it point to the open area.
        .defaultFocus($focus, focus ?? Self.mainEntry(for: selection))
        // **The menu button goes up one level instead of back through 79 groups.**
        //
        // Whoever stands far down in the group list otherwise gets out only by
        // working back up row by row — the way back is as long
        // as the way there, for a movement made often.
        //
        // Two steps, as is usual when going back: from a group to "Live", from
        // there to "Media library". On "Media library" itself the condition no longer applies
        // — there the button passes through and does what tvOS intends for it. That is the
        // reason for ``exitCommand(isActive:action:)``: An attached `onExitCommand`
        // consumes the button even if its body does nothing, and one would no longer
        // get out of the app.
        // **Attached unconditionally, not conditionally.** The conditional modifier
        // ``exitCommand(isActive:action:)`` is right in playback — there
        // its condition rarely changes. Here it hung on focus and flipped on every
        // change within the bar. Every flip swaps out the view structure,
        // the whole subtree is created anew, and with it the restoration
        // of the group focus fired again — which sets focus and thereby triggers the next
        // switch. The bar rebuilt itself endlessly on that until the
        // UI froze.
        //
        // The price is small: If focus is already on "Media library", the button
        // stays without effect here. Out of the app it leads anyway from the content, where
        // this section doesn't have focus.
        .disabled(!entry.over)
        .task { await entry.open() }
        // Observed only — see ``focusTrail(_:_:)``.
        .focusTrail("Seitenleiste", focus)
    }

    /// The main entry under which a destination is at home — groups and genres
    /// live under their area, everything else under itself.
    static func mainEntry(for selection: Destination) -> Destination {
        switch selection {
        case .liveGroup, .liveProvider, .liveProviderGroup: .live
        case .vodProvider: .vod
        case .portalProvider: .portals
        case .sync: .media
        default: selection
        }
    }

    /// Whether a focus change was a step **by tvOS**.
    ///
    /// The timestamp ``focusMovedAt`` has exactly one job: to intercept the straggler
    /// of a press that focus itself has already consumed —
    /// see ``isEdgePress(lastFocusMove:now:)``. This straggler exists only
    /// after a step by tvOS.
    ///
    /// Two changes are not one. The **entry from outside** (`previous == nil`)
    /// — there nobody pressed in the bar, there is nothing to catch up on.
    /// And the bar's **own assignment**: wraparound jump,
    /// entry correction, return to a provider. Both used to stamp
    /// as well and each cost an edge press that fizzled at the edge without a
    /// trace. A press that carries focus within the bar ONTO the edge
    /// remains a step, by contrast, and keeps stamping — otherwise the
    /// double jump of 2026-08-16 would come back.
    static func isNativeStep(
        from previous: Destination?,
        to current: Destination?,
        assigned: Destination?
    ) -> Bool {
        guard previous != nil, let current else { return false }
        return current != assigned
    }

    /// Which row should be bright — **hold ahead instead of catching up**.
    ///
    /// On entry from outside tvOS assigns focus geometrically, and the
    /// correction below (diagnostic line "Entry corrected") moves it into place
    /// only one pass later: a measured 20 ms during which the
    /// wrong row lights up. Catching up doesn't help in principle — the same
    /// measurement is at ``DetailModel``: The notification arrives **after** the
    /// focus change, a highlight that follows it is therefore always too
    /// late. So hold ahead: As long as focus is merely assigned and not
    /// navigated to, the entry on which the correction will shortly
    /// land lights up.
    ///
    /// That is possible only because the bar draws its highlight entirely
    /// itself (``bareFocusableButton()`` and the two color rules
    /// below) — the same precondition that ``DetailView`` names for it.
    ///
    /// **The price, and it deserves mention:** In these 20 ms the
    /// main entry lights up while focus still stands on the geometrically hit
    /// row; a select press in exactly this window would hit the latter.
    /// The alternative would be to keep letting the wrong row light up.
    ///
    /// If focus is in the content, nothing lights up in the bar — two bright
    /// spots in the picture would tell the viewer they stand on two.
    static func litRow(focus: Destination?, chosen: Bool, selection: Destination) -> Destination? {
        guard let focus else { return nil }
        return chosen ? focus : mainEntry(for: selection)
    }

    /// The brand mark above the sidebar.
    ///
    /// **In the collapsed bar it is the only visible part of the brand** (AP27,
    /// 2026-09-11). Until then `popcorn.fill` stood there — a system symbol that any
    /// other app can have just the same, and the **only** occurrence in the whole project.
    /// The own mark lay drawn next to it (`design/logo.svg`, four symbol variants
    /// built from it) and appeared in the running UI not a single time.
    ///
    /// **And it has grown, from 26 to 40 pt.** 26 is about 19 arcminutes at three meters
    /// — that carries as a shape and not as an image: You see that something
    /// is there, and don't recognize what. The upper limit is set by the collapsed bar: 116 pt
    /// minus padding, see `scripts/brand_mark.py`.
    private var brand: some View {
        HStack(spacing: 12) {
            Image("BrandMark", bundle: .main)
                .resizable()
                .scaledToFit()
                .frame(height: Self.logoHeight)
                // **Silent for the screen reader.** The name stands next to it as text; a
                // second "CineLounge" would be the same information twice.
                .accessibilityHidden(true)
            if isExpanded {
                wordmark
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 26)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: Self.firstPart + Self.secondPart))
    }

    /// The wordmark — **capitals, letter-spacing, two-color break.**
    ///
    /// **Taken over from the phone** (`BrandMark.swift`), but not completely:
    ///
    /// * **Capitals and letter-spacing come along.** Letter-spaced capitals at three meters are the
    ///   direct countermeasure against letters running together — exactly the
    ///   distance this app is built for.
    /// * **The two-color break comes along.** "Cine" is the origin, "Lounge" the
    ///   claim; the accent color lies on the second, because the eye
    ///   rests at the end of the line.
    /// * **The stacking stays there.** "CINE" over "LOUNGE" is the answer to a
    ///   44 pt tall header on the phone — narrow instead of wide. Here the bar is 348 pt
    ///   wide and height is free; stacked it would look cramped where nothing is cramped.
    private var wordmark: some View {
        HStack(spacing: 0) {
            Text(verbatim: Self.firstPart)
                .foregroundStyle(ColorRole.text.color)
            Text(verbatim: Self.secondPart)
                // **The brand and not the focus color** — see ``brandColor``.
                .foregroundStyle(Self.brandColor)
        }
        .font(TypeLevel.footer.font)
        .fontWeight(.semibold)
        .tracking(2.4)
        .lineLimit(1)
    }

    static let firstPart = "CINE"
    static let secondPart = "LOUNGE"

    /// How tall the symbol stands — the same number as `HOEHE` in
    /// `scripts/brand_mark.py`. If the two diverge, the image gets scaled.
    static let logoHeight: CGFloat = 40

    /// **The brand is separate from the focus color** (AP27, 2026-09-11).
    ///
    /// `Color(.brand, .bright)` stood here, and that resolves via ``AccentPalette`` to
    /// `Theme.current.accent` — in the "Mitternacht" pattern thus to a **blue**
    /// hue. The wordmark thereby changed color as soon as someone switched the pattern.
    ///
    /// **A brand doesn't change color, a focus ring does.** The ring remains
    /// fixed per pattern (``Styling/ColorRole/tag``); what becomes fixed here is
    /// the brand alone. **No new ring role, one line.**
    static let brandColor = Color(hex: 0xE2564A)

    // MARK: - Live with groups

    /// Whether "Live" expands the channel lists.
    ///
    /// **As soon as there is one** (product decision 2026-08-22). Until then it said
    /// "only from two" here — with one, the level would be an intermediate step to
    /// itself. Thrifty thinking, but the price was visibility: The user
    /// wished for this level **although it had long existed** — it was
    /// hidden behind a condition that occurs only when one happens to
    /// create a second list. A function you find only if you
    /// already know it is not one.
    ///
    /// The arrow thus remains an honest announcement even with one list: It
    /// shows that lists live here and where a second one would appear.
    ///
    /// **No "All channels" entry** (product decision 2026-08-22): Everything together
    /// is the press on "Live" itself — one row fewer, and the parent row
    /// thereby has a job instead of merely expanding.
    ///
    /// **And only the lists, no groups** (2026-08-10). The groups moved into
    /// the player: two swipes left, and you switch them without
    /// leaving playback. Hundreds of them stood here, through which
    /// nobody scrolled — and because the list is limited to the screen height,
    /// not all were ever visible anyway.
    private var showsProviders: Bool { Self.showsProviders(for: liveProviders) }

    /// The rule for it, testable on its own — the same design as
    /// ``NativePlaybackEngine/firstFrameVerdict``. It is one line and
    /// **was nevertheless wrong once before**; a check records the
    /// decision instead of merely claiming it in the comment.
    static func showsProviders(for providers: [LiveProvider]) -> Bool {
        showsProviders(forIDs: providers.map(\.id))
    }

    /// The same rule, just on the identifiers — so that "Live" and
    /// "Movies & Series" don't have two versions of the same decision.
    ///
    /// **Own name instead of an overload:** `showsProviders(for: [])` would be
    /// ambiguous between the two versions, and the compiler would report it at
    /// the call site instead of here.
    ///
    /// **Never since 2026-09-30** (AP59 N5): The bar is single-level. Providers and groups
    /// are chosen in the content, where the genre is also chosen — up to three levels in the bar
    /// cost focus work for something that is a filter.
    static func showsProviders(forIDs ids: [String]) -> Bool {
        false
    }

    @ViewBuilder
    private var liveSection: some View {
        row(
            .live,
            titleKey: "tab.live",
            symbol: "dot.radiowaves.left.and.right",
            // The arrow appears only if there is something to expand. An
            // arrow with nothing behind it is a promise the app
            // doesn't keep.
            accessory: !showsProviders
                ? nil : (expanded == .live ? "chevron.down" : "chevron.right")
        ) {
            // **A press opens the most recently watched channel — from ALL
            // lists.** That is also the way to the overall view, since a
            // row of its own "All channels" deliberately doesn't exist. Expansion
            // happens on the side: You see what you could choose from, without
            // playback waiting for it.
            if showsProviders { expanded = expanded == .live ? nil : .live }
            selection = .live
            onLive(nil)
        }

        if expanded == .live, isExpanded, showsProviders {
            // **The channel lists** (schedule P6, P15): Live → list, one level
            // and not two. The groups below moved into the player on 2026-08-10,
            // where you can switch them without leaving
            // playback.
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(liveProviders) { provider in
                            row(
                                .liveProvider(provider.id),
                                title: provider.name,
                                symbol: "antenna.radiowaves.left.and.right",
                                indented: true
                            ) {
                                selection = .liveProvider(provider.id)
                                onLive(provider.id)
                            }
                            .id("provider-" + provider.id)
                        }
                    }
                }
                // **Height by content, capped** — not `maxHeight`, otherwise
                // the scroll view takes all the rest, see ``listHeight(forRows:)``.
                .frame(height: Self.listHeight(forRows: liveProviders.count))
                .focusSection()
                // **Back to the place where you were.** If you return from the
                // channels, the list is created anew — it hangs on
                // ``isExpanded``, and that hangs on focus. tvOS then has nothing
                // to remember and puts focus on the
                // first row.
                //
                // **Tied to the expansion and not to `onAppear`.** That is
                // the difference between once and endless: `onAppear` fires
                // on every rebuild, and since the body sets focus, it thereby triggers
                // the next one. The bar once got stuck on exactly that.
                .onChange(of: isExpanded) { _, expanded in
                    guard expanded, case .liveProvider(let provider) = selection else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(120))
                        // Register only if the assignment also changes something:
                        // Otherwise the registration would stay armed, because `onChange`
                        // doesn't run at all, and the next real step
                        // onto the same row would count as an own assignment.
                        if focus != .liveProvider(provider) { selfSet = .liveProvider(provider) }
                        focus = .liveProvider(provider)
                        scroller.scrollTo("provider-" + provider, anchor: .center)
                    }
                }
            }
        }
    }

    /// Whether "Movies & Series" expands the lists — the same rule as for "Live".
    private var showsVODProviders: Bool { Self.showsProviders(forIDs: vodProviders.map(\.id)) }

    /// Movies and series of the provider, with the **lists** to expand.
    ///
    /// **The same mechanism as for Live, and explicitly the same state.** Both
    /// lists share ``expanded``: Whoever opens one closes the other. Two
    /// separate switches could have both open at once, and then the
    /// bar overflows.
    ///
    /// **Until 2026-08-22 the genres stood here** — "Action", "Netflix Production"
    /// and so on. They moved into the surface, for two reasons: With two
    /// providers "Action" would stand twice one below the other with no visible
    /// difference, and the genres of **series** are different from those of movies —
    /// a flat list couldn't carry both. Since then the bar answers
    /// "where from", the surface "what".
    ///
    /// Without genres the entry doesn't appear at all: Whoever has no channel list with
    /// movies set up should see no area that stays empty.
    @ViewBuilder
    private var vodSection: some View {
        if !vodCategories.isEmpty {
            row(
                .vod,
                titleKey: "tab.vod",
                symbol: "film.stack",
                accessory: !showsVODProviders
                    ? nil : (expanded == .vod ? "chevron.down" : "chevron.right")
            ) {
                if showsVODProviders { expanded = expanded == .vod ? nil : .vod }
                selection = .vod
            }

            if expanded == .vod, isExpanded, showsVODProviders {
                ScrollViewReader { scroller in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Self.rowSpacing) {
                            ForEach(vodProviders) { provider in
                                row(
                                    .vodProvider(provider.id),
                                    title: provider.name,
                                    symbol: "film",
                                    indented: true
                                )
                                .id("vodProvider-" + provider.id)
                            }
                        }
                    }
                    // The same computation as for the channel lists: Whoever has a
                    // list should see no half screen of emptiness below
                    // it.
                    .frame(height: Self.listHeight(forRows: vodProviders.count))
                    .focusSection()
                    .onChange(of: isExpanded) { _, open in
                        // Back to the place where you were — the rationale is given in detail
                        // at the channel lists.
                        guard open, case .vodProvider(let id) = selection else { return }
                        Task {
                            try? await Task.sleep(for: .milliseconds(120))
                            // Registered only on a real change — the
                            // rationale is at the channel lists.
                            if focus != .vodProvider(id) { selfSet = .vodProvider(id) }
                            focus = .vodProvider(id)
                            scroller.scrollTo("vodProvider-" + id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// Whether the portals get a level of their own.
    ///
    /// **The same rule as for Live and Movies & Series**, explicitly via
    /// ``showsProviders(forIDs:)`` and not as a second version of the same
    /// decision: Even a single portal gets the level, because unlike
    /// a channel list the **name** is the information here — which
    /// portal you look at decides what awaits you.
    private var showsPortals: Bool { Self.showsProviders(forIDs: portals.map(\.id)) }

    /// Foreign sources — with the individual portals to expand.
    ///
    /// **No new mechanism.** This form already exists twice in this file:
    /// ``liveSection`` and ``vodSection``. Portals are the third
    /// case of the same form — a parent item that expands, a child item
    /// per provider. And explicitly the same ``expanded`` state: Whoever opens one
    /// closes the others. Three separate switches could all be open
    /// at once, and then the bar overflows.
    @ViewBuilder
    private var portalsSection: some View {
        if !portals.isEmpty {
            row(
                .portals,
                titleKey: "tab.portals",
                symbol: "globe",
                accessory: !showsPortals
                    ? nil : (expanded == .portals ? "chevron.down" : "chevron.right")
            ) {
                if showsPortals { expanded = expanded == .portals ? nil : .portals }
                selection = .portals
            }

            if expanded == .portals, isExpanded, showsPortals {
                ScrollViewReader { scroller in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Self.rowSpacing) {
                            ForEach(portals) { portal in
                                row(
                                    .portalProvider(portal.id),
                                    title: portal.name,
                                    // **Not the symbol of the Live providers**, which
                                    // stands a few rows above in the same bar:
                                    // Two entries with the same symbol cannot be told apart
                                    // from three meters' distance — the same rule that already separates the sections of
                                    // Settings (``SettingsSection/symbol``).
                                    // `network` stays in the family of the parent item
                                    // "Portals" (`globe`) without resembling it.
                                    //
                                    // A broken portal stands there with a
                                    // warning symbol instead of being missing.
                                    symbol: portal.icon,
                                    indented: true
                                )
                                .id("portalProvider-" + portal.id)
                            }
                        }
                    }
                    .frame(height: Self.listHeight(forRows: portals.count))
                    .focusSection()
                    .onChange(of: isExpanded) { _, open in
                        // Back to the place where you were — the rationale
                        // is given in detail at the channel lists.
                        guard open, case .portalProvider(let id) = selection else { return }
                        Task {
                            try? await Task.sleep(for: .milliseconds(120))
                            if focus != .portalProvider(id) { selfSet = .portalProvider(id) }
                            focus = .portalProvider(id)
                            scroller.scrollTo("portalProvider-" + id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Entries

    /// What a row **is** — its name, regardless of whether the bar is collapsed.
    ///
    /// Translated rows carry a key, the names of providers and groups
    /// come raw from the access. If both are missing, the label stays empty instead of
    /// invented: A row without a name is a finding, not a reason for a placeholder.
    nonisolated static func label(titleKey: String?, title: String?) -> Text {
        if let titleKey { return Text(appKey: titleKey) }
        if let title { return Text(verbatim: title) }
        return Text(verbatim: "")
    }

    /// What currently **applies** to a row — and not only what it is called.
    ///
    /// **The state is part of the information** (AP30): `chevron.down` versus `chevron.right`
    /// is already guesswork with eyes at three meters; for the screen reader it is nothing
    /// at all. Three states come together here, and they don't exclude each other:
    /// selected, expanded, and "is syncing" (the pulsing of the symbol,
    /// which in the narrow bar is the only feedback anyway).
    nonisolated static func stateReport(
        isActive: Bool, disclosureSymbol: String?, isAligned: Bool
    ) -> Text {
        // **The words stand in one place** (AP30, 2026-09-11): ``SelectionState``
        // in the DesignSystem. The same concatenation stood here once more, and two
        // places for the same information drift apart at the first new state.
        SelectionState.combined(
            states(isActive: isActive, disclosureSymbol: disclosureSymbol, isAligned: isAligned))
    }

    /// The three states of a row — **written down once**, for the information and
    /// for the trait specification at the same time.
    nonisolated static func states(
        isActive: Bool, disclosureSymbol: String?, isAligned: Bool
    ) -> [SelectionState] {
        [
            .chosen(isActive),
            .key(
                disclosureSymbol.map {
                    $0.hasSuffix("down") ? "a11y.state.expanded" : "a11y.state.collapsed"
                }),
            .key(isAligned ? "a11y.state.syncing" : nil),
        ]
    }

    private func row(
        _ destination: Destination,
        titleKey: String? = nil,
        title: String? = nil,
        symbol: String,
        indented: Bool = false,
        // Third level: groups under an expanded provider. Only the
        // indent grows and the symbol shrinks — the font stays at the
        // legibility limit, as between the first and second level too.
        deepIndented: Bool = false,
        accessory: String? = nil,
        pulses: Bool = false,
        profile: SidebarProfile? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        let isActive = selection == destination
        let lit = Self.litRow(focus: focus, chosen: focusWasChosen, selection: selection)
        let isFocused = lit == destination

        return Button {
            if let action {
                action()
            } else {
                selection = destination
            }
        } label: {
            HStack(spacing: Self.iconGap) {
                // Symbols grow with the font. If they stay put, the row
                // looks not larger but merely airier — and the hierarchy between
                // main entry and group disappears.
                if let profile, profile.hasImage {
                    // **The profile picture, where one is chosen** — you see in every view
                    // who is signed in. In focus a bright ring, as in the switcher.
                    ProfileCircle(
                        letter: profile.letter, avatar: profile.avatar,
                        edge: Self.profileSize, font: TypeLevel.footer.font,
                        letterColor: ColorRole.text.color, surface: ColorRole.surfaceHigh.color,
                        frame: isFocused ? ColorRole.text.color : nil
                    )
                    .frame(width: Self.iconWidth, height: Self.iconWidth)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: deepIndented ? 21 : (indented ? 24 : 28)))
                        .frame(width: Self.iconWidth)
                        // The running sync pulses — visible also in the
                        // narrow bar, where no label would have room.
                        .symbolEffect(.pulse, isActive: pulses)
                }

                if isExpanded {
                    if let titleKey {
                        Text(appKey: titleKey)
                    } else if let title {
                        Text(verbatim: title)
                    }
                }

                Spacer(minLength: 0)

                if isExpanded, let accessory {
                    Image(systemName: accessory)
                        .font(.system(size: 22))
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            // **Both levels at the legibility limit**, not below it. The hierarchy
            // is carried by indentation, symbol size and stroke weight — see ``rowHeight``.
            .font(TypeLevel.text.font)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(foreground(isActive: isActive, isFocused: isFocused))
            .lineLimit(1)
            .padding(.leading, deepIndented ? 52 : (indented ? 34 : Self.rowLeadingInset))
            .padding(.trailing, Self.rowTrailingInset)
            // Fixed height instead of inner padding: The height of the bar is computed against
            // the screen height (see ``maximumVisibleGroups``), and a computation
            // with values that result from the font would be only estimated.
            .frame(
                maxWidth: .infinity,
                minHeight: indented ? Self.groupRowHeight : Self.rowHeight,
                maxHeight: indented ? Self.groupRowHeight : Self.rowHeight,
                alignment: .leading
            )
            .background(
                background(isActive: isActive, isFocused: isFocused),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: destination)
        // **The label stands at the factory, not at twelve rows** (AP30,
        // 2026-09-11). Every row of the bar comes out here, so one grip covers
        // them all — the same split as with the two button factories from AP26.
        //
        // **And the collapsed bar is the actual case.** There **no
        // text** stands, only a symbol: Whoever looks with the screen on recognizes
        // the symbol; the screen reader got nothing up to here. `Text` is bound to
        // `isExpanded` in the body, the label here explicitly is not.
        //
        // **`children: .ignore` and not `.combine`:** Otherwise the reader would read the name
        // of the symbol along (`chevron.down`), and that is not information but a
        // file name.
        .info(
            Self.label(titleKey: titleKey, title: title),
            Self.states(isActive: isActive, disclosureSymbol: accessory, isAligned: pulses)
        )
        // **The menu button hangs on the row, not on the section** — and that is
        // the difference between "leads one level out" and "is without effect on
        // 'Media library'".
        //
        // Before, it hung over the whole bar. An attached
        // `onExitCommand` consumes the button even if its body
        // does nothing — on "Media library" it was thereby dead, and one got out of the app only via
        // the Home button. Attaching it conditionally was ruled out as long as the
        // condition hung on **focus**: It flipped on every change within the
        // bar, swapped out the subtree and drove the restoration of the
        // group focus into an endless loop.
        //
        // On the row it hangs on the row's **own** identifier. That never
        // changes, so nothing flips — and the "Media library" row simply attaches
        // no catcher. There the button passes through to tvOS and does what it
        // should.
        .exitCommand(isActive: destination.stepOut != nil) {
            guard let out = destination.stepOut else { return }
            if focus != out { selfSet = out }
            focus = out
        }
    }

    /// Three states must be clearly distinguishable: selected, in focus,
    /// and both at once. At three meters' distance a fine gradation
    /// can't be recognized, and you press on the wrong entry.
    private func foreground(isActive: Bool, isFocused: Bool) -> Color {
        if isFocused { return ColorRole.reason.color }
        return isActive ? ColorRole.text.color : ColorRole.textMatt.color
    }

    private func background(isActive: Bool, isFocused: Bool) -> Color {
        if isFocused { return ColorRole.text.color }
        return isActive ? ColorRole.text.color.opacity(0.12) : .clear
    }
}

/// What the sidebar needs from the active profile — picture and initial letter.
struct SidebarProfile: Equatable {
    let avatar: String?
    let letter: String

    var hasImage: Bool {
        if case .image = AvatarMotif.appearance(avatar: avatar) { return true }
        return false
    }
}
