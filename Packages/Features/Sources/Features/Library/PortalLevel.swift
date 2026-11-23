import Core
import DesignSystem
import Flows
import ParentalControls
import PortalKit
import SwiftUI

/// A level of a portal — folder list or poster grid.
///
/// **The one rule that carries the whole thing:** a level is
/// drawn as a list when its entries are folders, and as a grid when they
/// are titles. It is decided by what came back — not predicted.
///
/// **Why not predicted:** one could guess from the target function
/// (`showValue` leads to folders, `showEntries` to titles), but that is
/// page-specific and breaks at the next rebuild of the page. Fetch first, then
/// draw is an answer that cannot age.
///
/// The finding behind it, from the device (2026-08-27): "Popular series" at Serieshub
/// are thirty **genres**, and they appeared as posters as if they were
/// series. A press opened a detail page for a genre. An interface
/// that claims structure it does not have is worse than a plain one.
struct PortalLevel<Title: View>: View {

    let source: PortalSource
    let library: Core.Library
    /// How a level of **titles** is drawn — the familiar grid.
    @ViewBuilder let titleView: (Core.Library) -> Title
    /// The way out into the sidebar — the end of the stairs.
    ///
    /// **Until 2026-08-28 it was passed in and never called.** That it was nevertheless
    /// mostly right made it worse instead of better: ancestors stepped in,
    /// so the behavior was right by chance — and would have become silently wrong at the next rebuild
    /// of the hierarchy.
    var onLeaveToSidebar: () -> Void = {}
    /// Whether there is another level below this one — see
    /// ``LibraryView/pendingExitSteps(focus:ids:hasLevel:)``.
    var hasLevelBelow = false
    /// Removes a level. `nil` means: there is no way back here.
    var onLeaveOneLevel: (() -> Void)?
    /// What should happen with a hit from the portal search.
    ///
    /// The folder list does not need it — it runs its rows as
    /// `NavigationLink` and leaves the target to the path. The search window lies
    /// **above** the path, though: a link inside it would lead nowhere while the
    /// window is open.
    var onOpen: (MediaItem) -> Void = { _ in }
    /// Continues playing a title from "Continue Watching" in place — `nil` means: the
    /// tile leads to the detail page like any other. See
    /// ``HomeModel/playsOnPress(_:inShelf:)``.
    var onContinue: ((MediaItem) -> Void)?
    /// What the button of a state that does not mean "once more" triggers — the shell
    /// knows the paths (``MainView/go(zu:)``).
    var onAction: (ActionTarget) -> Void = { _ in }
    /// The parental controls for the area itself — the level gets the raw source,
    /// and without a rule a child profile would see what Home withholds from it.
    var rule: ProtectionRule = .pending

    @State private var level: PortalTier?
    /// Continue Watching and favorites of this provider — only on its top level and
    /// only with an area of its own (AP60 point 5, ``OwnArea``).
    @State private var own: OwnArea?
    @State private var disruption: Disruption?
    /// What this portal asked for — `nil` means: there is nothing to search here.
    @State private var query: String?
    @State private var isLoadingMore = false
    @FocusState private var focus: String?

    private var items: [MediaItem]? { level?.items }

    /// The IDs of the focus anchors for the states without content.
    ///
    /// **Without them the sidebar opens and stays open** (error 6 of the
    /// expert report): as long as `items == nil`, a bare `ProgressView` stands here
    /// — nothing focusable —, and tvOS looks for the next target. In this app
    /// that is always the bar next to it on the left. ``LibraryView`` has solved the same
    /// three states this way for weeks; the reasoning as a whole is
    /// at ``FocusAnchor``.
    // Computed and not stored: ``PortalLevel`` is a generic type,
    // and Swift allows no stored type values in such types.
    private static var loadingAnchor: String { "portal-level-loading" }
    private static var errorHold: String { "portal-level-failed" }
    private static var emptyAnchor: String { "portal-level-empty" }

