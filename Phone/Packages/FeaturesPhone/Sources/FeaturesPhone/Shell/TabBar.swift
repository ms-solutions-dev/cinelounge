import DesignSystemPhone
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// The appearance of the tab bar.
///
/// **The native bar is built, not a custom one.** The draft draws it itself,
/// because HTML can do nothing else; here that would be a step backwards. The system bar brings
/// accessibility, Dynamic Type, the right safe-area insets and the gesture "tapping
/// the selected tab scrolls to the top" — all things you rebuild and then have
/// worse.
///
/// The material under the bar comes by itself. The two differences that make the
/// selected tab recognizable **without color** do not:
///
/// * **The shape.** iOS fills *every* tab icon by default, not just the
///   selected one — seen in the simulator, not assumed. Then color alone distinguishes,
///   and `rotHell` against `textQuiet` are 1.02 : 1 under deuteranopia. `ShellView`
///   therefore sets `symbolVariants` to `.none` and chooses the fill itself.
/// * **The semibold label**, which this file adds afterwards.
///
/// **What of this arrives in the iPad sidebar** (AP7, 2026-09-24, since
/// ``ShellView`` sets `.sidebarAdaptable`): **the shape yes, the label no.**
/// The sidebar is not a `UITabBar` but a list that the
/// `UITabBarController` builds itself; `UITabBarAppearance` does not reach it — according to the UIKit header (`UITabBarControllerSidebar.h`)
/// only a delegate with a content configuration styles its rows, and SwiftUI does not pass that through.
/// The selected fill, on the other hand, hangs on the `Tab` icon and travels with it. **That is no loss:**
/// the sidebar backs the selected row with a surface — a difference
/// without color, exactly what the semibold type has to achieve in the bar.
///
/// **On the phone and in the half-width window (both compact) this file works as
/// before** — there the bar is an ordinary `UITabBar` at the bottom. **What remains open
/// is the collapsed bar at the top on iPad:** it is a drawing of its own by the system, and
/// whether it reads `stackedLayoutAppearance` can only be seen in the simulator.
@MainActor
public enum TabBar {

    /// Sets the appearance. Once at launch, not per view.
    ///
    /// `@MainActor`, because `UITabBar.appearance()` is: without the annotation the
    /// compiler reports twelve warnings under strict concurrency for a single
    /// error — and `check.sh` counts every warning as a failure.
    public static func setUp() {
        #if canImport(UIKit)
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()

            // **Scaling, not fixed.** Until 2026-09-05 this was `systemFont(ofSize: 10)`
            // without `UIFontMetrics` — the label then stayed ten points tall at every
            // type size, while the whole rest of the screen scaled with it. In a
            // project that otherwise keeps measurements as proportions, this was the one place that fell
            // out of line.
            let metrics = UIFontMetrics(forTextStyle: .caption2)
            let chosen = appearance.stackedLayoutAppearance.selected
            chosen.titleTextAttributes = [
                .font: metrics.scaledFont(for: .systemFont(ofSize: 10, weight: .semibold))
            ]
            let resting = appearance.stackedLayoutAppearance.normal
            resting.titleTextAttributes = [
                .font: metrics.scaledFont(for: .systemFont(ofSize: 10, weight: .regular))
            ]

            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        #endif
    }
}
