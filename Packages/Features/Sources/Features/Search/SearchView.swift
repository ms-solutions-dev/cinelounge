import Core
import DesignSystem
import SwiftUI

/// The search: input field on top, hits as a grid below.
public struct SearchView: View {

    @StateObject private var model: SearchModel
    @FocusState private var focus: String?
    @State private var palette = AccentPalette.brand

    let onSelect: (MediaItem) -> Void
    /// A provider hit plays directly — it has no detail page
    /// (the same rule as in the VOD grid and in the favourites).
    let onPlayVOD: (MediaItem) -> Void

    public init(
        model: SearchModel,
        onSelect: @escaping (MediaItem) -> Void,
        onPlayVOD: @escaping (MediaItem) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: model)
        self.onSelect = onSelect
        self.onPlayVOD = onPlayVOD
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                switch model.state {
                case .idle:
                    // **No hint of its own, but no black void either.** A hint text once stood here and ended
                    // up directly under the system field's placeholder: two prompts to search on top of each
                    // other, worded almost the same — what needs saying is in the placeholder. The area
                    // below belongs instead to the newest from the catalog: suggestions that often save the
                    // typing effort on the remote. As long as they are missing — or there is nothing —, the
                    // area stays empty as before.
                    if model.suggestions.isEmpty {
                        EmptyView()
                    } else {
                        grid(of: model.suggestions) {
                            Text(app: "home.recentlyAdded")
                        }
                    }
                case .searching:
                    // The loading indicator sits in the same place as the hits later. A spinner in the middle
                    // of the screen would make the list jump when it appears.
                    message(systemImage: "magnifyingglass", titleKey: "search.running")
                case .empty(let term):
                    noResults(term)
                case .failed(let key):
                    message(systemImage: "exclamationmark.triangle.fill", titleKey: key)
                case .results(let groups):
                    results(groups)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // The same edge specification as on the Home screen, and for the same reason: at the top,
        // bottom and right the overscan inset is cancelled, at the left it is not — the sidebar
        // stands there. Without the restriction the content ran under it, and "Serien" lost its S,
        // "Skeblus deitseflaum Poblaplal" its A.
        // **The overscan inset is NO longer cancelled here — on no side.**
        //
        // Before, `.ignoresSafeArea(edges: [.top, .bottom, .trailing])` stood here, and that was
        // the common cause of all the display errors in this view. tvOS reports the height of its
        // search field together with the keyboard through the safe area. Whoever cancels it at the
        // top says thereby: "I know better" — and puts their content under the keyboard. It showed
        // up three ways: the "Nothing found" message lay behind the letters, the keyboard row
        // reached left into the sidebar, and the hint about switching keyboards was cut off on the
        // right in the middle of a word.
        //
        // On the Home screen cancelling is right, because the title image is meant to reach the
        // edge and nobody shows system elements there. When transferring the pattern this
        // difference is lost.
        .ignoresSafeArea(edges: [])
        .environment(\.accentPalette, palette)
        // The system keyboard, not a field of our own: on tvOS text input is laborious anyway, and
        // the built-in one knows dictation and the keyboard of a paired phone. Both would be lost
        // if rebuilt.
        // The placeholder is passed explicitly. Without it the system writes "Search" into it —
        // in the SYSTEM LANGUAGE, not in the one chosen in the app. On an Apple TV set up in
        // English that put an English word in the middle of a German interface.
        // **The remote keyboard hangs on `isSearching` and must lie INSIDE it** (AP24,
        // 2026-09-11) — hence in the background and not as a modifier next to it.
        .background { RemoteSearch(text: searchText) }
        .searchable(
            text: searchText,
            placement: .automatic,
            prompt: Text(app: "search.hint")
        )
        .task { await model.loadSuggestions() }
    }

    /// Between field and model: every change goes through the delay, so that not every letter
    /// triggers a request.
    private var searchText: Binding<String> {
        Binding(
            get: { model.term },
            set: { model.termChanged(to: $0) }
        )
    }

    // MARK: - States

