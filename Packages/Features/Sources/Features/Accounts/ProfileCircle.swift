import DesignSystem
import ProfileKit
import SwiftUI

/// The circle of a profile — **with a picture the crop around the face, otherwise the letter.**
///
/// **One view for all places** (AP49): "Who is watching?", the profile row, the preview
/// in ``ProfileSheet`` and the tiles of the picture choice. Before, every place drew its
/// letter circle itself; with the picture that would have become four versions of the same crop,
/// and the first to deviate shows a different face than the other three.
///
/// **The shape remains the circle, also for letters** (product decision of
/// 2026-09-25, concept addendum N1). The picture is not inscribed but enlarged around the
/// face center: `scaleEffect` around the center, then the offset from
/// ``ProfileKit/AvatarMotif/offset(edge:)`` — the same computation the phone uses.
///
/// **The colors of the letter circle come from the call site**, because there they were already
/// different and are meant to stay so: In "Who is watching?" the circle turns light in focus,
/// in the profile row the whole row turns light and the circle dark. This view accepts
/// both and changes nothing about it.
struct ProfileCircle: View {

    /// **Picture or letter is decided by ``ProfileKit/AvatarMotif/appearance(avatar:imageExists:)``**
    /// — the same computation on TV and phone (AP58 R2, finding P6); here it is only
    /// drawn.
    let letter: String
    let avatar: String?
    let edge: CGFloat
    let font: Font
    /// The text color of the letter — as the call site sets it today.
    let letterColor: Color
    /// The surface behind the letter, **already swapped in focus.**
    let surface: Color
    /// The frame around a picture — `nil` means none.
    ///
    /// **With a picture a light frame takes the place of the color swap.** The
    /// letter circle shows focus by its surface turning light; a picture has no
    /// surface that could be swapped, and replacing it with a light disc in focus
    /// would mean taking the face away exactly when one looks at it. The frame
    /// says the same — "this one is meant" — and leaves the picture in place. **Whether it carries
    /// from three meters is a device question** (concept 9 and N4, stage 4); it is deliberately
    /// a parameter, so that the finding on the TV changes one line and not four.
    let frame: Color?

    var body: some View {
        switch AvatarMotif.appearance(avatar: avatar) {
        case .image(let motif):
            slice(motif)
        case .letter:
            Text(verbatim: letter)
                .font(font)
                .foregroundStyle(letterColor)
                .frame(width: edge, height: edge)
                .background(surface, in: Circle())
        }
    }

    /// The motif, enlarged around the face center and clipped in the circle.
    ///
    /// **First enlarge, then shift:** `scaleEffect` acts around the center of the square,
    /// ``ProfileKit/AvatarMotif/offset(edge:)`` is computed for exactly this order
    /// and keeps the circle within the picture.
    private func slice(_ motif: AvatarMotif) -> some View {
        let offset = motif.offset(edge: Double(edge))
        return Image(motif.name, bundle: .main)
            .resizable()
            .scaledToFill()
            .frame(width: edge, height: edge)
            .scaleEffect(motif.effectiveZoom)
            .offset(x: offset.x, y: offset.y)
            .frame(width: edge, height: edge)
            .clipShape(Circle())
            .overlay {
                if let frame {
                    Circle().strokeBorder(frame, lineWidth: max(4, edge * 0.035))
                }
            }
            .accessibilityHidden(true)
    }
}

/// The whole motif as background — **the title image** (concept addendum N2).
///
/// **Darkened, because it is read over:** In "Who is watching?" heading and
/// names stand on the picture, and the motifs are light, colorful and full of detail. A cover
/// in the base color and a gradient downwards make a mood of it instead of a
/// second statement.
///
/// **Without a motif a gradient in the profile color** — the same place does not stay empty, and
/// whoever has chosen no picture still sees whose screen this is.
struct ProfileTitleImage: View {

    let avatar: String?
    let color: Profile.ColorTag
    /// How strongly the cover lies over the picture — `0…1`.
    var opacity: Double = 0.62

    var body: some View {
        switch AvatarMotif.appearance(avatar: avatar) {
        case .image(let motif):
            // **The picture lies on an empty surface and is not itself in the layout:**
            // `.scaledToFill()` without a frame reports the larger edge as its size and would push
            // the neighbor away. This way the space determines the size, the picture merely fills it.
            Color.clear
                .overlay {
                    Image(motif.name, bundle: .main)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .overlay {
                    ZStack {
                        ColorRole.reason.color.opacity(opacity)
                        LinearGradient(
                            colors: [.clear, ColorRole.reason.color.opacity(0.85)],
                            startPoint: .center, endPoint: .bottom)
                    }
                }
                .accessibilityHidden(true)
        case .letter:
            LinearGradient(
                colors: [
                    ProfileColor.tag(color.rawValue).opacity(0.42), ColorRole.reason.color,
                ],
                startPoint: .top, endPoint: .bottom
            )
            .accessibilityHidden(true)
        }
    }
}
