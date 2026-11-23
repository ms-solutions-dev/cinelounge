import DesignSystemPhone
import SwiftUI

/// All eight setups side by side: which tabs appear at the bottom and which shelves appear at
/// the top.
///
/// **Why this is a view and not a table in the roadmap** (question of 2026-09-05: "that would be 6
/// possible states at the bottom and just as many states for the Home screen"). The number at
/// the bottom almost holds — it is seven with content, `2³` instead of `3!`. At the top it does
/// not: Six shelves that each appear or not would be `2⁶ = 64` screens. That is exactly why
/// states are the wrong notion here. There is **one** rule — a tab or a shelf appears when its
/// source is there — and this screen works it out for all cases instead of asserting it.
struct BarProbe: View {

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.section) {
            ForEach(Array(CatalogState.allCases.enumerated()), id: \.offset) { _, setup in
                caseRow(setup)
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, MetricsBoard.phone.section)
    }

    @ViewBuilder
    private func caseRow(_ setup: CatalogState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: isConfigured(setup))
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            if setup.isSetUp {
                marks(setup.tabs.map(\.rawValue), color: ColorRole.tag.color)
                marks(
                    ShelfPlan.shelves(forItem: setup).map { $0.label.raw },
                    color: ColorRole.line.color)
            } else {
                Text(verbatim: "→ Setup")
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            ColorRole.surface.color, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius))
    }

    private func marks(_ names: [String], color: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(verbatim: name)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.horizontal, 7)
                    .frame(minHeight: 21)
                    .background(color.opacity(0.35), in: Capsule())
            }
        }
    }

    /// The origins as shorthand — here explicitly without a language catalog: The probe is a tool
    /// and is never translated.
    ///
    /// **Corrected on 2026-09-05:** This used to say "will be deleted by AP15". AP15 did not delete it,
    /// because it answers a different question from ``StateShowcase`` — which *tabs and shelves* a
    /// setup yields, not what a state looks like.
    private func isConfigured(_ setup: CatalogState) -> String {
        let names: [Catalog.Origin: String] = [
            .jellyfin: "Jellyfin", .channelList: "IPTV",
            .portals: "Portals", .downloads: "Downloads",
        ]
        let split = Catalog.Origin.allCases.filter(setup.hasKey).compactMap { names[$0] }
        return split.isEmpty ? "nothing set up" : split.joined(separator: " + ")
    }
}
