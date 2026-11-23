import Core
import DesignSystemPhone
import ParentalControls
import SwiftUI

/// Tab 2: the catalog you are currently in — and the choice to switch to another.
///
/// **The large title names the catalog, not the area.** "Movies", not "My
/// Library": Since there are six libraries, a collective name would have nothing to choose.
///
/// **The choice comes from below.** At the title it would lie between y = 152 and 480 and so
/// entirely above the thumb limit of 560 — that was the most embarrassing finding of the review.
public struct LibraryScreen: View {

    /// How often it was refreshed by hand — **only so that the haptics have a state.**
    /// A `Bool` flipped back on the second pull and reported nothing.
    @State private var refreshCount = 0

    @State private var model: LibraryViewModel
    @State private var isIndexOpen = false
    @State private var isCategoriesOpen = false

    private let account: String
    private let onAccountTap: () -> Void
    /// The way to the favorites — **`nil` if they sit at the bottom in the bar.**
    ///
    /// With a full setup the bar is full, and the favorites move to
    /// the top (``CatalogState/favoritesAtBottom``). Without this heart they would then be reachable
    /// from **nowhere** — the tab is missing precisely for that reason.
    private let onFavoritesTap: (() -> Void)?
    private let open: (TileContent) -> Void

    /// Where the long-press commands get their answer from — see ``TileCommands``.
    ///
    /// **The same source as the detail page**, for the same reason as on Home:
    /// It can `set(seen:)` and `set(favorite:)` and decides by identifier who
    /// is asked. The image widths are irrelevant there — the commands fetch no image.
    ///
    /// `nil` means **no menu**; the reasoning is at ``TitleGrid/commandSource``.
    private let commandSource: (any DetailSource)?
    /// How a title stands in the downloads — `nil` where no downloads are kept.
    private let downloadState: ((String) -> DownloadState?)?
    /// Opens the download sheet for a tile — `nil` as long as nobody can pull it up.
    private let load: ((TileContent) -> Void)?

