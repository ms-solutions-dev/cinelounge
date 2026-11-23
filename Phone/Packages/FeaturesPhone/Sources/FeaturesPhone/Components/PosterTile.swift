import DesignSystemPhone
import Flows
import RatingsKit
import SwiftUI

/// A poster, 110 × 165 — aspect ratio 2 : 3, **or 16 : 9 if the layer says so.**
///
/// **Two layers, as on the TV** (finding of 2026-09-07, on the device: their posters are
/// not portrait but landscape … on the phone they are still rendered as portrait).
/// ``wideFrame`` is the first — the layer chooses its format so the rows line up
/// —, ``isFilling`` the second: An image that does not fit the frame is fitted and not
/// cropped. The second carries exactly the cases the first cannot decide, namely a
/// mixed layer.
///
/// **With a permanent caption.** On the TV a card shows its title only once focus is
/// on it; 133 places in the TV code depend on that. On the phone this state does not
/// exist. Every tile always carries its caption — that makes the tile taller and the
/// shelf airier, and it is no loss: Focus there was a means against too little space,
/// not a design device.
struct PosterTile: View {

    let content: TileContent
    @Environment(AnimeScores.self) private var animeRatings: AnimeScores?

    /// How wide the tile is.
    ///
    /// Fixed in the shelf (110 points), because there it determines how many tiles are
    /// teased side by side. In the grid it is computed from the screen width — see
    /// ``JellyfinRaster/tileWidth(at:)``.
    var width: CGFloat = MetricsBoard.phone.poster.width

    /// Whether the **frame** is wide (16 : 9) rather than tall (2 : 3).
    ///
    /// **The layer sets it, not the tile** — even when `content.wide` says something
    /// else. A grid of alternately tall and wide cells has no rows left for the eye to run
    /// along; the rule for this is at ``TileContent/isWideShelf(_:)``. What saves a
    /// single image that does not fit the frame is the second layer underneath: It is then
    /// fitted instead of filled.
    var wideFrame = false

    /// Computed from the width — 2 : 3, or 16 : 9 in the wide frame.
    private var height: CGFloat {
        let metrics = wideFrame ? MetricsBoard.phone.episode : MetricsBoard.phone.poster
        return (width * metrics.height / metrics.width).rounded()
    }

    /// Whether the image may fill the frame — **only if both have the same orientation.**
    ///
    /// If they do not match, it is fitted: A 16 : 9 image in a 2 : 3 frame would lose 62.5 %
    /// of its width when filled, a 2 : 3 poster in a 16 : 9 frame two thirds of its height.
    /// An unchecked image (`nil`) counts as tall — that is the frame in which the app draws
    /// everything anyway, and so in the poster frame everything stays as it was.
    private var isFilling: Bool { (content.wide == true) == wideFrame }

    @State private var color: (hue: Double, saturation: Double)?

