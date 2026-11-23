import Core
import DesignSystem
import PlaylistKit
import PortalKit
import SwiftUI

/// **Two columns instead of one long list** — the choice of what appears on the Home screen.
///
/// **The finding of 2026-09-12, from the product owner:** the grouping view under Live and
/// the channel list are both endlessly long, and from a usability standpoint that does not
/// work; it has to be made cleaner somehow. Both pickers were the sixth and seventh block
/// in the single scroll view of "Display". A usability pass counted it:
/// **fourteen down-presses to reach the portal grid**, the grid itself fifty to a hundred
/// rows, and anyone who wanted the channels afterwards had to get through all of it.
///
/// **The in-house rationale was already there**, two files away in ``LiveSettings``:
/// *"With 79 groups the page is longer than the screen, and you scroll past everything you
/// are not looking for … One more section in the list on the left costs nothing; a page
/// that grows costs something on every use."* That change reintroduced exactly this mistake
/// in "Display".
///
/// **The shape: the source on the left, its entries on the right.** Switching costs **one
/// right-press** instead of twenty down-presses. Each column is its own
/// ``SwiftUICore/View/focusSection()``, so focus moves vertically within a column and
/// horizontally between them — the movement a remote naturally has.
///
/// **And the selection is always shown at the top right**, complete and uncapped. The
/// finding of 2026-09-07 on the phone was: two thousand channels in one list, and the four
/// selected ones got lost in it. Anyone who selects must be able to deselect without
/// searching.
struct ColumnChoice<Kopf: View>: View {

