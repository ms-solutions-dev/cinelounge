import DesignSystemPhone
import SwiftUI

/// The header area: an **inset, colored box** that you page through.
///
/// **Rounded and not edge to edge.** Edge to edge is the default of the big providers; on
/// the device's own screen the round surface stands out as a card from the background
/// instead of running out into it. The radius is the same as with the tiles — two
/// different roundings on one screen read as indecision.
///
/// **The box is colored out of the image**, not from the palette: it carries the same edge
/// light as every tile, only larger. It thereby visibly belongs to the title it shows.
///
/// **The image keeps its aspect ratio.** An earlier attempt had it fill the whole box and
/// lost 41 percent of the width in the process — for a background image that is half the
/// motif. Now it sits at the top in 16 : 9, and the text stands below on a surface of its
/// own. That is also the space that description, attributes and the play button need: over
/// the image they would lie on the motif, and two lines of blurb on a movie image are two
/// lines nobody reads.
///
/// **The play button is in the box** and not in a floating bar at the bottom edge. That
/// puts it above the thumb limit of 560 points, and that is defensible here: the limit
/// applies to what is pressed **often**. On Home that is paging and tapping a tile — the
/// header button is a shortcut for a deliberate start, and for that the second hand may
/// join in. A button at the bottom edge would be more comfortable and would in return no
/// longer answer the question of what it plays.
/// The finding of 2026-09-05: it was unclear what "Ansehen" (Watch) refers to on Home, although
/// on a detail view it would be understood. The finding was right — the bar stayed in place
/// while the box had long since paged on three shelves further up, and nobody could say
/// what it would play. In the box it is unambiguous, and with it the button disappears from
/// the picture.
///
/// **It measures itself by the word and not by the box.** Stretched across the full width,
/// the button read like the submit button of a form; beside it there is room, and room
/// beside a button is the difference between a card and a mask.
struct HeaderImage: View {

    /// **Less text in the children's interface** (G3, finding B3): title and a press are
    /// enough — without meta line, rating and synopsis (``Styling/Surface/showsExtras``).
    @Environment(\.surface) private var surface

    let content: HeroContent?

    /// What a press on the box does — **open, not play.**
    ///
    /// **Product decision of 2026-09-05:** remove the play button here and make the hero tappable —
    /// the button on Home is superfluous, since nothing is played from there anyway. The
    /// objection was already in the first question about this card (what the "Ansehen" button
    /// stands for here) and was the same both times: on an overview you pick, you do not start.
    ///
    /// **And a button that does something different from its box is a second target inside the
    /// first.** Anyone who presses the box wants to see the title; anyone who hits the button
    /// would have started the film — at 353 points of width both lie under the same thumb. One
    /// target, one meaning.
    let open: (TileContent) -> Void

    /// The height of the image area.
    ///
    /// **300 since 2026-09-06, before 200** (direction B to K4). The draft draws the box with
    /// 300 points of image and 140 points of text — 440 for a recommendation —, and what was
    /// built was 200 + 104 = 304. The box was drawn for "what is new" and carried "what have I
    /// started"; since it again does the first, the draft's height applies again too.
    ///
    /// At the 353 points that remain between the margins on an iPhone, a 16 : 9 image is
    /// 198.6 points high — 300 thus shows more than the format provides and crops at the top
    /// and bottom. That is intended: a background image is a section, and the anchor is at the
    /// top because on a movie image that is where the motif is.
    static let imageHeight: CGFloat = 300

    /// What the text block is **at least** high.
    ///
    /// **A lower limit and not a height** — that is the difference from 2026-09-06. Before, a fixed
    /// number stood here and the box reported it as its height: what did not fit was squeezed
    /// by `minimumScaleFactor` — differently strongly for each hero, depending on how long its
    /// title is. Now the box grows with its content, and this number only ensures that it does
    /// not collapse in on itself with a short blurb.
    ///
    /// Growing with the type size, because the block carries four lines: at the largest
    /// setting a fixed 165 points was enough for half of them.
    @ScaledMetric private var minTextHeight: CGFloat = 140

    /// The size class in which the box stands — **it alone determines the requested image
    /// size.**
    ///
    /// **``imageHeight`` stays at 300 and explicitly does not move with it.** The box shows the
    /// same section at the same height on every device; on the iPad it is only wider, and a
    /// 16 : 9 image crops correspondingly less there. All that changes is how many pixels are
    /// fetched for it — see ``MetricClass/headerBox(_:)``.
    @Environment(\.horizontalSizeClass) private var width

