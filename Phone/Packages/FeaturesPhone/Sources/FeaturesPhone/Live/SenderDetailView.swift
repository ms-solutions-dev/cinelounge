import Core
import DesignSystemPhone
import Flows
import Foundation
import Observation
import PlaylistKit
import SwiftUI

/// The daily schedule of a channel — **one level below the list.**
///
/// **Question 6, decided on 2026-09-06: "now" is shown in the list, the daily schedule one
/// level deeper.** Putting both in the row would not work — with 7.746 rows, every extra
/// row height directly costs visible channels. And fetching both would not work either:
/// ``ChannelListingSource/program(forItem:)`` fetches the whole list in one go, a daily schedule
/// needs more — but only for the one channel someone opens.
///
/// **Three time markers instead of a scroll bar.** "Now" is the most frequent question,
/// "20:15" the second most frequent — on German television it is not a time of day but an
/// institution —, and "Tomorrow" answers the only one that reaches beyond today. A freely
/// scrolling time axis answers all three worse: You have to find the spot first.
///
/// **Look back** (decision 27, A2, 2026-09-26): On an archive channel, "Now" also lists the
/// past programmes that are still in the archive, and a tap on one plays the recording —
/// the same rule as in the TV's programme grid (``Flows/CatchUpSelection``). Every other
/// row plays the channel.
public struct ChannelDetailView: View {

    @State private var model: ChannelDetailModel
    private let matches: (Channel) -> Void
    private let playRecording: (Channel, Programme) -> Void
    private let back: () -> Void

    public init(
        bundles: ChannelBundle, source: (any ChannelListingSource)?,
        matches: @escaping (Channel) -> Void = { _ in },
        playRecording: @escaping (Channel, Programme) -> Void = { _, _ in },
        back: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: ChannelDetailModel(bundles: bundles, source: source))
        self.matches = matches
        self.playRecording = playRecording
        self.back = back
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                SegmentRow(pages: TimeMark.labels, chosen: $model.tag)
                content
            }
        }
        .task { await model.load() }
    }

    private var header: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Button(action: back) {
                Image(systemName: Glyph.back.name)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            .target()
            .accessibilityLabel(Text(app: "common.back"))

            RemoteImage(
                source: model.bundles.leader.logoURL, longestEdge: Metrics.target,
                withColor: false, isFilling: false, placeholder: Glyph.Tab.live.outlined
            )
            .frame(width: Metrics.target, height: Metrics.target)
            .background(ColorRole.surface.color, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.bundles.name)
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
                if let group = model.bundles.group {
                    Text(verbatim: group)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            Button {
                matches(model.bundles.leader)
            } label: {
                Image(systemName: Glyph.play.name)
            }
            .buttonStyle(.rounded)
            .accessibilityLabel(Text(app: "common.play"))
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.gutter)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .isLoading:
            LoadingState(message: "live.loading").frame(maxHeight: .infinity)
        case .none:
            // **The honest normal case, not an error.** 7.126 of the 7.746 channels carry no
            // programme; the provider maintains no schedule for 92 percent of its channels. An error
            // screen here claimed a defect.
            StateBlock(
                form: .info(
                    StateInfo(
                        icon: Glyph.Tab.live.outlined,
                        headline: "live.noGuide.title", message: "live.noGuide.text"))
            )
            .frame(maxHeight: .infinity)
        case .settled:
            ScrollViewReader { roller in
                ScrollSurface {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.isVisible) { broadcast in
                            Button {
                                tap(broadcast)
                            } label: {
                                BroadcastRow(
                                    broadcast: broadcast, now: model.now,
                                    catchUpAvailable: model.catchUpAvailable(broadcast))
                            }
                            .buttonStyle(.plain)
                            .id(broadcast.id)
                        }
                    }
                    .padding(.top, Metrics.targetSpacing)
                }
                // **The running programme at the top**, even when past programmes come before it — "now"
                // stays the most frequent question; anyone who wants to catch up scrolls back.
                .onAppear { if let running = model.running { roller.scrollTo(running.id, anchor: .top) } }
                .onChange(of: model.tag) { _, _ in
                    if let first = model.running ?? model.isVisible.first {
                        roller.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
    }

    private func tap(_ broadcast: Programme) {
        if let choice = CatchUpSelection.recording(
            feeds: model.bundles.feeds, start: broadcast.start, end: broadcast.end,
            now: Date())
        {
            playRecording(choice.channels, broadcast)
        } else {
            matches(model.bundles.leader)
        }
    }
}

/// A programme in the daily schedule.
///
/// **The time carries the rank, not the title.** Someone reading a daily schedule looks
/// for a time — "what is on at eight" — and not for a name; in the channel list it is the
/// other way round, which is why the name comes first there.
struct BroadcastRow: View {

    let broadcast: Programme
    let now: Date
    /// Whether the programme is over and still in the archive — then a tap plays the
    /// recording, and the row says so **with a symbol and a word** (as on the TV: A note that
    /// only colour carries is missing for one person in ten).
    var catchUpAvailable = false

