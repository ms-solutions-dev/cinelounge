import DesignSystemPhone
import SwiftUI

/// The measurements of the detail page header — **and the one case distinction on which two
/// files depend.**
///
/// **A separate namespace, because ``HeaderSpace`` is generic.** Since the header takes a
/// text column along (AP7, 2026-09-24), it carries its type as a parameter — and a
/// generic type cannot hold stored static values. `HeaderSpace.height`
/// would also be reachable from outside only with the type parameter spelled out.
///
/// **Why ``DetailView`` asks here and does not compute itself:** It draws the trailer
/// in place of the header and the header block below or in it depending on size class. Both
/// decisions must flip exactly when the header flips — if the condition stood there
/// twice, one of them would drift apart at the next refactoring, and the page would jump at
/// trailer start or show the title twice.
enum HeaderSpaceMetrics {

    /// Full height only with a background image — fixed in *compact*, in *regular* the
    /// **lower bound**.
    ///
    /// **Seen on screen:** "Der Wutbatreik jopru spaukor Trusskeiborn" carries no
    /// background image, and 300 points stayed black — a third of the screen for
    /// nothing before the title came. Without an image the header space shrinks to what it has to
    /// carry: the way back.
    ///
    /// **Why only a lower bound in regular:** There the text column stands **in** the header,
    /// and at 520 points wide with title, ratings, buttons and synopsis it is taller than
    /// 300. A fixed height would cut it off; the lower bound keeps short entries from
    /// squashing the background image into a strip.
    static let height: CGFloat = 300
    static let heightWithoutImage: CGFloat = 108

    /// Whether the header takes the text column **next to** the poster.
    ///
    /// **Read from ``MetricClass/detailColumn(_:)`` and not from a second
    /// condition.** Its `0` means "no column"; whoever ever changes the number thereby changes
    /// when the header breaks as well — instead of letting a table and a switch run against
    /// each other.
    static func hasColumn(_ width: UserInterfaceSizeClass?) -> Bool {
        MetricClass.detailColumn(width) > 0
    }

    /// How tall the trailer is that takes the place of the header.
    ///
    /// **The coupling across the file boundary** (AP7, step 3). ``DetailView`` drew
    /// the trailer with the fixed header height — right as long as the header itself was fixed. In
    /// regular it no longer is: a trailer of 300 points in place of a header
    /// of 460 would pull everything below it up by 160 points at start and back
    /// down at the end. Therefore it takes there the **measured** height of the header it replaces —
    /// with the same lower bound as the header.
    ///
    /// **In compact it stays the fixed number**, even with a measured value: there the header is fixed,
    /// and "everything as today" also means that the trailer does not depend on a measurement
    /// that is none of its business.
    static func trailerHeight(_ width: UserInterfaceSizeClass?, measured: CGFloat?) -> CGFloat {
        guard hasColumn(width), let measured else { return height }
        return max(height, measured)
    }
}

/// The header of the detail page: image, veil, way back — and in *regular* poster and
/// text column side by side.
///
/// **Edge to edge, unlike the box on the Home screen.** There the box is a card
/// among several and needs an edge; here the image is the start of the page, and an
/// edge around the screen border would be a frame around nothing.
///
/// **The veil fades out into the background, not into black.** A black gradient on
/// a dark brown background has a visible edge — on a phone held
/// thirty centimeters from the face it is obvious.
///
/// **The header takes the column only in regular** (AP7, 2026-09-24). On the iPad the
/// header laid 345 points of empty gradient over the title, and under short single episodes
/// 69 % of the screen stayed black — the reading cap alone changed nothing about that, because it only
/// took the width and not the height. Side by side the text moves to where before there was
/// only gradient. **In compact `column` is not even built**: there
/// ``DetailView`` draws the same block below the header, and the header is what it was.
struct HeaderSpace<Spalte: View>: View {

    let content: HeroContent
    let back: () -> Void

    /// The header block of the page — title, ratings, buttons, synopsis.
    ///
    /// **As a build recipe and not as a finished view**, so that compact does not call it at
    /// all. The block belongs to ``DetailView``; the header only decides **whether** it
    /// stands in it.
    @ViewBuilder let column: () -> Spalte

    /// The size class in which this header stands.
    ///
    /// **It determines the requested image size** — at ``MetricClass/headerBox(_:)``,
    /// expressly at the class and not at the device, because Split View gives the iPad the
    /// *compact* class — **and since 2026-09-24 the arrangement too**, via
    /// ``HeaderSpaceMetrics/hasColumn(_:)``.
    @Environment(\.horizontalSizeClass) private var width

    @State private var color: (hue: Double, saturation: Double)?

    var body: some View {
        if HeaderSpaceMetrics.hasColumn(width) {
            sideBySide
        } else {
            stacked
        }
    }

    // MARK: - compact: wie vor dem 24.09.2026