    /// **Folder or title — and in doubt, folder.**
    ///
    /// A single folder in the list is enough: putting it in a poster grid
    /// would again mean passing it off as a title. Conversely,
    /// a list does not harm a title — it only shows it more plainly.
    /// A list only results when there is **nothing to show**.
    ///
    /// **Before, `contains` stood here, and a single folder was enough**
    /// (viewer finding 2026-08-28, on the device: no images at all were visible in one portal).
    /// That level has two folders —
    /// "Search" and "Categories" — and **25 films with posters**. The two
    /// folders turned it into a row list, and the 25 posters disappeared
    /// into rows with an icon in front.
    ///
    /// The rule belongs the other way round: a grid is shown as soon as there is something
    /// to show. A list remains only where the level consists **exclusively**
    /// of folders and subheadings — "Popular series" at
    /// Serieshub, for example, thirty genres without a single image. There a
    /// grid of empty frames would be the worse information.
    ///
    /// A folder in the grid is not a special case: it becomes a tile, and a
    /// press on it leads one level deeper as everywhere — that is decided by the
    /// target of the path, not by this view.
    ///
    /// **The rule has lived in ``PortalKit/PortalShape`` since AP58 R7** — the phone read it until then
    /// in a version of its own.
    private var areFolders: Bool {
        PortalShape.areFolders(items ?? [])
    }

    var body: some View {
        Group {
            if let disruption {
                disruptionView(disruption)
            } else if let query {
                // **A level that asks is not a level but a search**
                // — and it gets the whole area (viewer finding 2026-08-28:
                // the search still does not open in a window of its own like
                // the global search, which is why everything is so cramped).
                //
                // Before, the folder list stood here with its head and its
                // spacing, and tvOS's search field was wedged above it. Now
                // the same view stands at this place that the global
                // search draws — the same area, the same grid, the same
                // tile. Only the root is a different one.
                //
                // The way back removes the level along with it: behind the search
                // lies a level without a single entry, and being
                // dropped there would look like an error.
                PortalSearchView(
                    source: source,
                    library: library,
                    query: query,
                    onOpen: onOpen,
                    suggestion: level?.suggestion,
                    onClose: leave
                )
            } else if let items, items.isEmpty {
                // **Empty is an answer, not an error** (viewer finding
                // 2026-08-28: a red "RuntimeError" for an empty list). A folder
                // without content is a normal case for a portal — a category
                // without titles on this page, a page after the last. The red error for it was a
                // false statement; since then the bridge answers with an empty
                // level, and here it says what that means.
                // What the portal asked is shown as an addendum — an empty level with a follow-up question
                // was simply empty on the TV until AP77.
                StateView(
                    state: .emptyPortalLevel, extras: level?.hint ?? level?.followUpQuestion
                )
                .focusAnchor(Self.emptyAnchor, focus: $focus)
                .onExitCommand(perform: leave)
            } else if let items {
                if areFolders {
                    folderList(items)
                        // The interceptor sits on the list and not at the
                        // embedding: there it would lie outside the
                        // ``NavigationStack`` and never reach the
                        // row in the response chain — the same lesson as with ``VODArea``.
                        .onExitCommand(perform: leave)
                } else {
                    // Without an interceptor: the grid runs its own stairs, and a
                    // second interceptor above would consume the key twice.
                    titleView(library)
                }
            } else {
                LoadingBand()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusAnchor(Self.loadingAnchor, focus: $focus)
                    .onExitCommand(perform: leave)
            }
        }
        // **On the requested ID, not the passed one.** On
        // descending the library is swapped — and on submitting
        // a search likewise: the same level becomes the level with an
        // answer. Without the search term in the ID the task would then
        // not run again.
        .task(id: library.id) { await load() }
        // **Pass the focus from the anchor on to the first row.** The anchor
        // disappears at the moment the list appears; whoever still holds it
        // then holds an element that no longer exists — and tvOS
        // looks for something itself again, which would put the sidebar back in
        // the race. The same pattern as in ``LibraryView``.
        .onChange(of: items) { _, fresh in
            guard focus == Self.loadingAnchor || focus == Self.errorHold || focus == Self.emptyAnchor
            else { return }
            // A subheading is not selectable — the focus would go to
            // a target that is none.
            // **With an area of its own onto the first started tile** (decision 2026-09-30):
            // whoever switches it on wants to continue watching there — one press, and it plays.
            if let firstItem = own?.continueWatching.first {
                focus = Self.tileFocus(.continueWatching, firstItem)
                return
            }
            guard let firstValue = fresh?.first(where: { $0.kind != .separator }) else { return }
            focus = firstValue.id
        }
    }

