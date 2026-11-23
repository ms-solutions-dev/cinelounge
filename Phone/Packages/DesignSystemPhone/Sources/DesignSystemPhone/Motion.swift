import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Timing curves for transitions.
///
/// One place, so that a sheet, a tab switch and an expanding section share the same
/// handwriting. `reduceMotion` is taken into account here and not forgotten at forty call
/// sites.
@MainActor
public enum Motion {

    /// A sheet opens or closes.
    public static var sheet: Animation { muted(.spring(duration: 0.34, bounce: 0.12)) }

    /// The tab switches.
    public static var tabChange: Animation { muted(.easeOut(duration: 0.18)) }

    /// A section expands.
    public static var expand: Animation { muted(.easeInOut(duration: 0.22)) }

    /// A state changes its fill — Watched, Favorite, chip.
    public static var stateChange: Animation { muted(.easeOut(duration: 0.12)) }

    /// Replaces a motion with a short fade-in when the system asks for it.
    ///
    /// Not with *nothing*: a change without any transition looks like a jump, and "Reduce
    /// Motion" means less motion, not no feedback at all.
    private static func muted(_ curve: Animation) -> Animation {
        #if canImport(UIKit)
            UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.1) : curve
        #else
            curve
        #endif
    }
}
