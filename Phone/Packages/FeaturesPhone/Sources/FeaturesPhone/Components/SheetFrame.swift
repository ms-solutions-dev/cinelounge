import DesignSystemPhone
import SwiftUI

/// Heading, scrolling content, bottom inset — the frame of every sheet.
///
/// **So that the heading sits the same everywhere.** Six sheets that each set their own title
/// are six chances for six spacings; on screen you see it at once when two of them open in
/// succession.
///
/// **No close cross.** The system's grabber lies above it and is 44 points tall to touch; a
/// second way to the same goal at top right would be a target above the thumb limit for
/// something done with one swipe.
struct SheetFrame<Content: View>: View {

    /// Key in the string catalog.
    var title: String?
    /// Finished wording — for names that come from outside.
    var wording: String?
    /// The sentence below the heading, where one is needed.
    var message: String?

    /// The way back to the sheet one came from — **`nil` means: there was none.**
    ///
    /// **The finding of 2026-09-08, reported on screen:** after a sheet was opened from another one,
    /// there was no way back to the list. ``SheetState`` holds **exactly one** sheet at a time,
    /// and that is right — two on top of each other can no longer be closed with one thumb. The
    /// flip side: a sheet opened from another one **replaces** it, and the way back would be
    /// "close and start over".
    ///
    /// **The way back names its destination and is not called "Back".** Whoever comes from the
    /// career of Piosiaspeit Misplaus reads "‹ Piosiaspeit Misplaus" — and thus knows where they return to instead of
    /// guessing.
    var back: (wohin: String, action: () -> Void)?

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if let back {
                    Button(action: back.action) {
                        HStack(spacing: 4) {
                            Image(systemName: Glyph.back.name)
                                .iconSize(13, weight: .semibold)
                            Text(verbatim: back.wohin)
                                .font(TypeLevel.footer.font)
                                .lineLimit(1)
                        }
                        .foregroundStyle(ColorRole.brandLight.color)
                        .frame(minHeight: Metrics.target, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if let wording {
                    Text(verbatim: wording)
                        .font(TypeLevel.section.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(2)
                } else if let title {
                    Text(appKey: title)
                        .font(TypeLevel.section.font)
                        .foregroundStyle(ColorRole.text.color)
                }
                if let message {
                    Text(appKey: message)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.top, MetricsBoard.phone.section)
            .padding(.bottom, MetricsBoard.phone.gutter)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.bottom, MetricsBoard.phone.margin)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
