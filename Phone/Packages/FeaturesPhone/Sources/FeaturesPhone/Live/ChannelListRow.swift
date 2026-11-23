import Core
import DesignSystemPhone
import Foundation
import SwiftUI

/// Logo, name, now, next, remaining time.
///
/// **The channel name carries the rank, not the programme** (contradiction W3, decided on
/// 2026-09-06). Until then this row and "Live today" on the Home screen did it in opposite
/// directions: Here the name stood small, muted and in capitals above a bold programme.
/// But for 92 percent of channels there is no programme at all — there a pale name stood
/// above a bold "No programme stored", and the information you look for was the quietest
/// thing on the screen. Whoever reads "Friopliolian" does not yet know what they are
/// pressing; whoever reads "Das Nordlicht" does.
///
/// **72 points with a programme, 60 without.** The 44 of the logo are not design but the
/// hit area. A row without a programme has one line less to show, and with 7.126 such rows
/// twelve points per row are directly visible channels.
///
/// **The live state is the word mark "Live", not a coloured dot.** With deuteranopia the
/// dot becomes an olive-grey blotch that cannot be told from a bullet point — and a bullet
/// point in front of every row says nothing. The Live tab already follows the same rule:
/// Colour is never alone.
struct ChannelListRow: View {

    let bundles: ChannelBundle
    let program: ProgramState
    var taken = false
    let action: () -> Void
    /// Play another feed — **the fallback route** when one does not work.
    var playVariant: (Channel) -> Void = { _ in }

    /// The time as a value and not as `Date()` in the body: Otherwise every row would
    /// calculate with its own second, and two programmes of equal length would show different
    /// remaining times.
    let now: Date

    private var channels: Channel { bundles.leader }
    private var specialCases: [SpecialCase] {
        SpecialCase.forItem(channels, program: program, taken: taken)
    }

    private var isRunning: Programme? {
        guard case .list(let list) = program else { return nil }
        return list.first { $0.isRunning(at: now) }
    }

    private var following: Programme? {
        guard case .list(let list) = program else { return nil }
        return list.filter { $0.start > now }.min { $0.start < $1.start }
    }

