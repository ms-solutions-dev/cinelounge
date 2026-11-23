import Core
import DesignSystem
import SwiftUI

/// What the player can offer beyond the channel that is playing.
///
/// **Supplied separately, not as knowledge inside the player.** It knows no source — that
/// is why a channel, a film and a trailer look the same to it. The Live area passes these
/// details in; when they are missing, the overlays simply do not exist, and everything
/// else runs unchanged.
public struct LivePlayerContext {

    /// All channels that can be switched to — in the order of the view.
    ///
    /// **As a question, not a snapshot.** The context is created when the player opens, and a
    /// list that is frozen at that moment stays that way for the whole playback — even if it
    /// was still empty at that instant. That is exactly what happened: the overlay appeared
    /// and showed nothing, without an error occurring anywhere.
    public let channels: () -> [Channel]

    /// The full catalog — **only asked for when ``channels`` is empty.**
    ///
    /// **This is the fix for "both overlays are empty on first open".** On 2026-08-08 the finding
    /// was given three plausible but wrong causes; what all the explanations had in common
    /// was that the overlay depended on **someone else** having filled a state beforehand —
    /// the Live area the viewer came from.
    ///
    /// That dependency is removed here instead of repaired: if the list is empty, the overlay
    /// fetches the catalog itself. That makes the error impossible no matter what caused it —
    /// and if it did lie with the suspected state, the log says so the next time it opens.
    public let allChannels: @MainActor () async -> [Channel]
    /// The programme of a channel. Only asked for when the overlay appears, never in advance:
    /// with a provider that allows one connection, every request is one that is missing
    /// elsewhere.
    public let guide: @MainActor (Channel) async -> [Programme]
    /// The playback target for a channel.
    public let target: @MainActor (Channel) -> PlaybackTarget

    /// Adopts the catalog from which switching happens from now on.
    ///
    /// **This is the fix for "only the first group goes up and down"** (viewer finding 2026-08-11,
    /// at night). The catalog arrives once, when the player opens — it carries the group the
    /// viewer came from. Anyone who changes the group in the overlay and picks a channel there
    /// continues with a channel that **does not appear** in that catalog: no neighbour for the
    /// arrow keys, no running channel for the list, no group, no programme. The same four
    /// failures as with the address, just one level higher.
    ///
    /// That is why the overlay states, when picking, **what** it picked from.
    public let adopt: @MainActor ([Channel]) -> Void

    /// Records which channel is playing now — for the next press on "Live".
    ///
    /// **The finding of 2026-09-02** ("I always end up on the last sports channel"). The memory
    /// was written in four places, and all four were upstream of the player. A switch **in**
    /// the overlay passed none of them. It therefore lives here, where the switch happens, and
    /// not again in every caller that can trigger it — see
    /// ``LiveMemory/remember(playing:in:store:)``.
    public let remember: @MainActor (URL) -> Void

    public init(
        channels: @escaping () -> [Channel],
        allChannels: @escaping @MainActor () async -> [Channel] = { [] },
        guide: @escaping @MainActor (Channel) async -> [Programme],
        target: @escaping @MainActor (Channel) -> PlaybackTarget,
        adopt: @escaping @MainActor ([Channel]) -> Void = { _ in },
        remember: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.channels = channels
        self.allChannels = allChannels
        self.guide = guide
        self.target = target
        self.adopt = adopt
        self.remember = remember
    }
}

/// The two overlays while a channel is playing.
///
/// Channels on the left, programme on the right — both from the edge and over the picture.
/// **Separate rather than together**, because the questions differ: "where to switch" and
/// "what is coming next". Showing both at once covers the picture completely, and that is
/// exactly what this is not about.
/// **Explicitly NOT `Equatable`, and that is a lesson.** There was a comparison here to
/// decouple the overlay from the player's tick: it re-sets the position twice per second,
/// and the whole playback view hangs on that.
///
/// It made the overlay invisible. The log showed that it opens — the state switched
/// cleanly between "none", "channels" and "programme" —, yet it was not drawn: on
/// reopening, the page and the running channel are the same as last time, so SwiftUI
/// considered the view unchanged and skipped it.
///
/// The reason for the comparison has also gone away. The dark picture that prompted it
/// came from two engines loading the same stream — a double start on channel switch, also
/// found in the log. A comparison that eases a symptom whose cause lies elsewhere ends up
/// costing more than it brings.
struct LiveOverlay: View {

