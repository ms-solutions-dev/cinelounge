import DesignSystemPhone
import Downloads
import SwiftUI

/// The bar and what the colours mean.
///
/// **The legend is below and not in a footnote.** A stacked bar without a
/// caption is decoration: you see that something is occupied, and do not learn by what.
/// That was exactly the mistake of the two storage screens in the design — both showed
/// colours, and neither said which of them disappears on clean-up.
///
/// **The downloads do not carry the warning colour.** They are the only thing here that stays until
/// someone deletes it; showing them in the same colour as the temporary cache would
/// invite clearing them away.
struct StorageLegend: View {

    let household: StorageBudget

    private var total: Double { Double(max(household.taken + household.unrestricted, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar
            legend
        }
    }

    private var bar: some View {
        GeometryReader { space in
            HStack(spacing: 1) {
                ForEach(items, id: \.kind) { items in
                    Rectangle()
                        .fill(color(items.kind))
                        .frame(width: max(1, space.size.width * portion(items.bytes)))
                }
                Rectangle().fill(ColorRole.text.color.opacity(0.10))
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }

    private var legend: some View {
        // **Two columns and no running text.** With large type a row of
        // five colour dots with text would otherwise wrap in five different places.
        FlexRows(
            items.map { items in
                (
                    items.kind, color(items.kind), CaptionLabel.key(items.key).readable,
                    DownloadsModel.members(items.bytes)
                )
            })
    }

    /// **Only what actually occupies space.** An item with zero bytes in the legend is
    /// a row that costs a glance and says nothing.
    private var items: [LineItem] {
        household.items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    private func portion(_ bytes: Int64) -> Double { Double(bytes) / total }

    private func color(_ kind: LineItem.Kind) -> Color {
        switch kind {
        case .downloads: ColorRole.progress.color
        case .frames: ColorRole.textQuiet.color
        default: ColorRole.text.color.opacity(0.28)
        }
    }
}

/// Colour dot, name and amount — able to wrap.
private struct FlexRows: View {

    let items: [(LineItem.Kind, Color, String, String)]

    init(_ items: [(LineItem.Kind, Color, String, String)]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { _, color, name, members in
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(verbatim: name)
                        .foregroundStyle(ColorRole.textQuiet.color)
                    Spacer(minLength: Metrics.targetSpacing)
                    Text(verbatim: members)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .monospacedDigit()
                }
                .font(TypeLevel.label.font)
            }
        }
    }
}