    var body: some View {
        HStack(alignment: .top, spacing: MetricsBoard.phone.gutter) {
            Text(verbatim: broadcast.start.formatted(date: .omitted, time: .shortened))
                .font(TypeLevel.footer.font.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isRunning ? ColorRole.text.color : ColorRole.textMatt.color)
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isRunning { LiveBadge() }
                    Text(verbatim: broadcast.title)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if catchUpAvailable {
                    Label {
                        Text(appKey: "live.rasterRecording")
                    } icon: {
                        Image(systemName: Glyph.history.name)
                    }
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                }
                if let text = broadcast.description, !text.isEmpty {
                    Text(verbatim: text)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, 10)
        .frame(minHeight: Metrics.target)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Divider().overlay(ColorRole.lineQuiet.color).padding(.leading, MetricsBoard.phone.margin + 52)
        }
        .accessibilityElement(children: .combine)
    }

    private var isRunning: Bool { broadcast.isRunning(at: now) }
}

/// Where the time picker jumps to.
///
/// **Three and no more.** Every further marker would have to share the space with the
/// others, and the fourth answers no question anyone asks.
enum TimeMark: Int, CaseIterable {
    case now, evening, tomorrow

    static var labels: [String] {
        allCases.map { AppLanguageSetting.text(.init($0.key)) }
    }

    var key: String {
        switch self {
        case .now: "live.rasterNow"
        case .evening: "live.timePrime"
        case .tomorrow: "sport.tomorrow"
        }
    }

    /// From when on programmes are shown.
    ///
    /// `nonisolated`, because it is a calculation on a date — a test should be able to run it
    /// without the main queue.
    func start(um now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .now: now
        case .evening:
            // **20:15 today, and after 20:15 still 20:15 today.** Anyone who taps "20:15" at 21:00
            // wants to see the main film that is running — not tomorrow's.
            calendar.date(bySettingHour: 20, minute: 15, second: 0, of: now) ?? now
        case .tomorrow:
            calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        }
    }

    /// Until when programmes are shown — `nil` means: until the end of what is known.
    func end(um now: Date, calendar: Calendar = .current) -> Date? {
        guard self == .tomorrow else { return nil }
        return calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))
    }
}

/// What the channel detail page shows.
@MainActor
@Observable
final class ChannelDetailModel {

    enum Situation: Sendable, Equatable { case isLoading, none, settled }

    let bundles: ChannelBundle
    private(set) var state: Situation = .isLoading
    private(set) var broadcasts: [Programme] = []
    /// Which time marker is selected — as a number, because ``SegmentRow`` keeps a position.
    var tag = TimeMark.now.rawValue

    /// The clock of this view, set once on load.
    ///
    /// **Not `Date()` in the body**: Otherwise every row would calculate with its own second,
    /// and the time markers would jump between two redraws.
    private(set) var now = Date()

    private let source: (any ChannelListingSource)?

    init(bundles: ChannelBundle, source: (any ChannelListingSource)?) {
        self.bundles = bundles
        self.source = source
    }

    func load() async {
        guard let source else {
            state = .none
            return
        }
        now = Date()
        // **The first feed that knows something.** At the provider, often only one of the
        // variants carries a programme ID — "Das Nordlicht HD" has one, "Das Nordlicht SD" does not.
        var found: [Programme] = []
        for zuspielung in bundles.feeds {
            found = await source.dailyProgramme(forItem: zuspielung)
            if !found.isEmpty { break }
        }
        broadcasts = found.sorted { $0.start < $1.start }
        state = broadcasts.isEmpty ? .none : .settled
    }

    /// What is shown for the selected time marker.
    ///
    /// **The running programme stays, even if it began before the marker.** Anyone who taps
    /// "20:15" while the main film has been running since 20:00 wants to see it and not just
    /// what comes at 21:45.
    ///
    /// **Under "Now", what can still be caught up on comes first** (A2): past programmes of
    /// an archive channel that are still in the archive. Without an archive, it stays with the
    /// daily schedule from now on.
    var isVisible: [Programme] {
        let tag = TimeMark(rawValue: tag) ?? .now
        let from = tag.start(um: now)
        let until = tag.end(um: now)
        return broadcasts.filter { broadcast in
            guard broadcast.end > from || (tag == .now && catchUpAvailable(broadcast)) else {
                return false
            }
            guard let until else { return true }
            return broadcast.start < until
        }
    }

    /// The running programme — the list scrolls there on opening.
    var running: Programme? { isVisible.first { $0.isRunning(at: now) } }

    /// Whether a programme is over and still in the archive (``Flows/CatchUpSelection``).
    func catchUpAvailable(_ broadcast: Programme) -> Bool {
        CatchUpSelection.catchUpAvailable(feeds: bundles.feeds, broadcast: broadcast, now: now)
    }
}