    enum Side: Equatable {
        /// The channels of the open group — a swipe to the left.
        case channels
        /// The groups — another swipe to the left, one level deeper.
        ///
        /// **The proposal carries further than it looks** (test report 2026-08-08): anyone who can
        /// change the group in the player no longer needs it in the sidebar — only the saved lists
        /// would remain there, instead of hundreds of groups that nobody scrolls through.
        case groups
        /// The programme — a swipe to the right.
        case guide

        var isLeft: Bool { self != .guide }
    }

    let side: Side
    let context: LivePlayerContext
    /// The channel that is playing right now — for the highlight and the title above the programme.
    let current: Channel?
    /// Which group the channel list is restricted to.
    ///
    /// **As a binding from outside and not as its own state**, and that is the fix for "the
    /// selection is gone again the next time it opens": the overlay is torn down on close, and
    /// every `@State` with it. But the choice belongs to the session in front of the TV and
    /// not to the lifetime of a view — so it lives in ``PlayerScreen``.
    @Binding var groupChoice: GroupChoice
    /// The chosen channel — **and the catalog it comes from.**
    let onSelect: (Channel, [Channel]) -> Void
    /// One level deeper — from the channels into the groups.
    var onDeeper: () -> Void = {}
    /// One level back. From the groups to the channels, from the channels into the picture.
    let onClose: () -> Void
    /// "Someone is here." Resets the deadline after which the overlay closes on its own — see
    /// ``PlayerScreen/overlayTimeout``.
    var onActivity: () -> Void = {}

    @FocusState private var focus: String?
    /// The running wait time of the wraparound.
    ///
    /// **Wait first, then wrap around** — the same treatment as in the sidebar, for the same
    /// measured reason: with quick tapping, the tvOS movement arrives about 260 ms after the
    /// press. Anyone who wraps before that gets it afterwards and jumps two rows (see
    /// ``AppSidebar/wrapDelay``).
    @State private var wrapTask: Task<Void, Never>?

    /// When the focus last moved — for the edge-press check of the wraparound, see
    /// ``AppSidebar/isEdgePress(lastFocusMove:now:)``.
    @State private var focusMovedAt = Date.distantPast
    /// Keeps the move command and the swipe gesture apart — see ``MoveGate``.
    @State private var gate = MoveGate()

    /// The scroller of the open list.
    ///
    /// **As state and not only in the build**, because the wraparound needs it: before a row is
    /// grabbed, the list has to scroll there, and that is decided at the key press and not
    /// while drawing. See ``jump(to:)``.
    @State private var scroller: ScrollViewProxy?
    @State private var programmes: [Programme] = []
    /// Whether an answer has been given yet. Without this distinction, "nothing loaded yet"
    /// would look exactly like "this channel has no programme" — and the viewer would wait for
    /// something that never comes (finding 2026-08-08).
    @State private var didAnswer = false
    /// The catalog the overlay fetched for itself — see
    /// ``LivePlayerContext/allChannels``.
    @State private var rescued: [Channel] = []
    /// The show the programme cursor is on.
    ///
    /// **The programme has no buttons and still needs a cursor.** Since it shows the whole day
    /// (three hours back, twenty-one ahead), it no longer fits on the picture — and without
    /// something that answers to up and down, the rest would be unreachable. They are still
    /// not buttons: a show cannot be selected, so there is nothing to press.
    @State private var guideCursor: String?

    /// Which group applies.
    ///
    /// **Without an explicit choice, that of the running channel**, and that was exactly the
    /// finding of 2026-08-11: "the channel list always opens HEVC, although the running show is
    /// from another group". The list showed the catalog the player was entered with — after a
    /// group switch in the player that was the wrong group, the running channel did not appear
    /// in it, and the focus fell on the first row instead of on the channel the viewer is on.
    public enum GroupChoice: Equatable, Sendable {
        /// Nobody has chosen: the group of the running channel applies.
        case ofCurrentChannel
        /// Explicitly all groups.
        case all
        case named(String)

