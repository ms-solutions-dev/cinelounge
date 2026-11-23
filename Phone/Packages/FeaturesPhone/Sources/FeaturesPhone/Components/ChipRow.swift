import DesignSystemPhone
import SwiftUI

/// A scrolling row of chips — **one choice, horizontal.**
///
/// **A chip field and no `Picker`.** Six levels are too many for a segmented control (each
/// segment would be 55 points wide, "no limit" fits in none) and too few for a sheet. Chips
/// carry captions of unequal length side by side without the short one cutting off the long
/// one.
///
/// **It scrolls instead of wrapping.** A wrapping field changes its height as soon as the
/// type gets larger — and everything below jumps along. Horizontally the height is fixed, and
/// at Dynamic Type XXL one swipes on instead of searching.
struct ChipRow: View {

    /// The captions, already translated.
    ///
    /// **Finished and not keys:** the levels of the age limit are numbers, and a number is not
    /// translated. What does need a key hands it in translated — the same rule as with
    /// ``SegmentRow``.
    let labels: [String]

    @Binding var chosen: Int

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.targetSpacing) {
                ForEach(Array(labels.enumerated()), id: \.offset) { slot, wording in
                    Chip(wording: wording, on: slot == chosen) {
                        withAnimation(Motion.stateChange) { chosen = slot }
                    }
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .scrollIndicators(.hidden)
    }
}
