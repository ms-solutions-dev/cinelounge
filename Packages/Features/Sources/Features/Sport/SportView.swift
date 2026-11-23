import Core
import DesignSystem
import SwiftUI

/// The schedule — the live sports broadcasts of the next 24 hours.
///
/// The layout follows the design `design/sport-area.html`, with one deviation:
/// **no more day tabs** (product decision 2026-09-02). The section shows a rolling window of
/// 24 hours, see ``SportWindow``. Above it the sports filter bar, below it the events
/// with time band, channel bars and live mark. An event with one channel plays
/// immediately; several open the channel picker. A long press bookmarks the match or
/// follows the team and competition.
public struct SportView: View {

    // Observed, not held: The model belongs to the shell's ``SportKeeper`` and survives
    // the section change — only that way is the list there immediately on return
    // (requirement 2026-08-16).
    @ObservedObject private var model: SportModel
    @FocusState private var focus: String?

    /// Plays a channel — with the catalog from which switching continues.
    let onPlayChannel: (Channel, [Channel]) -> Void

    /// The last step of the staircase out — into the sidebar.
    let onLeaveToSidebar: () -> Void

    /// Counts up when the player closes — the section then takes the focus back to the row
    /// from which playback started (on-device finding 2026-08-16: on going back, the cursor
    /// always jumps into the sidebar). The same pattern as ``LiveView/focusToken``.
    var focusToken: Int = 0

    /// The event whose channel picker is open.
    @State private var choosing: SportEvent?
    /// The row from which playback last started — the target of the focus return.
    @State private var lastPlayed: String?
    /// The tick for "running" marks and remaining times.
    @State private var now = Date()

    /// The scroller of the event list — for the jump to the top and the return from the
    /// player. The list is built lazily; a focus on a row that does not exist yet fizzles
    /// out without an error.
    @State private var scroller: ScrollViewProxy?

    public init(
        model: SportModel,
        focusToken: Int = 0,
        onLeaveToSidebar: @escaping () -> Void = {},
        onPlayChannel: @escaping (Channel, [Channel]) -> Void
    ) {
        self.model = model
        self.focusToken = focusToken
        self.onLeaveToSidebar = onLeaveToSidebar
        self.onPlayChannel = onPlayChannel
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Text(app: "tab.sport")
                        .font(TypeLevel.title.font)
                        .foregroundStyle(ColorRole.text.color)

                    // **Instead of the day tabs** (product decision 2026-09-02). Without it nothing would say
                    // which time span the list means — and a list without a time span reads as
                    // "everything there is".
                    Text(app: "sport.window")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)

                    // **The status line says what the section is looking at.** Without it an empty
                    // schedule cannot be told apart from an old prefetch — and the finding of 2026-08-29
                    // hinged on exactly that.
                    if let state = model.fetchStatus {
                        Text(
                            String(
                                format: AppLanguageSetting.text("sport.stand"),
                                SportModel.alter(state.lastFetched))
                        )
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                    }

                    Button {
                        // **The press is discarded in the body and not at the button** (AP22, added here on
                        // 2026-09-11 during the pass for AP30). Here it said `.disabled(model.isFetching)` — and on
                        // tvOS a disabled button is not a faded button but **none**: it drops out of the focus
                        // tree, tvOS reassigns, and the focus ends up somewhere afterwards. Fetching goes
                        // over the thin line; one is watching during exactly those seconds.
                        guard !model.isFetching else { return }
                        Task { await model.fetch() }
                    } label: {
                        HStack(spacing: 10) {
                            if model.isFetching {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(app: "sport.refresh")
                        }
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(
                            focus == "sport-hole" ? ColorRole.reason.color : ColorRole.text.color
                        )
                        .padding(.horizontal, 26)
                        .padding(.vertical, 14)
                        .background(
                            focus == "sport-hole" ? ColorRole.text.color : ColorRole.surface.color,
                            in: Capsule()
                        )
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: "sport-hole")
                    .info(
                        appKey: "sport.refresh",
                        .key(model.isFetching ? "a11y.state.busy" : nil))

                    Spacer(minLength: 0)
                }
                .padding(.bottom, 26)
                // **Both together, otherwise the button is not reachable** (viewer finding 2026-08-29:
                // the button could not be navigated to).
                //
                // The focus section of its own, because the two rows below it have one too — without
                // it the focus leaves the whole content area on a press up instead of going into the
                // header.
                //
                // And the position: The button stood at the far right, the filter row begins at the
                // left. tvOS searches geometrically, and above the first chip there was simply
                // nothing. Now it stands at the left, next to the status line, with the gap behind
                // it.
                .focusSection()

