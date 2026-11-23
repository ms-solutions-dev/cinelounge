import Core
import DesignSystem
import Flows
import Foundation
import PlaylistKit
import SwiftUI

/// The Live area: on the left the channel list, on the right the channel in focus.
///
/// The arrangement comes from the design template (`design/cinelounge-ui.html`, screen
/// "Live TV"): title and group tabs on top, below them in two columns the list
/// and the board. It is designed for three meters of viewing distance.
///
/// **The focus moves horizontally from the list into the board**, because both are
/// siblings in the same `HStack`. This is not a matter of style: two areas that
/// do not overlap horizontally cannot reach each other on tvOS, and
/// separate layers of a `ZStack` are not neighbors.
public struct LiveView: View {

    // MARK: - Dimensions

    /// Width of an Apple TV screen in points. Applies to 1080p and 4K
    /// alike — tvOS calculates in points.
    static let screenWidth: CGFloat = 1920
    static let screenHeight: CGFloat = 1080

    /// Width of the channel list, taken from the design template.
    ///
    /// 620 points carry the logo, channel name and the program line — the calculation in
    /// detail is documented at ``ChannelRow/textWidth``.
    static let listWidth: CGFloat = 620

    /// Spacing between list and board.
    ///
    /// Also absorbs the enlargement of the row in focus: it grows by
    /// ``Tokens/Focus/buttonScale`` and protrudes on both sides in the process. If the
    /// spacing is smaller than this protrusion, the row pushes itself over the board.
    static let columnGap: CGFloat = 56

    /// Where the two-column part begins — below the title and group tabs.
    static let contentTop: CGFloat = 250

    /// How many rows fit in one screen height: eight.
    ///
    /// The number is the reason for everything else in this area. With 5389 channels
    /// that would be 674 screen heights — hence groups, favorites and search and not one
    /// list you page through.
    static var rowsPerScreen: Int {
        let room = screenHeight - contentTop - TVMetrics.topMargin
        return Int(room / (ChannelRow.height + ChannelRow.spacing))
    }

    @StateObject private var model: LiveModel
    /// The group that was selected from outside — the path from the sidebar.
    let group: String?
    /// The most recently watched channel — it gets the cursor.
    private let rememberedChannelID: String?
    /// What is played — **and from what.** The second piece of information is the catalog
    /// currently visible: the player later switches onward from it. It comes from
    /// here and not from the frame, because only this view knows what groups, search
    /// and filter have left of it — whoever switches through a group in the player
    /// does not want to suddenly be standing in all 5389 channels.
    let onPlay: (PlaybackTarget, [Channel]) -> Void
    /// The way out into the sidebar — it keeps its own focus state,
    /// and there is no geometric path to it.
    var onLeaveToSidebar: () -> Void = {}

    /// Counts up when the area is supposed to get the focus back.
    ///
    /// **The area stood there without focus, and that explains three findings at
    /// once** (reproduced in the simulator, 2026-08-11 at night): after returning from
    /// the player **nothing** was focused. Without a focused element
    /// tvOS delivers no move commands — so pressing left did nothing —, and
    /// the menu button goes to the system instead of the app: it closes itself.
    ///
    /// A counter and not "set the focus if it is empty": on opening
    /// the player it also becomes empty, and whoever fetches it back there tears it
    /// away from the player.
    var focusToken: Int = 0

    @FocusState private var focus: String?

    /// When the operator last did something themselves — the retrier
    /// then gives up (AP4 · K7, ``FocusRules/abandonsRetry(startedAt:lastInput:grace:)``).
    @State private var lastInputAt = Date.distantPast
    /// The point in time against which the remaining time is calculated.
    ///
    /// Updated every 30 seconds, not every second: the value is rounded to
    /// minutes, drawing more often changes nothing in the picture. It must be updated
    /// nonetheless — otherwise "24 min left" would stand unchanged an hour later,
    /// and that is a false statement and not merely an old one.
    @State private var now = Date()

    /// The channel whose preview is supposed to run right now.
    ///
    /// **Only after a short dwell**, and that is the core: starting at every
    /// move on immediately would mean opening and closing connections to the provider
    /// every second while browsing through a group. With an account
    /// with a single allowed connection that is not merely rude — it is
    /// the surest way to lock yourself out.
    @State private var previewTarget: PlaybackTarget?

    /// The running wait. Discarded and set anew on every focus change.
    @State private var previewDelay: Task<Void, Never>?

    /// How long a channel must stay in focus until its picture starts.
    ///
    /// Longer than for the trailer in the library: there a misfire costs only one
    /// request to your own server, here a connection at the provider.
    static let previewDwell: TimeInterval = 4