        /// The group to restrict to — `nil` means: all.
        ///
        /// Without actor binding, because it is a pure computation over values: that way it can be
        /// tested without involving the main thread.
        nonisolated func group(current: Channel?) -> String? {
            switch self {
            case .ofCurrentChannel: current?.group
            case .all: nil
            case .named(let name): name
            }
        }
    }

    /// The applicable group. `nil` means: all.
    private var group: String? { groupChoice.group(current: current) }

    /// Width of both overlays.
    ///
    /// A little under a third of the picture: wide enough for channel names with a provider
    /// prefix, narrow enough that something of the film remains visible — otherwise it would
    /// not be an overlay but a change of view.
    static let width: CGFloat = 560

    var body: some View {
        HStack(spacing: 0) {
            if side == .guide { Spacer(minLength: 0) }

            panel
                .frame(width: Self.width)
                .background(background)
                // **An invisible anchor for the programme page.**
                //
                // It is pure text and takes no focus — since the transport bar yields while the overlay is
                // open, nobody held the focus in the picture any more. But tvOS delivers move commands
                // only while something is focused: the press to the left did not arrive in the player at
                // all, and the overlay could no longer be closed (viewer finding 2026-08-08). The channel
                // page does not need this — its rows are buttons.
                .overlay(alignment: .top) {
                    if side == .guide {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .focusable()
                            .focused($focus, equals: "guide-anchor")
                            .accessibilityHidden(true)
                    }
                }

            // **`side.isLeft`, not `side == .channels`.** There was a comparison with a single case
            // here, and with the group level a second left case was added: for it, nobody added a
            // stretch space either above or here, and the overlay stood in the middle of the picture
            // instead of at the edge.
            if side.isLeft { Spacer(minLength: 0) }
        }
        .ignoresSafeArea()
        // **No movement transition.** It was here and was the reason the overlay could not be
        // seen: a `move` transition pushes the view in from the edge — but only if the change is
        // animated. The state `overlay` is set without animation, and without it the view stayed
        // where the transition had put it: outside the picture. In the log that was
        // indistinguishable from "does not open at all" — the state switched cleanly, nothing was
        // drawn.
        //
        // Fading in via opacity does the same without moving the view: what is not moved cannot
        // end up beside the target either.
        .transition(.opacity)
        .onMoveCommand { direction in
            guard gate.accepts(direction, .now, from: .command) else { return }
            move(direction)
        }
        // **The second way in, for the old remote.** On the smooth glass surface, swiping creates
        // no move command — see ``RemoteSwipeDirection``. Both sources feed into the same rule,
        // and ``MoveGate`` makes sure that a movement counts only once where both report it.
        .onRemoteSwipe("Einblendung") { swipe in
            guard gate.accepts(swipe.asMove, .now, from: .gesture) else { return }
            move(swipe.asMove)
        }
        // **The catalog, in case nobody passed one in.** See ``LivePlayerContext/allChannels`` —
        // and the log says the next time it opens whether it was ever needed.
        // **The full catalog is always fetched**, not only as a fallback: the group list needs
        // it, and the one passed in carries only the open group. Once per overlay, from the cache
        // — no network request.
        .task {
            guard rescued.isEmpty else { return }
            rescued = await context.allChannels()
        }
        // **Bound to the running channel, not only to appearing.** Anyone who flips through
        // channels in the player while the overlay is open would otherwise keep seeing the
        // programme of the previous channel — the task ran exactly once.
        .task(id: current?.id) {
            guard side == .guide else { return }
            // Grab the anchor first, then load: without a set focus no move command arrives, and
            // loading takes its time.
            focus = "guide-anchor"
            // **The answer is recorded even when nothing was asked.** There was a
            // `guard let current else { return }` here, and that is exactly what the spinner that
            // spun forever hung on: if the player did not find the running channel again, the task
            // returned silently without ever answering (viewer finding 2026-08-08). The cause for that is
            // fixed — but an overlay that waits for a result nobody fetches any more must not exist
            // again. On a switch, clear first: the programme of the previous channel under the name
            // of the new one would be worse than none at all.
            programmes = []
            didAnswer = false
            if let current { programmes = await context.guide(current) }
            didAnswer = true
        }
    }

