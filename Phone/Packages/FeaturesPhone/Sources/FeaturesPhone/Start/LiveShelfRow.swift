import Core
import DesignSystemPhone
import SwiftUI

/// A channel row in the "Live today" shelf — **as wide as the picture.**
///
/// **The draft was right.** At this point it says literally: "Live today: VERTICAL. A
/// channel row is as wide as the picture — side by side, 'now/next' would be unreadable."
/// The build overruled that with a principle — "Home has **one** grammar" —, and what came
/// out was a 200 × 112 wide plate with a logo on it, on which there was not a word of
/// "now". The principle was right and the conclusion wrong: a channel is not a title.
///
/// **It is not the same as ``ChannelListRow`` in the Live tab, and that is deliberate.**
/// There it sits in a `List` with swipe actions, badge row and section headers; here three
/// rows stand in a shelf on Home. What is missing here — badges, archive marks,
/// "next" — is one tap away.
///
/// **The remaining time is calculated and not passed along.** ``TileContent/runsUntil``
/// is a point in time; a calculated number would be wrong after ten minutes, and Home stays
/// standing for a long time while you page through the shelves.
struct LiveShelfRow: View {

    let content: TileContent
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                logo
                midpoint
                Spacer(minLength: Metrics.targetSpacing)
                right
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.vertical, 10)
            .frame(minHeight: Metrics.channelRowNarrow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: spokenText))
    }

    private var logo: some View {
        RemoteImage(
            source: content.image, longestEdge: Metrics.target, withColor: false,
            isFilling: false, placeholder: Glyph.Tab.live.outlined
        )
        .frame(width: Metrics.target, height: Metrics.target)
        .background(ColorRole.surface.color, in: RoundedRectangle(cornerRadius: 8))
    }

    private var midpoint: some View {
        VStack(alignment: .leading, spacing: 2) {
            // **The name carries the rank** — the same decision as in the Live tab (objection W3):
            // anyone who reads "Friopliolian" does not yet know what they are pressing on; anyone who
            // reads "Das Nordlicht" does.
            Text(verbatim: content.title)
                .font(TypeLevel.footer.font.weight(.semibold))
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(1)

            if let broadcast = content.beside {
                HStack(spacing: 6) {
                    LiveBadge()
                    Text(verbatim: broadcast)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .lineLimit(1)
                }
            }

            if let portion = content.progress {
                ProgressBar(portion: portion).padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var right: some View {
        if let rest = remainingMinutes {
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: "\(rest)")
                    .monospacedDigit()
                Text(appKey: "live.remaining")
            }
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.textQuiet.color)
        }
    }

    /// **Rounded up**, as in the Live tab: rounded down it would say "0 min left" in the last
    /// minute, a number that looks as if the show were over.
    private var remainingMinutes: Int? {
        guard let end = content.runsUntil, end > now else { return nil }
        return max(1, Int(ceil(end.timeIntervalSince(now) / 60)))
    }

    private var spokenText: String {
        var split = [content.title]
        if let broadcast = content.beside { split.append(broadcast) }
        if let rest = remainingMinutes {
            split.append("\(rest) \(AppLanguageSetting.text("live.remaining"))")
        }
        return split.joined(separator: ", ")
    }
}
