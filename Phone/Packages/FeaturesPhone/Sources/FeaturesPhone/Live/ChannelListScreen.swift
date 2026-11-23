import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// The channel list — **a `List`, not a `LazyVStack` in a `ScrollView`.**
///
/// **The reason is the length.** The provider of this household carries 7.746 channels;
/// without hidden groups they all appear in this list. A `LazyVStack` builds rows only
/// when they appear, but never releases them — after one pass through, all of them sit in
/// memory. `List` gives them back, and that is exactly what it exists for.
///
/// **Sections instead of one row** — the order is the frequency of the intents: recently
/// watched, saved, what is running, and last the rest without a programme. The last cut is
/// the answer to question 10 (decided on 2026-09-06): The explanatory sentence appears
/// **once** above the section instead of seven thousand times in the rows.
///
/// **What this cannot do is stated explicitly:** In 55 of the 96 groups **no** channel
/// carries a programme ID (6.099 channels). There the cut reorders nothing, and the section
/// header is the only one above the whole list. That is honest and not ineffective: It
/// then says why no single channel shows anything.
///
/// **Saving sits on a swipe, and that works here — unlike on 2026-09-06** The finding back then
/// was that removing and deleting sat "behind a gesture that does nothing in a
/// `ScrollSurface`". That is exactly the difference: This is a `List`, and `swipeActions` is
/// its own capability. So saving costs **no** row height — with 7.746 rows the whole point.
///
/// **The separator comes from the system and is only indented**: to the height of the text,
/// not of the logo. A line that runs under an image visually splits the row in two.
struct ChannelListScreen: View {

    let segments: [ChannelSection]
    let program: (ChannelBundle) -> ProgramState
    let now: Date
    let open: (Channel) -> Void
    let memorize: (Channel) -> Void
    /// One level deeper — the daily schedule of this channel.
    let showProgram: (ChannelBundle) -> Void

    var body: some View {
        List {
            ForEach(segments) { section in
                Section {
                    ForEach(section.entries) { row($0) }
                } header: {
                    header(section)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ColorRole.reason.color)
    }

    @ViewBuilder
    private func header(_ section: ChannelSection) -> some View {
        if let key = section.kind.titleKey {
            // **The number counts this section and not the catalog.** A number that counts something
            // other than what stands below it is the same error as finding M2 — there 5.389 stood
            // above a list with 2.055 entries.
            Text(
                verbatim: section.kind.showsCount
                    ? String(
                        format: AppLanguageSetting.text(.init(key)),
                        section.entries.count)
                    : AppLanguageSetting.text(.init(key))
            )
            .font(TypeLevel.lowercased.font)
            .textCase(nil)
            .foregroundStyle(ColorRole.textQuiet.color)
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowBackground(ColorRole.reason.color)
        }
    }

    private func row(_ bundles: ChannelBundle) -> some View {
        ChannelListRow(
            bundles: bundles, program: program(bundles),
            action: { open(bundles.leader) },
            playVariant: open,
            now: now
        )
        .listRowInsets(EdgeInsets())
        .listRowBackground(ColorRole.reason.color)
        .listRowSeparatorTint(ColorRole.lineQuiet.color)
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            MetricsBoard.phone.margin + Metrics.target + MetricsBoard.phone.gutter
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                memorize(bundles.leader)
            } label: {
                Label {
                    Text(app: bundles.leader.isFavorite ? "action.unfavorite" : "action.favorite")
                } icon: {
                    Image(systemName: Glyph.favorite.pair.zu(active: !bundles.leader.isFavorite))
                }
            }
            .tint(ColorRole.progress.color)
        }
        // **The daily schedule is on the other side** (question 6, decided on 2026-09-06): "now" is
        // shown in the list, everything else one level deeper. As a swipe action, the way there
        // costs **no** row height — with 7.746 rows the whole point —, and pressing the row stays
        // what it was: The channel plays.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                showProgram(bundles)
            } label: {
                Label {
                    Text(app: "live.raster")
                } icon: {
                    Image(systemName: Glyph.history.name)
                }
            }
            .tint(ColorRole.surfaceHigh.color)
        }
    }
}