    /// The backdrop under the overlay — a gradient and not a surface.
    ///
    /// **The show keeps running and is meant to stay visible.** An almost opaque surface takes
    /// a third of the picture away; what remains is then no longer a film with an overlay on
    /// top, but a list with a remainder of film next to it. That was exactly the impression
    /// the first version made.
    ///
    /// Opaque at the outer edge, fading out towards the centre of the picture: there the text
    /// sits and needs a backdrop under it, here the picture counts. The gradient runs in the
    /// direction the overlay came from — otherwise the readable edge would be the wrong one.
    /// The channels, in the order of the view — asked afresh on every draw.
    ///
    /// **With a safety net below.** If the passed catalog is empty, the one the overlay
    /// fetched itself applies; see
    /// ``LivePlayerContext/allChannels``. And if a group is chosen, only it remains.
    private var channels: [Channel] {
        guard let group else { return stock }
        return stock.filter { $0.group == group }
    }

    /// The whole catalog across all groups — the basis of the group list.
    ///
    /// **The passed catalog is only the open group.** It comes from the Live area and carries
    /// exactly the channels that are flipped through up and down in the player — so a single
    /// group. Anyone who builds the group list from it gets exactly one entry (viewer finding
    /// 2026-08-11: "groups are not visible again"). The full catalog is therefore what is asked for.
    private var everything: [Channel] {
        rescued.isEmpty ? context.channels() : rescued
    }

    /// The groups of the catalog, in the order of their first appearance.
    ///
    /// Derived from the channels and not passed in additionally: a second source for the same
    /// information would be a second place where it can go stale.
    private var groups: [String] { Self.groupNames(in: everything) }

    /// The channels on offer.
    ///
    /// Without a chosen group, the passed catalog — that is exactly the group the arrow keys
    /// flip through, and both must match. With a chosen group, the full catalog, because
    /// otherwise you could choose the group but see nothing in it.
    private var stock: [Channel] {
        group == nil ? (context.channels().isEmpty ? rescued : context.channels()) : everything
    }

    static func groupNames(in channels: [Channel]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for channel in channels {
            guard let name = channel.group, !name.isEmpty, seen.insert(name).inserted else {
                continue
            }
            result.append(name)
        }
        return result
    }

    private var background: some View {
        LinearGradient(
            stops: [
                // Stronger than the usual gradients: behind the rows runs a live picture — with a bright
                // scene, white text at 0.78 opacity was barely readable (finding 2026-08-08, native picture).
                .init(color: ColorRole.reason.color.opacity(0.97), location: 0),
                .init(color: ColorRole.reason.color.opacity(0.9), location: 0.55),
                .init(color: ColorRole.reason.color.opacity(0.35), location: 1),
            ],
            startPoint: side == .channels ? .leading : .trailing,
            endPoint: side == .channels ? .trailing : .leading
        )
    }

    @ViewBuilder
    private var panel: some View {
        switch side {
        case .channels: channelList
        case .groups: groupList
        case .guide: guideList
        }
    }

