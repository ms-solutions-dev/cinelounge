import DesignSystemPhone
import SwiftUI

/// A segmented switch with **more than two** sides.
///
/// ``SegmentPicker`` has exactly two and a `Bool` — right for "quality or audio" and too
/// narrow as soon as a portal asks three questions (provider, quality, version). A
/// second switch next to it would be the worse answer: Two switches claim two levels
/// where there is one.
///
/// **The row is filled from outside and not decided here.** Which sides exist depends
/// on the portal — a segment without content would otherwise stand there empty.
struct SegmentRow: View {

    /// The labels, already translated.
    let pages: [String]
    @Binding var chosen: Int

    var body: some View {
        Picker("", selection: $chosen) {
            ForEach(Array(pages.enumerated()), id: \.offset) { slot, wording in
                Text(verbatim: wording).tag(slot)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.gutter)
    }
}
