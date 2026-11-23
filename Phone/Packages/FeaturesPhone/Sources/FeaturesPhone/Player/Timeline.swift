import DesignSystemPhone
import SwiftUI

/// The timeline — **visibly narrow, 44 to grab.**
///
/// **The hardest finding of the usability review was here:** the drag handle was
/// 12 × 12 points. A thumb covers about forty-five; you hit it when sitting, not when
/// walking — and when walking, you seek.
///
/// **The surface is decoupled from the drawing**, as ``Metrics/target`` requires: the stroke
/// stays four points high and the dot fourteen wide, while the whole forty-four-point
/// height is grabbable. A thick bar would be the wrong answer — it covers the picture and
/// says nothing.
///
/// **Dragging happens without a jump.** A tap in the middle of the bar jumps there; a drag
/// follows the finger, and it is only reported on release. Anyone who sought on every
/// intermediate frame would send fifty requests over a narrow line for one movement — and
/// each of them restarts the picture.
struct Timeline: View {

    let location: TimeInterval
    let duration: TimeInterval
    /// What is already loaded, for the second stroke.
    var loaded: TimeInterval?
    let jump: (TimeInterval) -> Void
    /// What is on the left instead of the time — for a channel in the buffer "Live" or
    /// "Time-shifted" (AP58 G1, A1): the position in the buffer tells nobody anything.
    var links: String?
    /// The preview image for a position, **while dragging** (AP58 G1, A7) — the same
    /// calculation as for the chapter images (`Core.Trickplay`).
    var lookahead: ((TimeInterval) -> ArcExcerpt?)?

    @State private var movesAccount: Double?

    private static let strokeHeight: CGFloat = 4
    private static let point: CGFloat = 14

    private var portion: Double {
        if let movesAccount { return movesAccount }
        guard duration > 0 else { return 0 }
        return min(1, max(0, location / duration))
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { space in
                let width = space.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(ColorRole.text.color.opacity(0.22))
                        .frame(height: Self.strokeHeight)

                    if let loaded, duration > 0 {
                        Capsule().fill(ColorRole.text.color.opacity(0.34))
                            .frame(
                                width: width * min(1, loaded / duration),
                                height: Self.strokeHeight)
                    }

                    Capsule().fill(ColorRole.brandLight.color)
                        .frame(width: width * portion, height: Self.strokeHeight)

                    Circle().fill(ColorRole.brandLight.color)
                        .frame(width: Self.point, height: Self.point)
                        .offset(x: width * portion - Self.point / 2)
                        // While dragging it grows, so that the finger sees it is hitting — and only then: a
                        // permanently large dot covers the picture.
                        .scaleEffect(movesAccount == nil ? 1 : 1.6)
                        .animation(Motion.expand, value: movesAccount == nil)
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) { thumbnail(width: width) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            movesAccount = min(1, max(0, drag.location.x / max(1, width)))
                        }
                        .onEnded { _ in
                            if let movesAccount, duration > 0 { jump(movesAccount * duration) }
                            movesAccount = nil
                        }
                )
            }
            .frame(height: Metrics.target)

            HStack {
                Text(verbatim: links ?? Timeline.time(portion * duration))
                Spacer(minLength: 0)
                // **The remaining time, not the total duration.** "42 minutes left" answers the question
                // you ask yourself; "of 118" you first have to subtract from.
                Text(verbatim: "−" + Timeline.time(duration - portion * duration))
            }
            .font(TypeLevel.lowercased.font)
            .monospacedDigit()
            .foregroundStyle(ColorRole.textMatt.color)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(app: "player.position"))
        .accessibilityValue(Text(verbatim: Timeline.time(portion * duration)))
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            // Ten seconds per step — the same span as the skip-back button.
            jump(min(duration, max(0, location + (direction == .increment ? 10 : -10))))
        }
    }

    /// The size of the preview image — **sixteen to nine and small enough** that it sits above
    /// the bar without covering the title.
    private static let thumbnailSize = CGSize(width: 160, height: 90)

    /// The preview image above the dot, **only while dragging** — held at the edge so that it
    /// does not wander out of the picture.
    @ViewBuilder
    private func thumbnail(width: CGFloat) -> some View {
        if let movesAccount, duration > 0, let slice = lookahead?(movesAccount * duration) {
            let size = Self.thumbnailSize
            AtlasImage(
                sheet: slice.sheet, columns: slice.columns, rows: slice.rows,
                column: slice.column, row: slice.row, width: size.width
            )
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius, style: .continuous))
            .edge()
            .offset(
                x: min(max(0, width * movesAccount - size.width / 2), max(0, width - size.width)),
                y: -(Metrics.target + 8)
            )
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// "1:12:04" — and "12:04" as long as there is no hour.
    ///
    /// The leading zero would not be information: "0:12:04" on a short film reads as an
    /// error. The same rule as in ``ChapterDetail/timeText``.
    static func time(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds).rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let rest = whole % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }
}