    public init(
        source: (any CatalogSource)?,
        account: String = "?",
        onAccountTap: @escaping () -> Void = {},
        onFavoritesTap: (() -> Void)? = nil,
        open: @escaping (TileContent) -> Void = { _ in },
        commandSource: (any DetailSource)? = nil,
        downloadState: ((String) -> DownloadState?)? = nil,
        load: ((TileContent) -> Void)? = nil
    ) {
        _model = State(initialValue: LibraryViewModel(source: source))
        self.account = account
        self.onAccountTap = onAccountTap
        self.onFavoritesTap = onFavoritesTap
        self.open = open
        self.commandSource = commandSource
        self.downloadState = downloadState
        self.load = load
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HeaderRow(
                    account: account, onAccountTap: onAccountTap,
                    onFavoritesTap: onFavoritesTap
                )
                .padding(.bottom, 8)

                if let label = model.titleLine {
                    TitleChoice(title: labeled(label)) { isIndexOpen = true }
                }

                categoryRow

                // **The padding hangs on its content.** At the provider there are no
                // cut-outs (no server counts along there) — before, fourteen
                // points of nothing stood between category and grid, because padding on an
                // empty view still takes effect.
                if !model.availableSlices.isEmpty {
                    ExcerptRow(
                        possible: model.availableSlices, chosen: model.slice
                    ) { new in
                        model.select(slice: new)
                    }
                    .padding(.bottom, Metrics.targetSpacing)
                }

                content
            }
        }
        .safeAreaInset(edge: .bottom) { bar }
        .task { await model.load() }
        // **Pulling refreshes — it does not synchronize** (request of 2026-09-07). The
        // difference is deliberate: The button in the header throws **every**
        // cache of the app away and rebuilds all five tabs; a gesture you trigger
        // accidentally while scrolling must not do the most expensive thing the app can.
        // Here what this view shows is loaded — no more.
        //
        // **The haptics hang on the counter and not on the call.** `refreshable` brings none
        // itself, and the result is exactly the case from ``Haptics/Occasion/succeeded``:
        // Nothing happens for seconds, and afterwards the same list stands there with different
        // content.
        .refreshable {
            await model.load()
            refreshCount += 1
        }
        .haptics(.succeeded, at: refreshCount)
        .sheet(isPresented: $isIndexOpen) {
            register
        }
        .sheet(isPresented: $isCategoriesOpen) {
            categoryChoice
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .isLoading:
            LoadingState(forItem: .loadingStart).frame(maxHeight: .infinity)
        case .disrupted(let state):
            // The same dead button as on Home — see ``StartView``.
            StateView(state: state, action: { Task { await model.load() } })
        case .empty:
            // **A statement also names its next step.** It draws no loud button
            // today; if it ever gets one, the action is already there
            // instead of being added later.
            StateView(
                state: .emptyLibrary, action: { Task { await model.load() } })
        case .settled:
            // **One form for both catalogs** — see ``TitleGrid``.
            TitleGrid(
                order: model.order, open: open, commandSource: commandSource,
                downloadState: downloadState, load: load,
                following: { Task { await model.load() } })
        }
    }

    /// The index as a sheet from below.
    ///
    /// **`.large` as a second detent**, so that an index with fourteen libraries
    /// can be pulled up instead of scrolling within 63 percent of the height.
    private var register: some View {
        ScrollView {
            CatalogPickerSheet(
                state: model.catalogs, chosen: model.chosen?.id
            ) { catalog in
                isIndexOpen = false
                Task { await model.select(catalog) }
            }
            .padding(.vertical, MetricsBoard.phone.gutter)
        }
        .presentationDetents([.fraction(SheetID.catalogChoice.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    /// The category as a **capsule button** with the catalog count next to it.
    ///
    /// **The finding of 2026-09-05:** It stood as muted text with a small chevron —
    /// it looked like a caption and carried a hit area you could not tell
    /// from looking at it. With 108 categories and no search, this button is the most pressed
    /// control of the whole tab; it has to look like one.
    ///
    /// **And the number sits next to it instead of in a row of its own.** It belongs to the
    /// category you are in — a row of its own below it cost twenty points and
    /// answered the same question further away from it.
    @ViewBuilder
    private var categoryRow: some View {
        if !model.categories.isEmpty, let category = model.category {
            HStack(spacing: MetricsBoard.phone.gutter) {
                Button {
                    isCategoriesOpen = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Glyph.folder.name)
                            .iconSize(12)
                            .foregroundStyle(ColorRole.textMatt.color)
                        Text(verbatim: category.name)
                            .font(TypeLevel.footer.font.weight(.semibold))
                            .foregroundStyle(ColorRole.text.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: Glyph.down.name)
                            .iconSize(11, weight: .semibold)
                            .foregroundStyle(ColorRole.brandLight.color)
                    }
                    .padding(.horizontal, Metrics.pillInset)
                    .frame(minHeight: Metrics.target)
                    .background(ColorRole.surface.color, in: Capsule())
                    .overlay { Capsule().strokeBorder(ColorRole.outline.color, lineWidth: 0.5) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(app: "library.categoryIs \(category.name)"))
                .accessibilityHint(Text(app: "library.pickCategory"))

                // **The number comes from what is shown.** The provider reports no size for a
                // category; counting it would cost one query per category.
                // What is loaded, the view knows anyway.
                ProgressRow(count: statusCount, isEdgeless: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.bottom, Metrics.targetSpacing)
        } else {
            ProgressRow(count: statusCount)
                .padding(.bottom, 6)
        }
    }

    /// How many titles are shown — **and nothing while loading.**
    ///
    /// **"0 titles" during loading is a false statement** (seen on screen):
    /// The row then claims the catalog is empty while it is just arriving. An
    /// empty spot is more honest than a zero — the same rule as at the
    /// ``ProgressRow`` itself, where `nil` means "not counted" and not "zero".
    private var statusCount: Int? {
        if case .isLoading = model.state { return nil }
        return model.chosen?.extent ?? model.title.count
    }

    /// The floating bar with the three orders.
    ///
    /// **The space had long been booked and stood empty:** Both grid areas subtract
    /// ``Metrics/bottomInsetWithBar`` — 78 points for a floating bar that did not
    /// exist in this tab at all.
    ///
    /// **And the active chip is filled, not merely differently colored** — the same rule as
    /// for the active tab and for the same reason: With deuteranopia `rotHell` and
    /// `textQuiet` sit at 1.02 : 1.
    ///
    /// **Without a bar background** (user finding 2026-09-05). A material band across the whole
    /// width covers a row of tiles — for a button that sits on the left and is rarely
    /// pressed. The capsules bring their own material.
    private var bar: some View {
        SortRow(choice: model.choice, possible: model.availableOrders) { tapped in
            model.tap(tapped)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, Metrics.floatingBarBottom - Metrics.floatingBar + 14)
    }

    /// The category choice as a sheet from below — the same detent as the index.
    private var categoryChoice: some View {
        XtreamCategories(categories: model.categories, chosen: model.category) { category in
            isCategoriesOpen = false
            Task { await model.select(category: category) }
        }
        .presentationDetents([.fraction(SheetID.catalogChoice.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    private func labeled(_ label: CaptionLabel) -> String {
        switch label {
        case .key(let name): AppLanguageSetting.text(.init(name))
        case .wording(let name): name
        }
    }
}

extension LibraryScreen {

    /// What the library was built for: **rule, account, profile** (review 2026-09-27, D-S4).
    ///
    /// The view holds its model as `@State`; a new source on redraw does not
    /// reach it. Whoever attaches it to this identifier (`.id(_:)`) gets, after an
    /// account, profile or rule switch, a new library over the new source — also
    /// on a path that does not rebuild the shell.
    public struct Rebuild: Hashable {
        let rule: ProtectionRule
        let account: String
        let profile: String?

        public init(rule: ProtectionRule, account: String, profile: String? = ProfilePointer.active) {
            self.rule = rule
            self.account = account
            self.profile = profile
        }
    }
}
