import Core
import DesignSystemPhone
import SwiftUI

/// The channel list **over the running picture** — channels on the left, schedule on the right.
///
/// **This was asked for** (2026-09-06): *"On tvOS, while watching live, the channel list
/// with its group hangs on the left and the schedule on the right."* This view is the
/// port, not the copy — and what changes along the way is documented here.
///
/// **Not a sheet from the bottom.** A sheet lies horizontally over the picture; held in
/// landscape, only a strip of two rows would be left for the list. This view instead
/// covers the left half of the picture and leaves the right one free — on the TV it is
/// the same split and for the same reason: **you choose while you keep watching.**
///
/// **In portrait the right column drops out instead of shrinking.** Two columns on 393
/// points would be two too narrow ones; the broadcast that is running then appears in the
/// row, where it appears anyway.
///
/// **One press on the row switches, the schedule sits next to it.** The same two targets
/// as in the Live tab (``ChannelListScreen``) with the same meaning — whoever invented their own
/// rule here would have two channel lists that operate differently.
struct ChannelPicker: View {

    let model: LiveModel
    /// Which channel is running right now — it carries the mark and appears on the right when
    /// opened.
    let runningChannel: String?
    let select: (Channel) -> Void
    let close: () -> Void

    /// The channel whose schedule appears on the right.
    ///
    /// **Separate from the one that is running.** That is the whole purpose of the second
    /// column: whoever only wants to see what is on another channel should not have to
    /// switch for it — on an account with **one** allowed connection, every switch costs a
    /// teardown and a new startup.
    @State private var shown: ChannelBundle?
    @State private var isGroupSheetOpen = false
    @State private var now = Date()

    var body: some View {
        GeometryReader { space in
            let isLandscape = space.size.width > space.size.height

            HStack(spacing: 0) {
                leftColumn
                    .frame(width: isLandscape ? space.size.width * Self.leftShare : space.size.width)
                    .background(ColorRole.reason.color.opacity(0.94))

                if isLandscape {
                    rightColumn
                        .frame(maxWidth: .infinity)
                        // **Only dimmed and not filled.** On the right the picture keeps running; an opaque
                        // surface over it would take away exactly what this split is for.
                        // systemfarbe: A veil over the running picture, not a background. It should darken the
                        // picture and not tint it; every board color would lay a cast over it.
                        .background(Color.black.opacity(0.55))
                }
            }
        }
        // **The top margin stays.** Until 2026-09-07 this had `.ignoresSafeArea()` without edges,
        // and the group title lay under the Dynamic Island on the phone — the number after
        // "All" could not be read (screenshot from testing). At the bottom and sides the
        // surface should reach the edge so the picture runs through on the right; at the top
        // the header belongs below whatever the device carries there.
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        // **In a scroll area, as in the Live tab.** Seen on the device (2026-09-07): the sheet showed
        // the first countries and could not be scrolled — `ChannelGroupSheet` does not scroll
        // itself, its host does, and here it had none.
        .sheet(isPresented: $isGroupSheetOpen) { ScrollView { groupSheet } }
        .task { await model.load() }
        .task { await runClock() }
    }

    /// How wide the channel column is.
    ///
    /// **Forty-eight percent and not a third.** A ``ChannelListRow`` carries logo, name and two
    /// schedule lines; below roughly 380 points the broadcast wraps, and 72 points of row
    /// height become 96 — in a list whose whole purpose is the number of visible channels.
    static let leftShare = 0.48

    // MARK: - Left: group and channels

    private var leftColumn: some View {
        VStack(spacing: 0) {
            header

            SearchField(
                text: Binding(get: { model.searchTerm }, set: { model.searchTerm = $0 }),
                placeholder: "live.searchPrompt")

            ChannelListScreen(
                segments: model.segments,
                program: { model.program(zu: $0) },
                now: now,
                open: { select($0) },
                memorize: { channel in Task { await model.setEnabled(favorite: channel) } },
                // **The row's second path does not lead one level deeper here but to the right.** In the
                // Live tab it opens ``ChannelDetailView``; a full screen over a running picture would be
                // exactly the jump this split avoids.
                showProgram: { shown = $0 })
        }
    }

