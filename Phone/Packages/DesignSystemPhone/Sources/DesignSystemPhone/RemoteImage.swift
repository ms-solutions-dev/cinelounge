import CoreGraphics
import SwiftUI

/// An image from the network — with placeholder, cancellation and series color.
///
/// **Cancellation is the point.** A shelf shows ten posters, and every page turn pulls in new
/// ones; whoever does not cancel the old ones loads a hundred images when paging quickly,
/// ninety of which nobody sees. Through a tunnel with a measured 0.31 Mbit/s that is the
/// difference between "works" and "does not work". `task(id:)` handles it: SwiftUI cancels
/// the task as soon as the view disappears or the source changes.
public struct RemoteImage: View {

    private let source: URL?
    private let longestEdge: CGFloat
    private let withColor: Bool
    private let isFilling: Bool
    private let alignment: Alignment
    private let placeholder: String?
    private let onColorFound: (@MainActor (Double, Double) -> Void)?

    @State private var image: CGImage?
    @ScaledMetric private var scaleProbe: CGFloat = 1

    /// - Parameters:
    ///   - source: where from
    ///   - laengsteKante: the **longer** edge of the drawn image, in points.
    ///
    ///     **The finding of 2026-09-05: the header area was visibly pixelated.** The parameter was
    ///     called `edge`, and three callers gave it the **short** side: the header image its
    ///     height (200), the header space its (300), the title logo its (44).
    ///     `kCGImageSourceThumbnailMaxPixelSize`, however, caps the **longest** side — a 16 : 9
    ///     image was thereby built at 640 pixels wide and drawn at 1059.
    ///
    ///     On screen that looked like an image requested too small, and the address was fine: the
    ///     server delivered 1200 pixels, they were only thrown away during construction. The name
    ///     now carries the rule, so that the next caller does not have to guess it again.
    ///   - mitFarbe: whether the series color is needed
    ///   - fuellend: whether the frame is filled and cropped for it. Yes for posters and
    ///     background images — there the frame is the measure. No for a **title logo**: it is a
    ///     cut-out image with transparency and comes in every aspect ratio; brought in filling,
    ///     it would crop itself off.
    ///   - ausrichtung: where the image sits when it grows beyond the frame. **The anchored edge
    ///     is the one that stays** — the cropping happens opposite. A background image is
    ///     anchored at the top: the overflow then falls away at the bottom, where the gradient
    ///     for the text lies anyway, instead of cutting off the subject's head.
    ///   - platzhalter: SF Symbol that shows while or if no image comes. Set it only where the
    ///     empty area says something wrong — a person circle without a face otherwise looks like
    ///     an error and not like a missing photo.
    ///   - farbeGefunden: called as soon as it is determined
    public init(
        source: URL?,
        longestEdge: CGFloat,
        withColor: Bool = true,
        isFilling: Bool = true,
        alignment: Alignment = .center,
        placeholder: String? = nil,
        onColorFound: (@MainActor (Double, Double) -> Void)? = nil
    ) {
        self.source = source
        self.longestEdge = longestEdge
        self.withColor = withColor
        self.isFilling = isFilling
        self.alignment = alignment
        self.placeholder = placeholder
        self.onColorFound = onColorFound
    }

    public var body: some View {
        // **The image never determines its size itself.** `Color.clear` is the measurer: it is
        // stretchable at will and has a tiny ideal size, and an `overlay` does not affect the
        // layout. Without this trick a header image with 900 pixels proposes its natural width — and
        // because in a `ZStack` the widest child determines the width, it pushes the whole page to
        // the left out of view. `frame(maxWidth:)` does not help against that: it clips the
        // rendering and does not lower the ideal size.
        //
        // Seen twice in the simulator before the cause was established — both times everything
        // looked right in the source code.
        Color.clear
            .overlay(alignment: alignment) {
                if let image {
                    let drawn = Image(decorative: image, scale: 1).resizable()
                    if isFilling {
                        drawn.scaledToFill()
                    } else {
                        drawn.scaledToFit()
                    }
                } else if let placeholder {
                    // **A person, not a gray circle** (user finding from the TV, 2026-08-22). For many actors the
                    // media server has no image, and the film database does not find every name — the circle
                    // then stays empty, and what stands in it should at least hint at the right thing.
                    ZStack {
                        ColorRole.surface.color
                        Image(systemName: placeholder)
                            // festeschrift: **Stays fixed, and that is right** (AP5): this size depends on the tile and
                            // not on the type — the symbol fills the area where an image is missing. Growing with the
                            // system type size would mean it protrudes beyond its own tile at large type.
                            .font(.system(size: longestEdge * 0.42, weight: .light))
                            .foregroundStyle(ColorRole.textQuiet.color)
                    }
                } else if isFilling {
                    // No spinner: a shelf full of spinning spinners is more restless than a calm surface, and
                    // the images arrive within fractions of a second.
                    ColorRole.surface.color
                } else {
                    // A cut-out title logo has no frame that could be filled — a gray area would stand where
                    // nothing should stand.
                    Color.clear
                }
            }
            .clipped()
            .task(id: source) {
                guard let source else { return }
                let points = ImageSizes.pixels(forItem: longestEdge, reference: ImageSizes.reference)
                guard
                    let result = await ImageLoader.shared.load(source, pixels: points, withColor: withColor)
                else { return }
                image = result.image
                if let color = result.color {
                    onColorFound?(color.hue, color.saturation)
                }
            }
    }
}