    @State private var color: (hue: Double, saturation: Double)?

    /// The height below which the box does not go. The **actual** one it reports when drawing
    /// via ``BoxHeight``.
    var minHeight: CGFloat { Self.imageHeight + minTextHeight }

    var body: some View {
        Button {
            if let tile = content?.tile { open(tile) }
        } label: {
            card
        }
        .buttonStyle(.plain)
        .disabled(content == nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            imageSurface
            textArea
        }
        // **`minHeight` and not `height`** — the box grows with its content instead of squeezing
        // it. What comes out of that it reports upward; see ``BoxHeight``.
        .frame(minHeight: minHeight, alignment: .top)
        .background {
            GeometryReader { surface in
                Color.clear.preference(key: BoxHeight.self, value: surface.size.height)
            }
        }
        .background(ColorRole.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius, style: .continuous))
        .edgeGlow(color, radius: MetricsBoard.phone.imageRadius)
        .animation(Motion.expand, value: content?.id)
    }

    private var imageSurface: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = content?.tile.backdrop ?? content?.tile.image {
                // **The width, not the height** — see ``RemoteImage``. The box is as wide as the screen
                // between the margins; at 16 : 9 the height is the short side and caps the build far too
                // early.
                // **And "the screen between the margins" is not a phone screen on the iPad**
                // (2026-09-23). The fixed 400 came from the widest phone; on an iPad Pro 13″ the same box
                // is drawn about 992 points wide and was thus the one place where the big device looked
                // worse than the small one.
                RemoteImage(
                    source: image, longestEdge: MetricClass.headerBox(width),
                    alignment: .top
                ) { audio, saettigung in
                    color = (audio, saettigung)
                }
            } else {
                ColorRole.surfaceHigh.color
            }

            // The gradient carries the logo and at the same time takes the hardness from the edge to
            // the text block. Without it, a bright movie image lies abruptly on a dark background.
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .init(x: 0.5, y: 0.45), endPoint: .bottom)

            if let content, content.logo != nil {
                Wordmark(image: content.logo, title: content.tile.title)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(height: Self.imageHeight)
        .clipped()
    }

    @ViewBuilder
    private var textArea: some View {
        if let content {
            VStack(alignment: .leading, spacing: 6) {
                // The title appears here only if the image does not already carry it. Both at once would
                // be the same name twice one below the other.
                if content.logo == nil {
                    // **Two lines, and not additionally shrunk** (AP4). Here stood
                    // `minimumScaleFactor(0.75)` **and** `lineLimit(1)`: a title was first made smaller and
                    // then cut off, and which of the two the viewer saw depended solely on its length.
                    // "Skefijiot - Kidreplias Rufrotbe" ended up at 75 % font size **and** with an ellipsis —
                    // so twice as bad instead of once.
                    //
                    // **The title is the content here and not the label.** A header image without a logo has
                    // exactly one job: to say what this is. Two lines cost the space that the meta line below
                    // leaves free anyway; a shrunken line costs the legibility for which the system font size
                    // was set.
                    Text(verbatim: content.tile.title)
                        .font(TypeLevel.section.font)
                        .lineLimit(2)
                        .foregroundStyle(ColorRole.text.color)
                }

                if surface.showsExtras {
                    HStack(spacing: Metrics.targetSpacing) {
                        MetaRow(split: content.attributes)
                        if let rating = content.rating {
                            RatingBadge(rating: rating, conspicuous: true)
                        }
                    }
                }

                if surface.showsExtras, let description = content.description, !description.isEmpty {
                    Text(verbatim: description)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(Metrics.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// How high the header box has **actually** become.
///
/// **The finding this fixes:** until 2026-09-06. ``Pager`` got a fixed height from a
/// ``HeaderImage`` that was created for that purpose alone and **was never in the
/// hierarchy**. So it could measure nothing — the number was a default posing as a
/// measurement. What did not fit was squeezed.
///
/// **The largest is taken and not the last.** All pages of the box stand side by side in
/// the same `TabView` and must be equally high; the longest description determines the
/// height, otherwise the box jumps when paging.
struct BoxHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
