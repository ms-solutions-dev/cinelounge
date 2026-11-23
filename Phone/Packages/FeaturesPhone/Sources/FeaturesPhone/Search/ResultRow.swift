import Core
import DesignSystemPhone
import SwiftUI

/// A hit: tile, name, secondary line, state badge.
///
/// **A row and no grid — in the compact class.** In the library you browse,
/// here you look things up — and when looking things up you read from left to right, not
/// from tile to tile. The row also carries what a tile only 110 points wide
/// does not: which section the hit comes from, how many episodes it has, whether the
/// portal behind it demands a login.
///
/// **On the iPad the sentence no longer applies** (AP7, 2026-09-23). There this row is 1032
/// points wide and about 90 percent empty; what carries the form is not the verb
/// but the area. The calculation for both devices is at ``SearchGrid``.
///
/// **The state is on the hit, not above the group.** When a portal does not
/// answer or demands a login, that is a property of **this one**
/// result — next to it in the same group there can be a hit that plays immediately.
struct ResultRow: View {

    let match: Match
    let action: () -> Void

    /// The tile is small and wide — **a recognition mark, not a poster.**
    /// When looking things up the name carries, the image only confirms.
    private static let imageWidth: CGFloat = 46

    var body: some View {
        Button(action: action) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                image
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: match.tile.title)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    subRow
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.vertical, 10)
            .frame(minHeight: Metrics.choiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var image: some View {
        Group {
            if match.tile.image == nil {
                EmptyTile(title: match.tile.title, radius: 6)
            } else {
                RemoteImage(
                    source: match.tile.image, longestEdge: Self.imageWidth * 1.5,
                    withColor: false)
            }
        }
        .frame(width: Self.imageWidth, height: Self.imageWidth * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var subRow: some View {
        HStack(spacing: 6) {
            // **The state first.** What stops you from pressing comes before what
            // lies behind the press — the same ranking as in the channel row.
            if let state = match.state, !state.isReady {
                StateBadge(state: state)
            } else if let beside = match.tile.beside {
                Text(verbatim: beside)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .lineLimit(1)
            }
        }
    }
}

/// A group of hits — one per catalog.
///
/// **With hit count and footer.** The number says how much is here; the footer,
/// **what was searched**. Both answer the question that comes up with few hits:
/// was it me or the search?
/// One group per catalog, with hit count and footer.
///
/// **The same background as ``SearchEmpty``** (2026-09-07): the explanation was in
/// `ResultGroup.swift` — three lines of comment without a type, with the sentence "Not built yet"
/// above something that has long been here.
struct ResultGroup: View {

    let sharedStore: ResultBundle
    let open: (Match) -> Void

    /// Where the long-press commands get their answer — see ``TileCommands``.
    ///
    /// **The finding of 2026-09-09:** the long press was on three screens and missing from
    /// the search entirely. It belongs here too: a hit row is the last stop
    /// before opening, and "remember" or "download" is often exactly what someone
    /// searched for.
    ///
    /// `nil` means **no menu**; the reasoning is at ``TitleGrid/commandSource``.
    var commandSource: (any DetailSource)?
    var downloadState: ((String) -> DownloadState?)?
    var load: ((TileContent) -> Void)?
    var following: () -> Void = {}

    /// The dimensions of the tile grid — **`nil` means: list**, and that is the default.
    ///
    /// **Passed in from outside and not read here.** The dimensions hang on the measured
    /// width, and it is measured once in ``SearchScreen`` — for all groups together. Letting
    /// each group measure its own area would mean stacking four
    /// ``SwiftUI/GeometryReader`` for four catalogs, all of which find out the same thing.
    var raster: SearchGrid?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if sharedStore.hasAnswered {
                if let raster {
                    tiles(raster)
                } else {
                    rows
                }
            } else {
                // **A silent source stays and says so.** Leaving it out would be
                // convenient and would lie silently: the viewer would then count hits from two
                // catalogs and take them for all.
                Text(appKey: "search.groupSilent")
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.vertical, 10)
            }
            if let footer = sharedStore.footer {
                Text(verbatim: footer)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }

    /// The hits one below the other — **the version for the phone.**
    @ViewBuilder
    private var rows: some View {
        ForEach(sharedStore.match) { match in
            withCommands(match) {
                ResultRow(match: match) { open(match) }
            }
            if match.id != sharedStore.match.last?.id {
                Divider().overlay(ColorRole.lineQuiet.color)
                    .padding(.leading, MetricsBoard.phone.margin + 46 + MetricsBoard.phone.gutter)
            }
        }
    }

    /// The hits as a grid — **the version for the iPad**, see ``SearchGrid``.
    ///
    /// **Without separators between the tiles.** What the hairline does in the list, the spacing does in the
    /// grid: a tile is recognisable as its own hit by its image,
    /// and a line between them would be a second separator — the same consideration with
    /// which ``SettingsCard`` places its separators only inside.
    private func tiles(_ raster: SearchGrid) -> some View {
        LazyVGrid(columns: raster.grid, alignment: .leading, spacing: Metrics.rowGap) {
            ForEach(sharedStore.match) { match in
                withCommands(match) {
                    ResultTile(match: match, width: raster.cellWidth) {
                        open(match)
                    }
                }
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }

    /// The row with the long press — or without, if nothing can answer it.
    ///
    /// **The origin comes from the group and not from the ID.** It is there
    /// anyway (``ResultBundle/origin``), and without it a channel hit would not be recognisable as
    /// one — the same reasoning as for opening in ``SearchScreen``.
    ///
    /// **No "Reset progress".** The search is not a Continue Watching shelf.
    @ViewBuilder
    private func withCommands(
        _ match: Match, @ViewBuilder _ row: () -> some View
    ) -> some View {
        if commandSource != nil || load != nil {
            row()
                .tileCommands(
                    match.tile, origin: sharedStore.origin, source: commandSource,
                    inHistory: false,
                    downloadState: downloadState.flatMap { $0(match.tile.id) }, load: load,
                    following: following)
        } else {
            row()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            labeled(sharedStore.headline)
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer()
            Text(verbatim: sharedStore.match.count.formatted())
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .monospacedDigit()
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func labeled(_ was: CaptionLabel) -> some View {
        switch was {
        case .key(let key): Text(appKey: key)
        case .wording(let wording): Text(verbatim: wording)
        }
    }
}