    /// Whether this row is the narrow variant.
    ///
    /// **Only without a programme and only without a busy notice.** A busy channel has
    /// information to give, even when its schedule is empty.
    private var isNarrow: Bool { program == .none && !taken && archiveDays == nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                logo
                midpoint
                Spacer(minLength: Metrics.targetSpacing)
                right
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.vertical, isNarrow ? Metrics.targetSpacing : 14)
            .frame(minHeight: isNarrow ? Metrics.channelRowNarrow : Metrics.channelRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenText)
    }

    // MARK: - Parts

    private var logo: some View {
        RemoteImage(
            source: channels.logoURL, longestEdge: Metrics.target, withColor: false,
            isFilling: false, placeholder: Glyph.Tab.live.outlined
        )
        .frame(width: Metrics.target, height: Metrics.target)
        .background(ColorRole.surface.color, in: RoundedRectangle(cornerRadius: 8))
    }

    private var midpoint: some View {
        VStack(alignment: .leading, spacing: 2) {
            nameRow
            nowRow
            if let running = isRunning, let portion = LiveModel.progress(running, um: now) {
                ProgressBar(portion: portion)
                    .padding(.top, 3)
            }
            if let subRow {
                Text(verbatim: subRow)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(taken ? ColorRole.progress.color : ColorRole.textQuiet.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **The name leads.** The tags stand beside it — and only where there is more than one.
    private var nameRow: some View {
        HStack(spacing: 6) {
            Text(verbatim: bundles.name)
                .font(TypeLevel.footer.font.weight(.semibold))
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(1)
            brandRow
            if archiveDays != nil {
                Image(systemName: Glyph.history.name)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
    }

    /// The feeds to choose from.
    ///
    /// **Only with more than one**, and then they are **buttons** and not tags: Whoever
    /// presses "SD" gets SD. With an account that has exactly one permitted connection this is
    /// the natural detour when a feed does not work — and until 2026-09-06 a single tag stood here
    /// that did nothing and offered nothing.
    ///
    /// **A single tag therefore no longer appears.** It distinguished nothing: When there is
    /// only one variant, "HD" only says that it is the only one.
    @ViewBuilder
    private var brandRow: some View {
        if bundles.marks.count > 1 {
            HStack(spacing: 4) {
                ForEach(bundles.marks) { tag in
                    Button {
                        playVariant(tag.channels)
                    } label: {
                        Text(verbatim: tag.wording)
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(
                                tag.id == channels.id ? ColorRole.text.color : ColorRole.textQuiet.color
                            )
                            .padding(.horizontal, 4)
                            .frame(minHeight: 20)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        tag.id == channels.id
                                            ? ColorRole.brandLight.color : ColorRole.line.color,
                                        lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        Text(
                            verbatim: "\(bundles.name) \(tag.wording)"))
                }
            }
        }
    }

    @ViewBuilder
    private var nowRow: some View {
        if let running = isRunning {
            HStack(spacing: 6) {
                LiveBadge()
                Text(verbatim: running.title)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(1)
            }
        }
        // **Without a programme nothing stands here any more.** The sentence for it stands once
        // above the section (see ``ChannelListScreen``) instead of seven thousand times in the rows —
        // question 10, decided on 2026-09-06. And `.pending` used to write the name a second time below;
        // since the name leads at the top, that would be the same text twice.
    }

    @ViewBuilder
    private var right: some View {
        if taken {
            Image(systemName: Glyph.tv.name)
                .foregroundStyle(ColorRole.progress.color)
        } else if let rest = LiveModel.remainingMinutes(isRunning, um: now) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: "\(rest)")
                    .monospacedDigit()
                Text(appKey: "live.remaining")
            }
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.textQuiet.color)
        }
    }

    // MARK: - Texts

    private var archiveDays: Int? {
        for scenario in specialCases { if case .archive(let days) = scenario { return days } }
        return nil
    }

    /// The last row — **one sentence, not three side by side.**
    ///
    /// Exactly one line fits, and letting three pieces of information fight over the same
    /// space produces one that gets cut off. The order is urgency: What keeps you from
    /// pressing comes before what follows.
    ///
    /// **"No programme stored" no longer appears here.** It was the most frequent sentence in
    /// the whole app — in 7.126 of 7.746 rows — and so stood seven thousand times for the same
    /// information. Now the section carries it.
    private var subRow: String? {
        if taken { return AppLanguageSetting.text("live.busyOnTV") }
        if let days = archiveDays, let next = following {
            return String(
                format: AppLanguageSetting.text("live.archiveThenNext %lld %@ %@"),
                days, clockTime(next.start), next.title)
        }
        if let days = archiveDays {
            return String(
                format: AppLanguageSetting.text("live.archiveDays %lld"), days)
        }
        if let next = following {
            return String(
                format: AppLanguageSetting.text("live.next %@ %@"),
                clockTime(next.start), next.title)
        }
        return nil
    }

    private func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private var spokenText: String {
        var split = [bundles.name]
        if bundles.marks.count > 1 {
            split.append(bundles.marks.map(\.wording).joined(separator: ", "))
        }
        if let running = isRunning { split.append(running.title) }
        if let rest = LiveModel.remainingMinutes(isRunning, um: now) {
            split.append("\(rest) \(AppLanguageSetting.text("live.remaining"))")
        }
        if let subRow { split.append(subRow) }
        return split.joined(separator: ", ")
    }
}

/// The word mark "Live".
///
/// **Not a dot.** With deuteranopia `live` and `textQuiet` are so close together that the
/// dot becomes an olive-grey blotch — and a blotch in front of a row reads as a bullet
/// point. The word carries its meaning even when the colour does not arrive; the colour
/// comes on top.
struct LiveBadge: View {
    var body: some View {
        Text(appKey: "live.mark")
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.reason.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(ColorRole.live.color, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}
