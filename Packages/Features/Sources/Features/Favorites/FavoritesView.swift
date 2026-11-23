import Core
import DesignSystem
import SwiftUI

/// The favorites area: films, series and channels in one place.
///
/// Horizontal rows per section, as everywhere else in the library. A
/// vertical list would be more obvious, but would be wrong here: the sections are
/// of different length, and stacked the longest would push the others out of view.
/// This way each kind stays in its place, no matter how much is in it.
public struct FavoritesView: View {

    @StateObject private var model: FavoritesModel
    let onOpen: (MediaItem) -> Void
    /// The channel and the other favorite channels — the player switches onward from them.
    let onPlayChannel: (Channel, [Channel]) -> Void
    /// A provider title plays directly — it has no detail page.
    let onPlayVOD: (MediaItem) -> Void
    /// Removes the mark — the long press on every tile
    /// (user request 2026-08-15: favorites are also a watch list, and watched items
    /// should be removable here without first opening the title).
    let onUnfavorite: (FavoritesModel.Entry) async -> Void
    /// Resets the progress of a started title — the second
    /// long-press path (user request 2026-08-15: also start over from the favorites).
    let onResetProgress: (FavoritesModel.Entry) async -> Void

    @FocusState private var focus: String?

    /// Reloads when the value changes — the frame counts it up as soon as
    /// the player closes. Without it the tiles carried the state from BEFORE
    /// playback (device finding 2026-08-16: no bar, no reset after the
    /// first viewing, although resuming had long worked).
    let reloadToken: Int

    public init(
        reloadToken: Int = 0,
        model: FavoritesModel,
        onOpen: @escaping (MediaItem) -> Void,
        onPlayChannel: @escaping (Channel, [Channel]) -> Void,
        onPlayVOD: @escaping (MediaItem) -> Void = { _ in },
        onUnfavorite: @escaping (FavoritesModel.Entry) async -> Void = { _ in },
        onResetProgress: @escaping (FavoritesModel.Entry) async -> Void = { _ in }
    ) {
        self.reloadToken = reloadToken
        _model = StateObject(wrappedValue: model)
        self.onOpen = onOpen
        self.onPlayChannel = onPlayChannel
        self.onPlayVOD = onPlayVOD
        self.onUnfavorite = onUnfavorite
        self.onResetProgress = onResetProgress
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
        // As in the library: edge to edge at top, bottom and right, not on the left — the
        // sidebar stands there, and without the restriction the content would run under it.
        .ignoresSafeArea(edges: [.top, .bottom, .trailing])
        .task(id: reloadToken) { await model.load() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                Text(app: "tab.favorites")
                    .font(TypeLevel.title.font)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.top, 20)

                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(appKey: section.id.titleKey)
                            .font(TypeLevel.header.font)
                            .foregroundStyle(ColorRole.textMatt.color)

                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: MetricsBoard.tv.gutter) {
                                ForEach(section.items) { entry in
                                    tile(entry, in: section.id)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.trailing, MetricsBoard.tv.margin)
                        }
                        .scrollClipDisabled()
                        // A separate section per row: without it the focus jumps on horizontal
                        // paging to the row above or below.
                        .focusSection()
                    }
                }
            }
            .padding(.leading, MetricsBoard.tv.margin)
            .padding(.bottom, TVMetrics.topMargin)
        }
    }

    @ViewBuilder
    private func tile(_ entry: FavoritesModel.Entry, in kind: FavoritesModel.Section.Kind) -> some View {
        let id = "\(kind.rawValue)-\(entry.id)"

        Button {
            if let channel = entry.channel {
                onPlayChannel(channel, favouriteChannels)
            } else if let item = entry.item {
                entry.playsDirectly ? onPlayVOD(item) : onOpen(item)
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                artwork(for: entry, isFocused: focus == id)

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.title)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(1)
                    // For a series the number of marked episodes, for a channel
                    // its group. If both are missing, the line is dropped instead of
                    // standing empty — otherwise the tiles of a row drift apart.
                    if let subtitle = entry.subtitle {
                        Text(verbatim: subtitle)
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .lineLimit(1)
                    }
                }
                .frame(width: tileWidth(for: kind), alignment: .leading)
            }
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        // **The long press removes the mark** — the same mechanics and
        // the same label as in the grid (``LibraryView/cardMenu``): an
        // action that carries two names in two places reads as two
        // actions. Afterwards the list reloads, so that the tile
        // disappears immediately and not only on the next visit.
        .contextMenu {
            Button {
                Task {
                    for tag in entry.toResolve { await onUnfavorite(tag) }
                    await model.load()
                }
            } label: {
                Label(app: "common.unfavorite", systemImage: Glyph.favorite.pair.filled)
            }
            // Only for started titles — the same rule and label
            // as in the grid (user request 2026-08-15: being able to start over
            // from the favorites too).
            if entry.item?.progress?.isResumable == true {
                Button {
                    Task {
                        await onResetProgress(entry)
                        await model.load()
                    }
                } label: {
                    Label(app: "common.resetProgress", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    /// A tile's image.
    ///
    /// Channels in wide format, titles in poster format — the same dimensions as where they
    /// otherwise appear. A channel logo squeezed into a poster would be either distorted or
    /// mostly empty.
    private func artwork(for entry: FavoritesModel.Entry, isFocused: Bool) -> some View {
        let size =
            entry.channel != nil ? MetricsBoard.tv.episode : MetricsBoard.tv.poster

        return RemoteImage(url: entry.imageURL, displaySize: size)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // The progress lies on the image as in the grid (user request
            // 2026-08-15): whoever uses the favorites as a watch list sees at a
            // glance what is started.
            .overlay(alignment: .bottom) { progressBar(for: entry) }
            .focusHighlight(isFocused)
    }

    /// The bar on the image — the same drawing as ``PosterCard``.
    @ViewBuilder
    private func progressBar(for entry: FavoritesModel.Entry) -> some View {
        if let progress = entry.item?.progress, progress.isResumable {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.24))
                    Rectangle()
                        .fill(ColorRole.progress.color)
                        .frame(width: geometry.size.width * progress.fraction)
                }
            }
            .frame(height: 6)
        }
    }

    /// All channels of this area, in the displayed order.
    private var favouriteChannels: [Channel] {
        model.sections.first { $0.id == .channels }?.items.compactMap(\.channel) ?? []
    }

    private func tileWidth(for kind: FavoritesModel.Section.Kind) -> CGFloat {
        kind == .channels ? MetricsBoard.tv.episode.width : MetricsBoard.tv.poster.width
    }

    /// When nothing is marked yet.
    ///
    /// Says **how** to get something here. An empty area with "nothing
    /// available" leaves open whether the feature is missing or you just have not used it
    /// yet.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: Glyph.favorite.pair.outlined)
                .font(.system(size: 64))
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(app: "favorites.empty")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
            Text(app: "favorites.emptyHint")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, MetricsBoard.tv.margin)
        .padding(.top, 140)
        // An anchor for the empty area (AP5 · B9): without a focusable
        // element the focus falls into the sidebar, and the area looks
        // as if it had been skipped.
        .focusAnchor("favorites-empty", focus: $focus)
    }
}