    /// One step out — the rule is in ``FocusRules/portalLadder``.
    ///
    /// **The same stairs as in the grid, only without its first step:** a
    /// folder list runs no scroller at whose start one could jump,
    /// so ``FocusRules/ExitStep/topOfList`` is never pending here. That is exactly
    /// what the stairs are a value for and not a chain of `if`s — what a
    /// view cannot do, it skips, without the order of the
    /// other steps knowing about it.
    private func leave() {
        let pending = LibraryView.pendingExitSteps(
            focus: nil, ids: [], hasLevel: hasLevelBelow && onLeaveOneLevel != nil)
        switch FocusRules.stepOut(along: FocusRules.portalLadder, pending: pending) {
        case .level:
            onLeaveOneLevel?()
        default:
            onLeaveToSidebar()
        }
    }

    // MARK: - Folders

    @ViewBuilder
    private func folderList(_ items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // **The head stands outside the scroll view** — the same as above the
            // title grid, see ``LibraryHeader``. Inside, it scrolled away on
            // the first key press, and the level then had no name
            // any more; the title level of the same page kept its own.
            LibraryHeader(title: library.name, count: PortalList.count(items))

            ScrollView(.vertical) {
                // **The rows scroll with the list** — one area, as on the phone and
                // as header box and shelves on Home.
                if let own {
                    customRows(own)
                        .padding(.top, 24)
                }
                let recent = PortalSource.recentlyUsed(in: items.map(\.id))
                VStack(alignment: .leading, spacing: PortalList.rowSpacing) {
                    ForEach(items, id: \.id) { item in
                        if item.kind == .separator {
                            separatorRow(item)
                        } else {
                            // **Titles get a row here too.** A level
                            // can be mixed — "Discover" has series and
                            // headings side by side —, and a title that was missing from
                            // the folder list would be unreachable.
                            row(item, recent: recent.contains(item.id))
                                // The following page as soon as one of the last rows appears
                                // (AP77, ``Flows/LoadMore``) — as in the grid since AP60.
                                .onAppear {
                                    if LoadMore.applies(item, in: items) { Task { await loadMore() } }
                                }
                        }
                    }
                    if level?.truncated == true {
                        Text(appKey: "portal.truncated")
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                            .padding(.top, PortalList.rowSpacing)
                    }
                }
                // **The whole area and not 900 points** — the reasoning
                // is at ``PortalList/maxWidth``.
                .frame(maxWidth: PortalList.maxWidth, alignment: .leading)
                .padding(.horizontal, MetricsBoard.tv.margin)
                .padding(.top, 24)
                // More at the bottom than at the top, for the same reason as in the grid: the
                // scroll view reaches the physical screen edge, and the last
                // row should stand above the overscan zone at the end of scrolling.
                .padding(.bottom, TVMetrics.topMargin + 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Own area

    enum Row: String { case continueWatching = "weiterschauen", favorites = "favoriten" }

    /// The ID of a tile in the area's own section — with the row before it, because the same
    /// title can appear in both.
    static func tileFocus(_ row: Row, _ item: MediaItem) -> String {
        "eigen-\(row.rawValue)-\(item.id)"
    }

    /// Continue Watching, then favorites — the same order and the same words as on the
    /// phone. An empty row is omitted.
    @ViewBuilder
    private func customRows(_ area: OwnArea) -> some View {
        VStack(alignment: .leading, spacing: PortalList.sectionSpacing) {
            if !area.continueWatching.isEmpty {
                shelfRow("home.continueWatching", .continueWatching, area.continueWatching)
            }
            if !area.favorites.isEmpty {
                shelfRow("tab.favorites", .favorites, area.favorites)
            }
        }
    }

    /// A row as on Home — heading with counter, the tiles below.
    private func shelfRow(_ title: String, _ row: Row, _ titleList: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(appKey: title)
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(verbatim: "\(titleList.count)")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
            .padding(.horizontal, MetricsBoard.tv.margin)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MetricsBoard.tv.gutter) {
                    ForEach(titleList, id: \.id) { item in
                        tile(item, row)
                    }
                }
                .padding(.horizontal, MetricsBoard.tv.margin)
                // So that enlarged tiles are not cut off at the edge.
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
    }

    /// The same tiles as on Home — so that "70 %" means the same here as there.
    private func tile(_ item: MediaItem, _ row: Row) -> some View {
        let identifier = Self.tileFocus(row, item)
        return Group {
            if let onContinue, playsOnPress(item, row) {
                Button {
                    onContinue(item)
                } label: {
                    tileImage(item, row, identifier)
                }
            } else {
                NavigationLink(value: item) { tileImage(item, row, identifier) }
            }
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .contextMenu { tileMenu(item, row) }
    }

    @ViewBuilder
    private func tileImage(_ item: MediaItem, _ row: Row, _ identifier: String) -> some View {
        if row == .continueWatching {
            let image = HomeModel.tileImage(for: item, from: source)
            EpisodeCard(
                item: item, imageURL: image?.url, isPortraitImage: image?.up ?? false,
                isFocused: focus == identifier)
        } else {
            PosterCard(
                item: item,
                imageURL: PosterAddress.url(
                    for: item, from: source,
                    width: ImageSizing.requestWidth(points: MetricsBoard.tv.poster.width)),
                isFocused: focus == identifier)
        }
    }

    /// The same rule as on Home — the row is just called something else here.
    private func playsOnPress(_ item: MediaItem, _ row: Row) -> Bool {
        row == .continueWatching && HomeModel.playsOnPress(item, inShelf: ShelfPreferences.resumeID)
    }

    /// Reset watched, favorite and — in Continue Watching — progress: the same
    /// commands and words as on Home. Afterwards the rows refresh. If the press plays,
    /// "Details" is at the top.
    @ViewBuilder
    private func tileMenu(_ item: MediaItem, _ row: Row) -> some View {
        if onContinue != nil, playsOnPress(item, row) {
            Button {
                onOpen(item)
            } label: {
                Label(app: "common.details", systemImage: "info.circle")
            }
        }
        Button {
            Task { await command { try await source.setPlayed(!item.isWatched, for: item.id) } }
        } label: {
            Label(
                app: item.isWatched ? "detail.markUnwatched" : "common.markWatched",
                systemImage: item.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
        }
        Button {
            Task { await command { try await source.setFavorite(!item.isFavorite, for: item.id) } }
        } label: {
            Label(
                app: item.isFavorite ? "common.unfavorite" : "detail.favorite",
                systemImage: Glyph.favorite.pair.forItem(item.isFavorite))
        }
        if row == .continueWatching {
            Button {
                // As on Home: only the position, favorite and watched remain.
                Task { await command { try await source.removeFromContinueWatching(item.id) } }
            } label: {
                Label(app: "home.removeFromResume", systemImage: Glyph.remove.name)
            }
        }
    }

    private func command(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            Diagnostics.defect(
                "Command in the own area: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
        }
        own = await OwnArea.load(
            forItem: library.id, source: source,
            preferences: PortalPreferences.load(from: SecureStore()), rule: rule)
    }

    /// A subheading — "Hidden gems" structures the list.
    ///
    /// **It was as big as the content and paler than it.** That put the
    /// heading below what it heads: at three meters distance the
    /// structure was not visible at all. A heading is larger and
    /// at least as bright as its section — the model is the
    /// month grouping of the home videos (``LibraryView/monthHeading(_:)``).
    ///
    /// Not selectable: the focus would go to a target that is none.
    @ViewBuilder
    private func separatorRow(_ item: MediaItem) -> some View {
        Group {
            if let key = PortalGroups.wordingKey(for: item.title) {
                Text(appKey: key)
            } else {
                Text(verbatim: item.title)
            }
        }
        .font(TypeLevel.header.font)
        .foregroundStyle(ColorRole.text.color)
        .padding(.horizontal, PortalList.horizontalInset)
        .padding(.top, PortalList.sectionSpacing)
        .padding(.bottom, 6)
    }

    /// A row — folder as well as title.
    ///
    /// **Both put the same value on the path**, namely the entry itself.
    /// This area's path is fixed to ``MediaItem``; a folder type of its own
    /// could not be put on it there, and a `NavigationLink` to
    /// a value the path does not know **simply does nothing** — with no
    /// error and no hint. What is a folder and what is a title
    /// is decided by the target.
    ///
    /// **The long press only under "Recently used"** (2026-10-12): there it removes the
    /// page from the group, and the next of the ten remembered moves up. Every other
    /// folder row is a door without commands — a menu there would open and do nothing.
    @ViewBuilder
    private func row(_ item: MediaItem, recent: Bool = false) -> some View {
        let isFocused = focus == item.id
        NavigationLink(value: item) {
            HStack(spacing: 18) {
                Image(systemName: item.kind == .folder ? "folder" : "play.rectangle")
                    .font(.system(size: 24))
                    .foregroundStyle(secondary(isFocused))
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: PortalList.textSpacing) {
                    Text(verbatim: item.title)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
                        .lineLimit(1)
                    // The subtitle is set smaller than the title: it is the
                    // secondary detail, and at the same size the two fought over the
                    // row. That it no longer merely repeats the title is
                    // settled one floor down — see
                    // `BridgeReply.ContentEntryRecord.subtitles(_:forTitle:)`.
                    if let plot = item.overview, !plot.isEmpty {
                        Text(verbatim: plot)
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(secondary(isFocused))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 20))
                    .foregroundStyle(secondary(isFocused))
            }
            .padding(.horizontal, PortalList.horizontalInset)
            // **Fixed height, with subtitle as without.** With a subtitle the
            // row measured 112 points, without it 70 — in a mixed list the
            // bright focus bar therefore jumped in height, and the list was
            // ragged.
            // All lists in the house have fixed row heights (``AppSidebar/rowHeight``,
            // ``LibraryView/categoryEntryHeight``).
            .frame(maxWidth: .infinity, minHeight: PortalList.height, alignment: .leading)
            // **The bright area is the highlight**, as with every row in the
            // house (model: ``AppSidebar`` and the sections in ``VODArea``).
            .background(
                isFocused ? ColorRole.text.color : .clear,
                in: RoundedRectangle(cornerRadius: PortalList.radius, style: .continuous)
            )
        }
        // **No `.card`.** It was the only occurrence in the project: tvOS puts
        // its own bright box behind it, which covers the row — the
        // reasoning as a whole is at ``BareButtonStyle``.
        .bareFocusableButton()
        // So that the anchor can hand over the focus, the row must be
        // addressable — see the handover in the body.
        .focused($focus, equals: item.id)
        .contextMenu {
            if recent {
                Button {
                    Task { await forget(item) }
                } label: {
                    Label(app: "portal.forgetRecent", systemImage: Glyph.remove.name)
                }
            }
        }
    }

    /// Remove a page from "Recently used" and reload the level. The focus was on
    /// the row that no longer exists afterwards — it goes to the first row.
    private func forget(_ item: MediaItem) async {
        do {
            try await source.forgetRecent(item.id)
        } catch {
            Diagnostics.defect(
                "Recently used not removed: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
        }
        await load()
        if let items, !items.contains(where: { $0.id == focus }) {
            focus = items.first(where: { $0.kind != .separator })?.id
        }
    }

    /// The color of a row's secondary details: icon, subtitle, arrow.
    ///
    /// On the bright area of the focused row not `ground` but the
    /// warmer tone — the same choice as with the program row of a focused
    /// channel row, see ``Styling/ColorRole/textOnLight``.
    private func secondary(_ isFocused: Bool) -> Color {
        isFocused ? ColorRole.textOnLight.color : ColorRole.textQuiet.color
    }

    // MARK: - Loading

    /// The next page of the folder list — the grid fetches its own via ``LibraryModel``.
    private func loadMore() async {
        guard let pending = level, let tag = pending.next, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await source.level(library.id, next: tag)
            guard level?.next == tag else { return }
            level = pending.using(nextPage: page)
        } catch {
            Diagnostics.defect(
                "Portal level: next page not fetched: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
        }
    }

    private func load() async {
        do {
            // `level` and not `items(in:)`: the folder list also shows the
            // subheadings, the grid must not see them.
            let fetched = try await source.level(library.id)
            // **Set before the level**, so that the first focus already knows whether there is a
            // started tile — otherwise it would jump up from the folder row
            // afterwards.
            own = await OwnArea.load(
                forItem: library.id, source: source,
                preferences: PortalPreferences.load(from: SecureStore()), rule: rule)
            level = fetched
            // A level that asks is a search — and then the
            // search window opens instead of drawing an empty list here.
            query = fetched.query
            disruption = nil
        } catch {
            // **A cancellation is not a disruption** (Fable analysis 2026-10-01): whoever jumps between
            // levels cancels the old request (`.task(id:)`). Six times in one
            // minute "Portal level not loaded" then appeared, and the abandoned level would have
            // shown a disruption that nobody sees any more.
            guard !Task.isCancelled else {
                Diagnostics.verbose("Portal level: cancelled, the view changed", since: nil)
                return
            }
            Diagnostics.defect(
                "Portal level not loaded: \(Diagnostics.explain(error))", since: nil, area: "Oberfläche")
            disruption = Disruption(error)
            level = nil
        }
    }

    /// A disruption of this level — **via the one interpretation and not past it.**
    ///
    /// **Until 2026-09-26 every error here became ``PlaybackPhase/portalUnresolvable``**
    /// (report A, find S5) — also a bridge that did not answer at all, and a device
    /// that needs a person or a new sign-in. The phone did exactly the
    /// opposite: there everything became "the bridge does not answer". Now
    /// ``DisruptionInterpretation`` decides, and the level shows what comes out of it.
    ///
    /// **The bridge's reason travels along as an addendum**, where there is one: "setting
    /// required but empty" says more than any general message. For a rejection with a code,
    /// the server's translated sentence is shown, not the code.
    private struct Disruption {
        let state: PlaybackPhase
        let extras: String?

        init(_ error: any Error) {
            state = DisruptionInterpretation.state(forItem: error, origin: .portals)
            switch state {
            case .portalUnresolvable, .networkPortals:
                extras =
                    (error as? PortalBridge.TestError)?.message(lookUp: Self.lookedUp)
                    ?? error.localizedDescription
            default:
                extras = nil
            }
        }

        /// The sentence for a key, or `nil` if no catalog has it.
        private static func lookedUp(_ key: String) -> String? {
            let message = AppLanguageSetting.message(key)
            return message == key ? nil : message
        }
    }

    /// The disruption as a whole page.
    ///
    /// **The anchor only for an information message** (error 6 of the expert report): it takes no
    /// focus, and without an anchor the sidebar opened. A job takes it with its
    /// own button — an anchor next to it would be a second target that contests
    /// the focus.
    @ViewBuilder
    private func disruptionView(_ disruption: Disruption) -> some View {
        let view = StateView(
            state: disruption.state, extras: disruption.extras, onAction: handle)
        if disruption.state.form.hasButton {
            view.onExitCommand(perform: leave)
        } else {
            view
                .focusAnchor(Self.errorHold, focus: $focus)
                .onExitCommand(perform: leave)
        }
    }

    /// "Try again" loads this level; everything else the shell knows.
    private func handle(_ target: ActionTarget) {
        if target == .retry {
            Task { await load() }
        } else {
            onAction(target)
        }
    }
}

/// The measures of the portal folder list — extracted so they can be tested.
///
/// A number in a view cannot be recalculated; it stands there and
/// is right or is not. The same separation as with the heights of the
/// library page (``LibraryView``), which `LayoutBudgetTests` recalculates.
enum PortalList {

    /// How wide a row may get: as wide as the area.
    ///
    /// **900 points stood here, and that was the specification of another page.**
    /// Settings carry a section column on the left, next to which 900 points
    /// fit exactly. A portal area does not have that — in the 1724 points
    /// wide area next to the collapsed sidebar, 824
    /// points stayed empty on the right while the titles next to it were cut off after one word.
    ///
    /// As a value and not as `.infinity` at the call site: this way it can be read from the value
    /// itself that the full width is a decision, and a
    /// test pins it down.
    static let maxWidth: CGFloat = .infinity

    /// Width for running text — the reason for an error message.
    ///
    /// Here the measure stays, and for the reason for which it was
    /// wrong on a list: a line of text across the whole screen width cannot be read at three meters
    /// distance, because the eye does not find the beginning of the line
    /// again. Nobody reads a list in one go.
    static let readingWidth: CGFloat = 900

    /// Between two rows. Tight, because the bright area of the focused row
    /// already separates clearly enough.
    static let rowSpacing: CGFloat = 6

    /// Between title and subtitle within a row.
    static let textSpacing: CGFloat = 4

    static let verticalInset: CGFloat = 16
    static let horizontalInset: CGFloat = 24

    /// Corner radius of the focus area — the same measure as in the sidebar and
    /// at the provider's sections.
    static let radius: CGFloat = 12

    /// Air above a subheading. It is what makes a heading a
    /// heading: without spacing above, it belongs to the section before.
    static let sectionSpacing: CGFloat = 34

    /// The height of **every** row, with subtitle as without.
    ///
    /// Calculated and not copied: the line heights come from the tokens,
    /// so that a type change takes the calculation along (the reasoning as a whole
    /// is at ``Tokens/Typography/lineHeight(for:)``). The room for both lines
    /// is always reserved — a list in which the rows alternate between 70 and 112
    /// points is ragged, and the focus bar jumps in it.
    static var height: CGFloat {
        TypeLevel.lineHeight(zu: TypeLevel.text.points)
            + textSpacing
            + TypeLevel.lineHeight(zu: TypeLevel.lowercased.points)
            + 2 * verticalInset
    }

    /// What stands there when a level is empty and the portal says nothing about it.
    ///
    /// Two sentences, for two cases: a search without a hit names the term,
    /// an ordinary level is simply empty. Both are an answer and
    /// not an error — and both are here because two views need it:
    /// the folder list and the search window.
    static func emptyText(needle: String) -> String {
        guard !needle.isEmpty else {
            return AppLanguageSetting.text("portal.level.empty")
        }
        return String(
            format: AppLanguageSetting.text("portal.search.none %@"), needle)
    }

    /// How many entries a level carries.
    ///
    /// Subheadings do not count: they are not an entry but
    /// the structure above. Whoever counted them would promise more in the page's head
    /// than the list delivers.
    static func count(_ items: [MediaItem]) -> Int {
        items.filter { $0.kind != .separator }.count
    }
}
