import DesignSystemPhone
import SwiftUI

/// The segment toggle: two sides, one of them on.
///
/// **Two and no more.** A segment with four sides is a row of truncated words at 353
/// points; where there are more than two options, a sheet is the right construction —
/// the same grammar as with catalog and season.
///
/// **The numbers are part of the word.** "Movies 40" and "Series 8" answer the question
/// of whether switching is worthwhile before you do it. An empty segment you otherwise
/// switch on once and never again.
struct SegmentPicker: View {

    let links: String
    let right: String
    @Binding var isRightSelected: Bool

    var body: some View {
        Picker("", selection: $isRightSelected) {
            Text(verbatim: links).tag(false)
            Text(verbatim: right).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.gutter)
    }
}