    private var header: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Button(action: close) {
                Image(systemName: Glyph.close.name)
            }
            .buttonStyle(.rounded)
            .accessibilityLabel(Text(app: "action.close"))

            TitleChoice(title: groupTitle) { isGroupSheetOpen = true }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.gutter)
    }

    /// **The same title as in the Live tab, including the count.** Two wordings for the same
    /// information would be two places where it can drift apart.
    private var groupTitle: String {
        guard let chosen = model.chosen else {
            return SettingsModel.text("common.all") + " "
                + model.visibleCount.formatted()
        }
        return chosen
    }

    private var groupSheet: some View {
        ChannelGroupSheet(
            routes: GroupPath.routes(from: model.groups),
            total: model.visibleCount,
            chosen: model.chosen
        ) { group in
            isGroupSheetOpen = false
            if group != model.chosen { model.select(group: group) }
        }
    }

    // MARK: - Right: the programme run

    @ViewBuilder
    private var rightColumn: some View {
        if let bundles = shownOrRunning {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: bundles.name)
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.top, MetricsBoard.phone.section)

                programRun(bundles)
            }
        } else {
            // **Without a channel there is no schedule, and that is not an error.** When opened over
            // a film — not over a channel — nothing appears on the right yet.
            HintRow(
                icon: Glyph.info.name, title: "player.channels.pick",
                message: "player.channels.pick.text")
        }
    }

    /// The channel whose schedule appears on the right — **first the selection, then the
    /// running one.**
    private var shownOrRunning: ChannelBundle? {
        shown
            ?? model.rows.first { bundles in
                bundles.feeds.contains { $0.id == runningChannel }
            }
    }

    @ViewBuilder
    private func programRun(_ bundles: ChannelBundle) -> some View {
        switch model.program(zu: bundles) {
        case .list(let broadcasts):
            List {
                ForEach(upcoming(broadcasts)) { broadcast in
                    ProgramRow(broadcast: broadcast, isRunning: broadcast.isRunning(at: now))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(ColorRole.lineQuiet.color)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        case .none:
            HintRow(
                icon: Glyph.info.name, title: "live.noGuide",
                message: "live.noGuide.text")
        case .pending:
            ProgressView().tint(ColorRole.textMatt.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What is still to come — **and the running broadcast stays in.**
    ///
    /// Omitting the past is the whole difference between a schedule and an archive: when
    /// opened, what is running right now should be at the top, and not what ran this morning.
    private func upcoming(_ broadcasts: [Programme]) -> [Programme] {
        broadcasts.filter { $0.end > now }.sorted { $0.start < $1.start }
    }

    /// **The clock lives here and not in the row.** Otherwise every row would compute with its
    /// own second, and two broadcasts of equal length would show different remaining times —
    /// the same rule as in ``ChannelListRow``.
    private func runClock() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            now = Date()
        }
    }
}

/// One broadcast in the schedule — time, title, and the running one highlighted.
struct ProgramRow: View {

    let broadcast: Programme
    let isRunning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MetricsBoard.phone.gutter) {
            Text(verbatim: Self.clock.string(from: broadcast.start))
                .font(TypeLevel.label.font.monospacedDigit())
                .foregroundStyle(isRunning ? ColorRole.brandLight.color : ColorRole.textQuiet.color)
                .frame(width: 46, alignment: .leading)

            Text(verbatim: broadcast.title)
                .font(TypeLevel.text.font)
                .foregroundStyle(isRunning ? ColorRole.text.color : ColorRole.textMatt.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, Metrics.targetSpacing)
        .accessibilityElement(children: .combine)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
