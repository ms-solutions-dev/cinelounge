import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// Two chip rows: sport and channel — **and at the front of the first "Marked" and
/// "Busy"**, the same filters as on the TV (decision 27, B6, 2026-09-26).
///
/// **Two rows and not one.** On the TV, 23 sports stand as buttons, plus four per channel
/// group with 79 groups — over 300 targets. At 393 points that only works scrolling, and
/// two scrolling rows on top of each other are still readable as long as each asks **one**
/// question: *which sport* and *on whom*. A mixed row would again be the grammar that the
/// library already dissolved.
///
/// **Both rows count across the respective other filter.** Anyone who has filtered by
/// "Arena" wants to see, at "Football", the number that a press on it delivers — the
/// reasoning stands at ``SportModel/sports``.
///
/// **A row with a single entry is dropped.** A switch that has only one position is not a
/// switch; it then costs 44 points of height for nothing.
struct SportFilter: View {

    let sports: [(kind: SportKind, count: Int)]
    let channels: [(name: String, count: Int)]
    let selectedKind: SportKind?
    let selectedChannel: String?
    let total: Int
    let rememberFilter: SportsSchedule.BookmarkFilter
    let bookmarked: Int
    let taken: Int
    let selectKind: (SportKind?) -> Void
    let selectChannel: (String?) -> Void
    let selectBookmarkFilter: (SportsSchedule.BookmarkFilter) -> Void

    /// Whether the first row appears: with more than one sport **or** when there is something
    /// marked or busy — otherwise the two chips would have no row.
    private var isFirstRow: Bool {
        sports.count > 1 || bookmarked > 0 || taken > 0 || rememberFilter != .all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isFirstRow {
                row {
                    Chip(wording: allChip, on: selectedKind == nil && rememberFilter == .all) {
                        selectKind(nil)
                        if rememberFilter != .all { selectBookmarkFilter(rememberFilter) }
                    }
                    bookmarkChip(.bookmarked, bookmarked)
                    bookmarkChip(.taken, taken)
                    ForEach(sports.count > 1 ? sports : [], id: \.kind) { entry in
                        Chip(
                            wording: name(entry.kind, entry.count),
                            on: selectedKind == entry.kind
                        ) {
                            selectKind(entry.kind)
                        }
                    }
                }
            }
            if channels.count > 1 {
                row {
                    ForEach(channels, id: \.name) { entry in
                        Chip(
                            wording: "\(entry.name) \(entry.count.formatted())",
                            on: selectedChannel == entry.name
                        ) {
                            selectChannel(entry.name)
                        }
                    }
                }
            }
        }
        .padding(.bottom, Metrics.targetSpacing)
    }

    /// "Marked 3", "Busy 12" — **only where something stands behind it** or the filter is
    /// selected: A chip with zero delivers nothing.
    @ViewBuilder
    private func bookmarkChip(_ filter: SportsSchedule.BookmarkFilter, _ count: Int) -> some View {
        if count > 0 || rememberFilter == filter {
            Chip(
                wording: "\(AppLanguageSetting.text(.init(filter.key))) \(count.formatted())",
                on: rememberFilter == filter
            ) {
                selectBookmarkFilter(filter)
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.targetSpacing) { content() }
                .padding(.horizontal, MetricsBoard.phone.margin)
        }
    }

    private var allChip: String {
        "\(AppLanguageSetting.text("common.all")) \(total.formatted())"
    }

    private func name(_ kind: SportKind, _ count: Int) -> String {
        let word = AppLanguageSetting.text(String.LocalizationValue(kind.labelKey))
        return "\(word) \(count.formatted())"
    }
}