    var body: some View {
        mainContent
            .task(id: content.anime) {
                guard let request = content.anime, content.counter == nil else { return }
                animeRatings?.query(request)
            }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Height computed from the width, not proposed from the aspect ratio.**
            // `aspectRatio(.fit)` follows what the surrounding cell offers — and in a grid, a cell
            // with a two-line caption offers something different from one with a single line.
            // The posters therefore did not line up.
            imageSurface
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius))
                .edgeGlow(color, radius: MetricsBoard.phone.imageRadius)

            // **The caption is always there, even without an image.**
            //
            // Seen on 2026-09-06 in the portal catalog: "Wuweise'm Liatdouza" stood large in the
            // empty tile and small underneath. The first reflex was to omit it without an image
            // — and that traded one defect for a worse one: The area truncates long titles
            // ("A Piabriam Brostakuk Bliazilon Weprukror: Raising…"), and then the truncated one was the
            // **only** one. A title you cannot read is worse than one you read twice.
            //
            // ``EmptyTile`` solves the duplication instead: There the title now appears as the
            // **motif** — at most three lines, cleanly shortened —, here as a label.
            // That is the form the design draws: a cover with a name on it and the full title
            // underneath.
            Text(verbatim: content.title)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(2)
                .padding(.top, 7)

            if let beside = content.beside {
                Text(verbatim: beside)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .lineLimit(1)
                    .padding(.top, 1)
            }
        }
        // **Top-aligned, not centered.** The second part of the same finding from 2026-09-05:
        // Equally sized images still did not line up. A grid row is as tall as its tallest
        // cell — and a two-line caption makes a cell taller. Without this line SwiftUI
        // centers the shorter ones in it, and the posters shift against each other by half a
        // line of text.
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // **The hit area is the frame and not what is drawn** (finding of 2026-09-07, on the
        // device: in Continue Watching, when tapping a poster you have to hit its left edge …
        // as soon as you are slightly to the right on the poster, the neighboring poster is
        // selected).
        //
        // **Measured against the hit rectangles of the running screen:** In the Continue
        // Watching shelf they overlapped — "Greswotrio" from 731 to 840, "Hisvei Weprir" starting at
        // **761** and **292** points wide, so right into it. Whoever taps on the right of the
        // one tile hits the area of the next, because the one drawn later is on top.
        //
        // **A `Button` with its own label derives its hit area from what the label actually
        // draws** — not from its frame. Two lines of text and a fitted image together give
        // something different from 110 × 207. The one line says it explicitly, and it lives
        // here instead of at the call sites: The tile knows how big it is; whoever uses it
        // should not have to know.
        .contentShape(Rectangle())
        // **`.combine` and not `.ignore`.** Until 2026-09-06 the tile threw away everything its
        // children convey: Rating, progress, watched checkmark, counter and badges each have
        // their own correct label — and `.ignore` deletes them and leaves only the title.
        // A viewer using a screen reader therefore heard the same thing from two tiles with
        // the same name, although one of them is half watched.
        .accessibilityElement(children: .combine)
        // **The title stays for the screen reader** — even when it appears only in the area.
        // `EmptyTile` draws it, and drawn text helps only the eye.
        .accessibilityLabel(
            Text(verbatim: [content.title, content.beside].compactMap { $0 }.joined(separator: ", ")))
    }

    @ViewBuilder
    private var imageSurface: some View {
        ZStack(alignment: .topTrailing) {
            if content.image == nil {
                EmptyTile(title: content.title, radius: MetricsBoard.phone.imageRadius)
            } else {
                // **A wide image is fitted and not filled** (finding of 2026-09-07, on the device).
                // A portal delivers 640 × 360; filled into this 110 × 165 frame, 62.5 % of the width
                // falls away, and for an image with the title on it, a crop remained with neither the
                // beginning nor the end of the word. Fitted, it stays whole, and whatever the frame
                // offers beyond that is filled by the plate — the same solution as `PosterCard` on the
                // TV, and for the same reason.
                //
                // **A real poster sees none of this:** It fills the 2 : 3 frame anyway. That is why
                // this layer is also right where the layer is mixed and ``TileContent/isWideShelf(_:)``
                // therefore stays tall.
                //
                // **The longest edge of a widescreen image is its width.** It decides what size to
                // downscale to when decoding; computed with the height, an image would be requested
                // that is smaller than its frame.
                RemoteImage(
                    source: content.image,
                    longestEdge: (content.wide == true || wideFrame) ? width : height,
                    isFilling: isFilling
                ) { audio, saettigung in
                    color = (audio, saettigung)
                }
                // **The plate under the fitted image.** Without it the image would sit on the page's
                // base color, and the frame could no longer be recognized as a card — exactly why
                // `PosterCard` on the TV has `surfaceRaised`.
                .background(ColorRole.surfaceHigh.color)
            }

            // The top-right corner carries exactly one piece of information, and the order is a
            // ranking: Whoever is in the middle of a series wants to know how many episodes are
            // still open; whoever is not, what others think of it.
            // **Watched and favorite sit at the top left since 2026-09-29**
            // (``StatusMarks``) — as on the TV.
            // **For anime the MAL rating** (AP68), requested as soon as the tile is visible;
            // until it arrives, the server's is shown.
            // **Below it the language corner** (AP84): "EN" when there is no German audio.
            VStack(alignment: .trailing, spacing: 4) {
                if let counter = content.counter {
                    CounterBadge(text: counter)
                } else if let mal = content.anime.flatMap({ animeRatings?.note($0) }),
                    let rating = Rating.fromTen(mal, .mal)
                {
                    RatingBadge(rating: rating)
                } else if let rating = content.rating {
                    RatingBadge(rating: rating)
                }
                if let audio = content.audio {
                    ToneBadge(badge: audio)
                }
            }
            .padding(6)

            StatusMarks(seen: content.seen, favorite: content.favorite)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !content.marks.isEmpty {
                ImageMarkers(marks: content.marks)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if let progress = content.progress {
                ProgressBar(portion: progress)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}
