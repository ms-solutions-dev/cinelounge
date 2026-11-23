import Core
import DesignSystemPhone
import SwiftUI

/// **How long a series runs — and how much is still to go** (decision 27, C7).
///
/// The same information as on the TV next to the grid: "About 14 h in total", and as soon as
/// something has been watched, a bar and "About 6 h 30 min left" or "Fully watched".
/// **"About"**, because the duration is computed from episode count times runtime
/// (``Core/WatchEstimate``) — the server's figure for it is unusable.
struct WatchDurationRow: View {

    let estimate: WatchEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Glyph.clock.name)
                    .iconSize(12)
                Text(
                    app:
                        "library.totalLength \(WatchEstimate.durationText(estimate.total, roundedValue: true))"
                )
            }
            .font(TypeLevel.label.font)
            .foregroundStyle(ColorRole.textMatt.color)

            if estimate.watchedFraction > 0 {
                HStack(spacing: MetricsBoard.phone.gutter) {
                    ProgressView(value: estimate.watchedFraction)
                        .tint(ColorRole.progress.color)
                        .frame(maxWidth: 160)
                    Group {
                        if estimate.hasRemaining {
                            Text(
                                app:
                                    "library.remaining \(WatchEstimate.durationText(estimate.remaining, roundedValue: true))"
                            )
                        } else {
                            Text(app: "library.finished")
                        }
                    }
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