    private var hint: some View {
        message(systemImage: "magnifyingglass", titleKey: "search.hint")
    }

    private func noResults(_ term: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(ColorRole.textQuiet.color)
            // Name the term: "No hits" alone leaves open whether the search arrived at all.
            Text(app: "search.noResults \(term)")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
            Text(app: "search.noResultsHint")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        // No fixed top spacing any more: it was an attempt to get around the keyboard, whose
        // height nobody knows — at 120 points the message lay exactly behind the letters. The safe
        // area now keeps the space free.
        .padding(.top, 40)
    }

    private func message(systemImage: String, titleKey: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(appKey: titleKey)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        // No fixed top spacing any more: it was an attempt to get around the keyboard, whose
        // height nobody knows — at 120 points the message lay exactly behind the letters. The safe
        // area now keeps the space free.
        .padding(.top, 40)
    }

    // MARK: - Results

    /// Both groups in ONE grid: the library on top, the provider below (requirement 2026-08-16) —
    /// as sections IN the grid, not as two grids.
    ///
    /// **The structure is deliberately exactly that of the suggestions grid**, because that one
    /// proved itself on the device. Two stacked grids — first with `focusSection`, then without
    /// — never got out of the focus structure of the tvOS search: each time, the focus was
    /// thrown back from the hits into the input field (on-device finding 2026-08-16, confirmed
    /// twice). `Section` inside the `LazyVGrid` gives the headers without changing the view
    /// structure the focus hangs on.
    /// **The hits by origin, in the order of the sources** (AP29, 2026-09-11).
    ///
    /// Two hard-wired sections stood here — library and provider —, and a third would have
    /// needed a third branch. Now the same loop draws every origin; whoever introduces a fourth
    /// changes ``Origin`` and nothing else.
    private func results(_ groups: [SearchModel.ResultGroup]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(
                                .fixed(MetricsBoard.tv.poster.width), spacing: 44),
                            count: Self.columns(fitting: proxy.size.width)
                        ),
                        alignment: .leading,
                        spacing: 52
                    ) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.match) { item in
                                    // **The path depends on the origin**, and that is exactly
                                    // why it is grouped: a provider title starts
                                    // playing immediately, a media server title leads to
                                    // its detail page.
                                    tile(
                                        item,
                                        play: group.origin == .provider && !group.isChannel
                                            ? onPlayVOD : onSelect)
                                }
                            } header: {
                                sectionHeader(group.headline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, MetricsBoard.tv.margin)
                    .padding(.bottom, TVMetrics.topMargin)
                    // Room for the highlight — reasoning at the suggestions grid.
                    .padding(.top, Self.focusHeadroom)
                }
            }
        }
        .padding(.top, 30)
    }

    /// The header of a hit section — the same type as above the suggestions.
    private func sectionHeader(_ key: String) -> some View {
        Text(appKey: key)
            .font(TypeLevel.footer.font)
            .kerning(2)
            .foregroundStyle(ColorRole.textQuiet.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }

    /// A hit tile — identical to those of the suggestions grid, including the accent colour
    /// from the image.
    private func tile(_ item: MediaItem, play: @escaping (MediaItem) -> Void) -> some View {
        Button {
            play(item)
        } label: {
            PosterCard(
                item: item,
                imageURL: model.posterURL(for: item),
                isFocused: focus == item.id
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: item.id)
        .onChange(of: focus) { _, current in
            guard current == item.id else { return }
            Task {
                palette =
                    await AccentExtractor.shared
                    .palette(for: model.accentSourceURL(for: item)) ?? .brand
            }
        }
    }

    /// Header and poster grid — for the empty state's suggestions.
    private func grid<Header: View>(
        of items: [MediaItem],
        @ViewBuilder header: () -> Header
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
                .font(TypeLevel.footer.font)
                .kerning(2)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.trailing, MetricsBoard.tv.margin)
                .padding(.bottom, 20)

            GeometryReader { proxy in
                ScrollView {
                    // **Computed, not left to grow.** `.adaptive(minimum:)` stood here, and that spread the
                    // space over two very wide columns with a hand's breadth of air between them — the posters
                    // slid almost to the right edge. `.adaptive` only says how **narrow** a column may get at
                    // most; how wide it gets, it decides itself.
                    //
                    // Fixed columns in a computed number are predictable, and ``LayoutBudgetTests`` checks
                    // by calculation that they fit.
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(
                                .fixed(MetricsBoard.tv.poster.width), spacing: 44),
                            count: Self.columns(fitting: proxy.size.width)
                        ),
                        alignment: .leading,
                        spacing: 52
                    ) {
                        ForEach(items) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                PosterCard(
                                    item: item,
                                    imageURL: model.posterURL(for: item),
                                    isFocused: focus == item.id
                                )
                            }
                            .bareFocusableButton()
                            .focused($focus, equals: item.id)
                            .onChange(of: focus) { _, current in
                                guard current == item.id else { return }
                                // Derived from the image, not guessed from the title. The call is cheap: results are
                                // kept, and the image is requested tiny.
                                Task {
                                    palette =
                                        await AccentExtractor.shared
                                        .palette(for: model.accentSourceURL(for: item)) ?? .brand
                                }
                            }
                        }
                    }
                    // **Explicitly leading, otherwise it centres itself.** `LazyVGrid` with fixed columns
                    // distributes the remaining space to both sides, even with `alignment: .leading` — the
                    // posters therefore stood 340 points too far right and ran out past the right edge.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, MetricsBoard.tv.margin)
                    .padding(.bottom, TVMetrics.topMargin)
                    // **The room for the highlight lies INSIDE**, not outside.
                    //
                    // `.scrollClipDisabled()` stood here: the grid was allowed to draw beyond its box so that
                    // the enlarged poster is not cut off at the top. With the **square** keyboard, however,
                    // the box is only a few hundred points high — and whatever draws beyond lands in the middle
                    // of the keyboard. That is exactly the finding "with the linear one it looks good, with
                    // the square one the view is wrecked": with the flat keyboard there is enough room below
                    // it that the overhang is noticed by nobody.
                    //
                    // The room is therefore kept free **in** the scroll area. Then the poster no longer needs
                    // to draw beyond it, and clipping is allowed again — which makes the view independent of
                    // the keyboard's height instead of assuming one.
                    .padding(.top, Self.focusHeadroom)
                }
            }
        }
        .padding(.top, 30)
    }

    /// How many posters fit across the width that tvOS leaves us.
    ///
    /// **What is asked is the space, not the keyboard** — and that is the lesson from three
    /// wrong attempts at the same spot.
    ///
    /// First `.scrollClipDisabled()` seemed to be to blame, then the measurement reported
    /// `safeAreaInsets l=0` and suggested a keyboard that simply lies over everything — so a
    /// strip was kept free on the left. That was wrong: **tvOS already insets the content
    /// itself during search.** The strip of our own came on top, and between keyboard and first
    /// poster there was a hand's breadth of nothing.
    ///
    /// The real error was a different one and the same all along: six fixed columns need 1660
    /// points, they do not fit into the inset width — and `LazyVGrid` **centres** what does not
    /// fit. That is why the grid lay under the keyboard on the left and outside the picture on
    /// the right.
    ///
    /// The calculation now starts from the width that is really there. That makes the view
    /// independent of the keyboard type without knowing it.
    static func columns(fitting width: CGFloat) -> Int {
        let available = width - MetricsBoard.tv.margin
        let step = MetricsBoard.tv.poster.width + 44
        return max(1, Int((available + 44) / step))
    }

    /// How much air the highlight of a poster needs upward.
    ///
    /// Computed and not estimated: a poster grows in focus to
    /// ``Tokens/Focus/cardScale``, and half of that goes upward.
    /// ``LayoutBudgetTests`` checks by calculation that the value suffices.
    static var focusHeadroom: CGFloat {
        MetricsBoard.tv.poster.height * (Tokens.Focus.cardScale - 1) / 2
    }
}
