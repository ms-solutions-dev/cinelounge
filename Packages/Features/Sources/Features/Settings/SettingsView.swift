import Core
import DesignSystem
import JellyfinKit
import PlaylistKit
import PortalKit
import ProfileKit
import RatingsKit
import SwiftUI

/// The settings: sections on the left, content on the right.
///
/// The rationale for the structure is at ``SettingsSection`` — in short: on a
/// TV a long page is especially bad, because you scroll through everything with the
/// remote to reach the last item.
struct SettingsView: View {

    /// Access to the media server — **optional since AP29 (2026-09-11).**
    ///
    /// It alone carries the header: name and machine. Anyone who has none gets the
    /// heading and the kids-mode note there — **and not, say, "—" in place of the
    /// name.** An empty line says "something is missing here"; an omitted row says
    /// nothing, and that is exactly right here.
    let credentials: ServerCredentials?

    /// The way out of the settings — **the second stage of the menu button.**
    ///
    /// Empty by default, so that the checks can build this view without a shell; in the
    /// app, ``MainView`` uses it to put the focus on the sidebar's gear.
    var onLeaveToSidebar: () -> Void = {}
    let languages: LanguageSelection
    let onSignOut: () -> Void
    /// After an account switch in ``AccountsView``.
    let onAccountSwitched: (ServerCredentials?) -> Void
    /// Leads into the setup to add another account.
    let onAddAccount: () -> Void

    /// The parental controls in effect — **one for both sections.**
    ///
    /// `Account` and `ParentalControls` sit behind the same door and therefore share
    /// the same pass: anyone who has unlocked one should not have to
    /// type a second time for the other — it is the same action.
    @StateObject private var childLock = ParentalControlsState()

    /// What is not yet set up on this device (AP46, 2026-09-23).
    ///
    /// **Calculated here and not at the two call sites** that need the marker:
    /// two places that compose the same state drift apart at the next section
    /// — and then the list would carry a marker that the VoiceOver text
    /// does not know.
    ///
    /// **Three of the four statements are in the Keychain** and therefore need no
    /// further parameter on this view. The fourth, the channel lists, comes from the
    /// catalog it has anyway.
    /// Whether the CL-Server is missing for the profile — see ``setup``.
    nonisolated static func withoutCLServer(_ profile: Profile?) -> Bool {
        guard let profile else { return true }
        return !profile.wantsPortals || profile.portalPerson == nil
    }

    private var setup: SetupState {
        let keychain = SecureStore()
        return SetupState(
            lacksChannelLists: playlists.visiblePlaylists.isEmpty,
            // **By profile, not by device** (2026-09-28): the device flag knows
            // only the first-time setup; anyone who set up the CL-Server here kept the ⊕.
            // Set up means: the profile wants it, and a person is selected.
            lacksPortals: Self.withoutCLServer(ProfileBook.read(from: FileStore()).activeProfile),
            // **Even a single missing key counts.** The two services
            // deliver different things; anyone who has only one lacks what the other can do.
            lacksRatingsKey: keychain.omdbAPIKey() == nil
                || keychain.tmdbAPIKey() == nil,
            withoutAccess: (try? keychain.loadCredentials()) == nil)
    }
    let onRatingsKeyChanged: (String) -> Void
    /// Like ``onRatingsKeyChanged``, for the film database.
    let onFilmographyKeyChanged: (String) -> Void
    /// The media server — **optional since AP29 (2026-09-11).**
    ///
    /// **The settings could be reached only via the library**, and
    /// that did not exist without a media server. Anyone who had only a channel list therefore
    /// could not reach any setting — not even the one with which they would have added a media
    /// server. The sections that really need it now ask first.
    let source: JellyfinSource?
    let playlists: PlaylistStore
    /// The group names of the loaded channel lists, for the "Live" section.
    ///
    /// **Without a default value, on purpose.** Here stood `= []`, "until the frame
    /// passes them through" — and the frame never did: the call in ``MainView`` left the
    /// parameter out, the default value made that invisible, and the group list
    /// under "Live" stayed permanently empty although the sidebar had long been showing the same groups.
    /// A required parameter turns this mistake into a
    /// compile error — the only kind that is not first noticed on the TV.
    let liveGroups: [String]
    /// The channel catalog for counting the adult channels — not a
    /// second fetch, but the same one as in the Live section.
    var liveStock: @Sendable () async -> [Channel] = { [] }

    /// The bridge for the "Portals" section. `nil` means: none set up —
    /// then only the address under which it would be tried appears there.
    var portalSource: PortalSource?

    /// The portal levels — **fully loaded and not fetched here.**
    ///
    /// **The finding of 2026-09-12, from the product owner:** although portals are set up,
    /// nothing can be selected here. The folder selection asked `source.libraries()`, and
    /// `source` is the **media server** — portal levels never arrive there. The shell has
    /// long since loaded them (``MainView`` holds them for the sidebar); fetching them a second
    /// time would be a fetch for a list that is already there.
    var portalLibraries: [Core.Library] = []
    /// The sections of the provider catalog — **from outside for the same reason** as the
    /// portal levels above: `source` is the media server, and they never arrive there.
    /// The shell holds them for the sidebar; here the shelves are selected from them.
    var providerCategories: [Core.Library] = []
    /// The address of the bridge as it is tried. **To be shown even when
    /// nothing answers** — otherwise nobody knows where to look.
    var portalAddress: String = ""
    /// After a changed bridge address — the source is rebuilt.
    let onPortalBridgeChanged: () -> Void

    /// Discards the loaded channel catalog — for the refresh button of the
    /// channel lists. Without a default value, reason at ``liveGroups``.
    let onPlaylistsRefresh: () async -> Void

    /// The selected section — read from the store on construction.
    ///
    /// The same pattern as ``PlaybackSettings`` with ``AudioPreference`` and
    /// ``DiagnosticsSettings`` with ``DebugMode``: the initial value is there at the
    /// first render, not only after a `task` — otherwise you would see the
    /// jump from the first item to the remembered one.
    @State private var section: SettingsSection = .load(from: SecureStore())
    @FocusState private var focus: String?
    /// What the wait time is running for — see ``AppSidebar``.
    @State private var wrapPending: (from: String?, step: Int)?
    /// The running wait time of the wrap-around — reason at ``AppSidebar/wrapDelay``.
    @State private var wrapTask: Task<Void, Never>?

