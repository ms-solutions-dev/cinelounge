import CoreGraphics
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// The calculations behind profile circle and title image — **what both devices calculate the same.**
///
/// The two views (`Features/Konten/ProfileCircle`, `FeaturesPhone/Bausteine/
/// Profilkreis`) still exist per device; converting them is a step of its own. What lies
/// here was already duplicated or differs only in numbers (report B finding 16): the question of whether
/// the image is in the app bundle, the band around the centre of the face and the values of the gradient.
public enum ProfileImage {

    /// Whether the app bundle carries this image — **`in: .main`, not the package bundle.**
    ///
    /// The avatars are in the app's image catalog; `Image("…")` in a package would look in the
    /// package's bundle and find nothing there. On the Mac where the checks
    /// run there is no `UIImage` — there the answer is always no.
    public static func inBundle(_ name: String) -> Bool {
        #if canImport(UIKit)
            UIImage(named: name, in: .main, with: nil) != nil
        #else
            false
        #endif
    }

    /// Where a wide band begins at the top in the square stretched to `width`, in points.
    ///
    /// The centre of the face `midpoint` (fraction of the edge) should lie in the middle of the band; the band
    /// must not extend beyond either the top or the bottom edge of the image. If the band is taller
    /// than the image, it begins at the top.
    public static func bandTop(midpoint: Double, width: CGFloat, height: CGFloat) -> CGFloat {
        let request = CGFloat(midpoint) * width - height / 2
        return min(max(request, 0), max(width - height, 0))
    }
}

/// The values of the title image gradient — **the same form, different numbers per device.**
///
/// Without a motif both devices lay a gradient from the profile colour into the ground, and with a
/// motif a darkening on top of it. The numbers differ because the surfaces do: On the
/// TV heading and names stand **on** the image (hence the ceiling), on the phone
/// the band lies above circle and name.
public struct ProfileGradient: Sendable, Equatable {
    /// Opacity of the profile colour at the top of the gradient without a motif.
    public let brandTop: Double
    /// Opacity of the ground at the bottom of the gradient without a motif.
    public let backgroundBottom: Double
    /// Opacity of the ceiling in the ground colour above a motif.
    public let opacity: Double
    /// Opacity of the ground at the lower end above a motif.
    public let imageBottom: Double
    /// What is drawn with when the brand colour is unknown.
    ///
    /// **Different and left that way** (2026-09-26): The TV takes the bright brand colour,
    /// so that a circle can be seen at three metres; the phone the raised surface, because
    /// the header without a known profile draws muted anyway.
    public let fallback: ColorRole

    public static func forItem(_ platform: UIPlatform) -> ProfileGradient {
        switch platform {
        case .tv:
            ProfileGradient(
                brandTop: 0.42, backgroundBottom: 1, opacity: 0.62, imageBottom: 0.85,
                fallback: .brandLight)
        case .phone:
            ProfileGradient(
                brandTop: 0.55, backgroundBottom: 0, opacity: 0, imageBottom: 0.75,
                fallback: .surfaceHigh)
        }
    }
}
