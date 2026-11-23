import DesignSystemPhone
import NetworkStatus
import SwiftUI

/// "What this source can do on the go."
///
/// The sentence comes from ``NetworkStatus/LocationStatement`` — **one per source**, never one for
/// all. This file only displays it.
///
/// A warning appears in exactly two places: Jellyfin on the go and "Automatic" in the
/// sources sheet. A warning on every row would no longer be a warning.
struct LocationRow: View {

    /// **Optional, and that is half the statement** (AP6). When the location is unknown,
    /// ``NetworkStatus/LocationStatement/forItem(_:location:source:tvOccupied:childAccount:)`` returns
    /// nothing, and then nothing is shown here either. The viewer notices a missing line;
    /// a wrong one they notice only once they have believed it.
    let statement: LocationStatement.Statement?

    var body: some View {
        if let statement {
            row(statement)
        }
    }

    private func row(_ statement: LocationStatement.Statement) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statement.warning ? Glyph.check.name : Glyph.done.pair.outlined)
                .iconSize(13)
                .foregroundStyle(statement.warning ? ColorRole.progress.color : ColorRole.textQuiet.color)
                .padding(.top, 2)

            Text(appKey: statement.key)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.pillInset)
        .padding(.vertical, 9)
        .background(
            ColorRole.surface.color, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius)
                .strokeBorder(
                    statement.warning ? ColorRole.outline.color : ColorRole.line.color, lineWidth: 0.5)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }
}