    /// When the focus last moved — for the edge-press check of the
    /// wrap-around, see ``AppSidebar/isEdgePress(lastFocusMove:now:)``.
    @State private var focusMovedAt = Date.distantPast
    /// The topmost entry of the section shown — from its preference.
    @State private var firstEntry: String?
    /// The request to the section to focus its topmost entry —
    /// a counter, each step one request.
    @State private var entryRequest = 0
    /// The last directional press and when — for the rule on whether a jump into
    /// the content was intended (``isUnbiddenContentEntry(previous:current:lastMove:now:)``).
    @State private var lastMove: (direction: MoveCommandDirection, at: Date)?
    /// The last step from the section list into the content — and the
    /// check on whether a right-press confirms it (``entryConfirmation``).
    /// What the focused row reports about itself — `nil` as long as none has a card.
    @State private var reported: CardSpec?

    /// The card reported last — it carries **while the focus is in it**.
    @State private var pinned: CardSpec?

    @State private var contentEntry: (from: String, at: Date)?
    @State private var entryCheck: Task<Void, Never>?

    // MARK: - Dimensions
    //
    // As constants and not as bare numbers in the body, so that `SettingsViewTests`
    // can recompute that the heading and section entries fit in their column.
    // Text that is too long does not wrap visibly here, but in the middle of a word —
    // "Einstellung/en" stood like that for weeks on every settings screen.

    /// Width of the section list on the left, including its insets.
    static let sectionListWidth: CGFloat = 380
    /// Distance of the content on the right to the divider line and to the edge.
    static let contentInset: CGFloat = 40

    /// The width of the row column in the middle.
    ///
    /// **The number already existed, only at nineteen places as `maxWidth: 900`.** It lives
    /// here since a third column stands next to it on the right: from now on it determines whether all
    /// three fit on one screen, and that is a calculation — not a preference.
    static let contentWidth: CGFloat = 900

    /// The width of the card on the right (``SettingsCard``).
    ///
    /// **400, close to the 424 of the mock-up.** Until 2026-09-27 this was 480 with
    /// margins of 52 — and the sum only worked out because it did not count the main bar on the left.
    /// With it, it came to 2032 points: the centred row cut off the bar on the left
    /// and the card on the right (on-device test T5/T10).
    ///
    /// **The sum must work out next to the collapsed bar:** 116 + 1 + 380 + 40 +
    /// 900 + 40 + 400 + 40 = 1917 of 1920. ``SettingsViewTests`` recomputes it. The
    /// row column keeps its 900, because the rows hang on it.
    static let cardWidth: CGFloat = 400
    /// Inner padding of the section list to its two edges.
    static let listPadding: CGFloat = 20
    /// Indent of the heading and account name within the list.
    static let headerInset: CGFloat = 14
    /// Innenabstand eines Bereichseintrags zu seinem Kapselrand.
    static let entryInset: CGFloat = 18
    /// Space for the symbol of a section entry — fixed, so that the labels
    /// of all rows begin at the same place.
    static let entryIconWidth: CGFloat = 26
    /// Gap between symbol and label.
    static let entryGap: CGFloat = 14

    /// Font size of the heading: `title3`, not `title`.
    ///
    /// Measured with CoreText: "Einstellungen" needs 356 points at 57 pt bold
    /// and wraps in the column without a hyphen in the middle of the word — as
    /// "Einstellung/en", in the largest font on the page, in all seven
    /// sections. At 48 pt it is 301 points, and that fits. The scale factor on
    /// the heading remains regardless: a future translation that uses up the 11 points
    /// of slack should shrink rather than break.
    static let titleSize: CGFloat = TypeLevel.section.points

    /// What is left for the heading in the column.
    static var titleWidth: CGFloat {
        sectionListWidth - 2 * listPadding - 2 * headerInset
    }

    /// Font size of the section entries: `body`, not `caption`.
    ///
    /// "A navigation entry must be read" — with this rule the
    /// sidebar was raised to 29 pt (see ``AppSidebar/rowHeight``), and this
    /// list is the same kind of list: both can stand next to each other on screen,
    /// two sizes for the same purpose would be a visible contradiction.
    static let entrySize: CGFloat = TypeLevel.text.points

    /// What is left for the label of a section entry.
    ///
    /// Calculated, because truncation goes unnoticed: the entries are set with
    /// `lineLimit(1)`, too little space means an ellipsis. The widest
    /// entry of the three languages is "Değerlendirmeler" at 229 points at 29 pt
    /// semibold — German is not the worst case.
    static var entryTextWidth: CGFloat {
        sectionListWidth - 2 * listPadding - 2 * entryInset - entryIconWidth - entryGap
    }

    // MARK: - The list scrolls
    //
    // **Until 2026-09-25 it was not allowed to**, and `SettingsViewTests` recomputed on
    // every run that eleven entries and three gaps fit in 1080 pt. With
    // fourteen sections and four visible group headers this calculation no longer
    // works out, and product decision 1 lifts it: **group headers visible, the
    // section list scrolls.** What the calculation protected — that every entry is
    // reachable — is now protected by the focus: tvOS scrolls the focused entry into
    // view, and ``groupHeaderInView(forItem:)`` takes the header of its group along.

    /// **12 and not 15** (AP26, 2026-09-11) — three points of padding per row side
    /// cost nothing visible; the row keeps 62 pt for a 29-pt font. **Since
    /// AP26 (row building blocks) the number lives in ``SettingsMetrics``** — the same padding
    /// is carried by the list and the content next to it, so that both columns keep the same rhythm.
    static let entryVerticalInset: CGFloat = SettingsMetrics.vertical

    /// The height of a row: text line plus padding above and below.
    static var entryHeight: CGFloat {
        TypeLevel.lineHeight(zu: entrySize) + 2 * entryVerticalInset
    }

    /// The gap between two entries of the same group.
    static let entrySpacing: CGFloat = 6

    /// The gap above a group header — **except above the first one**, which stands directly under
    /// the heading.
    static let groupSpacing: CGFloat = 22