    private var stacked: some View {
        ZStack(alignment: .top) {
            backdrop
            LinearGradient(
                colors: [ColorRole.reason.color.opacity(0.55), .clear],
                startPoint: .top, endPoint: .init(x: 0.5, y: 0.4))
            LinearGradient(
                colors: [.clear, ColorRole.reason.color],
                startPoint: .init(x: 0.5, y: 0.5), endPoint: .bottom)
            backPath
        }
        .frame(
            height: content.tile.backdrop == nil
                ? HeaderSpaceMetrics.heightWithoutImage : HeaderSpaceMetrics.height
        )
        .clipped()
    }

    // MARK: - regular: Plakat links, Spalte rechts

    /// **The height comes from the content, not from a number** (step 2) — with
    /// ``HeaderSpaceMetrics/height`` as the lower bound.
    ///
    /// **The image lies behind and not next to.** As a background it takes the size
    /// that poster and column dictate; as a sibling in a `ZStack` it would propose its
    /// own.
    ///
    /// **Anchored to the left, not centered** — like every shelf below, which starts at
    /// ``DesignSystemPhone/Metrics/margin``. A centered header above rows running
    /// left-aligned would have two edges on one page.
    private var sideBySide: some View {
        HStack(alignment: .top, spacing: MetricsBoard.phone.margin) {
            poster
            column()
                .frame(maxWidth: MetricClass.detailColumn(width), alignment: .leading)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        // The way back sits at 52 and is ``DesignSystemPhone/Metrics/target`` tall; below it
        // the content begins — the same height to which the header shrinks without an image.
        .padding(.top, HeaderSpaceMetrics.heightWithoutImage)
        .frame(
            maxWidth: .infinity,
            minHeight: content.tile.backdrop == nil
                ? HeaderSpaceMetrics.heightWithoutImage : HeaderSpaceMetrics.height,
            alignment: .topLeading
        )
        .background(alignment: .top) {
            ZStack {
                backdrop
                LinearGradient(
                    colors: [ColorRole.reason.color.opacity(0.55), .clear],
                    startPoint: .top, endPoint: .init(x: 0.5, y: 0.3))
                // **Earlier and denser than in compact.** There only the way back stands over the
                // image; here the title stands in it, and the synopsis runs to
                // the bottom edge. It must be legible from the upper third on.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: ColorRole.reason.color.opacity(0.8), location: 0.45),
                        .init(color: ColorRole.reason.color, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .overlay(alignment: .top) { backPath }
        .clipped()
    }

    /// The poster next to the column.
    ///
    /// **At the width of the shelf** (``MetricClass/shelfPosterWidth(_:)``, 160) and with
    /// the same longest edge as ``PosterTile`` — whoever comes here from a shelf tile
    /// already has exactly this image at exactly this size in memory. A number
    /// of its own would have fetched a second version of the same poster, and at the moment
    /// when the page is loading the most anyway.
    ///
    /// **A wide image is fitted** — the same rule as in ``PosterTile``: portals
    /// deliver 16 : 9, and filled, 62.5 % of the width would be lost.
    private var poster: some View {
        let metrics = MetricClass.shelfPosterWidth(width)
        let up = (metrics * MetricsBoard.phone.poster.height / MetricsBoard.phone.poster.width).rounded()
        let isLandscape = content.tile.wide == true
        return Group {
            if content.tile.image == nil {
                EmptyTile(title: content.tile.title, radius: MetricsBoard.phone.imageRadius)
            } else {
                RemoteImage(
                    source: content.tile.image, longestEdge: isLandscape ? metrics : up,
                    isFilling: !isLandscape
                )
                .background(ColorRole.surfaceHigh.color)
            }
        }
        .frame(width: metrics, height: up)
        .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius))
        // The title stands right next to it in the column; read aloud a second time it would
        // only be longer.
        .accessibilityHidden(true)
    }

    // MARK: - Teile beider Anordnungen

    @ViewBuilder
    private var backdrop: some View {
        if let image = content.tile.backdrop {
            // **The width, not the height** — see ``RemoteImage``.
            // **And the width of the size class, not the fixed 400** (2026-09-23):
            // The image lies edge to edge across the whole page width, and that is
            // about 992 points on an iPad Pro 13″. 400 were requested — with
            // `reference: 2` that is 800 pixels, stretched to 1984.
            RemoteImage(
                source: image, longestEdge: MetricClass.headerBox(width),
                alignment: .top
            ) { audio, saturation in
                color = (audio, saturation)
            }
        } else {
            ColorRole.surface.color
        }
    }

    private var backPath: some View {
        HStack {
            Button(action: back) {
                Image(systemName: Glyph.back.name)
            }
            .buttonStyle(.rounded)
            .accessibilityLabel(Text(app: "common.back"))
            Spacer()
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, 52)
    }
}
