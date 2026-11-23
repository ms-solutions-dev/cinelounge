import Core
import DesignSystemPhone
import SwiftUI

/// The Channels ↔ Sports switch, **at the top** of the Live tab (decision 27, C15: Sports
/// variant 1 — on the TV a separate entry of the sidebar, here this switch).
///
/// **Why this switch exists at all.** On the TV the Live area has over
/// 300 focusable elements — 23 sports plus four buttons per channel group across 79
/// groups. At 393 points of width that is impossible in this form. Two modes
/// with a switch in between are the answer: each mode shows one
/// list and nothing else.
///
/// **The numbers are shown, and they are the visible ones.** Whoever does not know what awaits them on
/// the other side presses once and goes back. Exactly here the draft had
/// the wrong number twice: 5,389 is the provider's raw catalog, the list below
/// is 2,055 entries long (finding M2 of 2026-09-05). A counter above a list counts the
/// list.
///
/// - Note: AP17 builds the Sports page. Until then the switch is there and operable —
///   that is the more honest interim state than a switch that appears only later and
///   pushes the list below it down.
struct LiveSegment: View {

    let channels: Int
    let sport: Int
    @Binding var isSportSelected: Bool

    var body: some View {
        SegmentPicker(
            links: label("common.channels", channels),
            right: label("tab.sport", sport),
            isRightSelected: $isSportSelected
        )
        // **At the top under the title and no longer above the tab bar** (C15, 2026-09-26):
        // there it was an edge through which the list scrolled; here it is the first choice
        // of the tab, before the list begins.
        .padding(.top, Metrics.targetSpacing)
    }

    private func label(_ key: String, _ count: Int) -> String {
        let word = AppLanguageSetting.text(String.LocalizationValue(key))
        guard count > 0 else { return word }
        return "\(word) \(count.formatted(.number.grouping(.automatic)))"
    }
}