                filterRow

                content
            }
            .padding(.top, TVMetrics.topMargin)
            .padding(.leading, 56)
            .padding(.trailing, MetricsBoard.tv.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await model.load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
        // On entering, "All" (requirement 2026-08-16): Whoever opens the section wants to see the
        // day — not the filter from the last visit.
        .onAppear { model.filter = .all }
        // The section's focus trace — the on-device finding "cannot be focused" (2026-08-16) was
        // blind without it: a minute of key presses in the log, and no line said where the
        // focus was.
        .onChange(of: focus) { previous, current in
            Diagnostics.cursorMoved("Spielplan", from: previous, to: current)
            keepFocusInChoice(current)
        }
        // The player does not hand the focus back; the section takes it — onto the row from
        // which playback started.
        //
        // **With scroller and regrab** (E4, following the house pattern from
        // ``LiveView/jumpToGroup(with:)``). A bare `focus = lastPlayed` was enough only as
        // long as the row was still built: The list is lazy, and whoever played from row 40
        // returns to a list that begins at row 1. The focus then fizzles out without an
        // error, and tvOS puts it on the first built row.
        .onChange(of: focusToken) { _, _ in
            guard let lastPlayed else { return }
            jumpTo(lastPlayed)
        }
        // **Disabled as long as the channel picker is open** — following the example of the
        // filmography: As a sheet (`sheet`) the list behind it kept the focus, and the
        // channel picker could not be operated (on-device finding 2026-08-16: the focus stays
        // somewhere in the background). What is disabled is not even considered as a focus
        // target.
        .disabled(choosing != nil)
        // **The staircase out** (E4). The schedule was the only long list section without it:
        // A press on Menu at row 150 threw straight into the sidebar — position, focus and
        // scroll position lost in one press. The same staircase applies as in the provider
        // media library, and the same rule calculates it
        // (``FocusRules/stepOut(along:pending:)``).
        .onExitCommand { leaveOneStep() }
        .overlay {
            if let event = choosing {
                channelChoice(for: event)
                    .transition(.opacity)
            }
        }
    }

    /// Brings the focus back into the open channel picker in case tvOS hands it out beside
    /// it — for example into the sidebar, which knows nothing about the section being
    /// disabled. When it takes effect, it is a silent no-op pass.
    private func keepFocusInChoice(_ current: String?) {
        guard let event = choosing, current?.hasPrefix("choose-") != true,
            let first = model.sportChannels(of: event).first
        else { return }
        focus = "choose-\(first.id)"
    }

    // MARK: - Header

    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                filterChip(
                    id: "filter-all", systemImage: "sportscourt", labelKey: "common.all",
                    isOn: model.filter == .all
                ) { model.filter = .all }
                filterChip(
                    id: "filter-marked", systemImage: "star.fill", labelKey: "sport.filter.marked",
                    isOn: model.filter == .marked
                ) { model.filter = .marked }
                filterChip(
                    id: "filter-verified", systemImage: "checkmark.seal.fill",
                    labelKey: "sport.filter.verified",
                    isOn: model.filter == .verified
                ) { model.filter = .verified }
                ForEach(model.availableKinds, id: \.rawValue) { kind in
                    filterChip(
                        id: "filter-\(kind.rawValue)", systemImage: kind.symbol,
                        labelKey: kind.labelKey,
                        isOn: model.filter == .kind(kind)
                    ) { model.filter = .kind(kind) }
                }
            }
        }
        .scrollClipDisabled()
        .padding(.bottom, 26)
        .focusSection()
    }

    private func filterChip(
        id: String, systemImage: String, labelKey: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                Text(appKey: labelKey)
                    .font(TypeLevel.lowercased.font)
            }
            .frame(minWidth: 116)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(
                background(forFocusID: id, isOn: isOn),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .foregroundStyle(foreground(forFocusID: id, isOn: isOn))
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .info(appKey: labelKey, .on(isOn))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            hint(systemImage: "hourglass", titleKey: "sport.loading")
        case .noGuide:
            // **Three empty cases instead of one** (E1 of the sports concept). Until 2026-08-29 they
            // looked alike, and that was the reason "only one entry for today" could not be
            // cleared up: an empty prefetch, a prefetch without broadcasts on this day and a
            // filter that eats everything all showed the same sentence.
            //
            // Here: the prefetch is really empty. The button next to it fills it.
            hint(systemImage: "calendar.badge.exclamationmark", titleKey: "sport.noGuide")
        case .noWindow:
            // The prefetch carries, but not on this day. The provider EPG reaches, as measured,
            // about +24 h — whoever pages further is at the edge.
            hint(systemImage: "calendar", titleKey: "sport.noWindow")
        case .noSport:
            // Broadcasts yes, live sport no. That blames the filter and not the prefetch — and
            // exactly this information was missing.
            hint(systemImage: "sportscourt", titleKey: "sport.noSport")
        case .ready:
            if model.shown.isEmpty {
                hint(systemImage: "sportscourt", titleKey: "sport.emptyWindow")
            } else {
                eventList
            }
        }
    }

    private func hint(systemImage: String, titleKey: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(appKey: titleKey)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .padding(.top, 60)
    }

    private var eventList: some View {
        ScrollViewReader { roller in
            eventScroller
                // The scroller belongs to the view and not to this component: The jump to the top of
                // the list is triggered by the Menu button, and that arrives at the outer frame.
                .onAppear { scroller = roller }
        }
    }

    private var eventScroller: some View {
        ScrollView {
            // Lazy, not eager: With ~90 events the eager stack built all rows at once and did so
            // again on EVERY focus change — the section felt numb (on-device finding 2026-08-16).
            // **Without conference headers** (product decision 2026-08-29: no grouping labels inside
            // the list, for example a mid-list label such as "Turkish Super Lig, 2 matches"; such
            // things are fundamentally not needed).
            //
            // E7 had built them because the concept provides for them in section 5. Seen on the
            // TV they interrupt the flow of the list without answering a question: The matches
            // stand together by kickoff time anyway, and the competition name is in every row.
            // ``SportConference`` stays in the source together with its tests — the grouping is
            // calculated and verified, it is just not shown.
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(model.shown) { event in
                    eventRow(event)
                }
            }
            .padding(.bottom, TVMetrics.topMargin)
        }
        .focusSection()
    }

    // MARK: - The way out and back

    /// One step out — the rule for it is stated in
    /// ``FocusRules/stepOut(along:pending:)``.
    ///
    /// The same staircase as in the provider media library: first to the top of the list,
    /// then into the sidebar. **The catcher always does something** — an `onExitCommand`
    /// whose body may remain empty still consumes the button, and then one can no longer
    /// get out at all (lesson from P14).
    private func leaveOneStep() {
        let ids = model.shown.map(\.id)
        switch FocusRules.stepOut(
            along: FocusRules.vodLadder,
            pending: LibraryView.pendingExitSteps(focus: focus, ids: ids))
        {
        case .topOfList:
            if let first = ids.first { jumpTo(first) } else { onLeaveToSidebar() }
        default:
            onLeaveToSidebar()
        }
    }

    /// Sets the focus on a row — **first scroll, then grab, then regrab** (house pattern,
    /// lesson from E20).
    ///
    /// The list is built lazily: A focus on a row that does not exist yet fizzles out
    /// without an error — and a press that does nothing looks like a broken button on the
    /// TV.
    private func jumpTo(_ id: String) {
        scroller?.scrollTo(id, anchor: .center)
        focus = id

        Task { @MainActor in
            // **First wait, then check.** A focus that has just been written reads back
            // immediately, even if tvOS never accepted it — whoever checks in the same breath
            // always gets a yes.
            for _ in 1...5 {
                try? await Task.sleep(for: .milliseconds(50))
                if focus == id { return }
                scroller?.scrollTo(id, anchor: .center)
                focus = id
            }
        }
    }

    private func eventRow(_ event: SportEvent) -> some View {
        let channels = model.sportChannels(of: event)
        let isFocused = focus == event.id

        return HStack(spacing: 26) {
            timeColumn(event)

            Button {
                play(event, channels: channels)
            } label: {
                HStack(spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let competition = event.competition {
                            Text(verbatim: competition.uppercased())
                                .font(TypeLevel.lowercased.font)
                                .kerning(2)
                                .foregroundStyle(ColorRole.textQuiet.color)
                        }
                        HStack(spacing: 10) {
                            Text(verbatim: event.title)
                                .font(TypeLevel.header.font)
                                .fontWeight(.bold)
                                .lineLimit(1)
                            if event.isVerified {
                                // The seal of the sync: The kickoff time is confirmed by the online source — no
                                // repeat broadcast possible.
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(ColorRole.textQuiet.color)
                            }
                            if model.memory.marks(event) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(ColorRole.progress.color)
                            }
                        }
                        channelLine(channels)
                    }

                    Spacer(minLength: 20)

                    stateBadge(for: event)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 22)
                .background(
                    isFocused ? ColorRole.surfaceHigh.color : ColorRole.surface.color,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                // **The focus inversion has been taken back** (open decision 5 of the concept,
                // decided 2026-09-02).
                //
                // The row inverted onto the cream-coloured surface, and with that three colour
                // carriers stood on the wrong background: The bookmark star came to **1.50–1.80:1**
                // and was practically invisible, the remaining time to 2.47–3.08:1, the live mark
                // lost its red to the brightness. The approved design (`design/sport-area.html`,
                // `.ev.focused`) provides `surfaceRaised` plus an accent border for exactly this
                // reason: A border does not change the colour of the content — it encloses it.
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isFocused ? ColorRole.tag.color : .clear, lineWidth: 3)
                )
                .foregroundStyle(ColorRole.text.color)
                // The third carrier of the design: a hint of size. Surface and border alone do not
                // carry from three metres, and a fourth colour change would be exactly what has just
                // been dropped.
                .scaleEffect(isFocused ? 1.015 : 1)
                .animation(.easeOut(duration: 0.14), value: isFocused)
            }
            .bareFocusableButton()
            .focused($focus, equals: event.id)
            // **Seal and star are the only information here** — both just a symbol, one of them
            // in a colour that was already lost once on the focus background.
            .info(
                Text(verbatim: event.title),
                [
                    .key(event.isVerified ? "a11y.state.verified" : nil),
                    .key(model.memory.marks(event) ? "a11y.state.remembered" : nil),
                ]
            )
            .contextMenu { rememberMenu(for: event) }
        }
        .id(event.id)
    }

    /// The time column — sport symbol, time of day, and above it the day if the kickoff
    /// is not today.
    ///
    /// **Why the day belongs here** (E3, 2026-08-29; extended 2026-09-02): Here there used to be
    /// only the bare time of day, and that is information about today. Two cases refute
    /// it, and both are real with the 24-hour window: a broadcast that has been running
    /// since yesterday, and tomorrow's early match that stands in the window at 22:00.
    /// "10:30" alone otherwise reads as today 10:30 — that is, as something long over.
    ///
    /// **176 instead of 132 points, and the sport symbol moves in** (E4). Two measurements
    /// from the concept: "10:40 PM" needs 170 pt and was cut off in 12-hour regions; and the
    /// sport symbol took up 90 pt in **every** row, although in 48 of 54 it was the same
    /// ⚽. It now stands above the time, where it fills the column, instead of taking width
    /// from the title.
    private func timeColumn(_ event: SportEvent) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 34))
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.bottom, 4)
            timeReference(event)
            Text(verbatim: event.start.formatted(date: .omitted, time: .shortened))
                .font(TypeLevel.header.font)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .frame(width: 176, alignment: .trailing)
    }

    @ViewBuilder
    private func timeReference(_ event: SportEvent) -> some View {
        // The model calculates the rule itself — the view only looks up its words for it
        // (concept, section 4: no sport rule in ``SportView``).
        switch model.timeRelation(of: event) {
        case .today:
            EmptyView()
        case .tomorrow:
            Text(app: "sport.tomorrow")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
        case .yesterday:
            Text(app: "sport.yesterday")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
        case .earlier:
            Text(verbatim: event.start.formatted(.dateTime.day().month()))
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
        }
    }

    /// The channel bar of a row — **stations, not feeds**.
    ///
    /// Viewer, 2026-08-29: for Waubedaut–Kafausko 10 channels are shown, and something can hardly
    /// be right there. The source names one; the provider's channel list has ten of them,
    /// all under the same programme identifier. Bundling happens in ``ChannelVariants``,
    /// here only the result remains.
    ///
    /// **`FlowLayout` instead of `HStack`** (E4): An `HStack` does not wrap, it squeezes —
    /// and where nothing is left to squeeze, it cuts off. Three channels with long names
    /// looked like two that way.
    private func channelLine(_ channels: [ChannelVariants.VariantGroup]) -> some View {
        FlowLayout(spacing: 10, lineSpacing: 8) {
            ForEach(channels.prefix(3)) { bundles in
                Text(verbatim: bundles.name)
                    .font(TypeLevel.lowercased.font)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(ColorRole.reason.color, in: Capsule())
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            if channels.count > 3 {
                Text(app: "sport.moreChannels \(channels.count - 3)")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
    }

    @ViewBuilder
    private func stateBadge(for event: SportEvent) -> some View {
        if event.isRunning(at: now) {
            HStack(spacing: 10) {
                Circle().fill(ColorRole.live.color).frame(width: 12, height: 12)
                Text(app: "player.live")
                    .font(TypeLevel.footer.font)
                    .fontWeight(.heavy)
            }
            .foregroundStyle(ColorRole.live.color)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .overlay(Capsule().strokeBorder(ColorRole.live.color, lineWidth: 2))
        } else {
            Text(verbatim: remaining(until: event.start))
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
        }
    }

    private func remaining(until date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes >= 60 {
            return String(
                format: AppLanguageSetting.text("sport.inHours"), minutes / 60,
                minutes % 60)
        }
        return String(format: AppLanguageSetting.text("sport.inMinutes"), minutes)
    }

    // MARK: - Remembering

    /// **First the match, then club and competition** (B5, 2026-09-26) — the same menu as
    /// on the phone, and the same watch list behind it.
    @ViewBuilder
    private func rememberMenu(for event: SportEvent) -> some View {
        let bookmarked = model.memory.isBookmarked(event)
        Button {
            model.toggleMatch(event)
        } label: {
            Label {
                Text(app: bookmarked ? "sport.unmark" : "sport.mark")
            } icon: {
                Image(systemName: Glyph.bookmark.pair.zu(active: bookmarked))
            }
        }
        if let pairing = SportPlan.pairing(in: event.title) {
            rememberButton(pairing.home, marked: model.memory.hasTeam(pairing.home)) {
                model.toggleTeam(pairing.home)
            }
            rememberButton(pairing.away, marked: model.memory.hasTeam(pairing.away)) {
                model.toggleTeam(pairing.away)
            }
        }
        if let competition = event.competition {
            rememberButton(
                competition, marked: model.memory.hasCompetition(competition)
            ) {
                model.toggleCompetition(competition)
            }
        }
    }

    private func rememberButton(
        _ name: String, marked: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(verbatim: name)
            } icon: {
                Image(systemName: marked ? "star.fill" : "star")
            }
        }
        // **The star is the whole information here.** The label is the team's name and does not
        // change with it — without this line "Bookmark" sounds like "Remove bookmark", and
        // both stand one below the other in the same menu.
        .info(name: name, .key(marked ? "a11y.state.remembered" : nil))
    }

    // MARK: - Playing

    private func play(_ event: SportEvent, channels: [ChannelVariants.VariantGroup]) {
        lastPlayed = event.id
        switch channels.count {
        case 0:
            // No channel to resolve — the programme identifier leads nowhere. Happens when a
            // channel was hidden; the entry remains information, only the jump-off is missing.
            break
        case 1:
            matches(channels[0], from: channels)
        default:
            choosing = event
        }
    }

    /// Plays the best variant of a station — and switches on through the **stations**, not
    /// through their variants.
    ///
    /// This is the second half of bundling: Whoever opens from a match wants to go with
    /// Up/Down to the next channel that shows it. With the unbundled catalog they ended up
    /// at the same station four times.
    private func matches(
        _ bundles: ChannelVariants.VariantGroup, from channels: [ChannelVariants.VariantGroup]
    ) {
        onPlayChannel(bundles.best, channels.map(\.best))
    }

    private func channelChoice(for event: SportEvent) -> some View {
        let channels = model.sportChannels(of: event)

        return ZStack {
            // Darkened background instead of a system sheet: The window lies as an overlay over
            // the disabled section, the focus can only be here — as with the filmography.
            ColorRole.reason.color.opacity(0.72).ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 8) {
                if let competition = event.competition {
                    Text(verbatim: competition.uppercased())
                        .font(TypeLevel.lowercased.font)
                        .kerning(2)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                Text(verbatim: event.title)
                    .font(TypeLevel.section.font)
                    .fontWeight(.heavy)
                    .foregroundStyle(ColorRole.text.color)
                Text(app: "sport.channelCount \(channels.count)")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .padding(.bottom, 24)

                // **A scroll container, and that is not cosmetic** (E4): Eleven channel rows need
                // 1,180 pt at a screen height of 1,080 pt. The last ones stood outside the screen, and
                // the focus wandered to where nothing could be seen. Since the variants are bundled,
                // the case is rarer — it has not disappeared: A Bundesliga match runs on a dozen real
                // channels.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(channels) { bundles in
                            channelChoiceRow(bundles, from: channels)
                        }
                    }
                }
                .scrollClipDisabled()
            }
            .padding(52)
            .frame(maxWidth: 880, maxHeight: 900, alignment: .topLeading)
            .background(
                ColorRole.surface.color,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        // The focus moves into the window on opening — not only once tvOS has handed it out
        // somewhere.
        .onAppear {
            if let first = channels.first { focus = "choose-\(first.id)" }
        }
        // The Menu button closes the window and sets the focus back on the row it came from —
        // it does not lead out of the app.
        .onExitCommand {
            let eventID = event.id
            choosing = nil
            focus = eventID
        }
    }

    private func channelChoiceRow(
        _ bundles: ChannelVariants.VariantGroup, from channels: [ChannelVariants.VariantGroup]
    ) -> some View {
        let isFocused = focus == "choose-\(bundles.id)"

        return Button {
            choosing = nil
            matches(bundles, from: channels)
        } label: {
            HStack(spacing: 16) {
                Text(verbatim: bundles.name)
                    .font(TypeLevel.text.font)
                    .fontWeight(.semibold)
                Spacer(minLength: 12)
                // **What the number says, and what it does not say.** It names the feeds of this
                // station — the best one will start. The others remain in the catalog and are
                // available in the player through the group list; a second screen for that would be
                // exactly what the concept excludes with a single remote.
                if bundles.count > 1 {
                    Text(app: "sport.versions \(bundles.count)")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(
                            isFocused ? ColorRole.reason.color.opacity(0.6) : ColorRole.textQuiet.color)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .background(
                isFocused ? ColorRole.text.color : ColorRole.reason.color,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
        }
        .bareFocusableButton()
        .focused($focus, equals: "choose-\(bundles.id)")
        .padding(.top, 12)
    }

    // MARK: - Chip colors

    private func background(forFocusID id: String, isOn: Bool) -> Color {
        if focus == id { return ColorRole.text.color }
        return isOn ? ColorRole.surfaceHigh.color : ColorRole.surface.color
    }

    private func foreground(forFocusID id: String, isOn: Bool) -> Color {
        if focus == id { return ColorRole.reason.color }
        return isOn ? ColorRole.text.color : ColorRole.textMatt.color
    }

    private func secondary(forFocusID id: String) -> Color {
        focus == id ? ColorRole.reason.color.opacity(0.65) : ColorRole.textQuiet.color
    }
}