    /// The identifier of the search field in focus.
    ///
    /// A string, because the focus in this area runs over channel identifiers
    /// and both live in one state. It begins with a hyphen so that it
    /// coincides with no channel identifier — and so that it does not look like one when searching for
    /// language keys.
    nonisolated static let searchFieldID = "-suchfeld"

    /// Whether the groups stand in place of the channel list.
    @State private var showsGroups = false
    /// Whether the program grid stands instead of the channel list.
    ///
    /// **As a switch and not as its own area** (`design/konzept-p8.md`,
    /// section 3): "The list is for zapping, the grid for planning." Both
    /// show the same group, so they belong in the same place — a
    /// separate sidebar entry would have duplicated the group selection.
    @State private var showsGrid = false
    @State private var raster: GuideGridModel
    /// Keeps move command and swipe gesture apart — see ``MoveGate``.
    @State private var gate = MoveGate()

    /// The focus section of the two lists.
    ///
    /// **It keeps the press to the left within the area** (on-device finding 2026-08-12: "click
    /// left for the group view, and the focus jumps into
    /// the bar for milliseconds"). On switching, one list disappears before the
    /// other is built; in this gap the sidebar is the nearest target,
    /// because it stands in the same frame to the left. An anchor alone is not enough,
    /// however — it is set **after** tvOS has already handed out the focus;
    /// the trace shows the bar highlighted for 51 milliseconds.
    ///
    /// **The way into the bar remains open nonetheless**: it runs through
    /// ``onLeaveToSidebar`` and sets its focus explicitly — an assignment,
    /// not a movement, and that knows no area boundary.
    @Namespace private var listScope

    /// The scroller of the group list — without it no jump to a row that
    /// is not even built yet.
    @State private var groupScroller: ScrollViewProxy?

    /// Where the store keeps the most recently watched group.
    private static let lastSectionKey = "live.lastSection"