    /// A row in one of the two columns.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        /// What appears on the right of the row — a number, a state, or nothing.
        var secondaryLine: String?
        /// Whether the row leads deeper (left only, in the portal tree).
        var leadsDeeper = false
    }

    /// The left column: portals or groups, respectively.
    let sources: [Row]
    /// Which of them is selected.
    @Binding var openSource: String?
    /// The right column, already filtered and ordered: the selection first, then the rest.
    let selected: [Row]
    let other: [Row]
    /// What a press on a row on the right does.
    let select: (Row) -> Void

    /// What the arrow of a row that leads deeper does — `nil` means: no depth.
    ///
    /// **Two buttons per row rather than one with a double meaning.** On the TV there is no
    /// tap, only focus and the select button; a button that does something different
    /// depending on the row cannot be explained on the remote. The arrow appears only where
    /// there is a deeper level.
    var open: ((Row) -> Void)?

    /// The way up one level — `nil` means: there is no level above.
    ///
    /// **As the first row on the right and not on the left.** The left shows *which* portal
    /// applies; the right shows *where* you are within it. Anyone looking for the way back on
    /// the left would lose track when switching the portal.
    var back: (name: String, action: () -> Void)?

    /// What "up" and "down" do on a **selected** row — `nil` means: the selection has no
    /// order (AP46/AP32, 2026-09-25).
    ///
    /// **An option and not an obligation**, because of the four screens that use this
    /// component, only one has an order that matters: the channel shelf. Which six channels it
    /// shows is decided by the sequence (``LiveShelf/atMost``); for the portal folders the
    /// viewer decides the sequence under "Rows on the Home screen", and a second one here
    /// would drift apart from that one.
    ///
    /// **Greyed out at the edge and not removed** — a row in which a button disappears jumps
    /// when paging (``OtherSettings/shelfRow``). **And the focus moves with the channel** (the
    /// channel picker puts it on the same arrow of the moved row), otherwise it would sit on
    /// the neighbour that has just swapped places after the press.
    var arrange: ((Row, Bool) -> Void)?
    /// **Focus belongs to the screen, not to this component.**
    ///
    /// Both screens report their first target themselves (``SettingsFirstEntryKey``) and
    /// accept the request to jump there themselves — that is what
    /// ``EinstellungenFokusbaumTests`` requires, and the requirement is right: a section that
    /// hands its first target to a component has none left as soon as someone replaces the
    /// component.
    @FocusState.Binding var focus: String?

    /// The header above both columns — sentence, count, and whatever else the screen has to
    /// say.
    @ViewBuilder let header: () -> Kopf

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()

            HStack(alignment: .top, spacing: Self.columnSpacing) {
                // **The left column is narrow and carries the order.** It does not need to be
                // wide: a portal name and a group label are short, and
                // what costs space here is missing on the right, where the names are long.
                column(sources, prefix: "quelle", width: Self.sourceWidth) { row in
                    openSource = row.id
                    // **Focus stays where it was.** A press on the left rebuilds the right
                    // column; if focus jumps to the right in the process, the next
                    // group is no longer reachable with one press.
                    focus = "quelle-" + row.id
                }
                .focusSection()

                VStack(alignment: .leading, spacing: 0) {
                    if !selected.isEmpty {
                        Text(app: "settings.homeChosen")
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .padding(.bottom, 10)
                        column(
                            selected, prefix: "gewaehlt", width: Self.selectedWidth(orders: arrange != nil),
                            on: true, arrange: arrange
                        ) {
                            select($0)
                        }
                        .padding(.bottom, 26)
                    }
                    if let back {
                        Button(action: back.action) {
                            HStack(spacing: 10) {
                                Image(systemName: "chevron.left")
                                Text(verbatim: back.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(TypeLevel.footer.font)
                            .frame(width: Self.folderWidth, alignment: .leading)
                            .settingsFont(isFocused: focus == "zurueck", muted: true)
                            .settingsSurface(.pill, isFocused: focus == "zurueck")
                        }
                        .bareFocusableButton()
                        .focused($focus, equals: "zurueck")
                        .info(
                            name: AppLanguageSetting.text("common.back"),
                            .word(back.name)
                        )
                        .padding(.bottom, 10)
                    }
                    column(other, prefix: "uebrig", width: Self.folderWidth) { select($0) }
                }
                .focusSection()
            }
            .padding(.top, 24)
        }
    }

    /// The identifier that the right-press from the section list jumps to.
    ///
    /// **The first row on the left** — the order, not the content. Anyone pressing right from
    /// the section list first wants to know which portals or groups there are; the way into
    /// the entries is one press further.
    static func firstTarget(_ sources: [Row]) -> String {
        sources.first.map { "quelle-" + $0.id } ?? "quelle-"
    }
    /// A column of rows — **flat in a `VStack` and not as a grid.**
    ///
    /// ``LiveSettings`` gives the reason for 79 groups: *"All rows in **one**
    /// VStack: on tvOS, focus moves geometrically and reliably only between
    /// siblings."* A `LazyVGrid` has a second drawback, which the
    /// pass named: cells that are not built yet are not
    /// focusable — with a hundred rows the focus gets stuck in them.
    /// The width of the left column.
    ///
    /// **Derived from the row column and not set** (on-device test 2026-09-27, T12):
    /// here 480 on the left and 760 on the right were set, plus an arrow button — 1346 points in
    /// a column of 900. The rest stuck out on both sides and on the left lay over the
    /// section list. Now both columns share ``SettingsView/contentWidth``.
    static var sourceWidth: CGFloat { 320 }
    /// The gap between the two columns.
    static var columnSpacing: CGFloat { 30 }
    /// The width of the right column **including the buttons next to its rows.**
    static var folderWidth: CGFloat { SettingsView.contentWidth - sourceWidth - columnSpacing }
    /// What a glyph button next to a row costs, including the gap.
    static var buttonSpace: CGFloat { SettingsMetrics.iconButton.width + 10 }

    /// The width of a selected row — **narrower when arrows stand next to it**, so that
    /// the column keeps its width and does not run out to the right.
    static func selectedWidth(orders: Bool) -> CGFloat {
        orders ? folderWidth - 2 * buttonSpace : folderWidth
    }

    /// How wide a row itself is: the column width without the buttons next to it.
    ///
    /// **The column keeps its width, the row yields** — otherwise every row with an
    /// open arrow ran over the right edge by the arrow's width.
    static func rowWidth(column: CGFloat, buttons: Int) -> CGFloat {
        column - CGFloat(buttons) * buttonSpace
    }

    @ViewBuilder
    private func column(
        _ rows: [Row], prefix: String, width: CGFloat, on: Bool = false,
        arrange: ((Row, Bool) -> Void)? = nil,
        press: @escaping (Row) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { location, row in
                let id = prefix + "-" + row.id
                let chosen = on || row.id == openSource
                let opens = row.leadsDeeper && prefix != "quelle" && open != nil
                HStack(spacing: 10) {
                    Button {
                        press(row)
                    } label: {
                        HStack(spacing: 12) {
                            if prefix != "quelle" {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            }
                            Text(verbatim: row.name)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            if let secondaryLine = row.secondaryLine {
                                Text(verbatim: secondaryLine)
                                    .font(TypeLevel.lowercased.font)
                                    .foregroundStyle(ColorRole.textQuiet.color)
                            }
                            if row.leadsDeeper, prefix == "quelle" {
                                Image(systemName: "chevron.right")
                                    .font(TypeLevel.lowercased.font)
                                    .foregroundStyle(ColorRole.textQuiet.color)
                            }
                        }
                        .font(TypeLevel.footer.font)
                        .frame(
                            width: Self.rowWidth(column: width, buttons: opens ? 1 : 0),
                            alignment: .leading
                        )
                        .settingsFont(isFocused: focus == id, muted: !chosen)
                        .settingsSurface(
                            .pill, isFocused: focus == id,
                            reason: chosen ? ColorRole.surface.color : ColorRole.surfaceHigh.color)
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: id)
                    .info(name: row.name, .on(chosen))

                    if row.leadsDeeper, prefix != "quelle", let open {
                        iconButton(
                            Glyph.next.name, id: "oeffne-" + row.id,
                            name: AppLanguageSetting.text("settings.homeOpenFolder"),
                            value: row.name
                        ) {
                            open(row)
                        }
                    }

                    if let arrange {
                        iconButton(
                            Glyph.up.name, id: "hoch-" + row.id,
                            name: AppLanguageSetting.text("settings.live.a11y.moveUp"),
                            value: row.name,
                            active: location > 0
                        ) {
                            arrange(row, true)
                        }
                        iconButton(
                            Glyph.down.name, id: "runter-" + row.id,
                            name: AppLanguageSetting.text("settings.live.a11y.moveDown"),
                            value: row.name,
                            active: location < rows.count - 1
                        ) {
                            arrange(row, false)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Glyph buttons

extension ColumnChoice {

    /// A button that carries only a glyph — the arrow into the depth and the two for
    /// reordering.
    ///
    /// **`active` greys out the appearance and the body, not the focus tree** (AP22): a
    /// `.disabled` button would drop out of focus on tvOS, and the focus would then be somewhere or other.
    fileprivate func iconButton(
        _ symbol: String, id: String, name: String, value: String, active: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard active else { return }
            action()
        } label: {
            Image(systemName: symbol)
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: focus == id, muted: true)
                .opacity(active || focus == id ? 1 : 0.4)
                .settingsSurface(.character, isFocused: focus == id)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .info(name: name, .word(value))
    }
}

// MARK: - Portal shelves

/// **Which portal folders get their own shelf** — the portal on the left, its
/// folders on the right.
///
/// **The folder tree has a stack** (finding of the pass, S2-5): before, "back" was **one**
/// value and always jumped to the root — anyone three levels deep had to walk the whole
/// way again. Now the left column carries a breadcrumb, and the arrow goes up
/// **one** level.
///
/// **The open level is itself selectable.** Otherwise, to make "Popular Series" a
/// shelf you would first have to climb back up — the same decision as on the phone: *"That
/// the row is selectable at the same time saves the way back."*
struct PortalShelfChoice: View {

    let layers: [Core.Library]
    let source: PortalSource?

    @State private var preferences = ShelfPreferences()
    /// The way in — empty means: at the portals.
    @State private var stack: [(identifier: String, name: String)] = []
    @State private var content: [ColumnChoice<AnyView>.Row] = []
    @State private var isLoading = false
    @State private var openPortal: String?
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    var body: some View {
        ColumnChoice(
            sources: sourceColumn,
            openSource: $openPortal,
            selected: selectedRows,
            other: isLoading ? [] : content,
            select: { select($0) },
            open: { goDeeper($0) },
            back: backPath,
            focus: $focus
        ) {
            AnyView(headerArea)
        }
        .preference(
            key: SettingsFirstEntryKey.self,
            value: ColumnChoice<AnyView>.firstTarget(sourceColumn)
        )
        .onChange(of: entryRequest) { _, _ in
            focus = ColumnChoice<AnyView>.firstTarget(sourceColumn)
        }
        .task {
            preferences = ShelfPreferences.load(from: FileStore(), forItem: ProfilePointer.active)
            // **Without a preselection there would be nothing on the right.** Anyone opening the section should see
            // what is up for selection — and not have to press something on the left first to
            // find out that there is anything on the right at all.
            if openPortal == nil { openPortal = portals.first }
        }
        // **A press on the left selects the portal — and shows its entry points on the right.**
        //
        // **Here was the bug that the product owner reported on 2026-09-13**
        // (the report: in the portal view no content can be selected, something seems
        // fundamentally wrong here): the press called `enter(portalIdentifier)`, and that asked
        // the source for the entries of **a level named after the portal**. A
        // portal is not a level, though — its entry points are the ``Core/Library`` entries
        // that ``PortalSource/libraries()`` had long since delivered. The request went
        // nowhere, and nothing appeared on the right.
        .onChange(of: openPortal, initial: true) { _, fresh in
            guard let fresh else { return }
            stack = []
            content = entries(from: fresh)
        }
    }

    @ViewBuilder
    private var headerArea: some View {
        SettingsHeader("settings.section.homePortals", hint: "settings.homePortalsHint")
        // **The count is shown in the header** (finding S2-6): without it nobody notices that the
        // fourth folder pushes out the oldest — the displaced row typically lies
        // in a different portal, two levels deep.
        Text(
            app:
                "settings.homeChosenOf \(preferences.portalFolders.count) \(ShelfPreferences.maximumPortalFolders)"
        )
        .font(TypeLevel.lowercased.font)
        .foregroundStyle(ColorRole.textQuiet.color)
        .padding(.top, 8)
    }

    /// The left column: the portals — or, in the tree, the breadcrumb including the way back.
    /// The left column: **always the portals.**
    ///
    /// **And not the breadcrumb** (corrected on 2026-09-13). The first attempt replaced
    /// the portal list with the way in — that left no other portal reachable
    /// when descending, and the column showed a single row. The left shows
    /// *which* portal applies; where you are within it is shown by the "back" row on the right.
    private var sourceColumn: [ColumnChoice<AnyView>.Row] {
        portals.map { portal in
            .init(
                id: portal,
                name: portal.uppercased(),
                secondaryLine: "\(selectedIn(portal))/\(levelsIn(portal))",
                leadsDeeper: false)
        }
    }

    private var portals: [String] {
        var seen = Set<String>()
        return layers.compactMap { level in
            guard let portal = PortalLibraryID(level.id)?.portal else { return nil }
            return seen.insert(portal).inserted ? portal : nil
        }
    }

    private func levelsIn(_ portal: String) -> Int {
        layers.count { PortalLibraryID($0.id)?.portal == portal }
    }

    private func selectedIn(_ portal: String) -> Int {
        preferences.portalFolders.count { $0.identifier.hasPrefix(portal + "|") }
    }

    /// The selection — **including what lies deep in another portal.**
    ///
    /// Finding S2-6 of the pass: without this block, a deeply selected level is not visible in
    /// the root list, and to deselect it you would have to walk the way there again — around
    /// forty presses. The name is in the store, so it appears here.
    private var selectedRows: [ColumnChoice<AnyView>.Row] {
        preferences.portalFolders.map { .init(id: $0.identifier, name: $0.name) }
    }

    /// **What is saved is the name together with the way to it**, not the row as it
    /// stands. On the right a subfolder is called "Most watched right now" — under the breadcrumb
    /// that is enough. On the shelf it stands alone, and there "Most watched right now" without a
    /// portal is exactly the information that ``Core/ShelfPreferences/PortalChoice`` requires and
    /// that was missing on 2026-09-13. The open level already carries its way (``fullName``);
    /// everything else gets it here.
    private func select(_ row: ColumnChoice<AnyView>.Row) {
        let name = row.id == stack.last?.identifier ? row.name : fullName(row.name, under: stack)
        preferences.select(.init(identifier: row.id, name: name), on: !preferences.selects(row.id))
        preferences.save(to: FileStore(), forItem: ProfilePointer.active)
    }

    /// One level up — `nil` at the root of a portal.
    ///
    /// **A stack and not a single value** (finding S2-5 of the usability pass):
    /// before, "back" always jumped to the root; anyone three levels deep walked the
    /// whole way again — three times for three allowed selections from different portals.
    private var backPath: (name: String, action: () -> Void)? {
        guard !stack.isEmpty else { return nil }
        let target = stack.dropLast().last?.name ?? (openPortal?.uppercased() ?? "")
        return (
            name: target,
            action: {
                stack.removeLast()
                if let pending = stack.last {
                    Task { await loadLevel(pending.identifier) }
                } else if let portal = openPortal {
                    content = entries(from: portal)
                }
            }
        )
    }

    /// The entry points of a portal — **from the loaded list, without a fetch.**
    ///
    /// ``PortalSource/libraries()`` fetched them at startup; the shell holds them for the
    /// sidebar. Asking for them a second time here would be a fetch for a list
    /// that is already there — and with the portal identifier as the path it went nowhere anyway.
    private func entries(from portal: String) -> [ColumnChoice<AnyView>.Row] {
        layers
            .filter { PortalLibraryID($0.id)?.portal == portal }
            .map { .init(id: $0.id, name: $0.name, leadsDeeper: true) }
    }

    /// One level deeper — the arrow on a row on the right.
    private func goDeeper(_ row: ColumnChoice<AnyView>.Row) {
        stack.append((identifier: row.id, name: row.name))
        Task { await loadLevel(row.id) }
    }

    /// The subfolders of a level — **only the folders, not the titles.**
    ///
    /// A shelf fills a level; a single film is not one. That is recognised by
    /// ``Core/MediaItem/Kind/folder`` — the bridge derives the kind from the target function
    /// and not from the view the portal suggests.
    ///
    /// **The row carries the identifier of the level, not that of the entry** (2026-09-13).
    /// Here `$0.id` stood — the entry identifier `portal|schlüssel|address`. What belongs in the store,
    /// though, is what ``HomeModel`` later presents to ``PortalSource/items(in:filter:)``,
    /// and that is a level identifier; ``MainView`` forms it when descending
    /// via ``PortalSource/levelID(forItem:)``, and the same route applies here. Two identifiers
    /// for the same folder would be the place where selection and shelf drift apart.
    private func loadLevel(_ identifier: String) async {
        isLoading = true
        defer { isLoading = false }
        let filter = Core.ItemFilter(kinds: [], sortBy: .natural, limit: 200)
        let found = (try? await source?.items(in: identifier, filter: filter)) ?? []
        // **The open level is also in the list, in first place.** It is often the
        // target: "Popular Series" as a shelf, not one of its thirty genres.
        var rows: [ColumnChoice<AnyView>.Row] = []
        if let pending = stack.last {
            rows.append(.init(id: pending.identifier, name: fullName(pending.name)))
        }
        rows +=
            found
            .compactMap { entry in
                PortalSource.levelID(forItem: entry).map {
                    .init(id: $0, name: entry.title, leadsDeeper: true)
                }
            }
        content = rows
    }

    /// The name that later appears on the shelf — **with the way to it.**
    ///
    /// "SERIESHUB · Popular Series · Most watched right now" and not "Most watched
    /// right now": the name goes into the store, and there nobody knows any more where it came from.
    private func fullName(_ name: String) -> String {
        fullName(name, under: Array(stack.dropLast()))
    }

    /// - Parameter weg: The levels **above** the name — for the open level the stack
    ///   without itself, for a row below it the whole stack.
    private func fullName(_ name: String, under route: [(identifier: String, name: String)]) -> String {
        let portal = openPortal.map { [$0.uppercased()] } ?? []
        return (portal + route.map(\.name) + [name]).joined(separator: " · ")
    }
}

// MARK: - Channel shelves

/// **Which channels appear on the channel shelf** — the group on the left, its channels on the right.
///
/// Four findings of the usability pass of 2026-09-12 are built into this view:
///
/// * **Search did not find "HD".** Filtering ran over the raw name, and forty
///   percent of channels carry superscript decorative characters (`ᴴᴰ`). ``Core/Channel`` carries
///   a precomputed ``Core/Channel/searchKey``; what is compared now is that one against
///   ``Core/ChannelName/searchKey(_:)`` of the search term. A failed search costs
///   ten to twenty keyboard presses on the TV, and afterwards "no match" is displayed as if
///   the channel did not exist.
/// * **The names were shown raw** and truncated to one line — `DE| WELLE
///   ENTERTAINMENT ᴴᴰ ᴰᴼᴸᴮʸ` read as `DE| WELLE ENTERTAI…`. Now ``Core/Channel/cleanName``
///   is shown, and the groups go through ``LiveSettings/label(for:)``: 46
///   of 79 groups begin with `DE|`, so the pills would otherwise all read the same.
/// * **Only 24 of 2046 were reachable without a keyboard**, even within a group.
///   The group is now the order, and the count states the **excerpt shown**
///   instead of the total catalog.
/// * **Six are effective** (``LiveShelf/atMost``), but any number could be selected.
///   From the seventh on, a note appears on the row — greyed out and **not** `.disabled`, because
///   that would take away the focus target on tvOS.
struct ChannelShelfChoice: View {

    let catalog: @Sendable () async -> [Channel]
    /// The visible groups in the viewer's order — from ``LivePreferences``.
    let groups: [String]

    @State private var preferences = ShelfPreferences()
    @State private var channels: [Channel] = []
    @State private var openGroup: String?
    /// Search term and index letter — **together in one value**, because only one
    /// of the two applies at a time. The rule for this lives in ``Core/ChannelFilter`` and not here: as
    /// two states it lay in two places (once when typing, once when pressing a
    /// marker) and would have drifted apart at the next section.
    @State private var filter = ChannelFilter()
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    /// This many channels are shown by the right column.
    ///
    /// **Capped, because a settings page is not a channel list** — the same sentence as
    /// on the phone. The group in front makes the cap bearable: it is no longer a limit
    /// but the excerpt of an order, and the count says how large the
    /// rest is.
    private static let atMost = 30

    var body: some View {
        ColumnChoice(
            sources: groupColumn,
            openSource: $openGroup,
            selected: selectedRows,
            other: remainingRows,
            select: { select($0.id) },
            arrange: { row, up in
                preferences.moveChannel(row.id, up: up)
                preferences.save(to: FileStore(), forItem: ProfilePointer.active)
                focus = (up ? "hoch-" : "runter-") + row.id
            },
            focus: $focus
        ) {
            AnyView(headerArea)
        }
        .preference(
            key: SettingsFirstEntryKey.self,
            value: ColumnChoice<AnyView>.firstTarget(groupColumn)
        )
        .onChange(of: entryRequest) { _, _ in
            focus = ColumnChoice<AnyView>.firstTarget(groupColumn)
        }
        .task {
            channels = await catalog().filter { !$0.isSectionMarker }
            preferences = ShelfPreferences.loadNamed(
                from: FileStore(), channels: channels, forItem: ProfilePointer.active)
        }
    }

    @ViewBuilder
    private var headerArea: some View {
        SettingsHeader("settings.section.homeChannels", hint: "settings.homeChannelsHint2")

        HStack(spacing: 20) {
            // **The search field is at the top and not below the groups.** Before, 14
            // to 27 grid rows lay in front of it, and a press on a group had no
            // visible effect because the result lay below the screen.
            TextField(
                text: Binding(
                    get: { filter.searchTerm }, set: { filter.search($0) })
            ) {
                Text(app: "live.searchPrompt")
            }
            .keyboard(forItem: .prose)
            .font(TypeLevel.footer.font)
            .settingsSurface(.pill, isFocused: focus == "suche")
            .focused($focus, equals: "suche")
            .frame(maxWidth: 620)

            Text(
                app:
                    "settings.homeShownOf \(remainingRows.count) \(filtered.count)"
            )
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.textQuiet.color)
        }
        .padding(.top, 10)

        register
    }

    /// **The A–Z index: every channel in two presses, without a keyboard** (AP32, from E80).
    ///
    /// **Why it does not replace search and search does not replace it:** typing is the most
    /// expensive operation on the remote that this app knows — anyone who knows the name is
    /// faster with search; anyone who knows it only roughly finds it only that way. The right
    /// column shows **thirty** entries, and with a letter in front that cap is
    /// never in the way.
    ///
    /// **Its own focus section**, as with the jump markers in ``LiveSettings``: otherwise
    /// pressing down would walk through up to twenty-seven markers instead of getting
    /// into the channel list.
    @ViewBuilder
    private var register: some View {
        let letters = indexLetters
        // **Below two letters there is nothing to choose.** A bar with a single marker
        // is a button that changes nothing.
        if letters.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(letters, id: \.self) { character in
                        ChoiceRow(
                            wording: character,
                            chosen: filter.letter == character,
                            // Equal width, so that the bar remains an index and not a
                            // row of buttons of different sizes: "I" is half as wide
                            // as "W".
                            width: 74,
                            identifier: "letter-" + character,
                            focus: $focus
                        ) {
                            filter.select(character)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            .frame(maxWidth: Self.indexWidth, alignment: .leading)
            .focusSection()
        }
    }

    /// How wide the index bar may become.
    ///
    /// **The same width as the right column** — the index belongs to it and not to the
    /// screen. Twenty-seven markers do not fit side by side; they scroll, and the
    /// selected one stays in view because the focus pulls it along.
    private static var indexWidth: CGFloat { ColumnChoice<AnyView>.folderWidth }

    /// On the left: "All groups" and the visible groups, each with its channel count.
    ///
    /// **Only groups in which a channel actually exists** — an empty group is a
    /// way into nothing. And **only the visible ones**: ``groups`` comes from
    /// ``LivePreferences/ordered(_:)``, so it lists exactly those that are switched on
    /// under "Live".
    private var groupColumn: [ColumnChoice<AnyView>.Row] {
        var rows: [ColumnChoice<AnyView>.Row] = [
            .init(
                id: Self.allGroups,
                name: AppLanguageSetting.text("settings.homeAllGroups"),
                secondaryLine: "\(channels.count)")
        ]
        var number: [String: Int] = [:]
        for channel in channels { number[channel.group ?? "", default: 0] += 1 }
        rows += groups.compactMap { group in
            guard let count = number[group], count > 0 else { return nil }
            return .init(
                id: group, name: LiveSettings.label(for: group), secondaryLine: "\(count)")
        }
        return rows
    }

    /// The identifier of the "All groups" row — **a value that no group carries.**
    private static let allGroups = "\u{001F}alle"

    /// The selection, complete — **also from a group that has meanwhile been hidden.**
    ///
    /// Finding S3-12 of the pass: without this row, a selected channel drops out of the
    /// block as soon as its group is switched off under "Live" — it stays in the
    /// store, fills one of the six places and can no longer be deselected.
    private var selectedRows: [ColumnChoice<AnyView>.Row] {
        preferences.liveChannel.enumerated().map { slot, name in
            guard let channel = channels.first(where: { $0.channelName == name }) else {
                return .init(
                    id: name, name: name,
                    secondaryLine: AppLanguageSetting.text("settings.homeHiddenGroup"))
            }
            // **From the seventh on, a note appears.** Six are effective; a selection that
            // does nothing and says nothing is the worst way to respond.
            let extras =
                slot < LiveShelf.atMost
                ? "\(slot + 1)" : AppLanguageSetting.text("settings.homeFull")
            return .init(id: name, name: channel.cleanName, secondaryLine: extras)
        }
    }

    /// What the group and the search term leave over — **before** the cap.
    private var filtered: [Channel] {
        channels
            .filter { !preferences.selectsChannel($0.channelName) }
            .filter {
                openGroup == nil || openGroup == Self.allGroups
                    || $0.group == openGroup
            }
            .filter { filter.letsPass(rawName: $0.name, key: $0.searchKey) }
    }

    /// The letters that the index offers — **from the open group and not from
    /// everything.**
    ///
    /// Anyone who has opened "Sport" searches there; an index over all 7,746 channels offered
    /// letters under which nothing exists in this group — and that is the same
    /// futile press that the rule "only occupied letters" is meant to prevent.
    ///
    /// **The own selection is also counted out**, as in ``filtered``: a letter whose
    /// only channel is already selected would lead to an empty right column.
    private var indexLetters: [String] {
        ChannelIndex.letters(
            channels
                .filter { !preferences.selectsChannel($0.channelName) }
                .filter {
                    openGroup == nil || openGroup == Self.allGroups
                        || $0.group == openGroup
                }
                .map(\.name))
    }

    /// **One row per name**, because the selection remembers a name (decision 21): the same
    /// channel appears at the provider in several groups and versions, and two rows that
    /// both toggle the same selection would look like two channels.
    private var remainingRows: [ColumnChoice<AnyView>.Row] {
        var seen = Set<String>()
        var rows: [ColumnChoice<AnyView>.Row] = []
        for channel in filtered where rows.count < Self.atMost {
            guard seen.insert(channel.channelName).inserted else { continue }
            rows.append(.init(id: channel.channelName, name: channel.cleanName))
        }
        return rows
    }

    /// - Parameter name: The channel name — it is the identifier of the row.
    private func select(_ name: String) {
        preferences.selectChannel(name, on: !preferences.selectsChannel(name))
        preferences.save(to: FileStore(), forItem: ProfilePointer.active)
    }
}

// MARK: - The way back

extension View {

    /// **The menu button goes back one level instead of jumping to the section list.**
    ///
    /// ``SettingsView`` intercepts the button and puts the focus in the list on the left — that
    /// is right as long as a section has **one** level. The two shelf pickers are
    /// a second one; without this row a press would leave the picker and the settings
    /// at the same time, and the way back into the picker would be two presses long.
    ///
    /// **Attached unconditionally, the decision is made in the body** — the same house rule as
    /// for `.disabled`: a modifier that is sometimes there and sometimes not changes the
    /// view identity and with it the focus.
    func backWithMenu(_ action: @escaping () -> Void) -> some View {
        onExitCommand(perform: action)
    }
}

// MARK: - Shelves from the provider catalog

/// **Which categories of the provider get a shelf** — the prefix on the left, the
/// categories on the right.
///
/// **The finding of 2026-09-13:** on VOD only 2 items are now shown, but both
/// items appear to be series. One number decides **how many**; which ones they
/// become was decided by the provider's order — and there the series sections
/// come first. Two series shelves, no film shelf.
///
/// **The prefix on the left and not the kind.** The categories are called "TR| PAZARTESI DIZILERI"
/// and "DE| KINO"; the provider orders by country, not by film and series. An
/// organisation by "films/series" would have to be guessed from the name, and guessing is the
/// mistake this project has already made twice.
///
/// **Nothing is sorted here.** The selected categories appear as rows under
/// "Rows on the Home screen" and are moved there like any other shelf — a
/// second order would drift apart from that one.
struct ProviderShelfChoice: View {

    let categories: [Core.Library]

    @State private var preferences = ShelfPreferences()
    @State private var openPrefix: String?
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    var body: some View {
        ColumnChoice(
            sources: prefixColumn,
            openSource: $openPrefix,
            selected: selectedRows,
            other: remainingRows,
            select: { select($0.id) },
            focus: $focus
        ) {
            AnyView(
                SettingsHeader(
                    "settings.section.homeCategories", hint: "settings.homeCategoriesHint"))
        }
        .preference(
            key: SettingsFirstEntryKey.self,
            value: ColumnChoice<AnyView>.firstTarget(prefixColumn)
        )
        .onChange(of: entryRequest) { _, _ in
            focus = ColumnChoice<AnyView>.firstTarget(prefixColumn)
        }
        .task {
            preferences = ShelfPreferences.load(from: FileStore(), forItem: ProfilePointer.active)
            if openPrefix == nil { openPrefix = prefixColumn.first?.id }
        }
    }

    /// The prefixes — "TR|", "DE|" — with their count.
    ///
    /// **Without a prefix the category appears under "All".** A provider that has none
    /// would otherwise get an empty left column.
    private var prefixColumn: [ColumnChoice<AnyView>.Row] {
        var number: [String: Int] = [:]
        for category in categories { number[prefix(category.name), default: 0] += 1 }
        let all = AppLanguageSetting.text("settings.homeAllGroups")
        return [
            .init(id: Self.allPrefixes, name: all, secondaryLine: "\(categories.count)")
        ]
            + number.keys.sorted().map {
                .init(id: $0, name: $0, secondaryLine: "\(number[$0] ?? 0)")
            }
    }

    private static let allPrefixes = "\u{001F}alle"

    /// The prefix of a name — everything before the vertical bar.
    private func prefix(_ name: String) -> String {
        guard let pipe = name.firstIndex(of: "|") else {
            return AppLanguageSetting.text("settings.homeAllGroups")
        }
        return String(name[..<pipe]).trimmingCharacters(in: .whitespaces)
    }

    /// The selection — **also a category that the provider is not currently reporting.**
    private var selectedRows: [ColumnChoice<AnyView>.Row] {
        preferences.providerCategories.map { identifier in
            .init(
                id: identifier,
                name: categories.first { $0.id == identifier }?.name ?? identifier)
        }
    }

    private var remainingRows: [ColumnChoice<AnyView>.Row] {
        categories
            .filter { !preferences.selectsCategory($0.id) }
            .filter {
                openPrefix == nil || openPrefix == Self.allPrefixes
                    || prefix($0.name) == openPrefix
            }
            .map { .init(id: $0.id, name: $0.name, secondaryLine: $0.itemCount.map { "\($0)" }) }
    }

    private func select(_ identifier: String) {
        preferences.selectCategory(identifier, on: !preferences.selectsCategory(identifier))
        preferences.save(to: FileStore(), forItem: ProfilePointer.active)
    }
}
