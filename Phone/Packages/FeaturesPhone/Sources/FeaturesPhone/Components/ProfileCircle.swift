import DesignSystemPhone
import ProfileKit
import SwiftUI

/// A profile's circle — **with a picture the crop around the face, otherwise the letter.**
///
/// **One view for all places** (AP49, step 3): the profile picture in the header, the
/// account rows, the header of the person sheet and the tiles of the picture chooser.
/// Before, each place drew its own letter circle; with the picture there would have
/// been four variants of the same crop, and the first to deviate shows a different face.
///
/// **The shape stays the circle, also for letters** (product decision of 2026-09-25,
/// concept addendum N1 in the TV repo). The picture is not inscribed but enlarged
/// around the face center: `scaleEffect` around the center, then the offset from
/// ``ProfileKit/AvatarMotif/offset(edge:)`` — **the same calculation as on the TV**, it
/// lives in the shared package and not here.
///
/// **The letter's colors come from the call site.** Without a known profile the header
/// keeps drawing on the muted surface, with a profile on its color; this view accepts
/// both and decides nothing about them.
struct ProfileCircle: View {

    /// **Picture or letter is decided by ``ProfileKit/AvatarMotif/appearance(avatar:imageExists:)``**
    /// — the same calculation on TV and phone (AP58 R2, finding P6); here it is only
    /// drawn.
    let letter: String
    let avatar: String?
    let edge: CGFloat
    let font: Font
    /// The letter's text color.
    let letterColor: Color
    /// The surface behind the letter.
    let surface: Color

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

    /// The motif, enlarged around the face center and clipped to the circle.
    ///
    /// **Enlarge first, then shift:** `scaleEffect` acts around the center of the square,
    /// ``ProfileKit/AvatarMotif/offset(edge:)`` is computed for exactly this order and keeps
    /// the circle inside the image.
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
            .accessibilityHidden(true)
    }
}

/// The whole motif as a header banner — **the cover image** (concept addendum N2).
///
/// **A band around the face, not the middle of the image.** The motif is square, the
/// banner wide; of a full-width square, a strip remains. If it sat in the middle of
/// the image, half of the head would fall out for almost all sixteen motifs — the
/// faces lie between 33 and 48 percent of the height. ``bandTop(midpoint:width:height:)``
/// therefore places the strip on the face center and clamps it to the image edges.
///
/// **Darkened toward the bottom**, because the circle and the name sit below.
/// **Without a motif a gradient in the profile color** — the spot does not stay empty,
/// and whoever has not chosen a picture still sees whose sheet this is.
struct ProfileTitleImage: View {

    let avatar: String?
    /// The profile's color tag — its name, resolved via ``DesignSystemPhone/ProfileColor``.
    let color: Profile.ColorTag
    let height: CGFloat

    /// Where the band starts at the top in the square stretched to `width` — **in points.**
    ///
    /// The face center `midpoint` (a fraction of the edge) should lie in the middle of the
    /// band; the band must not extend beyond the upper or the lower image edge. If the
    /// banner is taller than the image (only at very narrow widths), it starts at the top.
    static func bandTop(midpoint: Double, width: CGFloat, height: CGFloat) -> CGFloat {
        let request = CGFloat(midpoint) * width - height / 2
        return min(max(request, 0), max(width - height, 0))
    }

    var body: some View {
        switch AvatarMotif.appearance(avatar: avatar) {
        case .image(let motif):
            GeometryReader { space in
                let width = max(space.size.width, height)
                Image(motif.name, bundle: .main)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: width)
                    .offset(
                        y: -Self.bandTop(midpoint: motif.midpoint.y, width: width, height: height)
                    )
                    .frame(width: space.size.width, height: height, alignment: .top)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            colors: [.clear, ColorRole.reason.color.opacity(0.75)],
                            startPoint: .center, endPoint: .bottom)
                    }
            }
            .frame(height: height)
            .accessibilityHidden(true)
        case .letter:
            LinearGradient(
                colors: [
                    (ProfileColor.tag(color.rawValue) ?? ColorRole.surfaceHigh.color).opacity(0.55),
                    ColorRole.reason.color.opacity(0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: height)
            .accessibilityHidden(true)
        }
    }
}
