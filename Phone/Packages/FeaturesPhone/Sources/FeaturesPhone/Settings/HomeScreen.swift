import Core
import DesignSystemPhone
import Flows
import Observation
import PlaylistKit
import SwiftUI

/// `Presentation → Startseite` — **Order shelves, hide them, and who appears big at the top.**
///
/// **The screen that did not exist until 2026-09-06** `Presentation` carried a row
/// "Order shelves"; it pointed to ``ViewID/arrangeShelves``, and the wrapper had
/// no branch for it — the path ended in the placeholder. That made Home the only
/// screen in the app where nobody could change anything.
///
/// **On the TV this has long existed** (`HomePreferences.allows(_:)`), and the same question
/// is asked here against the same ``CatalogState`` — which is why Home and Settings are
/// not two truths.
///
/// **Four sections, because there are four questions:** in which order the shelves
/// stand, which of them fill the header area, which channels appear in "Live today",
/// and which folders the portal shelves draw from.
///
/// **The last two appear only if they exist.** A section "which portal folder"
/// without a configured bridge would be a question about something that does not exist
/// — the same rule as for the tabs: **gone instead of greyed out.**
///
/// **And both were unusable on the device** (findings of 2026-09-07). "From the portals" was
/// a flat list of end points — you could not reach "Popular series → Most watched
/// right now" because there was no forward navigation; it has become a folder browser.
/// "Live today" put two thousand channels in one column, and the four chosen ones got
/// lost in it; now they stand at the top, and the rest collapses.
public struct HomeScreen: View {

    @State private var model: HomeViewModel