    /// The vertical padding of the whole column.
    static let listVerticalInset: CGFloat = 40

    /// The identifier under which a group header sits in the scroll view.
    nonisolated static func groupHeaderID(_ group: SettingsSection.Group) -> String {
        "gruppe-" + group.rawValue
    }

    /// **Which group header must come into view with a focused section** — or `nil`.
    ///
    /// tvOS scrolls the focused entry into view, but only it. Anyone going from "Display"
    /// up to the first section of a group — or jumping via the wrap-around from the end
    /// to "Media server" — would see the entry without the header above it, and the header
    /// is exactly the information it is there for. That is why, at the **first
    /// section of a group**, the list additionally scrolls its header into view; for all others the
    /// header is further up anyway and not meant.
    nonisolated static func groupHeaderInView(forItem area: SettingsSection) -> SettingsSection.Group? {
        area.startsGroup ? area.group : nil
    }

    /// Which card appears on the right (AP46, decision 6).
    ///
    /// **The core problem of the walkable card, as a calculation:** when the focus goes into the
    /// card, the row loses it, reports nothing any more — and the card would disappear under
    /// the focus. As long as the focus is in it, the held one therefore applies; otherwise whatever
    /// is reported, even if that means `nil`.
    nonisolated static func displayedCard(
        reported: CardSpec?, pinned: CardSpec?, focusInCard: Bool
    ) -> CardSpec? {
        focusInCard ? (reported ?? pinned) : reported
    }

    /// Whether the focus is on a pill of the card.
    nonisolated static func isInCard(_ focus: String?) -> Bool {
        focus?.hasPrefix(SettingsCard.focusPrefix) == true
    }

    /// The height of a tvOS screen.
    static let screenHeight: CGFloat = 1080

    /// The width of a tvOS screen.
    ///
    /// **Since AP46 a measure and not just a fact:** three columns side by side
    /// have to fit in it, and what sticks out on the right is gone — a page that is too wide
    /// cannot be scrolled down like one that is too long.
    static let screenWidth: CGFloat = 1920

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sectionList

            Divider().overlay(ColorRole.lineQuiet.color)