    /// **The overlay takes all four directions itself.**
    ///
    /// What arrives here is only what the focus did not consume — so the press past the end of
    /// the list and the movement to the side. Those are exactly the two cases this is about:
    /// **up and down the list wraps around**, left goes one level deeper, right goes one back.
    ///
    /// **Left is deeper, right is back — the same everywhere.** "Double right to close" would
    /// have been the obvious alternative and is deliberately not built: right is already taken
    /// in the player, and a key that does two different things depending on state is exactly
    /// the unpredictability P14 set out to fight.
    /// For the log: which side is open.
    private var sideName: String {
        switch side {
        case .channels: "Channels"
        case .groups: "Groups"
        case .guide: "Guide"
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        Diagnostics.verbose(
            "Overlay \(sideName): key \(direction) arrived, focus \(focus ?? "—")"
        )
        onActivity()
        switch direction {
        case .up where side == .guide: moveGuideCursor(by: -1)
        case .down where side == .guide: moveGuideCursor(by: 1)
        case .up: wrap(by: -1)
        case .down: wrap(by: 1)
        case .left where side == .channels: onDeeper()
        case .right where side.isLeft: onClose()
        case .left where side == .guide: onClose()
        default: break
        }
    }

    /// The identifiers of the rows of the open list, in their order.
    private var rowIDs: [String] {
        side == .groups
            ? [Self.groupPrefix] + groups.map { Self.groupPrefix + $0 }
            : channels.map(\.id)
    }

    /// Leads the focus to a row — **scroll first, then grab.**
    ///
    /// **This is the cause that explains two findings** (2026-08-11: the cursor does not sit on
    /// the running channel, and the wraparound does not take effect). The list is built
    /// lazily: row 10 does not exist yet as long as only the first few are drawn, and a focus
    /// on a row that does not exist fizzles out without an error. In the group list both
    /// worked — it fits on the picture, so every row is already there. The viewer reported
    /// exactly this difference, and it is the witness for this explanation.
    ///
    /// **With re-grabbing**, because scrolling only creates a row on the next frame: the first
    /// attempt stands directly here — if it takes, the loop is finished after the first pass
    /// —, the further ones lie behind it. A loop and not a fixed wait: how long tvOS needs
    /// depends on the length of the list, and a guess would be wrong with the next provider.
    private func jump(to id: String) {
        Diagnostics.verbose("Overlay \(sideName): jumping to \(id)")
        scroller?.scrollTo(id, anchor: .center)
        focus = id

        Task { @MainActor in
            for attempt in 0..<6 {
                if focus == id {
                    if attempt > 0 {
                        Diagnostics.verbose("Overlay: \(id) only settled on attempt \(attempt)")
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
                scroller?.scrollTo(id, anchor: .center)
                focus = id
            }
            // **Giving up is better than standing on a row that does not exist.** If the focus
            // sticks nowhere, tvOS delivers no more move commands, and the overlay looks frozen.
            if focus != id {
                Diagnostics.verbose("Overlay \(sideName): \(id) not reachable, going to the start")
                focus = rowIDs.first
            }
        }
    }

    /// The wraparound at the end of the list.
    ///
    /// **tvOS has no natural wraparound** — arrived at the bottom, nothing happens, and one
    /// keeps pressing until one thinks the app has hung. The arrow keys in the player have long
    /// wrapped (`neighbourChannel`); the overlay did not.
    private func wrap(by offset: Int) {
        // **First wait to see whether the press does something after all.** The reasoning
        // including the measurement is at ``AppSidebar/wrapDelay``: our jump to the other end
        // stands immediately, the tvOS movement arrives 260 ms later — and then pushes on from
        // the new end.
        let on = focus
        wrapTask?.cancel()
        // **Only a real edge press plans a wraparound** — the command of a press that has just
        // led the focus ONTO the edge is the documented straggler (numeric finding 2026-08-16: it
        // doubles exactly the press that lands on the last entry). Rule at
        // ``AppSidebar/isEdgePress(lastFocusMove:now:)``.
        guard AppSidebar.isEdgePress(lastFocusMove: focusMovedAt) else { return }
        guard Self.wrapped(from: on, by: offset, in: rowIDs) != nil else { return }
        wrapTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(AppSidebar.wrapDelay))
            guard !Task.isCancelled, focus == on,
                let next = Self.wrapped(from: on, by: offset, in: rowIDs)
            else { return }
            jump(to: next)
        }
    }

    /// The cursor in the programme, without wraparound.
    ///
    /// **Unlike the lists, and on purpose.** A channel list is a ring — one has to go somewhere.
    /// A programme is a timeline: anyone who keeps pressing at the end of the day does not mean
    /// "back to the morning".
    private func moveGuideCursor(by offset: Int) {
        guard !programmes.isEmpty else { return }
        let ids = programmes.map(\.id)
        let index = guideCursor.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = min(max(index + offset, 0), ids.count - 1)
        guideCursor = ids[next]
        scroller?.scrollTo(ids[next], anchor: .center)
    }

    /// The row the wraparound leads to. `nil` if there is nothing to wrap around.
    ///
    /// **Only asked at the end.** Within the list the focus consumes the movement itself; what
    /// arrives here is what tvOS could no longer move — and exactly there the list should wrap
    /// around instead of standing still.
    static func wrapped(from current: String?, by offset: Int, in rows: [String]) -> String? {
        guard rows.count > 1, let current, let index = rows.firstIndex(of: current)
        else { return nil }
        // **Only at the edge, and that is the whole point.** `onMoveCommand` also arrives when the
        // focus has already moved — the assumption that it reports only unconsumed movements was
        // wrong (viewer finding 2026-08-11: "I press down once and it jumps twice"). In the middle of
        // the list the focus itself moves, so nothing may happen here; only at the end, where it
        // would stop, does it wrap around.
        if offset > 0, index == rows.count - 1 { return rows[0] }
        if offset < 0, index == 0 { return rows[rows.count - 1] }
        return nil
    }

    static let groupPrefix = "group-"

    /// The row the channel list opens on.
    ///
    /// **The running channel, if it appears in the list** — otherwise the list's first row.
    /// Stands here as a pure computation and not as a `guard` in the view, so that it is
    /// tested: "when I am on channel 10, the cursor should also be on 10 when opening and not
    /// elsewhere" (user request 2026-08-11) is a promise one does not want to verify on the TV.
    nonisolated static func openingRow(current: Channel?, in channels: [Channel]) -> String? {
        guard let current, channels.contains(where: { $0.id == current.id })
        else { return channels.first?.id }
        return current.id
    }

    // MARK: - Channels

    /// The header above a list — **fixed, not selectable, pure information.**
    ///
    /// **It used to appear in a single group only**, and by accident: the provider puts a row
    /// `▁▂▃▄ ULUSAL HEVC` into its Turkish list that looks like a channel and delivers
    /// nothing. It is gone now — and what it did unintentionally, this row does intentionally
    /// and identically everywhere (user request 2026-08-11: a really classic header, info only,
    /// fixed at the top).
    ///
    /// **Outside the scroll area**, so that it stays put while paging, and without focus: what
    /// accepts focus wants to be pressed.
    private func listHeader(_ title: String, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(1)
            Text(app: subtitle)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 46)
        .padding(.top, TVMetrics.topMargin)
        .padding(.bottom, 12)
        .allowsHitTesting(false)
    }

