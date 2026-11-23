import Core
import DesignSystemPhone
import SwiftUI

/// The schedule: three pinned sections.
///
/// **Pinned and not scrolling along.** Anyone far down in "Later today" would otherwise
/// see a list of times without context; the heading is exactly the information that is
/// missing there. `List` with `Section` brings pinning along by itself — a rebuilt header
/// would be worse and more expensive.
///
/// **The number stands at the heading.** "Running now 21" answers the question whether it
/// is worth scrolling on, before you scroll.
struct SportList: View {

    let segments: [SportModel.Segment]
    let channelName: (SportEvent) -> String?
    let watchlist: SportReminderList
    let now: Date
    let matches: (SportEvent) -> Void
    let memorize: (SportEvent) -> Void
    let followClub: (String) -> Void
    let followCompetition: (String) -> Void

    var body: some View {
        List {
            ForEach(segments) { section in
                Section {
                    ForEach(section.events) { event in
                        SportRow(
                            event: event,
                            channelName: channelName(event),
                            watchlist: watchlist,
                            now: now,
                            matches: { matches(event) },
                            memorize: { memorize(event) },
                            followClub: followClub,
                            followCompetition: followCompetition
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(ColorRole.reason.color)
                        .listRowSeparatorTint(ColorRole.lineQuiet.color)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in MetricsBoard.phone.margin }
                    }
                } header: {
                    header(section)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ColorRole.reason.color)
    }

    private func header(_ section: SportModel.Segment) -> some View {
        HStack {
            Text(appKey: section.kind.titleKey)
            Spacer()
            Text(verbatim: section.count.formatted())
                .monospacedDigit()
        }
        .font(TypeLevel.lowercased.font)
        .textCase(.uppercase)
        .foregroundStyle(ColorRole.textQuiet.color)
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorRole.reason.color)
        .listRowInsets(EdgeInsets())
    }
}
