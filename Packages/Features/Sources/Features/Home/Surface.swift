import CoreGraphics
import DesignSystem
import ProfileKit

/// **The form factor on the TV** — since G3 (2026-09-26) the rules live shared in
/// ``Styling/Surface``, so that the phone gets the same child UI
/// (finding B3). All that remains here is how the TV reads it from its profile and measures it with
/// its ``Styling/MetricsBoard/tv``.
///
/// **It does not invent the ratings, and not the scope either** (AP58 R1, K1). What
/// a child may see and reach is decided by ``ParentalControls/ChildScope``; this
/// form factor carries only how it looks: poster size, wide images, extras.
extension Surface {

    /// The form factor for this profile — **without a profile, the usual one.**
    nonisolated static func forItem(_ profile: Profile?) -> Surface {
        forItem(kind: profile?.kind == .kind)
    }

    /// The size of a poster on the TV in this form factor.
    nonisolated var posterSize: CGSize { posterSize(to: .tv) }
}
