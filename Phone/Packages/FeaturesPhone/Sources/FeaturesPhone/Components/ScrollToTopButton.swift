import DesignSystemPhone
import SwiftUI

/// The way back to the top of a long page.
///
/// **Why it is needed** (user finding 2026-09-05: with large content, where you scroll far,
/// there should be a way to get back to the header faster).
/// A series with fifty episodes is a good fifteen screen heights long at 393 points
/// wide; whoever is at the bottom would otherwise swipe fifteen times.
///
/// **iOS already has a gesture for this — it is not enough here.** Tapping the status
/// bar scrolls to the top, but only if exactly one scroll view claims it, and it is
/// invisible: Whoever does not know it never finds it. The button is the visible way
/// alongside it, not its replacement.
///
/// **It appears only when there is something to fetch**, and disappears again at the
/// top. A button that is already there on the first screen height covers content to
/// offer a journey nobody has started.
///
/// **And it sits above the floating bar, not inside it.** In the bar it would sit next
/// to the play button and look like its accessory — the same confusion that moved the
/// playback target out of the bar into the header.
struct ScrollToTopButton: View {

    let isVisible: Bool
    let action: () -> Void

    /// From this scroll offset it appears — just under one screen height.
    ///
    /// **Not zero and not three heights.** At zero it would be there immediately; at three
    /// it would only be visible once you had needed it long ago. One screen height is the
    /// distance at which the header is out of view — and from there swiping back becomes
    /// work.
    static let fromHeight: CGFloat = 700

    var body: some View {
        Button(action: action) {
            Image(systemName: Glyph.upward.name)
                .iconSize(15, weight: .semibold)
        }
        .buttonStyle(.rounded)
        .accessibilityLabel(Text(app: "action.toTop"))
        .opacity(isVisible ? 1 : 0)
        // **Not touchable while it is invisible.** A transparent button that still receives
        // hits is the worse version of none at all: You press the content underneath, and the
        // page jumps.
        .allowsHitTesting(isVisible)
        .animation(Motion.expand, value: isVisible)
    }
}