    /// What stands above the channel list: the group, or "All groups".
    private var channelListTitle: String {
        guard let group else {
            return NSLocalizedString(
                "live.allGroups", bundle: AppLanguageSetting.bundles(zu: "live.allGroups"), comment: "")
        }
        return ChannelName.display(group)
    }

    private var channelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            listHeader(channelListTitle, subtitle: "live.channelCount \(channels.count)")
            channelRows
        }
    }

    private var channelRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    edge(Self.topEdgeID)
                    ForEach(channels) { channel in
                        Button {
                            onSelect(channel, channels)
                        } label: {
                            row(channel)
                        }
                        .bareFocusableButton()
                        .focused($focus, equals: channel.id)
                        .id(channel.id)
                    }
                    edge(Self.bottomEdgeID)
                }
                .padding(.vertical, TVMetrics.topMargin)
                .padding(.horizontal, 26)
            }
            .onAppear {
                scroller = proxy
                // On appearing, to where one is standing — not to the start. With a group of a hundred
                // channels, the way back to the running one would otherwise be longer than the benefit of
                // the whole list.
                guard let id = Self.openingRow(current: current, in: channels) else { return }
                jump(to: id)
            }
            .onChange(of: focus) { _, current in
                followFocus(current, in: proxy)
            }
        }
    }

    /// An invisible row at the list edge — the trigger for the wraparound.
    ///
    /// **Why not the key press?** That is how it was built, and on the TV the wraparound did
    /// not occur (viewer finding 2026-08-11). `onMoveCommand` reports only what the focus has
    /// **not** consumed — whether a scrolling list takes the press at its end itself is
    /// decided by tvOS, not by us. A focusable row, in contrast, is a target like any other:
    /// the focus **must** go there, and that it is there can be seen without guessing.
    ///
    /// It is one point high and carries nothing; all that is visible is that the focus
    /// reappears at the other end when pressing on.
    private func edge(_ id: String) -> some View {
        Color.clear
            .frame(height: 1)
            .focusable()
            .focused($focus, equals: id)
            .id(id)
            .accessibilityHidden(true)
    }

    static let topEdgeID = "-rand-oben"
    static let bottomEdgeID = "-rand-unten"

    /// What follows a focus change in a list.
    ///
    /// Two things: the wraparound has to **scroll along** — anyone who leaves at the bottom and
    /// arrives at the top would otherwise see the first row a hundred rows outside the
    /// picture —, and the border rows lead to the other end.
    private func followFocus(_ current: String?, in proxy: ScrollViewProxy) {
        // For the edge-press check of the wraparound: when the focus last really moved — see
        // ``wrap(by:)``.
        focusMovedAt = Date()
        // **The focus is written down, and that is no extra.** Three rounds on this block failed
        // at the same boundary: what tvOS does with a key press cannot be seen from outside, and
        // without sight only guessing remains. The line costs nothing in normal operation — it
        // only exists when diagnostics are switched on.
        Diagnostics.verbose(
            "Overlay \(sideName): focus → \(current ?? "—"), "
                + "\(rowIDs.count) rows, group \(group ?? "all")"
        )
        guard let current else { return }
        onActivity()

        if current == Self.topEdgeID {
            guard let last = rowIDs.last else { return }
            jump(to: last)
            return
        }
        if current == Self.bottomEdgeID {
            guard let first = rowIDs.first else { return }
            jump(to: first)
            return
        }
        proxy.scrollTo(current, anchor: .center)
    }

    private func row(_ channel: Channel) -> some View {
        let isCurrent = channel.id == current?.id
        let isFocused = focus == channel.id

        return HStack(spacing: 14) {
            // The running channel is marked even when the focus is elsewhere: otherwise, while
            // paging, one no longer knows what one started from.
            Circle()
                .fill(isCurrent ? ColorRole.live.color : .clear)
                .frame(width: 10, height: 10)

            Text(verbatim: ChannelName.display(channel.name))
                .font(TypeLevel.footer.font)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            isFocused ? ColorRole.text.color : ColorRole.surface.color.opacity(isCurrent ? 0.9 : 0),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: - Groups

    /// The groups — one level below the channels.
    ///
    /// **This is how one changes the group without leaving playback.** Anyone who wants a
    /// different group today has to go back to the Live area, choose the group there and
    /// reopen the channel — three steps for something that should happen while watching.
    private var groupList: some View {
        VStack(alignment: .leading, spacing: 0) {
            listHeader(
                NSLocalizedString(
                    "live.groups", bundle: AppLanguageSetting.bundles(zu: "live.groups"), comment: ""),
                subtitle: "live.groupCount \(groups.count)"
            )
            groupRows
        }
    }

    private var groupRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    edge(Self.topEdgeID)
                    // **"All" is part of the list** and not a special path beside it: anyone who has chosen a
                    // group must also be able to get out again, and a way back that exists only as a key press
                    // is found by nobody.
                    groupRow(name: nil)
                    ForEach(groups, id: \.self) { name in
                        groupRow(name: name)
                    }
                    edge(Self.bottomEdgeID)
                }
                .padding(.vertical, TVMetrics.topMargin)
                .padding(.horizontal, 26)
            }
            .onAppear {
                scroller = proxy
                jump(to: group.map { Self.groupPrefix + $0 } ?? Self.groupPrefix)
            }
            .onChange(of: focus) { _, current in
                followFocus(current, in: proxy)
            }
        }
    }

    private func groupRow(name: String?) -> some View {
        let id = Self.groupPrefix + (name ?? "")
        let isActive = group == name
        let isFocused = focus == id

        return Button {
            // **Explicitly chosen**, and that holds until the next choice — even across closing the
            // overlay. See ``LiveOverlay/GroupChoice``.
            groupChoice = name.map(GroupChoice.named) ?? .all
            // **Chosen means: back to the channels.** A group is not a destination in itself; one
            // chooses it in order to watch within it.
            onClose()
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(isActive ? ColorRole.live.color : .clear)
                    .frame(width: 10, height: 10)
                Group {
                    if let name {
                        Text(verbatim: ChannelName.display(name))
                    } else {
                        Text(app: "live.allGroups")
                    }
                }
                .font(TypeLevel.footer.font)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                isFocused
                    ? ColorRole.text.color : ColorRole.surface.color.opacity(isActive ? 0.9 : 0),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .id(id)
    }

    // MARK: - Guide

    private var guideList: some View {
        VStack(alignment: .leading, spacing: 18) {
            // **Above the programme it says whose programme it is.** Without this row one reads a
            // list of shows and has to remember which channel is playing — when flipping through, that
            // is no longer clear to anyone after the third switch.
            if let current {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: ChannelName.display(current.name))
                        .font(TypeLevel.header.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(2)
                    if let group = current.group, !group.isEmpty {
                        Text(verbatim: ChannelName.display(group))
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .lineLimit(1)
                    }
                }
            }

            if programmes.isEmpty, !didAnswer {
                // Spinner only **while no answer is there**. Since the programme lies in the cache, it
                // arrives in milliseconds — the spinner is then not visible at all. If it used to stay,
                // that was not loading but a channel without a programme: the provider has none for 89
                // percent of its channels (viewer finding 2026-08-08, "hangs on loading and shows nothing").
                HStack(spacing: 14) {
                    ProgressView()
                    Text(app: "live.guidePending")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
            } else if programmes.isEmpty {
                Text(app: "live.guideNone")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(programmes) { programs in
                                programmeRow(programs)
                                    .id(programs.id)
                            }
                        }
                    }
                    // **Scrolled to the running show, not to the start.** The programme reaches three hours
                    // back; anyone who opens it wants to know what is on **now**, and not first scroll
                    // through the afternoon.
                    //
                    // **By content and not by count.** `programmes.count` was here, and two channels with the
                    // same number of shows produced no change — when flipping through, the view stayed where
                    // the previous channel ended.
                    .onAppear { scroller = proxy }
                    .onChange(of: programmes) { _, _ in
                        scroller = proxy
                        let running = programmes.first { $0.isRunning(at: .now) }
                        guideCursor = running?.id ?? programmes.first?.id
                        guard let id = guideCursor else { return }
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
                // The programme does not accept focus — these are rows and not buttons. Without this
                // statement tvOS would still try to jump in and leave the focus standing in nothing.
                .allowsHitTesting(false)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, TVMetrics.topMargin)
    }

    /// One row of the programme — the running one highlighted.
    ///
    /// **Without an anchor one reads times to find one's bearings** (test report 2026-08-08). The
    /// running show is the only place from which "what is coming next" is a question at all; it
    /// therefore belongs marked and not merely listed.
    private func programmeRow(_ programs: Programme) -> some View {
        let isRunning = programs.isRunning(at: .now)
        // **Over is not the same as "coming next".** Since the programme reaches three hours back,
        // both stand one below the other; without a difference one reads times to see what one
        // has missed.
        let isPast = programs.end <= .now
        let isCursor = guideCursor == programs.id
        let framed = isRunning || isCursor

        return HStack(alignment: .top, spacing: 16) {
            Text(verbatim: Self.clock(programs.start))
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(isRunning ? ColorRole.live.color : ColorRole.textQuiet.color)
                .frame(width: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: programs.title)
                    .font(TypeLevel.footer.font)
                    .fontWeight(isRunning ? .semibold : .regular)
                    .foregroundStyle(rowColour(isRunning: isRunning, isPast: isPast))
                    .lineLimit(2)

                if isRunning {
                    Text(app: "live.nowOnAir")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.live.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, framed ? 14 : 0)
        .padding(.vertical, framed ? 10 : 0)
        .background(
            framed ? ColorRole.surface.color.opacity(isRunning ? 0.9 : 0.55) : .clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(alignment: .leading) {
            // The cursor as a line at the edge, not as a focus frame: it is not a button, and what
            // looks like one wants to be pressed.
            if isCursor, !isRunning {
                Capsule()
                    .fill(ColorRole.text.color)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .offset(x: -8)
            }
        }
    }

    private func rowColour(isRunning: Bool, isPast: Bool) -> Color {
        if isRunning { return ColorRole.text.color }
        return isPast ? ColorRole.textQuiet.color : ColorRole.textMatt.color
    }

    /// "20:15" — in the device's time zone.
    ///
    /// The provider's times arrive as UTC without a marker; conversion happens when parsing,
    /// not here. This place only formats.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