            ScrollView {
                content
                    .padding(.horizontal, Self.contentInset)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            // **The row column is limited since the card stands on the right** (AP46,
            // 2026-09-24). Before, the content took the whole width and the blocks
            // limited themselves individually to 900; a row that forgot this simply ran
            // on. Now the limit is that of the column, and the card has its place.
            .frame(width: Self.contentWidth + 2 * Self.contentInset)
            // **The card hangs on the scroll area and not on the row that reports it.**
            // It receives its work from the same direction as the first target: the row in
            // focus puts it into a preference, here it is picked up. A mapping from
            // identifiers to cards would be a second list next to the sections — and the
            // first to become outdated with a new section.
            .onPreferenceChange(CardKey.self) { fresh in
                reported = fresh
                if let fresh { pinned = fresh }
            }
            // **The row asks, the page leads:** a row with four or more values
            // enters the card on its selected value (``EnterCardKey``).
            .environment(\.enterCard) { identifier in
                focus = SettingsCard.focusPrefix + identifier
            }
            // **The entry into Diagnostics is intercepted, not corrected**
            // (F-041, 2026-09-04: it first jumps into a random diagnostic and then
            // lands at the top). tvOS assigns by geometry — with the long
            // log list that is some row or other, and the correction
            // afterwards was visible as a jump. As long as the section list stands on
            // "Diagnostics", there is an invisible catcher here at the left
            // edge of the content: it is the next target of the right-press, and
            // it passes the focus on immediately to the topmost entry.
            // **Since 2026-09-04 for every section** (user finding: in Storage the focus
            // lands on "Clean up cache" because there is no button directly above):
            // every section names its topmost entry via a preference, and the catcher passes
            // the right-press there.
            .onPreferenceChange(SettingsFirstEntryKey.self) { firstEntry = $0 }
            .environment(\.settingsEntryRequest, entryRequest)
            .overlay(alignment: .leading) {
                if Self.showsContentCatcher(focus: focus, firstEntry: firstEntry) {
                    Color.clear
                        .frame(width: 10)
                        .frame(maxHeight: .infinity)
                        .focusable()
                        .focused($focus, equals: Self.contentCatcherID)
                        .accessibilityHidden(true)
                }
            }
            // **Without this row the right column was not reachable.** The
            // section list on the left carries a `focusSection`, the right side had
            // none — and then the way to the right leads nowhere: you stood on
            // "Channel lists", pressed right, and nothing happened. The button for
            // adding was visible and unreachable.
            //
            // The reason lies in the divider line in between: it is not
            // focusable, but it interrupts the direct neighbourhood along which
            // the focus moves on tvOS. Two named sections restore
            // the connection without the line having to give way.
            .focusSection()

            // **Without `focusSection` and without a divider line.** The card takes no focus
            // (``SettingsCard``); a section of its own would be an invitation that leads
            // nowhere, and a line would turn the explanation into a third section
            // of equal rank. It belongs to the row on the left, not next to it.
            SettingsCard(
                spec: Self.displayedCard(
                    reported: reported, pinned: pinned,
                    focusInCard: Self.isInCard(focus)),
                focus: $focus,
                onSelected: { pinned = pinned?.withSelection($0) }
            )
            .padding(.trailing, Self.contentInset)
        }
        .background(ColorRole.reason.color)
        // **Cut off instead of shifted** when the main bar expands (T5): the
        // three columns have fixed widths and cannot shrink. Without
        // `minWidth: 0` the view reported its full width upward, the shell's row
        // became wider than the screen and tvOS centred it — the bar
        // lost its left half. This way the view takes what is left over, and on the right
        // the card temporarily disappears.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(pinSheet)
        .modifier(ShelfCatchUp(lock: childLock))
        // **The menu button gets its intermediate stage** (AP26, 2026-09-11). Until then
        // it led from every point in one step to the gear of the
        // sidebar — even from the middle of a section. The way back into the
        // section list, which you mean nine times out of ten, did not exist.
        //
        // **Attached unconditionally, the body decides.** A condition hanging on the focus
        // (`if … { .onExitCommand … }`) is exactly the mistake that once drove the
        // sidebar into an endless rebuild: the tree changes,
        // tvOS reassigns, the condition flips, the tree changes. So it is always
        // there, and the body asks where the focus is.
        //
        // **And exactly ONE.** A second one in ``MainView`` above it consumed the button
        // even with an empty body — the one that was there before has moved here,
        // because only this view knows whether the focus is in the content or in the list.
        .onExitCommand {
            if Self.section(ofFocus: focus) != nil || focus == Self.listEntryID
                || focus == Self.listReturnID
            {
                // Already in the list — the next stage is the sidebar.
                Diagnostics.cursorKey("Einstellungen", "Menu → sidebar")
                onLeaveToSidebar()
            } else {
                // Somewhere in the content: back to the section you are in.
                Diagnostics.cursorKey("Einstellungen", "Menu → section list")
                focus = Self.sectionPrefix + section.id
            }
        }
    }

    // MARK: - Sections

    /// The section list: the heading, below it the scrolling list with group headers.
    ///
    /// **The heading does not scroll along.** It says who is watching and on which server —
    /// that applies to every section, even the fourteenth.
    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountHeader

            ScrollViewReader { role in
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.entrySpacing) {
                        ForEach(SettingsSection.allCases) { entry in
                            if entry.startsGroup {
                                groupHeader(entry.group, first: entry == SettingsSection.allCases.first)
                            }
                            sectionButton(entry)
                        }
                    }
                    .padding(.bottom, Self.listVerticalInset)
                }
                .onChange(of: focus) { _, fresh in
                    guard let area = Self.section(ofFocus: fresh),
                        let group = Self.groupHeaderInView(forItem: area)
                    else { return }
                    withAnimation(Tokens.Focus.animation) {
                        role.scrollTo(Self.groupHeaderID(group), anchor: nil)
                    }
                }
            }
        }
        .padding(.top, Self.listVerticalInset)
        .padding(.horizontal, Self.listPadding)
        .frame(width: Self.sectionListWidth, alignment: .leading)
        // Its own section, so that the focus jumps between list and content as a whole
        // and does not get stuck on the nearest element.
        .focusSection()
        // **Entering from the left lands on the active section, not at the
        // end of the list** (on-device finding: the selection starts at the bottom instead of the top).
        // The sidebar's gear sits at the very bottom; tvOS searches geometrically
        // and hit "Account" — and because the section follows the focus, the
        // display switched away at once from what you wanted to open. The catcher stands at the
        // left edge of the list, intercepts the press before the entries and passes
        // it on to the active section. It exists only while the focus is
        // outside the list — otherwise it would get in the way of moving around (the
        // teardown trap of the filter row, see ``LibraryView``).
        .overlay(alignment: .leading) {
            entryCatcher(id: Self.listEntryID)
        }
        // **And the same catcher at the right edge, for the way back from the
        // content** (user request 2026-08-07): anyone who stands in "Playback" on the right and
        // goes left should land on "Playback" — not where the
        // focus memory or the geometry happens to point.
        .overlay(alignment: .trailing) {
            entryCatcher(id: Self.listReturnID)
        }
        // **At the top and bottom the section list wraps around** (user request 2026-08-11).
        // The rule lives as a value in ``SettingsSection/wrapped(from:by:)`` —
        // what arrives here is only what the focus has not consumed itself,
        // that is, the press beyond the edge.
        .onMoveCommand { direction in
            // Into the focus trail, as in the sidebar — until 2026-08-15
            // this section had only focus rows and no button rows: the
            // reported double jump ("every seventh click") could not be held
            // against the presses here, the instrument was one-sided.
            Diagnostics.cursorKey("Einstellungen", FocusTrail.name(direction))
            lastMove = (direction, Date())
            guard direction == .up || direction == .down else { return }
            // **Wait first, then wrap** — the measurement for it is at
            // ``AppSidebar/wrapDelay``. Here it was "every seventh press is a
            // double jump", in the bar every sixth: both the place where
            // the list wraps, and both the same cause.
            let on = focus
            let step = direction == .down ? 1 : -1
            // **A second press does not restart the wait time** — reason
            // and measurement at the same place in ``AppSidebar``.
            if let wrapPending, wrapPending.from == on, wrapPending.step == step { return }
            wrapTask?.cancel()
            wrapPending = nil
            // **Only a real edge press plans a wrap** — the rule and
            // the numerical finding ("eight entries, every seventh press") are at
            // ``AppSidebar/isEdgePress(lastFocusMove:now:)``.
            guard AppSidebar.isEdgePress(lastFocusMove: focusMovedAt) else { return }
            guard let current = Self.section(ofFocus: focus),
                SettingsSection.wrapped(from: current, by: direction == .down ? 1 : -1) != nil
            else { return }
            wrapPending = (on, step)
            wrapTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(AppSidebar.wrapDelay))
                defer { wrapPending = nil }
                guard !Task.isCancelled, focus == on,
                    let current = Self.section(ofFocus: focus),
                    let next = SettingsSection.wrapped(from: current, by: step)
                else { return }
                focus = Self.sectionPrefix + next.id
            }
        }
        // The section follows the focus — the same rule as with the pill above and with
        // the seasons. Anyone moving through the list wants to see where they stand; an
        // additional press per stop is pure work on the remote.
        .onChange(of: focus) { previous, current in
            // For the edge-press check of the wrap-around: when the focus last
            // really moved.
            focusMovedAt = Date()
            // **The entry into Diagnostics begins at the top** (user request
            // 2026-08-15: when I navigate into Diagnostics I want to be at the top,
            // not in the middle or somewhere else). tvOS assigns by geometry when entering the
            // content — with a long log list that is
            // some row in the middle. Only the step from the section list into
            // the content is corrected; anyone moving within the content
            // is left undisturbed.
            // **A jump into the content without a right-press is none** (on-device finding
            // 2026-09-04, "millisecond jumps"): when moving through the list,
            // the focus landed in the content **in the same beat** as the switch to "Diagnostics"
            // ("section-diagnostics → sendLog +0 ms") and was then
            // corrected to the switch — two jumps that nobody
            // triggered. Anyone who has not pressed right stays on
            // their section.
            // **The focus moves BEFORE the key command** (F-043, 2026-09-04): the
            // jump into the content appears in the trail at +0 ms, the right-press
            // arrives in `onMoveCommand` 50–70 ms later. A guard that decides at the
            // same instant takes back real right-presses —
            // pressing three times for one entry. That is why it decides only
            // after a short grace period: if a right-press arrived by then, the
            // entry stays; otherwise it was the geometry, and it goes back.
            if let from = previous, Self.isContentEntry(previous: previous, current: current) {
                contentEntry = (from, Date())
                entryCheck?.cancel()
                entryCheck = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Self.entryConfirmation))
                    guard !Task.isCancelled, let entry = contentEntry else { return }
                    contentEntry = nil
                    guard Self.section(ofFocus: focus) == nil, focus != Self.listReturnID else { return }
                    if Self.isConfirmedEntry(lastMove: lastMove, since: entry.at) { return }
                    Diagnostics.cursorKey(
                        "Einstellungen", "Jump into the content without a right press — back")
                    focus = entry.from
                }
            }
            if current == Self.contentCatcherID {
                // **The sections keep their own focus** (on-device finding
                // F-044: no longer able to get into the sections at all —
                // an identifier from a foreign focus state is worth nothing here).
                // Only Diagnostics hangs on this focus; all others get
                // a request via the environment and accept it themselves.
                if section == .diagnostics {
                    Diagnostics.cursorKey("Einstellungen", "Entry intercepted → \(Self.diagnosticsTopID)")
                    focus = Self.diagnosticsTopID
                } else {
                    Diagnostics.cursorKey("Einstellungen", "Entry intercepted → section \(section.id)")
                    entryRequest += 1
                }
                return
            }
            if let corrected = Self.correctedDiagnosticsEntry(from: previous, to: current) {
                Diagnostics.cursorKey("Einstellungen", "Entry corrected to Diagnostics")
                focus = corrected
                return
            }
            if current == Self.listEntryID || current == Self.listReturnID {
                focus = Self.sectionPrefix + section.id
                return
            }
            guard let entry = Self.section(ofFocus: current) else { return }
            section = entry
        }
        // **One writer, and it is this one.** The section changes in two
        // ways — by pressing an entry and when moving through the list.
        // Two writers on the same question drift apart sooner or later;
        // here the remembering hangs on the value itself and not on the
        // ways that set it.
        .onChange(of: section) { _, current in
            current.save(to: SecureStore())
        }
        // Observes only — see ``focusTrail(_:_:)``.
        .focusTrail("Einstellungen", focus)
    }

    /// An invisible catcher over the full list height.
    ///
    /// It exists only while the focus is outside the list — otherwise
    /// it would get in the way of moving around (the teardown trap of the filter row, see
    /// ``LibraryView``). Both edges carry one: the left for entering from
    /// the sidebar, the right for the way back from the content.
    ///
    /// **"Outside the list" means: not on a section** (on-device finding
    /// 2026-09-04): this used to be `focus == nil`, and on tvOS the focus is never
    /// nowhere — in the content it carries the identifier of a switch. The catcher
    /// at the right edge therefore never existed when it was needed; the press
    /// to the left from "Diagnostics" hit "Ratings" by geometry (same
    /// height), the section followed the focus, was remembered — and the
    /// settings opened the next time on a section that nobody
    /// had chosen (mostly Portals preselected).
    @ViewBuilder
    private func entryCatcher(id: String) -> some View {
        if Self.section(ofFocus: focus) == nil || focus == id {
            Color.clear
                .frame(width: 10)
                .frame(maxHeight: .infinity)
                .focusable()
                .focused($focus, equals: id)
                .accessibilityHidden(true)
        }
    }

    /// Identifier of the invisible entry catcher at the left edge of the section list.
    nonisolated static let listEntryID = "list-entry"
    /// Identifier of the way-back catcher at the right edge.
    nonisolated static let listReturnID = "list-return"

    /// What identifies a section marker — see ``DetailView/seasonPrefix``.
    nonisolated static let sectionPrefix = "section-"

    /// The topmost entry of the Diagnostics content — the entry begins there.
    nonisolated static let diagnosticsTopID = "debugMode"
    /// The catcher at the left edge of the content — see `body`.
    nonisolated static let contentCatcherID = "content-entry"

    /// Whether the catcher is in place: as long as the section list has the focus and the
    /// section has named its topmost entry — Diagnostics knows its own
    /// even without a preference.
    nonisolated static func showsContentCatcher(focus: String?, firstEntry: String?) -> Bool {
        guard let focus else { return false }
        // As long as it holds the focus, it stays — until the section has taken over.
        if focus == contentCatcherID { return true }
        guard focus.hasPrefix(sectionPrefix) else { return false }
        return firstEntry != nil || focus == sectionPrefix + SettingsSection.diagnostics.id
    }

    /// What identifies an entry of the Diagnostics content.
    ///
    /// The identifiers are in ``DiagnosticsSettings``: the switch, the
    /// two buttons and the log rows (`log-…`). As an enumeration of what
    /// **belongs to it** — a rule about everything else would also apply to the
    /// catchers and the section list.
    nonisolated static func isDiagnosticsPaneID(_ id: String) -> Bool {
        id == diagnosticsTopID || id == "measure" || id == "sendLog"
            || id.hasPrefix("log-")
    }

    /// Where the entry into Diagnostics is corrected to — or `nil` if
    /// there is nothing to correct.
    ///
    /// Exactly the step **from the section list** into the content is corrected
    /// (user request 2026-08-15): tvOS assigns by geometry there, and with
    /// a long log list that is some row in the middle. Anyone moving
    /// within the content is left undisturbed — otherwise you would never get away
    /// from the topmost entry again.
    nonisolated static func correctedDiagnosticsEntry(
        from previous: String?, to current: String?
    ) -> String? {
        guard previous == sectionPrefix + SettingsSection.diagnostics.id,
            let current, isDiagnosticsPaneID(current), current != diagnosticsTopID
        else { return nil }
        return diagnosticsTopID
    }

    /// How long after the entry the right-press is waited for, in
    /// milliseconds. Measured: the command arrives 50–70 ms after the focus.
    nonisolated static let entryConfirmation = 200
    /// How far before the entry a right-press still counts as its own.
    nonisolated static let entryGrace: TimeInterval = 0.5

    /// Whether a focus change leads from the section list into the content — the
    /// case that has to be checked for its right-press.
    nonisolated static func isContentEntry(previous: String?, current: String?) -> Bool {
        guard section(ofFocus: previous) != nil, let current,
            section(ofFocus: current) == nil,
            current != listEntryID, current != listReturnID
        else { return false }
        return true
    }

    /// Whether a right-press confirms the entry: shortly before or after.
    nonisolated static func isConfirmedEntry(
        lastMove: (direction: MoveCommandDirection, at: Date)?, since entry: Date
    ) -> Bool {
        guard let lastMove, lastMove.direction == .right else { return false }
        return lastMove.at >= entry.addingTimeInterval(-entryGrace)
    }

    /// The section behind a focus marker — `nil` for the catchers and outside
    /// the list. A function of its own because two places have the same question:
    /// the wrap-around and the following along of the content.
    /// Without actor binding: a pure calculation over values, so that it can be tested without the
    /// main thread.
    nonisolated static func section(ofFocus focus: String?) -> SettingsSection? {
        guard let focus, focus.hasPrefix(sectionPrefix) else { return nil }
        return SettingsSection.allCases.first { sectionPrefix + $0.id == focus }
    }

    /// Which door stands in front of a section.
    ///
    /// **Every section names its door — and "open" is a decision, not a
    /// fallback** (AP40, 2026-09-20).
    ///
    /// **The finding, and it was a hole:** until then there were two cases here and a
    /// `default: "einstellungenOffen"`. Under this `default` lay not only
    /// Display, Playback and Diagnostics, but also **Channel lists, Portals and
    /// Live** — and the shared door board lists all three explicitly as locked:
    /// "A new list brings channels without approvals", "Here is the switch for
    /// the adult channels". A child on the TV could therefore reach exactly the switch in front of
    /// which the whole lock stands; on the phone not. The sentence that stood here — "The
    /// other sections set Display, Playback and Diagnostics" — was simply wrong for
    /// three of nine, and it explained the hole away for three months.
    ///
    /// **That is why there is no `default`.** The translator now demands a line for every new section;
    /// anyone who adds one has to say whether it can lift a limit. That
    /// is the same rule that ``LockedDoors`` enforces for the board, only one
    /// level higher.
    ///
    /// **What stays open is what lifts no limit** — and that on purpose: a lock that
    /// asks at every touch gets switched off. "About" belongs here, because it holds
    /// version, privacy and licences; putting the privacy policy behind a PIN
    /// would contradict the guideline that requires it ("easily accessible").
    nonisolated static func door(forItem area: SettingsSection) -> String {
        switch area {
        // ── Sources: what comes in and what of it is shown ─────────────────────
        case .playlists: "senderlisten"
        case .portals: "portaleEinstellungen"
        case .live: "liveEinstellungen"
        // ── Who is allowed, and on which server ────────────────────────────────
        case .childLock: "kindersicherung"
        // Every way inside carries its own door (``OtherDevicesSettings``); the section itself
        // only shows that they exist.
        case .devices: "einstellungenOffen"
        case .account: "kontoEinstellungen"
        // **The profiles behind the door of the accounts** (2026-09-25): people are
        // created, switched and removed here — a switch lifts every limit. Until then they
        // stood behind "kontoEinstellungen", because they lay in "Account".
        case .profiles: "konten"
        // ── Open: none of this lifts a limit ───────────────────────────────────
        // Subtitles and language set how something looks and is read —
        // the same kind of choice as Display and Playback.
        case .ratings, .playback, .appearance, .storage, .diagnostics, .about, .language:
            "einstellungenOffen"
        }
    }

    /// The header above the section list — **who is watching, on which server.**
    ///
    /// **Several people sit in front of the same device at the TV** (AP26, 2026-09-11).
    /// Until then only the account name stood here; anyone running two servers or a child account
    /// could not see at this place which one currently applied — and right
    /// below it begin the sections that change it.
    ///
    /// **As text and explicitly not as a button.** The reason is the wrap-around and not
    /// the catcher: a focusable header is not a section, ``section(ofFocus:)`` would give
    /// `nil`, the `guard` in the wrap-around would fall — and the upward press from the topmost entry
    /// would land on the header instead of the last section. The wrap-around from the user request
    /// of 2026-08-11 would be dead at the top end.
    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app: "settings.title")
                // festeschrift: Size and reason at ``titleSize`` — at `title` the word wrapped.
                // One line is mandatory here, the scale factor the safety net for
                // longer translations.
                .font(.system(size: Self.titleSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .foregroundStyle(ColorRole.text.color)

            if let credentials {
                Text(verbatim: credentials.username)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                // **The machine and not the whole address.** `https://media.example:8096/`
                // is not readable from three metres and distinguishes nothing either — anyone with
                // two servers tells them apart by the name. The same rule as in
                // ``Account/serverName``.
                if let credentials {
                    Text(
                        verbatim: credentials.serverURL.host()
                            ?? credentials.serverURL.absoluteString
                    )
                    .lineLimit(1)
                }
                if childLock.rule.applies {
                    // **Colour AND symbol**, as with every note in this app.
                    Image(systemName: Glyph.kind.name)
                    Text(app: "accounts.childMode")
                }
            }
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(childLock.rule.applies ? ColorRole.text.color : ColorRole.textQuiet.color)
            .padding(.top, 4)
        }
        .padding(.bottom, 28)
        .padding(.horizontal, Self.headerInset)
    }

    /// The header of a group in the list — **capitals, small, muted, without focus.**
    ///
    /// The same form as ``SettingsHeader`` in the content and as the section header of the
    /// phone: capitals carry the structure, not the size. **Not a button:** a
    /// focusable header would not be a section, ``section(ofFocus:)`` would give `nil`, and the
    /// wrap-around over the list end would stop on it.
    private func groupHeader(_ group: SettingsSection.Group, first: Bool) -> some View {
        Text(appKey: group.catalogTitleKey)
            .font(TypeLevel.lowercased.font)
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(ColorRole.textQuiet.color)
            .lineLimit(1)
            .padding(.horizontal, Self.entryInset)
            .padding(.top, first ? 0 : Self.groupSpacing)
            .padding(.bottom, 4)
            .id(Self.groupHeaderID(group))
            .accessibilityAddTraits(.isHeader)
    }

    private func sectionButton(_ entry: SettingsSection) -> some View {
        let isActive = section == entry
        let id = "section-" + entry.id
        let isFocused = focus == id

        return Button {
            // **The door sits at the section choice and not in the section** (G3). A
            // sheet that appeared only in the section would already have shown it — and
            // "Parental controls" shows the adult switch, "Account" the account list.
            // Both are information before anyone presses anything.
            guard childLock.isAllowed(finished: Self.door(forItem: entry)) else { return }
            section = entry
            // **And the press jumps into the content** (AP23, 2026-09-11). Until then
            // it did the same as mere moving around — the section follows the focus anyway —
            // and thereby it was a button without an effect of its own.
            //
            // **Only if the section reports a first target.** The request goes as
            // ``SettingsEntryRequestKey`` to the section shown; anyone who does not
            // accept it would get a press without consequence. The curtain reports its own
            // so that the two locked sections are not the only ones in
            // which the press fizzles out.
            if firstEntry != nil { entryRequest += 1 }
        } label: {
            let isMissing = entry.isMissingSomething(at: setup)
            HStack(spacing: Self.entryGap) {
                // **The symbol column carries both** (AP26, 2026-09-11): the symbol of the
                // section — and, when something remains to be filled in there, its golden
                // version. There would be no second column: 264 pt remain for the label,
                // and the widest entry measures 229.
                //
                // **On the light focus surface the gold stays off:** there it would hardly
                // register against the light background, and the information is not lost —
                // the sentence in the section's header states it (colour never carries alone).
                // **Fitted into the column** (on-device test 2026-09-27, T6): wide symbols
                // like that of the profiles otherwise stuck out beyond the 26 pt into the
                // label — the column fixed only the centre, not the width.
                Image(systemName: isMissing ? Glyph.toBackfill.name : entry.symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(
                        isMissing && !isFocused ? ColorRole.progress.color : ColorRole.text.color
                    )
                    .frame(width: Self.entryIconWidth, height: Self.entryIconWidth)
                Text(appKey: entry.titleKey)
                Spacer(minLength: 0)
            }
            // festeschrift: Size and reason at ``entrySize`` — the navigation rule of the
            // sidebar also applies to this list.
            .font(.system(size: Self.entrySize))
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(
                isFocused
                    ? ColorRole.reason.color : (isActive ? ColorRole.text.color : ColorRole.textMatt.color)
            )
            .lineLimit(1)
            .padding(.horizontal, Self.entryInset)
            // **From the constant and not as a number**: the height calculation in
            // ``sectionListHeight`` reads the same value, and two numbers for the same
            // padding drift apart at the first refactoring.
            .padding(.vertical, Self.entryVerticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isFocused
                    ? ColorRole.text.color
                    : (isActive ? ColorRole.text.color.opacity(0.12) : .clear),
                in: RoundedRectangle(cornerRadius: SettingsMetrics.radius, style: .continuous)
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        // **The gold is information and must remain so** (AP30, 2026-09-11). For
        // the eye the symbol column carries it; anyone who does not look would learn it only in the
        // section — that is, in exactly the order in which it no longer helps.
        .info(
            Text(appKey: entry.titleKey),
            [
                .chosen(isActive),
                .key(
                    entry.isMissingSomething(at: setup)
                        ? "a11y.state.incomplete" : nil),
            ])
    }

    /// The PIN sheet above the settings.
    ///
    /// **Here and not in the individual sections.** The door sits at the section choice;
    /// the sheet belongs at the same place, otherwise it would lie under the view it is
    /// meant to prevent.
    @ViewBuilder
    private var pinSheet: some View {
        #if os(tvOS)
            Color.clear.fullScreenCover(
                isPresented: Binding(
                    get: { childLock.openQuestion != nil },
                    set: { if !$0 { childLock.cancel() } }
                )
            ) {
                PinDoorSheet(lock: childLock)
            }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // **The curtain hangs on the focus, the door on the action** (AP23, 2026-09-11).
        // Until then only the button body checked (`sectionButton`); but the section also follows
        // the mere **focus change** (`:294-358`), and without any check.
        // Anyone moving through the section list in kids mode got to see "Parental controls"
        // with the adult switch and "Account" with the account list — the
        // door stood, and next to it the wall was made of glass.
        //
        // ``ParentalControlsState/isHidden(_:)`` asks and **consumes nothing**. The
        // obvious remedy — calling `isAllowed(finished:)` here — was tested and is wrong:
        // it would pull up the PIN sheet on every move.
        if childLock.isHidden(Self.door(forItem: section)) {
            Curtain(
                door: Self.door(forItem: section),
                reason: childLock.reason(forItem: Self.door(forItem: section)),
                asks: { childLock.queryPending(Self.door(forItem: section)) }
            )
        } else {
            openContent
        }
    }

    @ViewBuilder
    private var openContent: some View {
        // **Once here and not in eleven sections** (AP46, 2026-09-24): six of eleven
        // named their own name at the top, five nothing at all — and the headers below that
        // looked the same carried group names. At this place no section can forget the crumb
        // and none can set it twice.
        //
        // **Not for locked content:** there stands a number pad, and a location indication
        // above a door says nothing that the door does not already say.
        AreaBreadcrumb(area: section)
        switch section {
        case .playlists:
            PlaylistSettings(store: playlists, onRefresh: onPlaylistsRefresh)
        case .portals:
            PortalSettings(
                source: portalSource, address: portalAddress,
                onBridgeChanged: onPortalBridgeChanged
            )
        case .live:
            LiveSettings(
                groups: liveGroups,
                // **Through the same door as via the section list.** A second way into
                // the parental controls that does not ask would be exactly the gap against which
                // the switch was moved there.
                openParentalControls: {
                    guard childLock.isAllowed(finished: Self.door(forItem: .childLock)) else { return }
                    section = .childLock
                },
                stock: liveStock)
        // **"Picture & Sound" — audio track and subtitles in one section** (AP59 N7, 2026-09-30), as
        // on the phone. The subtitles were an entry of their own in the list with four rows.
        case .playback:
            VStack(alignment: .leading, spacing: 40) {
                PlaybackSettings()
                SubtitleSettings(embedded: true)
            }
        case .language:
            LanguageSettings(languages: languages)
        case .profiles:
            ProfileSettings(onSwitched: onAccountSwitched, onAddAccess: onAddAccount)
        case .ratings:
            RatingsSettings(
                onKeyChanged: onRatingsKeyChanged,
                onFilmographyKeyChanged: onFilmographyKeyChanged
            )
        case .appearance:
            // **The groups of the channel lists travel along**, so that "What is on now"
            // appears in the shelf list: the Live shelf comes from the stock of the
            // channel lists and not from `source.libraries()` — asking that
            // was the wrong question (2026-09-12).
            // **The same channel catalog that "Live" already gets** (`liveStock`) — no
            // second path for the same thing. It is needed for the channel selection of the
            // Live shelf.
            AppearanceSettings(
                source: source, liveGroups: liveGroups,
                portalLevels: portalLibraries, portalDataSource: portalSource,
                providerCategories: providerCategories,
                channelCatalog: liveStock)
        case .storage:
            StorageSettings(source: source)
        case .diagnostics:
            DiagnosticsSettings(focus: $focus, source: source)
        case .childLock:
            // **With the channel catalog and the list names** for the children's allow list
            // (AP52) — the same catalog as under "Live", no second fetch.
            ParentalControlsView(
                lock: childLock, source: source,
                live: LivePreferences.load(from: ProfileStore.playback),
                channelCatalog: liveStock,
                listNames: Dictionary(
                    playlists.visiblePlaylists.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        case .devices:
            OtherDevicesSettings()
        case .about:
            AboutSettings()
        case .account:
            AccountSettings(
                signedIn: !setup.withoutAccess, onSignOut: onSignOut,
                onAddServer: onAddAccount)
        }
    }
}

// MARK: - Shared building blocks

/// Heading of a settings section together with an explanation.
///
/// The explanation is not decoration: with "Libraries in the header area" or an
/// access key for ratings it is not clear without a sentence what the
/// setting does — and what happens if you leave it as it is.
struct SettingsHeader: View {
    let titleKey: String
    let hintKey: String?

    init(_ titleKey: String, hint hintKey: String? = nil) {
        self.titleKey = titleKey
        self.hintKey = hintKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // **The smallest font for the header and not the largest** (AP46,
            // 2026-09-23). Here stood **57 points bold** — more than the
            // page heading "Settings" at 48. "Display" stacks nine
            // such headers and thereby became around three screens long, without a
            // single one of them saying anything other than "something starts here".
            //
            // **Capitals carry the structure, not the size.** That is the form
            // the phone has used since 2026-09-07. (``SectionHeader``): the header
            // orders, the row below it is the statement. Anyone entering the section should
            // read first **what is in it** — not what the section is called.
            Text(appKey: titleKey)
                .font(TypeLevel.footer.font)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(ColorRole.textQuiet.color)

            if let hintKey {
                // **The explanatory sentence stays and gets quieter.** It carries sentences like "Applies
                // to the device, whoever is signed in" — that is the difference
                // between two locks and no decoration. Only it used to stand in
                // 29 points under a 57-point header and was thereby itself a
                // heading.
                Text(appKey: hintKey)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .padding(.bottom, 18)
    }
}

/// **The breadcrumb above a section** — "Viewing · Playback" (AP46, 2026-09-24).
///
/// **The finding: ``SettingsHeader`` had two roles in one form.** At **nine** of the
/// thirty places it carried a `settings.section.*` key, that is, the **section** name
/// — the same one that already stands on the left in the list; at the other twenty a
/// **group** name. Both looked the same, so there was no hierarchy to see,
/// only repetition.
///
/// **The group comes first and is the gain**, not the section name: thirteen sections
/// lie in four groups (``SettingsSection/Group``), and which one is currently open was
/// until now said only by a **gap** in the list on the left.
///
/// **Why that does not contradict the decision of AP26:** there the four
/// group headings were removed from the **list**, and the reason is measured — they
/// cost 160 pt, made the column scroll and would be **not focusable**. That applies to
/// the list. Here the group stands in the **content**, costs no list height and takes
/// no focus.
///
/// **The group is muted, the section is not.** Anyone who already knows where they are reads only the
/// second word; anyone who has got lost finds the answer in the first. The other way round, the
/// information that is rarely needed would be the more prominent one.
struct AreaBreadcrumb: View {

    let area: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
        }
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Text(appKey: "settings.group." + area.group.rawValue)
                .foregroundStyle(ColorRole.textQuiet.color)
            // **A separator and not a chevron.** A chevron says "it goes on here",
            // and it does not: the crumb is a location indication, not a path.
            Text(verbatim: "·")
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(appKey: area.titleKey)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .font(TypeLevel.footer.font)
        .textCase(.uppercase)
        .tracking(1.2)

        if let hintKey = area.hintKey {
            // **The explanatory sentence belongs to the crumb and no longer at six call sites.**
            // It carries sentences like "Applies to the device, whoever is signed in" — not
            // decoration; only it stood at six sections and was missing at five.
            Text(appKey: hintKey)
                .font(TypeLevel.lowercased.font)
                .textCase(nil)
                .tracking(0)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.top, 8)
        }
    }
}

/// With which a settings section names its topmost entry — the catcher
/// at the content edge passes the right-press from the section list there.
nonisolated struct SettingsFirstEntryKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = nextValue() ?? value
    }
}

/// The request of the section list to the section shown to focus its topmost
/// entry — every section keeps its own focus and
/// accepts it in `onChange`.
nonisolated struct SettingsEntryRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

nonisolated extension EnvironmentValues {
    var settingsEntryRequest: Int {
        get { self[SettingsEntryRequestKey.self] }
        set { self[SettingsEntryRequestKey.self] = newValue }
    }
}
