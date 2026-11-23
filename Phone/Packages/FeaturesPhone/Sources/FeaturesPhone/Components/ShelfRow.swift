import DesignSystemPhone
import SwiftUI

/// A horizontal row with a heading and a count.
///
/// **The heading almost always carries a number** — "5 · Jellyfin", "96 new episodes",
/// "610 with schedule". It says how big the catalog is without having to page to the
/// end. A shelf without a count is a row whose length you only learn by trying.
struct ShelfRow<Content: View>: View {

    let title: String
    var tally: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // **The brand stroke before the heading** (2026-09-07). It carries no information and is
                // not meant to — the rule is at ``StripeBand``. It sits here and not at the call
                // sites, so that every shelf has it and none gets it twice.
                Text(verbatim: title)
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
                    .withBrandStripe()
                Spacer(minLength: MetricsBoard.phone.gutter)
                if let tally {
                    Text(verbatim: tally)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.bottom, 10)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MetricsBoard.phone.gutter) {
                    content
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }
}