    public init(
        model: LiveModel,
        group: String? = nil,
        rememberedChannelID: String? = nil,
        onLeaveToSidebar: @escaping () -> Void = {},
        focusToken: Int = 0,
        /// Where the grid takes its program from. Preset to "nothing", so that
        /// checks and previews can build the view without a database —
        /// then the honest hint stands there instead of an empty grid.
        rasterProgramm: @escaping @Sendable ([Channel], Date, Date) async -> [String: [Programme]] = {
            _, _, _ in [:]
        },
        onPlay: @escaping (PlaybackTarget, [Channel]) -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        _raster = State(initialValue: GuideGridModel(load: rasterProgramm))
        self.group = group
        self.rememberedChannelID = rememberedChannelID
        self.onLeaveToSidebar = onLeaveToSidebar
        self.focusToken = focusToken
        self.onPlay = onPlay
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            switch model.state {
            case .loading:
                LoadingBand()
            case .empty:
                emptyState
            case .ready:
                content
            }
        }
        // **An anchor that is always there** (on-device finding 2026-08-12: "click left for
        // the group view, and the focus jumps into the
        // bar for milliseconds").
        //
        // When switching between channels and groups, one list disappears
        // before the other is built — for one frame there is **nothing** focusable
        // here, and then the sidebar takes the
        // focus: it stands in the same frame to the left. That is exactly the
        // case ``FocusAnchor`` exists for.
        //
        // The anchor lies outside the branching and therefore lives through the
        // switch. It takes nothing from anyone: as soon as the new list
        // stands, ``jumpToGroup()`` fetches the focus to where it belongs.
        //
        // **And it stands at the left edge, over the full height.** An anchor in the
        // corner is not enough: tvOS looks for its target in a horizontal band,
        // and from the middle of the channel list it does not find a point at the top left
        // — it finds the sidebar. As a narrow strip over the
        // whole height the anchor, by contrast, lies next to **every** row on the left and
        // is thus closer than the bar. The press stays in the area, and what
        // it means is decided by ``move(_:)``.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .focusable()
                .focused($focus, equals: Self.switchAnchorID)
                .accessibilityHidden(true)
        }
        // The same edge specification as in the library, and for the same reason: at the top,
        // bottom and right the overscan inset is removed, on the left not — there
        // the sidebar stands. Without the restriction the content ran under it.
        .ignoresSafeArea(edges: [.top, .bottom, .trailing])
        .task {
            // **Read first, then load — and that is the error from before.**
            // ``LiveModel/load()`` sets the first group, that is a
            // change, and the change writes to the store. Whoever reads afterwards
            // reads their own default: the remembered group was
            // overwritten before anyone had needed it (viewer finding
            // 2026-08-11, at night — "HEVC is back again").
            let remembered = try? SecureStore().value(for: Self.lastSectionKey)
            let hadStock = model.state == .ready
            await model.load()
            // **The sidebar takes precedence over the memory.** Whoever selects a
            // group there means it — and not the one from last night.
            if let group {
                model.selectGroup(named: group)
            } else if let stored = remembered {
                // **Otherwise the most recently watched** (viewer finding 2026-08-11: "when
                // I go to Live, the last group should be visible and
                // not always HEVC"). If it no longer exists — list removed,
                // group hidden —, the first stays; ``select(_:)``
                // checks that itself and otherwise does nothing.
                model.select(stored)
            }
            // When coming back from the player, `state` stays at `.ready`
            // (``LiveModel/load()``), so the `onChange` below stays silent —
            // the focus is therefore fetched here.
            // The most recently watched channel gets the cursor — on entering
            // as on coming back from the player.
            model.focusRemembered(rememberedChannelID)
            if hadStock, model.state == .ready { takeFocus() }
        }
        .onChange(of: group) { _, current in
            guard let current else { return }
            model.selectGroup(named: current)
        }
        .onChange(of: model.selectedSectionID) { _, current in
            guard let current else { return }
            try? SecureStore().set(current, for: Self.lastSectionKey)
        }
        .onChange(of: model.focused?.id) { _, _ in
            schedulePreview(for: model.focused)
        }
        .onChange(of: focus) { previous, current in
            // **The focus is recorded.** What tvOS does with a key press
            // cannot be seen from outside; in this block therefore the
            // wrong end was repaired twice.
            Diagnostics.verbose("Live area: focus \(previous ?? "—") → \(current ?? "—")")
        }
        .onChange(of: focusToken) { _, _ in takeFocus() }
        .onChange(of: model.state) { _, state in
            guard state == .ready else { return }
            takeFocus()
        }
        // **The view takes the sideways directions itself.** Only what the
        // focus did not consume has arrived — and to the left it consumes
        // nothing here, see ``rail``.
        .onMoveCommand { direction in
            // **Before the gate and not behind it.** What the gate discards as an echo of the same
            // hand movement (``MoveGate``) was pressed nonetheless —
            // and the trace needs the press, not our decision about it.
            // See AP4 · K7 — the mark next to the trace line.
            lastInputAt = Date()
            Diagnostics.cursorKey("Live", FocusTrail.name(direction))
            guard gate.accepts(direction, .now, from: .command) else { return }
            move(direction)
        }
        // **The second way in, for the old remote.** On the smooth
        // glass surface swiping produces no move command — see
        // ``RemoteSwipeDirection``. That is also the reason why ``rail`` can remain a
        // sign and need not become a button: the way to the left
        // still runs through the rule in ``move(_:)``, only now whoever swipes
        // instead of pressing reaches it too.
        .onRemoteSwipe("Live") { swipe in
            guard gate.accepts(swipe.asMove, .now, from: .gesture) else { return }
            move(swipe.asMove)
        }
        // Observes only — see ``focusTrail(_:_:)``.
        .focusTrail("Live", focus)
        .onDisappear {
            // The triggered program fetch stops. Otherwise a request goes out for
            // a view nobody sees any more — and the provider allows one
            // single connection. For the same reason the preview falls away: it
            // would otherwise keep running while you are long since in the library.
            stopPreview()
            model.stop()
        }
        // The clock hangs on the outer frame: the content below is replaced while browsing,
        // and a clock inside it would never expire.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    // MARK: - Setup

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls

            if showsGrid {
                ProgrammeGridView(
                    model: raster,
                    now: now,
                    onPlay: { channel, cell in playFromGrid(channel, cell) },
                    onLeaveToList: { showsGrid = false }
                )
                .padding(.horizontal, MetricsBoard.tv.margin)
                .padding(.top, 22)
            } else {
                list
            }
        }
        // Whoever changes the group while the grid is showing should see the new
        // channels — without leaving the view.
        .onChange(of: model.shownChannels.map(\.id)) { _, _ in
            guard showsGrid else { return }
            raster.show(model.shownChannels, now: now)
        }
    }

    /// Channel list with rail and board — the zapping path.
    private var list: some View {
        HStack(alignment: .top, spacing: 0) {
            rail
                .padding(.trailing, 12)

            Group {
                if showsGroups {
                    groupList
                } else {
                    channelList
                }
            }
            .focusScope(listScope)

            Spacer(minLength: 0)
                .frame(width: Self.columnGap)

            NowPlayingPanel(
                channel: model.focused,
                guide: model.focused.map(model.guide(for:)) ?? .pending,
                now: now,
                preview: previewTarget,
                onPlay: { play(model.focused) },
                onToggleFavorite: {
                    guard let channel = model.focused else { return }
                    model.toggleFavorite(channel)
                }
            )
            .padding(.trailing, MetricsBoard.tv.margin)
        }
        .padding(.leading, MetricsBoard.tv.margin)
        .padding(.top, 22)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(app: "tab.live")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)

            // **Which group you are currently looking at is shown in the header** (user request
            // 2026-08-08): the sidebar shows it only while it is expanded —
            // collapsed it said "Live · 14 channels" here, and which of the
            // 79 groups that was nobody knew any more. In a search
            // the name yields, because then the hits count across all groups.
            if !model.isSearching, let section = model.selectedSection {
                Text(verbatim: Self.title(of: section))
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
            }

            Text(app: "live.channelCount \(shownCount)")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)

            // A list that did not answer is reported and not concealed:
            // otherwise channels are missing, and the app looks as if it had lost them.
            ForEach(model.failures) { failure in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(verbatim: failure.name)
                    Text(appKey: failure.messageKey)
                }
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.live.color)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.top, 20)
    }

    /// The count shown in the header: when searching the hits, otherwise the channels
    /// of the group. The uncapped number, so that it is correct.
    private var shownCount: Int {
        model.isSearching ? model.hitCount : (model.selectedSection?.channels.count ?? 0)
    }

    // MARK: - Search and group tabs

    private var controls: some View {
        HStack(spacing: 14) {
            searchField

            Divider()
                .frame(height: 40)
                // Decoration, and therefore without hit testing: an overlay takes
                // part in it and blocks the focus beneath it. This error has already occurred in
                // this project four times.
                .overlay(ColorRole.line.color.allowsHitTesting(false))
                .padding(.horizontal, 8)

            // The switch between list and grid — see ``showsGrid``.
            Button {
                showsGrid.toggle()
                if showsGrid {
                    raster.show(model.shownChannels, now: now)
                } else {
                    raster.stop()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: showsGrid ? "list.bullet" : "calendar.day.timeline.left")
                    Text(app: showsGrid ? "live.rasterBack" : "live.raster")
                }
                .font(TypeLevel.footer.font)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .foregroundStyle(
                    focus == "live-raster-schalter"
                        ? ColorRole.reason.color : ColorRole.text.color
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            focus == "live-raster-schalter"
                                ? ColorRole.text.color : ColorRole.surface.color.opacity(0.5))
                )
            }
            .bareFocusableButton()
            .focused($focus, equals: "live-raster-schalter")
            .focusHighlight(focus == "live-raster-schalter")
            .info(appKey: showsGrid ? "live.rasterBack" : "live.raster")

            // **No group row here any more.** The sidebar carries the same
            // groups, and the same thing twice in two places is not twice as
            // helpful but confusing: you select something at the top and see
            // a different highlight on the left. One place for one decision.
            Spacer(minLength: 0)
        }
        .padding(.leading, MetricsBoard.tv.margin)
        .padding(.top, 22)
        // A section of its own, so that the focus jumps up as a whole from the channel list
        // and does not get stuck in the tab row.
        .focusSection()
    }

    /// The search field.
    ///
    /// A field and no `.searchable` bar: that hangs on a
    /// navigation frame that does not exist here — it would be invisible. Access
    /// to the on-screen keyboard stays the same.
    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ColorRole.textQuiet.color)

            TextField(
                text: Binding(get: { model.term }, set: { model.search($0) }),
                prompt: Text(app: "live.searchPrompt")
            ) {
                Text(app: "live.searchPrompt")
            }
            .keyboard(forItem: .prose)
            .remoteKeyboard(
                Binding(get: { model.term }, set: { model.search($0) }),
                pending: focus == Self.searchFieldID
            )
            .font(TypeLevel.footer.font)
            .frame(width: 300)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(ColorRole.surface.color, in: Capsule())
        .focused($focus, equals: Self.searchFieldID)
    }

    /// The groups as tabs, in the provider's order.
    ///
    /// Scrolling horizontally, because there are 79. The path via the sidebar remains
    /// the faster one; this row is the path for whoever is already standing here.
    private var groupTabs: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(model.groupRows) { section in
                        groupChip(section)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, MetricsBoard.tv.margin)
            }
            .scrollClipDisabled()
            .onChange(of: model.selectedSectionID) { _, current in
                guard let current else { return }
                withAnimation { scroller.scrollTo(current, anchor: .leading) }
            }
        }
    }

    private func groupChip(_ section: LiveLibrary.Group) -> some View {
        let isActive = model.selectedSectionID == section.id
        let chipID = "group-" + section.id

        return Button {
            model.select(section.id)
        } label: {
            HStack(spacing: 10) {
                if section.id == LiveModel.favoritesSectionID {
                    // **A heart and not a star** (AP25, 2026-09-11). The star stood
                    // here for the same thing the heart stands for in seven other
                    // places — and the same star means **bookmarking** in the sports
                    // area. Two meanings on one symbol is one too
                    // many; see ``DesignSystem/Sinnbilder``.
                    Image(systemName: Glyph.favorite.pair.filled)
                }
                Text(verbatim: Self.title(of: section))
                    .lineLimit(1)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(chipForeground(isActive: isActive, id: chipID))
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(chipBackground(isActive: isActive, id: chipID), in: Capsule())
        }
        .bareFocusableButton()
        .focused($focus, equals: chipID)
        .focusHighlight(focus == chipID, scale: Tokens.Focus.buttonScale)
        .info(name: Self.title(of: section), .chosen(isActive))
        .id(section.id)
    }

    /// The label of a tab.
    ///
    /// Favorites and the channels without a group carry no name from the provider —
    /// ``LiveLibrary`` leaves it empty there. An empty tab would be a button without a
    /// label, so translated names stand here. Everything else is the provider's name,
    /// cleaned by ``ChannelName/display(_:)``: group names carry
    /// the same superscript characters as channel names.
    static func title(of section: LiveLibrary.Group) -> String {
        if section.id == LiveModel.overviewSectionID {
            return AppLanguageSetting.text("common.all")
        }
        if section.id == LiveModel.favoritesSectionID {
            return NSLocalizedString(
                "tab.favorites", bundle: AppLanguageSetting.bundles(zu: "tab.favorites"), comment: "")
        }
        if section.id.isEmpty {
            return NSLocalizedString(
                "live.ungrouped", bundle: AppLanguageSetting.bundles(zu: "live.ungrouped"), comment: "")
        }
        return ChannelName.display(section.name)
    }

    private func chipForeground(isActive: Bool, id: String) -> Color {
        if focus == id { return ColorRole.reason.color }
        return isActive ? ColorRole.text.color : ColorRole.textMatt.color
    }

    private func chipBackground(isActive: Bool, id: String) -> Color {
        if focus == id { return ColorRole.text.color }
        return isActive ? ColorRole.tag.color : ColorRole.surface.color
    }

    // MARK: - The way to the left

    /// The column between sidebar and channel list.
    ///
    /// **It was invisible and four points wide — and did not work**
    /// (viewer finding 2026-08-11, at night: "doesn't work at all at the moment").
    /// The idea was right: a press to the left needs a target, otherwise the
    /// sidebar takes it. The execution was not — it depended on tvOS
    /// jumping to a transparent strip and on the previous focus giving away the
    /// direction. Both were an assumption, and neither could be checked.
    ///
    /// **And on the second attempt it was a button — that did not work either.** Reproduced in the
    /// simulator: a press to the left from the channel list does not move the
    /// focus **at all**. Not into the sidebar, not onto a strip next to it, nowhere. What would stand here
    /// would therefore be unreachable.
    ///
    /// Exactly from that follows the path: a press that nobody consumes arrives as
    /// `onMoveCommand` — see ``move(_:)``. This column is therefore a
    /// **sign and not a button**: it says that the path exists.
    private var rail: some View {
        VStack(spacing: 10) {
            Image(systemName: showsGroups ? "chevron.right" : "chevron.left")
            Image(systemName: "square.stack.3d.up")
        }
        // festeschrift: a stack of two symbols, not text.
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(ColorRole.textQuiet.color)
        .frame(width: Self.railWidth, height: Self.railHeight)
        .background(
            ColorRole.surface.color.opacity(0.45),
            in: RoundedRectangle(cornerRadius: Self.railWidth / 2, style: .continuous)
        )
        // **A sign and not a button** — and that is the finding from the second
        // attempt, reproduced in the simulator: a press to the left from the
        // channel list does not move the focus **at all**. Not into the
        // sidebar, not onto a strip next to it, nowhere. What would
        // stand here would therefore be unreachable, however nice it looks.
        //
        // Exactly from that, however, follows the path: a press that nobody consumes
        // arrives as `onMoveCommand` — see ``move(_:)``. This column only says
        // that it exists.
        .allowsHitTesting(false)
        .padding(.top, (ChannelRow.height - Self.railHeight) / 2)
    }

    /// Measures of the column. Narrow enough that the channel list keeps its measures —
    /// the calculation for that is documented at ``ChannelRow/textWidth``.
    static let railWidth: CGFloat = 44
    static let railHeight: CGFloat = 96

    /// What a press to the side means.
    ///
    /// **As a rule and not as focus guidance**, and that is the lesson from two
    /// failures: first an invisible strip was supposed to catch the press,
    /// then a button. Both assumed that tvOS moves the focus to the left
    /// at all — reproduced in the simulator it does **not**. The
    /// press stays unconsumed, and exactly then it arrives as `onMoveCommand`.
    enum SideStep: Equatable {
        /// From the channel list to the left: the groups take its place.
        case showGroups
        /// From the groups to the right: back to the channels.
        case backToChannels
        /// From the groups to the left: out into the sidebar.
        case toSidebar
        case none
    }

    nonisolated static func sideStep(
        _ direction: MoveCommandDirection,
        showsGroups: Bool
    ) -> SideStep {
        switch (direction, showsGroups) {
        case (.left, false): .showGroups
        case (.left, true): .toSidebar
        case (.right, true): .backToChannels
        default: .none
        }
    }

    /// Fetches the focus into the list.
    ///
    /// Without it the area cannot be operated and the menu button closes the
    /// app — the full reasoning is documented at ``focusToken``.
    private func takeFocus() {
        guard !showsGroups else {
            jumpToGroup()
            return
        }
        let wanted = model.focused?.id ?? model.shownChannels.first?.id
        guard let wanted else { return }
        Diagnostics.verbose("Live area: focus being fetched on \(wanted)")
        focus = wanted
    }

    /// Performs a press to the side.
    private func move(_ direction: MoveCommandDirection) {
        let step = Self.sideStep(direction, showsGroups: showsGroups)
        Diagnostics.verbose("Live area: \(direction) → \(step), focus \(focus ?? "—")")

        switch step {
        case .none:
            return
        case .showGroups:
            // **Grab the anchor first, then switch — in this order.**
            //
            // The other way round it was demonstrably too late (focus trace, 2026-08-12): the
            // list disappears, tvOS reassigns the focus in the same step, and
            // the sidebar is the nearest target — it stands in the same frame
            // to the left. The assignment afterwards never arrived; the trace showed
            // `Live … → —`, then the bar, and only 60 ms later the way back.
            //
            // If the focus is on the anchor **before** switching, there is
            // nothing to reassign: the anchor lives outside the branching
            // and is there before as after.
            focus = Self.switchAnchorID
            showsGroups = true
        case .backToChannels:
            focus = Self.switchAnchorID
            showsGroups = false
            // **Anchor first, then the channel.** The channel list is not yet built at that
            // moment; the anchor carries the focus across the
            // switch, and the assignment below takes effect as soon as the row
            // exists. Without the anchor the sidebar would grab it in the gap.
            focus = Self.switchAnchorID
            let wanted = model.focused?.id ?? model.shownChannels.first?.id
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                if let wanted { focus = wanted }
            }
        case .toSidebar:
            // **The focus is set and not moved.** From here to the left
            // there is no geometric path — the bar is a separate
            // focus state, and the press would otherwise arrive nowhere.
            showsGroups = false
            onLeaveToSidebar()
        }
    }

    /// Puts the focus on the group whose channel list is currently open.
    ///
    /// **Scroll first, then grab, and then grab again.** The list is built
    /// lazily: a focus on a row that does not exist yet fizzles out without an
    /// error, and tvOS sets it to the first built row instead — exactly
    /// that was visible in the on-device test, the groups opened at the wrong place.
    /// The same cause and the same answer as in ``LiveOverlay``.
    private func jumpToGroup(with proxy: ScrollViewProxy? = nil) {
        let roller = proxy ?? groupScroller
        let id = Self.groupRowID(model.selectedSectionID)
        Diagnostics.verbose(
            "Live area: groups jump to \(id), scroller \(roller == nil ? "missing" : "present")"
        )
        roller?.scrollTo(id, anchor: .center)
        focus = id

        let startedAt = Date()
        Task { @MainActor in
            // **Wait first, then check.** A focus that was just written reads
            // back immediately, even if tvOS never accepted it — whoever checks in the
            // same breath always gets a yes and stops trying.
            for attempt in 1...6 {
                try? await Task.sleep(for: .milliseconds(50))
                if focus == id {
                    if attempt > 1 {
                        Diagnostics.verbose("Live area: group only settled on attempt \(attempt)")
                    }
                    return
                }
                // The operator beats the retrier (AP4 · K7): whoever keeps browsing
                // themselves while we are still retrying had their
                // movement actively undone.
                if FocusRules.abandonsRetry(startedAt: startedAt, lastInput: lastInputAt) {
                    Diagnostics.verbose("Live area: retry cancelled — input")
                    return
                }
                Diagnostics.verbose("Live area: attempt \(attempt), focus is on \(focus ?? "—")")
                roller?.scrollTo(id, anchor: .center)
                focus = id
            }
            // Better the first row than none at all: without focus tvOS delivers no
            // move commands any more, and the view looks frozen.
            if focus != id, let first = model.groupRows.first {
                Diagnostics.verbose("Live area: \(id) not reachable, going to the first group")
                focus = Self.groupRowID(first.id)
            }
        }
    }

    /// The anchor that bridges the switch between channels and groups.
    nonisolated static let switchAnchorID = "-umschalter"

    nonisolated static let groupRowPrefix = "group-"

    nonisolated static func groupRowID(_ sectionID: String?) -> String {
        groupRowPrefix + (sectionID ?? "")
    }

    // MARK: - Groups instead of the channel list

    /// The groups, where the channels otherwise stand.
    ///
    /// **The same movement as in the player** (``LiveOverlay``): left goes deeper,
    /// a selection leads back. Whoever can change the group in the running picture
    /// expects it all the more here — here the list is the whole purpose of the
    /// view.
    private var groupList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChannelRow.spacing) {
                    ForEach(model.groupRows) { section in
                        groupRow(section)
                    }
                }
                .padding(.bottom, TVMetrics.topMargin)
            }
            .frame(width: LiveView.listWidth)
            .focusSection()
            // **The jump belongs here and not to the key press.** At the press
            // the list does not exist yet: no scroller, no rows, and the
            // focus falls on the first row that happens to be standing. Only
            // this `onAppear` runs when there is something to grab — just as
            // in ``LiveOverlay``, where it therefore sat from the start.
            .onAppear {
                groupScroller = proxy
                jumpToGroup(with: proxy)
            }
        }
    }

    private func groupRow(_ section: LiveLibrary.Group) -> some View {
        let id = Self.groupRowID(section.id)
        let isActive = model.selectedSectionID == section.id
        let isFocused = focus == id

        return Button {
            model.select(section.id)
            // **Selected means: back to the channels.** A group is not a destination
            // in itself; you select it in order to see within it.
            showsGroups = false
            focus = model.shownChannels.first?.id
        } label: {
            HStack(spacing: 14) {
                if section.id == LiveModel.favoritesSectionID {
                    // See the chip row further up — the same symbol for the same
                    // thing.
                    Image(systemName: Glyph.favorite.pair.filled)
                }
                Circle()
                    .fill(isActive ? ColorRole.live.color : .clear)
                    .frame(width: 10, height: 10)
                Text(verbatim: Self.title(of: section))
                    .font(TypeLevel.footer.font)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: String(section.channels.count))
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.textQuiet.color)
            }
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 22)
            .frame(height: ChannelRow.height)
            .background(
                isFocused
                    ? ColorRole.text.color : ColorRole.surface.color.opacity(isActive ? 0.9 : 0),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .info(
            Text(verbatim: Self.title(of: section)) + Text(verbatim: ", ")
                + Text(verbatim: String(section.channels.count)),
            .chosen(isActive)
        )
        .id(id)
    }

    // MARK: - Channel list

    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: ChannelRow.spacing) {
                if model.isSearching {
                    ForEach(model.hits) { channel in
                        channelButton(channel, id: channel.id)
                    }
                } else {
                    // **The same section order as on the phone** (B9): above "All"
                    // first "Recently watched" and the favorites, at the end the channels without
                    // program. A channel from the top two stands at the bottom a second
                    // time — its row there therefore gets its own focus identifier.
                    ForEach(model.segments) { section in
                        if let header = section.kind.titleKey {
                            sectionHeader(
                                header, count: section.kind.showsCount ? section.entries.count : nil)
                        }
                        ForEach(section.entries) { channel in
                            channelButton(
                                channel,
                                id: section.kind.isShelf
                                    ? "\(section.kind.rawValue)|\(channel.id)" : channel.id)
                        }
                    }
                }
            }
            .padding(.bottom, TVMetrics.topMargin)
        }
        // **Clipped only at the top** (viewer finding 2026-08-08: "when I scroll,
        // the search gets overlapped"). `scrollClipDisabled` stood here so that the
        // enlarged row in focus is not cut off at the sides — but it lifted
        // the clipping in ALL directions, and the rows scrolled up
        // were drawn on above the search field. The mask cuts
        // at the top edge of the list and leaves room at the sides and bottom for
        // the focus zoom.
        .mask(alignment: .top) {
            Rectangle()
                .padding(.horizontal, -60)
                .padding(.bottom, -80)
        }
        .frame(width: LiveView.listWidth)
        .focusSection()
    }

    private func channelButton(_ channel: Channel, id: String) -> some View {
        Button {
            play(channel)
        } label: {
            ChannelRow(
                channel: channel,
                programs: model.runningProgramme(for: channel, at: now),
                now: now,
                isFocused: focus == id
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .focusHighlight(focus == id, scale: Tokens.Focus.buttonScale)
        .onChange(of: focus) { _, current in
            // Only its own row reports, and only when it
            // gets the focus: otherwise each of the visible rows would report
            // every change, and the last would win.
            guard current == id else { return }
            model.focus(channel)
        }
        .id(id)
    }

    /// The heading of a section — the same font as above the search hits.
    private func sectionHeader(_ key: String, count: Int?) -> some View {
        Group {
            if let count {
                Text(verbatim: String(format: AppLanguageSetting.text(.init(key)), count))
            } else {
                Text(appKey: key)
            }
        }
        .font(TypeLevel.footer.font)
        .kerning(2)
        .textCase(.uppercase)
        .foregroundStyle(ColorRole.textQuiet.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .accessibilityAddTraits(.isHeader)
    }

    private func play(_ channel: Channel?) {
        guard let channel else { return }
        // **Hand over the preview first, then open.** The provider allows one
        // connection; two streams open at the same time would mean that precisely the
        // channel you want to see does not start. The view disappears in the process,
        // and ``ChannelPreview`` stops its engine — setting it to nil here is the
        // trigger for that and must come before ``onPlay``.
        stopPreview()
        onPlay(model.target(for: channel, at: now), model.shownChannels)
    }

    /// A press in the grid — running means channel, past means catch-up.
    ///
    /// **For the player the recording is a film and not a channel**
    /// (`design/konzept-p8.md`, section 4): its playlist has an
    /// end, so the engine takes over seeking by itself. Registered as `.live`
    /// it would instead get the channel controls — up and
    /// down for channel switching, no timeline.
    ///
    /// **The rule lives in ``Flows/CatchUpSelection``** and since 2026-09-26 also applies
    /// in the daily schedule on the phone (A2).
    private func playFromGrid(_ channel: Channel, _ cell: ProgramGrid.Cell) {
        stopPreview()
        guard
            let address = CatchUpSelection.recording(
                channels: channel, start: cell.start, end: cell.end,
                isGap: cell.isGap, now: now)
        else {
            // Running, upcoming or without archive: the channel itself.
            play(channel)
            return
        }
        onPlay(
            PlaybackTarget(
                itemID: nil,
                title: channel.cleanName,
                subtitle: cell.title,
                url: address,
                decision: LiveModel.decision(forURL: address),
                kind: .recording
            ),
            model.shownChannels
        )
    }

    /// Ends the preview and a wait that is still running.
    private func stopPreview() {
        previewDelay?.cancel()
        previewDelay = nil
        previewTarget = nil
    }

    /// Starts the wait for the channel in focus.
    ///
    /// Nothing happens without the preview switched on — and that here and not only in
    /// the board: what does not start in the first place cannot occupy a connection either.
    private func schedulePreview(for channel: Channel?) {
        stopPreview()
        guard model.preferences.previewsChannels, let channel else { return }
        // If the player keeps running in the picture-in-picture window, it holds the
        // connection to the provider — a preview next to it would be the second connection
        // on a one-connection account, and that waits forever
        // (on-device finding F-040: after picture-in-picture the Live area hung).
        guard PictureInPictureKeeper.shared.held == nil else {
            Diagnostics.verbose("Live area: no preview, Picture in Picture is running")
            return
        }

        previewDelay = Task {
            try? await Task.sleep(for: .seconds(Self.previewDwell))
            guard !Task.isCancelled else { return }
            // Through the same calculation as playback: a channel whose
            // playlist carries no picture would stay black in the preview as well
            // (viewer finding 2026-08-08: "the preview window stays
            // black"). ``LiveModel/target(for:at:)`` chooses for remembered
            // channels the raw stream and thus the engine that shows it.
            previewTarget = model.target(for: channel, at: now)
        }
    }

    // MARK: - Nothing to show

    /// Two different messages, and the difference matters: whoever has hidden
    /// everything will not want to create a channel list in the settings —
    /// they are looking for their filter.
    ///
    /// **One statement per state, and both lines tell the same one.** Here the heading
    /// said "No channels in this group" — but this state occurs
    /// only when nothing at all is loaded; there is no group then at all.
    /// Directly below it the hint said "No channel list
    /// stored yet": two diagnoses, one wrong, and the wrong one sent people
    /// hunting for the filter instead of to the settings.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: model.isEverythingHidden ? "eye.slash" : "dot.radiowaves.left.and.right")
                .font(.system(size: 64))
                .foregroundStyle(ColorRole.textQuiet.color)

            Text(app: model.isEverythingHidden ? "live.allHidden" : "live.noChannelsYet")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            Text(app: model.isEverythingHidden ? "live.allHiddenHint" : "live.setupHint")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .frame(maxWidth: 900, alignment: .leading)

            ForEach(model.failures) { failure in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(verbatim: failure.name)
                    Text(appKey: failure.messageKey)
                }
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.live.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.top, 140)
    }
}
