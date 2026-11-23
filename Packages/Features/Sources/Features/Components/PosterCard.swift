import Core
import DesignSystem
import SwiftUI

/// A poster tile as it appears in every row and every grid.
///
/// The dimensions come unchanged from the UI template: 240 × 360 points
/// at 2:3. The focus ring sits **only around the image**, not around the
/// caption below — otherwise it clips the text, as the first
/// startup on the TV showed.
public struct PosterCard: View {

    let item: MediaItem
    let imageURL: URL?
    let isFocused: Bool
    /// Whether the caption comes along. In a grid it helps; in a row with
    /// recognisable posters it is often an extra.
    let showsTitle: Bool

    /// How large the poster is drawn. **Default: the template, 240 × 360.**
    ///
    /// The children's interface (AP45) draws larger — see
    /// ``Surface/posterSize``. One parameter and not a second tile: two
    /// tiles would drift apart the next time the focus rule is reworked, and the
    /// one left behind would be the children's.
    let size: CGSize

    @Environment(\.accentPalette) private var palette

    /// Gap between image and caption — see the reasoning at the stack.
    public static let captionSpacing: CGFloat = 26

    /// How many lines the caption gets — **and reserved for good.**
    ///
    /// One line was too few: at 240 points wide and 27 points type that is
    /// about fifteen characters, and "Biziskei Biamik: Britwu kiaskau fluvo Laufiongliak"
    /// became "Biziskei Biamik: Lelou…" — the part that tells titles apart was missing.
    /// Reserved and not merely allowed, because the tiles sit in a `LazyVGrid`:
    /// cells of different heights made the rows of the grid drift against each other.
    /// The home-video tiles show their titles on two lines for the same
    /// reason.
    public static let captionLines = 2

    /// The total height of a tile **with** caption — calculated, not measured.
    ///
    /// `LayoutBudgetTests` checks against this number that a full poster row
    /// still fits on screen below the header and filter row. The line height comes from
    /// the tokens, so that a type change updates the calculation.
    public static var titledHeight: CGFloat {
        MetricsBoard.tv.poster.height + captionSpacing
            + CGFloat(captionLines)
            * TypeLevel.lineHeight(zu: TypeLevel.footer.points)
    }

    public init(
        item: MediaItem,
        imageURL: URL?,
        isFocused: Bool,
        showsTitle: Bool = true,
        size: CGSize = MetricsBoard.tv.poster
    ) {
        self.item = item
        self.imageURL = imageURL
        self.isFocused = isFocused
        self.showsTitle = showsTitle
        self.size = size
    }

    public var body: some View {
        // **The gap has to absorb the enlargement.** In focus the poster grows to
        // 1.12 — at 390 points height that is about 23 points downwards. With a 14-point
        // gap nothing of that was left, and the title stuck to the image or was
        // swallowed by the glow underneath. The gap therefore has to be larger than
        // what the enlargement adds at one edge.
        VStack(alignment: .leading, spacing: Self.captionSpacing) {
            // The display size has to be passed in: it determines what size
            // to downscale to while decoding. Without it the image is unpacked at full size
            // and scaled down to 240 points on **every** draw —
            // on the main thread, in the middle of scrolling.
            //
            // **`.fit` on a plate, not `.fill`.** Measured on 2026-08-27: the
            // images of a portal are 640 × 360, exactly 16:9 (five out of five
            // checked). Filled into this 240 × 360 frame, 62.5 % of the image width
            // is lost — on a poster with the title on it,
            // a crop remained without the beginning and end of the word.
            //
            // Same solution as for the channel icon in ``ChannelRow``, which is not filled
            // for the same reason: the image stays whole, and whatever
            // the frame offers beyond that is filled by the plate. A real 2:3 poster
            // sees none of this — it fills the frame anyway.
            //
            // The plate is the **first** of two layers. The second decides
            // at the frame already whether a level is wide
            // (``MediaItem/prefersWideArtwork(in:)``); this one stays
            // correct even then, because it applies exactly to the entries whose format
            // nobody has said anything about.
            RemoteImage(url: imageURL, contentMode: .fit, displaySize: size)
                .frame(width: size.width, height: size.height)
                .background(ColorRole.surfaceHigh.color)
                .clipShape(
                    RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous)
                )
                .overlay(alignment: .bottom) { progressBar }
                // **Top left watched and favourite, top right open episodes or the
                // rating** — as on the phone (2026-09-29).
                .overlay(alignment: .topLeading) { StatusBadges(item: item) }
                .overlay(alignment: .topTrailing) { PosterInfo(item: item) }
                // **Grey means: there is nothing to watch.** For the provider that was
                // checked, 19.3 % of series carry not a single episode, and a
                // colourful poster then promises something that is not behind it.
                //
                // Tinted instead of hidden, at the viewer's request and for the
                // same reason that ``MediaItem/hasNoEpisodes`` is optional:
                // the directory behind it is a snapshot. A title
                // that is wrongly grey can still be opened and
                // explains itself there; a title wrongly **gone**
                // could no longer be found by the viewer.
                //
                // Only `== true`, never `!= true`: "not checked" is not a statement.
                .grayscale(item.hasNoEpisodes == true ? 1 : 0)
                .focusHighlight(isFocused, accent: Color(palette, .bright))

            if showsTitle {
                label
            }
        }
    }

    /// Title — **and above it the series, when there is one.**
    ///
    /// **The finding from 2026-09-11, from search:** a search for "krimireihe" returned hits from the
    /// ARD Mediathek such as `Episode 41: Kreidespur (S04/E05)` and `Folge 51: Houglom rehe
    /// kauprind, macewand rehe (S04/E11)` — they belong to *Die Almwache* and *Ruhestandsrevier*, and
    /// that was stated nowhere. A result list without series titles is unreadable.
    ///
    /// **Above and not after.** Appended ("Folge 41 · Die Almwache") it
    /// drops off with two lines of title, and it is needed precisely for the long episode titles.
    ///
    /// **The height budget stays the same, and that is the reason for the line
    /// calculation below.** ``titledHeight`` reserves two ``captionLines``, and
    /// ``LayoutBudgetTests`` uses that to calculate the whole shelf height. A third line would have
    /// shifted every shelf; the series therefore takes the **first** of the two lines and
    /// the title keeps the second. Without a series the title gets both, as before.
    @ViewBuilder
    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row = item.parentTitle, !row.isEmpty, item.kind == .episode {
                Text(row)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .lineLimit(1)
            }
            Text(item.title)
                .font(TypeLevel.footer.font)
                .foregroundStyle(isFocused ? ColorRole.text.color : ColorRole.textMatt.color)
                .lineLimit(linesForTitle, reservesSpace: true)
        }
        .frame(width: size.width, alignment: .topLeading)
    }

    /// How many lines are left for the title.
    ///
    /// **Only for an episode does the series count.** For a series the server sends it
    /// empty on purpose, and for a film there is none — there two lines of title would be
    /// right and one too few.
    private var linesForTitle: Int {
        let hasSeries = item.kind == .episode && item.parentTitle?.isEmpty == false
        return hasSeries ? Self.captionLines - 1 : Self.captionLines
    }

    /// Progress sits on the image, not below it — that way what has been started stays
    /// recognisable at a glance, without an extra line.
    @ViewBuilder
    private var progressBar: some View {
        if let progress = item.progress, progress.isResumable {
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
}
