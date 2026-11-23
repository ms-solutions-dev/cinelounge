import Core
import DesignSystem
import Flows
import PortalKit
import SwiftUI

/// Search within a portal — **its own window, like the global search.**
///
/// **Why it could not stay inside the level** (viewer finding 2026-08-28:
/// "the search still does not open in its own window like the global
/// search, which is why everything is so cramped"): A `.searchable` on a
/// *stacked* view gets the narrow bar above the content from tvOS —
/// above a folder list with its own header, its own spacing and a
/// title grid next to it. The global search, by contrast, stands on its own as a
/// whole and has the full area.
///
/// This view is therefore built to the same blueprint as ``SearchView``
/// and is laid over the whole screen: the same states, the same grid,
/// the same tile. **Only the root is different** — there the
/// media server answers, here the page whose folder you are currently in.
///
/// One difference in behavior is intentional and is documented at ``PortalKit/PortalSearch/pause``: searching
/// starts later than there, because behind every request there is a fetch from a third-party
/// site.
struct PortalSearchView: View {

    let source: PortalSource
    /// The level that asked. Its identifier together with the search term yields the
    /// level with the results.
    let library: Core.Library
    /// What the portal asked for — verbatim, as the placeholder in the field.
    let query: String
    let onOpen: (MediaItem) -> Void
    /// The way out. It **takes the search level with it**: behind this window
    /// there is a level without a single entry — being dropped off there
    /// would look like an error.
    var suggestion: String? = nil
    let onClose: () -> Void

    @State private var text = ""
    @State private var needle = ""
    @State private var match: [MediaItem]?
    @State private var isRunning = false
    @State private var searchRun: Task<Void, Never>?
    @State private var error: String?
    @State private var searchTarget: Library.ID?
    @State private var searchContinuation: String?
    @State private var isLoadingMore = false
    @State private var palette = AccentPalette.brand
    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                if needle.isEmpty {
                    // **No separate hint.** What needs saying is in the
                    // field's placeholder — the same decision as in
                    // ``SearchView``, where a second call to action for searching
                    // stood directly below.
                    EmptyView()
                } else if isRunning {
                    report("magnifyingglass", "search.running")
                } else if let error {
                    // **An error is not an empty result** (AP77): Until then a `try?`
                    // swallowed the reason, and "no results" stood in for a server that
                    // did not answer.
                    errorBoard(error)
                } else if let match, match.isEmpty {
                    // **With the term in it.** "No results" alone leaves
                    // open what was searched for — and on tvOS the text
                    // in the field is often no longer visible by the time the message is read.
                    noResults
                } else if let match {
                    raster(match)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // **The overscan inset is NOT removed here.** tvOS shares the
        // height of its search field including the keyboard through the safe area;
        // whoever removes it at the top puts their content under the keyboard. The
        // lesson is documented at length in ``SearchView``, where it showed up
        // three times — message behind the letters, keyboard in the sidebar,
        // hint cut off on the right.
        .ignoresSafeArea(edges: [])
        .environment(\.accentPalette, palette)
        // The system keyboard and no custom field: on tvOS text input is
        // tedious anyway, and the built-in one supports dictation and the keyboard
        // of a paired phone. Both would be lost if rebuilt.
        // See ``SearchView``: tied to `isSearching` and therefore in the content (AP24).
        .background { RemoteSearch(text: $text) }
        .searchable(text: $text, placement: .automatic, prompt: Text(verbatim: query))
        .onChange(of: text) { old, fresh in
            // **Real changes only** (the same lesson as in ``SearchModel``):
            // the tvOS search field sets its text again on focus changes,
            // with the same wording.
            guard old != fresh else { return }
            handleInput(fresh)
        }
        // On submit immediately — but the search does not depend on it. Whether the
        // on-screen keyboard fires a "submit" depends on how it is
        // left; whoever closes it with the menu button triggers none.
        .onSubmit(of: .search) { search(text, immediately: true) }
        .onAppear {
            // The portal's suggestion is prefilled in the field — as on the phone.
            if text.isEmpty, let suggestion { text = suggestion }
        }
        .onExitCommand(perform: onClose)
    }

    // MARK: - States

    private var noResults: some View {
        HStack(spacing: 18) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(verbatim: PortalList.emptyText(needle: needle))
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.top, 40)
    }

    private func errorBoard(_ text: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(verbatim: text)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.top, 40)
    }

    private func report(_ symbol: String, _ key: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(appKey: key)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.top, 40)
    }

    /// The results grid — the same measure and the same tile as in the
    /// global search. ``SearchView/columns(fitting:)`` computes the number of
    /// columns; two versions of the same calculation would drift apart.
    private func raster(_ items: [MediaItem]) -> some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(MetricsBoard.tv.poster.width), spacing: 44),
                        count: SearchView.columns(fitting: proxy.size.width)
                    ),
                    alignment: .leading,
                    spacing: 52
                ) {
                    ForEach(items) { item in
                        tile(item)
                            .onAppear {
                                if LoadMore.applies(item, in: items) { Task { await loadMoreResults() } }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, MetricsBoard.tv.margin)
                .padding(.trailing, MetricsBoard.tv.margin)
                .padding(.bottom, TVMetrics.topMargin)
                .padding(.top, SearchView.focusHeadroom)
            }
        }
        .padding(.top, 30)
    }

    private func tile(_ item: MediaItem) -> some View {
        Button {
            onOpen(item)
        } label: {
            PosterCard(
                item: item,
                imageURL: source.imageURL(
                    itemID: item.artwork.posterID ?? "",
                    kind: .primary,
                    width: ImageSizing.requestWidth(points: MetricsBoard.tv.poster.width),
                    tag: nil
                ),
                isFocused: focus == item.id
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: item.id)
    }

    // MARK: - Search

    private func handleInput(_ input: String) {
        searchRun?.cancel()
        guard let word = PortalSearch.term(input, whileTyping: true) else {
            // Back to the initial state instead of "no results": whoever has just
            // cleared everything has not searched unsuccessfully.
            needle = ""
            match = nil
            return
        }
        searchRun = Task {
            try? await Task.sleep(for: PortalSearch.pause)
            guard !Task.isCancelled else { return }
            search(word, immediately: true)
        }
    }

    private func search(_ input: String, immediately: Bool) {
        guard let word = PortalSearch.term(input, whileTyping: true), word != needle else { return }
        searchRun?.cancel()
        needle = word
        isRunning = true
        error = nil
        Task {
            defer { isRunning = false }
            guard let target = PortalSource.searchedID(forItem: library.id, input: word) else { return }
            do {
                let page = try await source.level(target)
                guard needle == word else { return }
                match = page.items.filter { $0.kind != .separator }
                searchTarget = target
                searchContinuation = page.next
            } catch let thrownError {
                guard needle == word else { return }
                match = nil
                error = Diagnostics.explain(thrownError)
            }
        }
    }

    /// The next page of results — until AP77 the TV stayed at the first one.
    private func loadMoreResults() async {
        guard let target = searchTarget, let tag = searchContinuation, !isLoadingMore, let previous = match
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await source.level(target, next: tag)
            guard searchContinuation == tag else { return }
            let known = Set(previous.map(\.id))
            match = previous + page.items.filter { $0.kind != .separator && !known.contains($0.id) }
            searchContinuation = page.next
        } catch {
            Diagnostics.defect(
                "Portal search: next page not fetched: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
        }
    }
}