    public init(
        state: CatalogState, catalogSource: (any CatalogSource)? = nil,
        channelSource: (any ChannelListingSource)? = nil,
        portalDataSource: (any PortalContentSource)? = nil, catalog: XtreamCatalogSource? = nil
    ) {
        _model = State(
            initialValue: HomeViewModel(
                state: state, catalogSource: catalogSource, channelSource: channelSource,
                portalDataSource: portalDataSource, catalog: catalog))
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            // **The portals stand above "Live today", since 2026-09-07** Two thousand
            // channels are the longest section of this screen, even collapsed; anyone looking for
            // the portals below it did not find them on the device. The long
            // section belongs at the end, not in the middle.
            List {
                shelves
                heroes
                if model.showsCatalogChoice { catalog }
                if model.showsPortalChoice { portals }
                if model.showsChannelChoice { channels }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ColorRole.reason.color)
            // **The handles are always shown.** On a screen you open *in order*
            // to reorder, an "Edit" button would be one step too many. On the
            // Mac only the checks run, and `editMode` does not exist there.
            .alwaysSort()
        }
        .task { await model.load() }
    }

    // MARK: - The shelves

    /// **Dragging orders, the switch hides** — two actions on one row.
    ///
    /// `editMode` is permanently `.active` so that the handles are there without an
    /// "Edit" button: on a screen you open **in order** to reorder, a button that
    /// first unlocks reordering is one step too many.
    @ViewBuilder
    private var shelves: some View {
        Section {
            ForEach(model.shelves) { shelf in
                row(shelf)
            }
            .onMove { from, destination in model.move(from: from, after: destination) }
        } header: {
            header("settings.home.shelves", "settings.home.shelves.hint")
        }
    }

    private func row(_ shelf: Shelf) -> some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Text(verbatim: model.labeled(shelf))
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer(minLength: Metrics.targetSpacing)
            if shelf.id == StartPreferences.immovable {
                // **No switch where there is nothing to switch.** "Continue Watching"
                // stays put (decision 1), and a switch that does not give way
                // would be a button without effect.
                Text(app: "settings.home.fixed")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            } else {
                Toggle(
                    "",
                    isOn: .init(
                        get: { model.preferences.shows(shelf.id) },
                        set: { model.show(shelf.id, $0) })
                )
                .labelsHidden()
                .tint(ColorRole.tag.color)
            }
        }
        .listRowBackground(ColorRole.reason.color)
        .moveDisabled(shelf.id == StartPreferences.immovable)
    }

    // MARK: - The header area

    @ViewBuilder
    private var heroes: some View {
        Section {
            ForEach(model.heroShelves) { shelf in
                HStack(spacing: MetricsBoard.phone.gutter) {
                    Text(verbatim: model.labeled(shelf))
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    Spacer(minLength: Metrics.targetSpacing)
                    Toggle(
                        "",
                        isOn: .init(
                            get: { model.preferences.fillsHeroes(shelf.id) },
                            set: { model.fillHeroes(shelf.id, $0) })
                    )
                    .labelsHidden()
                    .tint(ColorRole.tag.color)
                }
                .listRowBackground(ColorRole.reason.color)
            }
            .moveDisabled(true)
        } header: {
            header("settings.home.hero", "settings.home.hero.hint")
        }
    }

    // MARK: - From the provider catalog

    /// **Which of the provider's categories get a shelf** — as on the TV
    /// (decision 27, C2): first the number, then on request the categories themselves.
    ///
    /// Both live in the same `shelves.json` as on the TV (``Core/ShelfOrder``); the
    /// order of the category shelves is set above with the shelves, not here.
    @ViewBuilder
    private var catalog: some View {
        Section {
            Picker(
                selection: .init(
                    get: { model.shelvesPerProvider }, set: { model.set(shelvesPerProvider: $0) }
                )
            ) {
                ForEach(ShelfPreferences.providerLevels, id: \.self) { tier in
                    Text(verbatim: "\(tier)").tag(tier)
                }
            } label: {
                Text(app: "settings.homeVodShelves")
            }
            .pickerStyle(.segmented)
            .disabled(!model.selectedCategories.isEmpty)
            .listRowBackground(ColorRole.reason.color)

            if model.catalogLoading {
                LoadingState(message: "settings.home.catalog.loading")
                    .listRowBackground(ColorRole.reason.color)
            } else if !model.categories.isEmpty {
                SearchField(text: $model.categorySearchTerm, placeholder: "library.findCategory")
                    .listRowBackground(ColorRole.reason.color)
                ForEach(model.shownCategories) { category in
                    ChoiceRow(
                        name: category.category.name, icon: category.catalog.kind.icon,
                        subRow: model.subRow(category),
                        chosen: model.selectedCategories.contains(category.id)
                    ) {
                        model.setEnabled(category: category.id)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(ColorRole.reason.color)
                }
            }
        } header: {
            header("settings.section.homeCategories", "settings.home.catalog.hint")
        }
        .moveDisabled(true)
    }

    // MARK: - Live today

    /// Which channels stand in the "Live today" shelf.
    ///
    /// **Without a choice of its own, the most recently watched channels stand there** — the
    /// product requirement of 2026-09-06: if no selection has been made under Appearance,
    /// the default is the last three channels that carry a programme. The
    /// list for that has lived in the ``ChannelHistory`` since the Live package; so only
    /// the **deviation** from it is stored here.
    ///
    /// **What is chosen at the top, the rest collapsed** — the finding of 2026-09-07: "Live today"
    /// should let the unselected items be hidden so the display does not become
    /// endless. The access leads through two thousand channels; if they all stood
    /// in one column, the four chosen ones got lost in it, and you scrolled past your
    /// own selection to find them.
    ///
    /// **The search field stands above everything and applies to everything.** Whoever searches, searches the whole
    /// catalog and not just the collapsed part — otherwise the flap would be a lock instead of a
    /// tidying aid.
    @ViewBuilder
    private var channels: some View {
        Section {
            if model.channelsLoading {
                LoadingState(message: "live.loading")
                    .listRowBackground(ColorRole.reason.color)
            } else {
                SearchField(text: $model.searchTerm, placeholder: "live.searchPrompt")
                    .listRowBackground(ColorRole.reason.color)

                if !model.selectedChannels.isEmpty {
                    SectionHeader(title: "settings.home.live.chosen")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(ColorRole.reason.color)
                }
                ForEach(model.selectedChannels) { channelRow($0) }

                if !model.isSearching { channelDisclosure }
                ForEach(model.remainingChannels) { channelRow($0) }
            }
        } header: {
            header("settings.home.live", "settings.homeLiveChannelsHint")
        }
        .moveDisabled(true)
    }

    private func channelRow(_ entry: HomeViewModel.ChannelRowContent) -> some View {
        ChoiceRow(
            name: entry.name, icon: Glyph.Tab.live.outlined,
            subRow: entry.group, chosen: entry.chosen
        ) {
            model.setEnabled(channels: entry.name)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(ColorRole.reason.color)
    }

    /// The handle on the remaining channels — **with the number it hides.**
    ///
    /// **Without the number, collapsed would look like empty.** "2.043 channels" says that behind the
    /// chevron lies a catalog and not a fault; the same information that
    /// ``SummaryRow`` gives in the group choice.
    ///
    /// **It is also there when nothing is chosen.** Then it is open, and the number is
    /// the information on how far the list reaches — only the first
    /// forty are shown (``HomeViewModel/maxRows``).
    private var channelDisclosure: some View {
        Button {
            withAnimation(Motion.expand) { model.channelListOpen.toggle() }
        } label: {
            HStack(spacing: Metrics.targetSpacing) {
                Text(verbatim: model.channelCount)
                    .font(TypeLevel.lowercased.font)
                    .monospacedDigit()
                    .foregroundStyle(ColorRole.textQuiet.color)
                Spacer(minLength: 0)
                Image(systemName: Glyph.down.name)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .rotationEffect(.degrees(model.channelListOpen ? 0 : -90))
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .frame(minHeight: Metrics.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(ColorRole.reason.color)
        .accessibilityLabel(Text(app: "settings.home.live.all"))
        .accessibilityValue(Text(verbatim: model.channelCount))
    }

    // MARK: - From the portals

    /// Which folders the portal shelves draw from — **a folder browser, not a list.**
    ///
    /// **One checkmark per portal since 2026-09-07** (can I also choose several items,
    /// one from each portal?). Until then the choice was **exclusive** across all portals:
    /// whoever took Animehub lost Serieshub, without anything saying
    /// why the checkmark disappeared. Now a choice replaces only the one of the same
    /// portal, and the root list writes on every group heading what is already
    /// chosen there.
    ///
    /// **Without a choice of its own it stays with the automatic one** — the most recently used portal
    /// and in it the recommended entry point (``FromPortals``). So, as
    /// with the channels, only the **deviation** from it is stored here; a second press on the same
    /// folder takes it back (``StartPreferences/set(portalFolders:under:atMost:)``).
    ///
    /// **The finding of 2026-09-07:** choosing content from, say, serieshub → popular series →
    /// most watched is not possible because forward navigation is not
    /// available here. What stood here was a flat list of the root folders of all portals, and
    /// every row was an **end point**: selectable, but not openable. Behind "Popular
    /// Series" lies another menu on Serieshub — the same observation on which
    /// ``FromPortals`` already failed once.
    ///
    /// **Two targets per row, and that is the whole difference.** The name chooses, the
    /// chevron opens. A row that only opened would take "Popular series" away as a choice;
    /// one that only chooses is the state from before.
    ///
    /// **Drawn with the same building blocks as the channel choice and with the behavior of
    /// ``PortalsView``:** a stack, a way back, the path as a breadcrumb. A second
    /// grammar for descending would be a second truth about the same tree.
    @ViewBuilder
    private var portals: some View {
        Section {
            if model.portalLoading {
                LoadingState(message: "portal.loading")
                    .listRowBackground(ColorRole.reason.color)
            } else {
                SearchField(
                    text: $model.portalSearchTerm, placeholder: "settings.home.portals.search"
                )
                .listRowBackground(ColorRole.reason.color)

                // **Whoever searches must know where.** A tester searched from the root on 2026-09-07
                // for "Most watched" and found nothing — the
                // folder lies two levels deeper, and what has not been fetched cannot be
                // found. A field that hides this looks like a
                // defect.
                if model.portalSearching {
                    Footnote(message: "settings.home.portals.scope")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(ColorRole.reason.color)
                }

                ForEach(model.portalGroups) { group in
                    if let name = group.headline {
                        portalDisclosure(group, name: name)
                    }
                    if model.isPortalGroupOpen(group) {
                        ForEach(group.folder) { portalRow($0) }
                    }
                }

                if let message = model.portalEmptyText {
                    Footnote(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(ColorRole.reason.color)
                }
            }
        } header: {
            portalHeader
        }
        .moveDisabled(true)
    }

    /// The heading of a portal — **and its expand button.**
    ///
    /// **The same pattern as ``channelDisclosure``**, and for the same reason: the number says
    /// how far the list reaches, and the chevron says whether it is shown. Two different
    /// flaps in one screen would be two controls for the same action.
    ///
    /// **Only while searching is the button missing.** Then everything is open (see
    /// ``HomeViewModel/isPortalGroupOpen(_:)``), and a chevron that does not turn
    /// would be a promise that breaks on the first press. **A portal with a choice of its own had
    /// no button until the evening of 2026-09-12 either — that was the bug:** whoever had chosen a
    /// shelf there got a portal that could never be collapsed again.
    @ViewBuilder
    private func portalDisclosure(_ group: HomeViewModel.PortalGroup, name: String) -> some View {
        let isPinnedOpen = model.portalSearching
        let pending = model.isPortalGroupOpen(group)
        Button {
            guard !isPinnedOpen else { return }
            withAnimation(Motion.expand) { model.togglePortal(group) }
        } label: {
            HStack(spacing: Metrics.targetSpacing) {
                SectionHeader(wording: name)
                Spacer(minLength: 0)
                Text(verbatim: "\(group.folder.count)")
                    .font(TypeLevel.lowercased.font)
                    .monospacedDigit()
                    .foregroundStyle(ColorRole.textQuiet.color)
                if !isPinnedOpen {
                    Image(systemName: Glyph.down.name)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .rotationEffect(.degrees(pending ? 0 : -90))
                }
            }
            .padding(.trailing, MetricsBoard.phone.margin)
            .frame(minHeight: Metrics.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(ColorRole.reason.color)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: "\(group.folder.count)"))
        .accessibilityAddTraits(isPinnedOpen ? [] : .isButton)
    }

    /// The heading of the section — **and, once you descend, the path within it.**
    ///
    /// **The way back belongs in the pinned heading and not in the first row.**
    /// Measured on the device (2026-09-07): as a row it lay below the heading that a `List`
    /// in the plain style pins to the top edge — it was visible only to someone who had scrolled
    /// to the right place beforehand. A way back you have to look for is none.
    ///
    /// **The explanatory sentence yields to the path.** Both stacked made the pinned
    /// heading four lines tall; and whoever is already descending knows what the section is for
    /// — then "Serieshub › Popular series" is the more useful line.
    @ViewBuilder
    private var portalHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(appKey: "common.fromPortals")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
            if model.portalLevel == nil {
                Text(appKey: "settings.home.portals.hint")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                portalRoute
            }
        }
        .textCase(nil)
        .padding(.top, MetricsBoard.phone.gutter)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets())
        .listRowBackground(ColorRole.reason.color)
    }

    /// Where you are, the way back — **and the choice of the level you are on.**
    ///
    /// **The path as a quiet line**, taken over from ``PortalsView``: with three levels
    /// the title alone no longer says where you are — "Action" exists under "Series" and under
    /// "Movies".
    ///
    /// **That the line is also selectable saves the way back.** Whoever is in "Popular series"
    /// and wants to take exactly that would otherwise have to go one level back first to make the same
    /// choice on the same identifier.
    ///
    /// **It is not shown on the root.** A way back that leads nowhere claims
    /// a place — the same reasoning as in the Portals tab.
    @ViewBuilder
    private var portalRoute: some View {
        if let pending = model.openLevel {
            HStack(spacing: 0) {
                Button {
                    model.backInPortal()
                } label: {
                    Image(systemName: Glyph.back.name)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .frame(width: Metrics.target, height: Metrics.choiceRow)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(app: "common.back"))

                ChoiceRow(
                    name: pending.name, icon: Glyph.Tab.portals.outlined,
                    subRow: model.portalPath,
                    chosen: model.preferences.selects(portalFolders: pending.identifier)
                ) {
                    model.select(portalFolders: pending)
                }
            }
        }
    }

    /// A folder: **choose on the left, open on the right.**
    ///
    /// The chevron is the same as in ``FolderRow`` and says the same — "leads
    /// deeper". It is a target of its own and not decoration: 44 points wide so that the
    /// thumb does not hit the choice when it meant to open.
    ///
    /// **`.borderless` and not `.plain`, and the whole folder browser hung on that.** A
    /// `List` row forwards its press to the **first** button in it as soon as that one is
    /// in the plain style — no matter where you press. Measured on the device (2026-09-07): a
    /// press exactly on the chevron set the checkmark instead of going one level deeper.
    /// A tester described that as "forward navigation is not possible", and was
    /// right: the button was there, it just never got its turn.
    /// `.borderless` takes the button out of this forwarding — it is then a
    /// target of its own, and the row stays responsible for the choice.
    private func portalRow(_ entry: HomeViewModel.PortalFolderContent) -> some View {
        HStack(spacing: 0) {
            ChoiceRow(
                name: entry.name, icon: Glyph.Tab.portals.outlined,
                chosen: model.preferences.selects(portalFolders: entry.identifier)
            ) {
                model.select(portalFolders: entry)
            }

            Button {
                Task { await model.open(portalFolders: entry) }
            } label: {
                Image(systemName: Glyph.next.name)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .frame(width: Metrics.target, height: Metrics.choiceRow)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(app: "settings.home.portals.open"))
            .accessibilityValue(Text(verbatim: entry.name))
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(ColorRole.reason.color)
    }

    private func header(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(appKey: title)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
            Text(appKey: message)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textCase(nil)
        .padding(.top, MetricsBoard.phone.gutter)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets())
        .listRowBackground(ColorRole.reason.color)
    }
}

/// What the screen shows and what it stores.
///
/// **It is stored immediately and not on "Done".** Every other setting of this app
/// takes effect when toggled; a screen with a save button would be the only one, and whoever
/// overlooks it loses their work.
@MainActor
@Observable
public final class HomeViewModel {

    public private(set) var preferences: StartPreferences
    public private(set) var shelves: [Shelf]
    public private(set) var channelsLoading = false
    public var searchTerm = "" {
        didSet { if searchTerm != oldValue { sortChannels() } }
    }

    /// A channel to choose from.
    public struct ChannelRowContent: Sendable, Equatable, Identifiable {
        public let name: String
        public let group: String?
        public let chosen: Bool
        public var id: String { name }
    }

    /// What the viewer has chosen — **set apart from the rest and always visible.**
    public private(set) var selectedChannels: [ChannelRowContent] = []

    /// What it is supplemented from. **Empty as long as the access is collapsed.**
    public private(set) var remainingChannels: [ChannelRowContent] = []

    /// How many channels there are at all.
    ///
    /// **So that "collapsed" does not look like "empty".** A flap without a number claims
    /// nothing about what lies behind it.
    public private(set) var channelsTotal = 0

    /// Whether the access is open.
    ///
    /// **Closed as soon as something is chosen; open when nothing is chosen** (finding of 2026-09-07).
    /// Whoever has already chosen channels at most adds to them — the list is then a tool
    /// and not a catalog. Whoever has chosen none **must** be able to find something; putting
    /// a collapsed, empty area in front of them would be a dead end.
    public var channelListOpen = false {
        didSet { if channelListOpen != oldValue { sortChannels() } }
    }

    /// At most this many rows does the access show.
    ///
    /// **Capped, because a settings page is not a channel list.** Whoever is looking for a specific one
    /// types it; whoever browses is better off in the Live tab.
    static let maxRows = 40

    /// A portal folder to choose from.
    ///
    /// **The identifier carries portal and folder in one word** — it fetches the level and says
    /// at the same time which portal the choice belongs to. It is stored together with the
    /// name, because that appears nowhere else later: see ``StartPreferences/portalFolders``
    /// and ``StartPreferences/PortalChoice/name``.
    ///
    /// **The portal appears in the subtitle only on the root level.** There the folders
    /// of several services mix, and without the origin "New episodes" and "New
    /// episodes" would stand one above the other. One level deeper the path says where you are — the same
    /// information a second time in every row would be none.
    public struct PortalFolderContent: Sendable, Equatable, Identifiable {
        public let identifier: String
        public let name: String
        public let portal: String?

        /// The root identifier of the portal in which this folder lies.
        ///
        /// **It travels along so that "one per portal" needs no knowledge of the identifier
        /// form.** ``StartPreferences/set(portalFolders:under:atMost:)`` replaces
        /// the choice of the same portal and recognises it by the prefix; where the prefix comes from
        /// is known only to ``PortalContentSource/root(zu:)``. The row one level deeper no longer knows its
        /// portal by itself — it inherits it from the path on which you stand.
        public let root: String

        public var id: String { identifier }
    }

    /// The root folders of all ready portals — **the top level of the browser.**
    public private(set) var portalRoots: [PortalFolderContent] = []

    /// The path you are on. **Empty means: on the root.**
    ///
    /// The same stack as in ``PortalsModel``, and for the same reason: a portal is a
    /// tree and is walked through. Without a stack there is no way back — exactly the
    /// state that a tester saw on the device on 2026-09-07.
    public private(set) var portalStack: [PortalLayer] = []

    public private(set) var portalLoading = false

    /// The search term of the folder browser — it filters **the folders of the open level.**
    public var portalSearchTerm = ""

    /// Which portal the open level comes from — the first place in the path.
    ///
    /// The levels know their title but not their portal; on the root it stands in the
    /// subtitle, and when descending it moves into the breadcrumb.
    private var portalOrigin = ""

    /// The root identifier of the portal you have descended into. **Empty on the root.**
    ///
    /// The name in ``portalOrigin`` appears on screen, this identifier decides
    /// which choice is replaced — see ``PortalFolderContent/root``.
    private var portalRoot = ""

    /// The state the shelves are built from — **first that of the accesses, then the real one.**
    ///
    /// Until 2026-09-27 it stayed with the placeholders from
    /// ``CatalogState/fromAccesses(jellyfin:channelList:portals:downloads:provider:)``
    /// (check finding A-S2): the real library shelves (movies, series, home videos …)
    /// never appeared here, only a placeholder could be ordered and hidden, whose
    /// identifier never occurs on Home, and the header-area choice got only
    /// placeholders. Now the real state from the ``catalogSource`` is added (``load()``).
    private var state: CatalogState
    /// Where the real catalogs come from — the same source as the library.
    private let catalogSource: (any CatalogSource)?
    private var realStateLoaded = false
    /// The genre per catalog of the shelves currently shown — for ``heroShelves``.
    private var genres: [Catalog.Identifier: Genre] = [:]
    private let channelSource: (any ChannelListingSource)?
    private let portalDataSource: (any PortalContentSource)?

    /// The provider catalog — **for the category shelves** (decision 27, C2).
    private let catalog: XtreamCatalogSource?

    /// All categories of all accesses, once loaded.
    public private(set) var categories: [ProviderCategory] = []
    public private(set) var catalogLoading = false
    /// This many categories get a shelf without a choice of their own.
    public private(set) var shelvesPerProvider: Int
    /// The chosen categories — empty means "the first ``shelvesPerProvider``".
    public private(set) var selectedCategories: [String]
    public var categorySearchTerm = ""
    private let store: any KeyValueStore

    /// Where the shelf order comes from — **a second store, and with reason.**
    ///
    /// Since AP40 (2026-09-21) it lives as a file; the visibility of the channel groups
    /// (``LivePreferences``) still lives in the Keychain. Fetching both from one hand
    /// would mean taking the groups along silently — and with ninety-six
    /// of them that is the most expensive loss this app has to offer.
    private let shelfStore: any KeyValueStore
    private var allChannels: [ChannelBundle] = []

    public init(
        state: CatalogState, catalogSource: (any CatalogSource)? = nil,
        channelSource: (any ChannelListingSource)? = nil,
        portalDataSource: (any PortalContentSource)? = nil,
        catalog: XtreamCatalogSource? = nil,
        store: (any KeyValueStore)? = nil,
        shelfStore: (any KeyValueStore)? = nil
    ) {
        self.state = state
        self.catalogSource = catalogSource
        self.channelSource = channelSource
        self.portalDataSource = portalDataSource
        self.catalog = catalog
        self.store = store ?? SecureStore()
        self.shelfStore = shelfStore ?? FileStore()
        let loaded = StartPreferences.load(from: self.shelfStore, forItem: ProfilePointer.active)
        self.preferences = loaded
        let choice = ProviderCategory.choice(from: self.shelfStore)
        self.shelvesPerProvider = choice.perProvider
        self.selectedCategories = choice.chosen
        // **All shelves, including the hidden ones.** A screen for showing again that
        // does not show what is hidden is a one-way street.
        self.shelves = Self.shelves(forItem: state.catalogs, order: loaded.order)
        self.genres = Self.genres(state.catalogs)
        self.channelListOpen = loaded.liveChannel.isEmpty
    }

    /// The shelves of a state, ordered — **each identifier once.** A view with two
    /// identical identifiers moves the wrong one, and an order with a duplicate was a crash
    /// until 2026-09-27 (check finding A-S2).
    static func shelves(forItem catalogs: [Catalog], order: [Shelf.Identifier]) -> [Shelf] {
        var seen = Set<Shelf.Identifier>()
        return StartPreferences(order: order)
            .arrange(ShelfPlan.shelves(forItem: CatalogState(catalogs)))
            .filter { seen.insert($0.id).inserted }
    }

    static func genres(_ catalogs: [Catalog]) -> [Catalog.Identifier: Genre] {
        Dictionary(catalogs.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    /// The shelves that can fill the header area — **only the per-catalog ones.**
    ///
    /// "Continue Watching" and "Live today" do not fill it: since 2026-09-06 the box shows
    /// what is new, and a channel has no background image with a blurb.
    ///
    /// **And only movie and series shelves** (check finding A-S3): a mixed library does not fill
    /// the header on any device (``Flows/HomeLayout/fillsHeader(_:)``), so it is not
    /// offered for choice here either.
    public var heroShelves: [Shelf] {
        shelves.filter { shelf in
            shelf.target.map { HomeLayout.fillsHeader(genres[$0]?.libraryKind) } ?? false
        }
    }

    public var showsChannelChoice: Bool { state.hasKey(.channelList) }

    public var showsPortalChoice: Bool { state.hasKey(.portals) }

    /// **A key is translated, a wording stands as the server
    /// reports it.** The same rule as in ``StartView``: "Heimvideos und -bilder" is called that
    /// because someone named it that.
    public func labeled(_ shelf: Shelf) -> String {
        switch shelf.label {
        case .key(let name): AppLanguageSetting.text(.init(name))
        case .wording(let name): name
        }
    }

    public func load() async {
        await loadCatalogs()
        await loadCatalog()
        await loadChannels()
        await loadPortalFolders()
    }

    // MARK: - The provider catalog

    public var showsCatalogChoice: Bool { catalog != nil && state.hasKey(.provider) }

    /// The categories that the search field lets through — **the chosen ones always first.**
    public var shownCategories: [ProviderCategory] {
        let term = categorySearchTerm.trimmingCharacters(in: .whitespaces)
        let chosen = Set(selectedCategories)
        let matching =
            term.isEmpty
            ? categories : categories.filter { $0.category.name.localizedCaseInsensitiveContains(term) }
        return matching.filter { chosen.contains($0.id) }
            + matching.filter { !chosen.contains($0.id) }.prefix(Self.maxRows)
    }

    /// Access and kind — "My provider · Movies".
    public func subRow(_ category: ProviderCategory) -> String {
        [category.catalog.group.map(labeled), labeled(category.catalog.label)]
            .compactMap { $0 }.joined(separator: DelimiterChars.point)
    }

    private func labeled(_ label: CaptionLabel) -> String {
        switch label {
        case .key(let name): AppLanguageSetting.text(.init(name))
        case .wording(let name): name
        }
    }

    /// Fetches the real catalogs — **once**, and a failure leaves the state as it was.
    private func loadCatalogs() async {
        guard let catalogSource, !realStateLoaded,
            let real = try? await catalogSource.state()
        else { return }
        realStateLoaded = true
        state = CatalogState(state.catalogs + real.catalogs)
        buildShelves()
    }

    private func loadCatalog() async {
        guard let catalog, showsCatalogChoice, categories.isEmpty else { return }
        catalogLoading = true
        defer { catalogLoading = false }
        categories = (try? await ProviderCategory.all(from: catalog)) ?? []
        buildShelves()
    }

    /// The shelves rebuilt from the state — **with the category shelves instead of the register catalogs**,
    /// once the categories are loaded. The same calculation as ``XtreamStartSource``, so that
    /// the same shelves stand here as on Home.
    private func buildShelves() {
        var catalogs = state.catalogs
        if !categories.isEmpty {
            catalogs.removeAll { $0.origin == .provider }
            catalogs += ProviderCategory.chosen(
                categories, perProvider: shelvesPerProvider, chosen: selectedCategories
            ).map { $0.shelfCatalog() }
        }
        shelves = Self.shelves(forItem: catalogs, order: preferences.order)
        genres = Self.genres(catalogs)
    }

    public func set(shelvesPerProvider number: Int) {
        shelvesPerProvider = number
        saveCatalog()
    }

    /// Choose or deselect a category — **the rule of ``Core/ShelfPreferences``.**
    public func setEnabled(category identifier: String) {
        var choice = ShelfPreferences(providerCategories: selectedCategories)
        choice.selectCategory(identifier, on: !choice.selectsCategory(identifier))
        selectedCategories = choice.providerCategories
        saveCatalog()
    }

    /// **Only the two fields of the catalog** — the others of the shared store stay as
    /// they are.
    private func saveCatalog() {
        var order = ShelfOrder.read(from: shelfStore, forItem: ProfilePointer.active)
        order.shelvesPerProvider =
            shelvesPerProvider == ShelfPreferences.shelvesPerProviderDefault ? nil : shelvesPerProvider
        order.providerCategories = selectedCategories
        order.write(in: shelfStore, forItem: ProfilePointer.active)
        buildShelves()
    }

    private func loadChannels() async {
        guard let channelSource, showsChannelChoice, allChannels.isEmpty else { return }
        channelsLoading = true
        defer { channelsLoading = false }
        let catalog = await channelSource.channels()
        let isVisible = LivePreferences.load(from: store).isVisible(catalog.channels)
        allChannels = ChannelBundle.fold(isVisible)
        sortChannels()
    }

    /// The root folders the browser starts with.
    ///
    /// **Only ready portals.** One that currently demands a login can deliver
    /// nothing today — offering it for choice would be a promise that Home
    /// does not keep.
    ///
    /// **Still the roots of all portals in one list.** It is the entry point and
    /// no longer the whole: since 2026-09-07 every one of these rows can be opened
    /// (``open(portalFolders:)``), and the path then begins at the name of the portal.
    ///
    /// **In the same order in which Home tries** (``FromPortals``):
    /// what the shelf would take by itself stands at the top — then you see what you are changing.
    private func loadPortalFolders() async {
        guard let portalDataSource, showsPortalChoice, portalRoots.isEmpty else { return }
        portalLoading = true
        defer { portalLoading = false }
        guard let portals = try? await portalDataSource.portals() else { return }

        var found: [PortalFolderContent] = []
        for portal in portals where portal.state.isReady {
            guard
                let rootLevel = try? await portalDataSource.level(
                    zu: portalDataSource.root(zu: portal.id), title: portal.name)
            else { continue }
            let rootIdentifier = portalDataSource.root(zu: portal.id)
            found += FromPortals.entries(from: rootLevel.entries).compactMap { door in
                door.leadsDeeper.map {
                    PortalFolderContent(
                        identifier: $0, name: door.title, portal: portal.name,
                        root: rootIdentifier)
                }
            }
        }
        portalRoots = found
    }

    // MARK: - The folder browser

    /// The level that is currently open. `nil` means: **the root.**
    public var portalLevel: PortalLayer? { portalStack.last }

    /// The same level as a choice row — **so that the path chooses the same as a folder row.**
    ///
    /// Without it the choice would stand in two forms in two places: the row with identifier,
    /// name and root, the breadcrumb with a bare identifier. Two forms of the same
    /// handle are two opportunities to answer "one per portal" differently.
    public var openLevel: PortalFolderContent? {
        portalLevel.map {
            PortalFolderContent(
                identifier: $0.identifier, name: $0.title, portal: nil, root: portalRoot)
        }
    }

    /// The path as a line — "Serieshub › Popular series › Most watched right now".
    ///
    /// Built like ``PortalsModel/path``, only with the portal name in front: the browser starts
    /// here with the folders of **several** services, and without the name the path would begin
    /// in the middle of a catalog whose owner you no longer know.
    public var portalPath: String {
        ([portalOrigin] + portalStack.map(\.title))
            .filter { !$0.isEmpty }
            .joined(separator: " › ")
    }

    /// The folders currently up for choice — **filtered, but never re-sorted.**
    ///
    /// **Only doors.** A title is not a level and has no identifier that
    /// ``StartPreferences/portalFolders`` could take; a separator is a
    /// subheading and cannot be opened. Showing either here would mean offering
    /// rows that lead nowhere.
    public var portalFolderRows: [PortalFolderContent] {
        let allEntries: [PortalFolderContent]
        if let pending = portalLevel {
            allEntries = pending.entries.compactMap { entry -> PortalFolderContent? in
                guard !entry.isSeparator, let deeper = entry.leadsDeeper else { return nil }
                return PortalFolderContent(
                    identifier: deeper, name: entry.title, portal: nil, root: portalRoot)
            }
        } else {
            allEntries = portalRoots
        }
        let term = portalSearchTerm.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return allEntries }
        return allEntries.filter { $0.name.lowercased().contains(term) }
    }

    /// Whether the folder browser is currently being searched.
    public var portalSearching: Bool {
        !portalSearchTerm.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The folders of a level, grouped by portal.
    ///
    /// **Only the root has groups**, and there they are needed: twenty-five
    /// rows from three services stand there one above the other, and **"Popular series" occurs
    /// twice** — once at Animehub, once at Serieshub. Without a heading
    /// you choose the wrong one and never notice. One level deeper the path says where you are;
    /// there a heading per row is only noise.
    public struct PortalGroup: Sendable, Equatable, Identifiable {
        public let portal: String?
        public let folder: [PortalFolderContent]

        /// What is already chosen in this portal — `nil` if nothing.
        ///
        /// **The information without which "one checkmark per portal" would be invisible** (2026-09-07). The
        /// checkmark on a row says something only about the 25 rows currently shown;
        /// a choice two levels deeper — "Popular series › Most watched right now" — does
        /// **not appear at all** in the root list. Without this line Serieshub would look there
        /// like a portal without a choice, and the next press would silently replace a choice
        /// that nobody knew about.
        public let choice: String?

        public var id: String { portal ?? "" }

        /// The heading as it stands — "SERIESHUB · MEISTGESEHEN GERADE".
        ///
        /// **Composed and not two lines.** ``SectionHeader`` carries one text;
        /// a second line below would turn every group heading into a block and
        /// the list into a staircase.
        public var headline: String? {
            guard let portal else { return nil }
            guard let choice else { return portal }
            return portal + DelimiterChars.point + choice
        }
    }

    /// Which portals are expanded.
    ///
    /// **The finding of 2026-09-12, from the client:** can the portals themselves be made
    /// expandable here? Then you do not have to scroll forever. Ten portals with
    /// eight to twelve folders each are around a hundred rows in a list in which you look for a
    /// single folder.
    ///
    /// **Only what was set by hand is stored here** — not what is open. A
    /// missing entry means "not yet decided", and then the default applies
    /// (``isPortalGroupOpen(_:)``). An allow list would be wrong here: if a
    /// portal is added, it should not be silently expanded just because nobody
    /// collapsed it.
    ///
    /// **A set of truth values instead of a set of members, and because of a finding of the evening of
    /// 2026-09-12:** "once expanded they cannot be collapsed again".
    /// A set knows only "in" and "not in" — so the default ("whoever has a
    /// choice stands open") could not be overridden, and the portal in which a
    /// shelf had just been chosen lacked the button. Three states are one more than
    /// seems necessary, and exactly the one that was missing here.
    public var portalToggles: [String: Bool] = [:]

    /// Whether the folders of this portal are shown.
    ///
    /// **Whoever searches sees everything.** A search that hides its hits behind a collapsed
    /// heading is broken — and exactly this case was already noticed on 2026-09-07
    /// once (most watched, searched from the root, and nothing
    /// found).
    ///
    /// **And the portal with its own choice stands open — but only as a default.** Otherwise
    /// the first impression would be a list of ten closed rows in which your own
    /// setting does not appear; the information that ``PortalGroup/choice`` was built
    /// for would fall behind the flap. **Whoever collapses it afterwards collapses it:** a
    /// default that cannot be overridden is not a default but a latch — and
    /// as such it was noticed on the device on 2026-09-12.
    public func isPortalGroupOpen(_ group: PortalGroup) -> Bool {
        guard let portal = group.portal else { return true }
        if portalSearching { return true }
        if let decided = portalToggles[portal] { return decided }
        return group.choice != nil
    }

    /// Toggle the flap of this group.
    ///
    /// **The group and not just its name**, because the opposite of expanding can only be
    /// determined if the default is known — and that depends on
    /// ``PortalGroup/choice``.
    public func togglePortal(_ group: PortalGroup) {
        guard let portal = group.portal else { return }
        portalToggles[portal] = !isPortalGroupOpen(group)
    }

    public var portalGroups: [PortalGroup] {
        let rows = portalFolderRows
        guard rows.contains(where: { $0.portal != nil }) else {
            return rows.isEmpty ? [] : [PortalGroup(portal: nil, folder: rows, choice: nil)]
        }
        var order: [String] = []
        var byName: [String: [PortalFolderContent]] = [:]
        for row in rows {
            let name = row.portal ?? ""
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(row)
        }
        return order.map { name in
            let folder = byName[name] ?? []
            return PortalGroup(portal: name, folder: folder, choice: choice(in: folder))
        }
    }

    /// The name of the chosen folder of this portal — recognised by the prefix of its root.
    ///
    /// **The name comes from the preferences and not from the list**, because in
    /// the case for which this information exists it is precisely not there: a choice from a deeper
    /// level is not contained in the root list. An entry from the time before
    /// 2026-09-07 carries no name (``StartPreferences/PortalChoice/name``) — then the
    /// heading stands alone as before.
    private func choice(in folder: [PortalFolderContent]) -> String? {
        guard let root = folder.first?.root, !root.isEmpty else { return nil }
        let chosen = preferences.portalFolders.first { $0.identifier.hasPrefix(root) }
        return chosen.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Why the list is empty — **or `nil` if it is not.**
    ///
    /// Two reasons, two sentences. A level without folders is **not an error**: behind
    /// "Most watched right now" stand titles, and a folder that carries only titles is the
    /// goal of this search and not its failure. Whoever merely sees nothing considers
    /// the chevron broken.
    public var portalEmptyText: String? {
        guard portalFolderRows.isEmpty else { return nil }
        if portalSearching { return "settings.home.portals.none" }
        return portalLevel == nil ? nil : "settings.home.portals.leaf"
    }

    /// Open a folder — **one level deeper.**
    ///
    /// Modelled on ``PortalsModel/open(_:)``: the level is fetched and pushed onto the stack.
    /// **The search term does not stay** — it belonged to the list you have just
    /// left, and would otherwise silently filter the new one.
    ///
    /// **Failure means: nothing happens.** A portal that is currently not answering must not
    /// put the viewer in an empty level from which they have to press their way back.
    public func open(portalFolders folder: PortalFolderContent) async {
        guard let portalDataSource else { return }
        portalLoading = true
        defer { portalLoading = false }
        guard let level = try? await portalDataSource.level(zu: folder.identifier, title: folder.name)
        else { return }
        if portalStack.isEmpty {
            portalOrigin = folder.portal ?? ""
            portalRoot = folder.root
        }
        portalStack.append(level)
        portalSearchTerm = ""
    }

    /// One step back. On the root there is none.
    public func backInPortal() {
        guard !portalStack.isEmpty else { return }
        portalStack.removeLast()
        if portalStack.isEmpty {
            portalOrigin = ""
            portalRoot = ""
        }
        portalSearchTerm = ""
    }

    // MARK: - The channel list

    /// Whether a search is currently running.
    ///
    /// **Measured on the search key and not on the field.** `ChannelName.searchKey` throws away
    /// ornamental characters and whitespace; a field with a space in it would otherwise look like
    /// a search and filter nothing.
    public var isSearching: Bool { !ChannelName.searchKey(searchTerm).isEmpty }

    /// "2.043 channels" — the information at the flap.
    public var channelCount: String {
        SettingsModel.text("live.channelCount %lld", channelsTotal)
    }

    /// **Chosen ones first, then the rest** — otherwise you search for your own selection.
    ///
    /// **While searching, the whole catalog applies.** Whoever types wants to find what they do not
    /// have yet; the flap is a tidying aid and not a lock. The chosen ones then
    /// no longer stand set apart at the top, but among the hits, where they belong — with
    /// their checkmark.
    private func sortChannels() {
        channelsTotal = allChannels.count
        let chosen = Set(preferences.liveChannel)
        func row(_ bundles: ChannelBundle) -> ChannelRowContent {
            ChannelRowContent(
                name: bundles.name, group: bundles.group,
                chosen: chosen.contains(bundles.name))
        }

        let term = ChannelName.searchKey(searchTerm)
        guard term.isEmpty else {
            selectedChannels = []
            remainingChannels =
                allChannels
                .filter { $0.leader.searchKey.contains(term) }
                .prefix(Self.maxRows).map(row)
            return
        }

        selectedChannels = preferences.liveChannel
            .compactMap { name in allChannels.first { $0.name == name } }
            .map(row)
        remainingChannels =
            channelListOpen
            ? allChannels.filter { !chosen.contains($0.name) }
                .prefix(Self.maxRows).map(row)
            : []
    }

    // MARK: - Changing

    /// **The places of currently absent shelves stay put** (check finding A-S6) — the
    /// rule of both programs, ``Core/ShelfView/merge(order:using:)``.
    public func move(from: IndexSet, after destination: Int) {
        shelves.move(fromOffsets: from, toOffset: destination)
        preferences.set(
            order: ShelfView.merge(
                order: preferences.order.map(\.rawValue),
                using: shelves.map(\.id.rawValue)
            ).map(Shelf.Identifier.init(rawValue:)))
        save()
    }

    public func show(_ shelf: Shelf.Identifier, _ on: Bool) {
        // **All identifiers go along** — ``StartPreferences/show(_:_:from:)`` needs them
        // for the migration of a collective statement into individual statements. ``shelves`` also
        // carries the hidden ones (see ``load()``), and those are exactly the important ones here.
        preferences.show(shelf, on, from: shelves.map(\.id))
        save()
    }

    public func fillHeroes(_ shelf: Shelf.Identifier, _ on: Bool) {
        preferences.fillHeroes(shelf, on, from: heroShelves.map(\.id))
        save()
    }

    /// **At most six, the oldest yields** — the rule lives in
    /// ``Core/LiveShelfChoice/select(_:on:in:)`` and applies on the TV just the same.
    public func setEnabled(channels name: String) {
        let list = LiveShelfChoice.select(
            name, on: !preferences.liveChannel.contains(name), in: preferences.liveChannel)
        preferences.set(liveChannel: list)
        save()
        sortChannels()
    }

    /// **One per portal, at most three** — that many shelves result from it.
    ///
    /// A second press on the same folder takes the choice back and restores the automatic
    /// one for this portal; without this way back you could only pin down another
    /// folder, never none at all again. The same cycling logic as with the
    /// sort chips.
    ///
    /// **The limit lives at ``FromPortals/atMost`` and not here** — just as
    /// the channels fetch theirs from ``TodayLive/atMost``. A choice that gets no shelf
    /// would be a promise that Home does not keep; and where the number of
    /// shelves is decided, the number of choices must be decided too.
    public func select(portalFolders folder: PortalFolderContent) {
        preferences.set(
            portalFolders: .init(identifier: folder.identifier, name: folder.name),
            under: folder.root, atMost: FromPortals.atMost)
        save()
    }

    private func save() {
        preferences.save(to: shelfStore, forItem: ProfilePointer.active)
    }
}

extension View {

    /// Show the ordering handles of a `List` permanently.
    ///
    /// `editMode` exists only on iOS; on the Mac the checks run, and they
    /// check the content and not the gesture.
    @ViewBuilder
    func alwaysSort() -> some View {
        sortIf(true)
    }

    /// Ordering on demand — **for lists that have two modes of operation.**
    ///
    /// Home has four shelves and is opened to reorder; there an
    /// "Edit" button would be one step too many. Seventy-nine channel groups are the
    /// other case: there the normal case is **looking**, and the drag handle would take
    /// every row's space away (see ``GroupsView``).
    ///
    /// **The same platform switch in the same place.** `editMode` does not exist on macOS,
    /// and macOS is built here only so that `swift test` runs on the Mac.
    func sortIf(_ on: Bool) -> some View {
        #if os(iOS)
            environment(\.editMode, .constant(on ? .active : .inactive))
        #else
            self
        #endif
    }
}
